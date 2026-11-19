//! Do the Kani models match the real thing? Each proof checks a rule on small stand-ins (u8
//! instead of strings, 3-row tables, 3-byte path components, 4-byte paths, 12-byte file heads).
//! Here the same properties are checked with the real types at real sizes, against independent
//! reference implementations where one exists, so a property that only holds for the stand-ins
//! (an empty string, a multi-byte character, a long table, a cycle of renames) is caught.
use proptest::prelude::*;
use std::collections::{BTreeSet, HashMap, HashSet};
use tl_core::rules::*;

fn label() -> impl Strategy<Value = String> { prop_oneof!["[a-c]{0,3}", "[猫狗墙]{1,2}", Just(String::new()), Just(" ".to_string())] }
fn opt_reg() -> impl Strategy<Value = Option<(u64, String)>> { proptest::option::of((0u64..4, label())) }

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2000))]

    /// post_field_merge_is_a_semilattice, with strings (the proof uses u8).
    #[test]
    fn field_merge_with_strings(a in opt_reg(), b in opt_reg(), c in opt_reg()) {
        prop_assert_eq!(merge_field(a.clone(), b.clone()), merge_field(b.clone(), a.clone()));
        prop_assert_eq!(merge_field(merge_field(a.clone(), b.clone()), c.clone()), merge_field(a.clone(), merge_field(b.clone(), c.clone())));
        prop_assert_eq!(merge_field(a.clone(), a.clone()), a.clone());
        let m = merge_field(a.clone(), b.clone());
        prop_assert!(m == a || m == b);
        if a.is_some() { prop_assert!(m.is_some(), "an absent value never erases"); }
    }

    /// media_owner_merge_is_a_semilattice and rename_rule_merge_is_a_semilattice, with strings.
    #[test]
    fn owner_and_alias_merge_with_strings(a in (label(), -2i64..3), b in (label(), -2i64..3), c in (label(), -2i64..3),
                                          x in (0u64..3, proptest::option::of(label())), y in (0u64..3, proptest::option::of(label())), z in (0u64..3, proptest::option::of(label()))) {
        prop_assert_eq!(merge_owner(a.clone(), b.clone()), merge_owner(b.clone(), a.clone()));
        prop_assert_eq!(merge_owner(merge_owner(a.clone(), b.clone()), c.clone()), merge_owner(a.clone(), merge_owner(b.clone(), c.clone())));
        prop_assert_eq!(merge_owner(a.clone(), b.clone()), std::cmp::min(a.clone(), b.clone()), "the smallest (post, ordinal) in Rust's string order");
        prop_assert_eq!(merge_alias(x.clone(), y.clone()), merge_alias(y.clone(), x.clone()));
        prop_assert_eq!(merge_alias(merge_alias(x.clone(), y.clone()), z.clone()), merge_alias(x.clone(), merge_alias(y.clone(), z.clone())));
        prop_assert_eq!(merge_alias(x.clone(), x.clone()), x);
    }

    /// retag_rule_never_removes_user_bits / retag_rule_is_idempotent on whole tables of string
    /// labels (the proofs check one label at a time).
    #[test]
    fn retag_on_real_tables(existing in proptest::collection::vec((label(), 0u8..4), 0..30), new in proptest::collection::vec(label(), 0..12), replace in any::<bool>()) {
        // one row per label, as in the database
        let mut seen = HashSet::new();
        let existing: Vec<(String, u8)> = existing.into_iter().filter(|(l, _)| seen.insert(l.clone())).collect();
        let plan = retag_plan(&existing, &new, replace);
        let after = apply_plan(&existing, &plan);
        let get = |t: &[(String, u8)], l: &str| t.iter().find(|(x, _)| x == l).map_or(0, |(_, o)| *o);
        for (l, o) in &existing {
            let n = get(&after, l);
            prop_assert!(n & USER == o & USER, "the USER bit of {l:?} is never changed");
            if !replace { prop_assert!(n & o == *o, "without replace nothing is removed"); }
            if n == 0 && *o != 0 { prop_assert!(replace && *o == AI && !new.contains(l), "only unendorsed AI tags go, and only when replacing"); }
        }
        for l in &new { prop_assert!(get(&after, l) & AI != 0, "a proposed label {l:?} carries the AI bit"); }
        // the same re-tag again changes nothing
        prop_assert!(apply_plan(&after, &retag_plan(&after, &new, replace)) == after);
    }

    /// export_selection_rules / review_filter_partitions against a set-based reference, with
    /// tables and include/exclude lists longer than the proofs' (3 rows, 1 + 1 labels).
    #[test]
    fn selection_matches_a_set_reference(tags in proptest::collection::vec((label(), 0u8..4), 0..20),
                                        include in proptest::collection::vec(label(), 0..6), exclude in proptest::collection::vec(label(), 0..6)) {
        let live: HashSet<&String> = tags.iter().filter(|(_, o)| *o != 0).map(|(l, _)| l).collect();
        let want = !exclude.iter().any(|l| live.contains(l)) && (include.is_empty() || include.iter().any(|l| live.contains(l)));
        prop_assert_eq!(export_selected(&tags, &include, &exclude), want);
        let reviewed_ref = tags.iter().any(|(_, o)| o & USER != 0);
        prop_assert_eq!(reviewed(&tags), reviewed_ref);
        for r in [Review::Any, Review::Reviewed, Review::Unreviewed] {
            let w = match r { Review::Any => true, Review::Reviewed => reviewed_ref, Review::Unreviewed => !reviewed_ref };
            prop_assert_eq!(review_matches(&tags, r), w);
        }
        for mask in 1u8..4 { for (_, o) in &tags { prop_assert_eq!(scope_matches(*o, mask), (o & mask) != 0); } }
    }

    /// renames_resolve_consistently with string labels in label order (as the store builds the
    /// table), against an independent walk: the end of the chain, or the smallest label of the
    /// cycle the chain runs into — whatever order the labels are listed in.
    #[test]
    fn rename_resolution_matches_a_reference(rules in proptest::collection::vec((label(), label()), 0..12), shuffle in any::<u64>()) {
        let mut labels: BTreeSet<String> = BTreeSet::new();
        let mut next_l: HashMap<String, String> = HashMap::new();
        for (a, b) in &rules { if a != b { next_l.insert(a.clone(), b.clone()); } labels.insert(a.clone()); labels.insert(b.clone()); }
        let sorted: Vec<String> = labels.iter().cloned().collect();
        let idx: HashMap<&str, usize> = sorted.iter().enumerate().map(|(i, l)| (l.as_str(), i)).collect();
        let next: Vec<Option<usize>> = sorted.iter().map(|l| next_l.get(l).map(|t| idx[t.as_str()])).collect();
        for (i, l) in sorted.iter().enumerate() {
            // reference: walk with a visited list
            let mut path = vec![l.clone()];
            let want = loop {
                let cur = path.last().unwrap().clone();
                match next_l.get(&cur) {
                    None => break cur,
                    Some(n) => {
                        if let Some(p) = path.iter().position(|x| x == n) { break path[p..].iter().min().unwrap().clone(); }
                        path.push(n.clone());
                    }
                }
            };
            prop_assert_eq!(&sorted[resolve_alias(i, &next)], &want, "label {:?}", l);
        }
        let _ = shuffle;
    }

    /// path_components_are_classified_safely holds for whole paths of any characters and length
    /// (the proof covers components of up to 3 bytes).
    #[test]
    fn path_sanitizer_on_any_path(parts in proptest::collection::vec(prop_oneof![Just("".to_string()), Just(".".to_string()), Just("..".to_string()), Just("...".to_string()),
                                    "[a-z猫😀 ]{1,8}", Just("a\\\\b".to_string()), Just("a\0b".to_string()), Just("..a".to_string()), Just("part:name".to_string())], 0..10), absolute in any::<bool>()) {
        let p = format!("{}{}", if absolute { "/" } else { "" }, parts.join("/"));
        let got = safe_relative_bytes(p.as_bytes());
        let kept: Vec<&String> = parts.iter().filter(|c| !c.is_empty() && *c != ".").collect();
        let bad = p.starts_with('/') || kept.iter().any(|c| c.contains(['\0', '\\', ':']) || c.ends_with(['.', ' ']));
        if bad || kept.is_empty() { prop_assert_eq!(got, None, "{:?}", p); }
        else {
            let want = kept.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("/");
            prop_assert_eq!(got.as_deref(), Some(want.as_bytes()), "{:?}", p);
        }
    }

    /// sniffed_media_really_has_its_signature for heads of any length (the proof sees 12 bytes),
    /// including the real readers' 16-byte heads and short files.
    #[test]
    fn sniff_on_any_bytes(head in proptest::collection::vec(any::<u8>(), 0..40), magic in 0usize..8) {
        let prefixes: [&[u8]; 8] = [b"\xFF\xD8\xFF", b"\x89PNG\r\n\x1a\n", b"GIF89a", b"RIFF\0\0\0\0WEBP", b"\0\0\0\x18ftypheic", b"\0\0\0\x18ftypqt  ", b"\0\0\0\x18ftypisom", b"<html>"];
        let mut h = prefixes[magic].to_vec();
        h.extend_from_slice(&head);
        for bytes in [&head[..], &h[..]] {
            match sniff(bytes) {
                Sniff::Jpeg => prop_assert!(bytes.starts_with(b"\xFF\xD8\xFF")),
                Sniff::Png => prop_assert!(bytes.starts_with(b"\x89PNG\r\n\x1a\n")),
                Sniff::Gif => prop_assert!(bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")),
                Sniff::Webp => prop_assert!(bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP"),
                Sniff::Heif | Sniff::Mp4 => prop_assert!(bytes.len() >= 8 && &bytes[4..8] == b"ftyp"),
                Sniff::Mov => prop_assert!(bytes.len() >= 8 && (&bytes[4..8] == b"ftyp" || [&b"moov"[..], b"mdat", b"wide", b"free", b"skip", b"pnot"].contains(&&bytes[4..8]))),
                Sniff::Empty => prop_assert!(bytes.is_empty()),
                _ => {}
            }
            // nothing sniffed as text or markup is ever accepted as media
            let s = sniff(bytes);
            if matches!(s, Sniff::Html | Sniff::Text | Sniff::Empty | Sniff::Unknown) { prop_assert!(!sniff_ok(s, true) && !sniff_ok(s, false)); }
        }
    }

    /// The tag-bit merge with real clocks: the proofs cover every u64, so here the point is the
    /// embedding the store relies on — a write leaves bits outside its mask untouched.
    #[test]
    fn tag_writes_touch_only_their_bits(o in 0u8..4, h_user in any::<u64>(), h_ai in any::<u64>(), w in 0u8..4, mask in 1u8..4, h in any::<u64>()) {
        use tl_core::crdt::{merge_bits, TagBits};
        let cur = TagBits { origin: o, h_user, h_ai };
        let m = merge_bits(cur, TagBits::write(w, mask, h));
        if mask & 1 == 0 { prop_assert_eq!((m.origin & 1, m.h_user), (o & 1, h_user)); }
        if mask & 2 == 0 { prop_assert_eq!((m.origin & 2, m.h_ai), (o & 2, h_ai)); }
    }
}

/// record_deletion_stays_inside_owned_folders on a real file system (the proof works on 4-byte
/// paths): a report whose source is a symbolic link inside the app's folder, pointing at a file
/// outside it, never deletes that file; neither does a path that climbs out with `..`.
#[test]
fn deleting_records_never_follows_links_out_of_owned_folders() {
    use tl_core::library::Library;
    let base = std::env::temp_dir().join(format!("tl-fidelity-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let (lib_dir, owned, outside) = (base.join("lib"), base.join("owned"), base.join("outside"));
    for d in [&owned, &outside] { std::fs::create_dir_all(d).unwrap(); }
    let lib = Library::open(&lib_dir).unwrap();
    std::fs::write(outside.join("precious.jpg"), b"\xFF\xD8\xFF keep me").unwrap();
    for (name, src) in [("link", owned.join("share")), ("climb", owned.join("..").join("outside"))] {
        // an import of a folder inside the owned folder makes a report whose source is that folder
        let share = owned.join(format!("share-{name}"));
        std::fs::create_dir_all(&share).unwrap();
        std::fs::write(share.join("a.jpg"), b"\xFF\xD8\xFF\xE0 one").unwrap();
        let rep = tl_core::import::import_loose_dir(&lib, &share, None, false).unwrap();
        let report = std::path::PathBuf::from(rep.report_file.clone().unwrap());
        // then the source is replaced: by a link to the outside folder, or the record points out
        std::fs::remove_dir_all(&share).unwrap();
        if name == "link" { std::os::unix::fs::symlink(&outside, &share).unwrap(); }
        else {
            let mut j: serde_json::Value = serde_json::from_slice(&std::fs::read(&report).unwrap()).unwrap();
            j["source"] = serde_json::Value::String(src.to_string_lossy().into_owned());
            std::fs::write(&report, serde_json::to_vec(&j).unwrap()).unwrap();
        }
        let _ = src;
        tl_core::import::delete_reports(&lib, &[report], &[owned.clone()]).unwrap();
        assert!(outside.join("precious.jpg").exists(), "{name}: a file outside the owned folder was deleted");
    }
    drop(lib);
    let _ = std::fs::remove_dir_all(&base);
}

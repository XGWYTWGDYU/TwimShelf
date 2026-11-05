//! Property tests: replicas that exchange op logs in any order converge to identical state,
//! and the re-tag rules hold at the database level.
use proptest::prelude::*;
use tl_core::model::{MediaKind, Origin, PostMeta};
use tl_core::oplog::VersionVector;
use tl_core::rules::{Review, TrashAction, TrashReg};
use tl_core::store::Store;

#[derive(Debug, Clone)]
enum Edit {
    Tag { media: u8, label: u8, ai: bool },
    Untag { media: u8, label: u8 },
    Retag { media: u8, model: u8, labels: Vec<u8>, replace: bool },
    /// (Re-)import of a post with possibly different text / link / author (None = field absent).
    ImportPost { post: u8, text: Option<u8>, url: Option<u8>, author: Option<u8> },
    /// The same file claimed by a post at an ordinal (duplicates across posts).
    ClaimMedia { media: u8, post: u8, ordinal: u8 },
    /// Recycle bin: 0 = move to bin, 1 = restore, 2 = delete permanently.
    Bin { media: u8, action: u8 },
    /// Explicit re-download of a post containing the media (brings it back even after deletion).
    Reimport { media: u8 },
    /// Rename a tag (or merge it into another), and undo a rename.
    Rename { from: u8, to: u8 },
    UndoRename { label: u8 },
    /// Folders: create, delete, add or remove a media.
    FolderCreate { f: u8 },
    FolderDelete { f: u8 },
    FolderAdd { f: u8, media: u8 },
    FolderRemove { f: u8, media: u8 },
    /// "最近添加" mark of a post at a time (any order of marks converges to the latest).
    Recent { post: u8, at: u8 },
    /// Local clean-up of tag names nothing refers to (never an op, never visible).
    GcTags,
}

fn edit() -> impl Strategy<Value = Edit> {
    prop_oneof![
        (0..3u8, 0..4u8, any::<bool>()).prop_map(|(media, label, ai)| Edit::Tag { media, label, ai }),
        (0..3u8, 0..4u8).prop_map(|(media, label)| Edit::Untag { media, label }),
        (0..3u8, 0..2u8, proptest::collection::vec(0..4u8, 0..3), any::<bool>())
            .prop_map(|(media, model, labels, replace)| Edit::Retag { media, model, labels, replace }),
        (0..3u8, proptest::option::of(0..3u8), proptest::option::of(0..3u8), proptest::option::of(0..2u8))
            .prop_map(|(post, text, url, author)| Edit::ImportPost { post, text, url, author }),
        (0..4u8, 0..3u8, 0..3u8).prop_map(|(media, post, ordinal)| Edit::ClaimMedia { media, post, ordinal }),
        (0..3u8, 0..3u8).prop_map(|(media, action)| Edit::Bin { media, action }),
        (0..3u8).prop_map(|media| Edit::Reimport { media }),
        (0..4u8, 0..5u8).prop_map(|(from, to)| Edit::Rename { from, to }),
        (0..5u8).prop_map(|label| Edit::UndoRename { label }),
        (0..2u8).prop_map(|f| Edit::FolderCreate { f }),
        (0..2u8).prop_map(|f| Edit::FolderDelete { f }),
        (0..2u8, 0..3u8).prop_map(|(f, media)| Edit::FolderAdd { f, media }),
        (0..2u8, 0..3u8).prop_map(|(f, media)| Edit::FolderRemove { f, media }),
        (0..3u8, 0..5u8).prop_map(|(post, at)| Edit::Recent { post, at }),
        Just(Edit::GcTags),
    ]
}

fn replica() -> Store {
    let s = Store::open(":memory:").unwrap();
    for p in 0..3 { s.upsert_post(&PostMeta { id: format!("p{p}"), ..Default::default() }).unwrap(); }
    for m in 0..3 { s.add_media(&format!("{m:064}"), "p0", m, &MediaKind::Photo, &format!("blobs/00/{m:064}.jpg"), false).unwrap(); }
    s
}

fn run(s: &Store, e: &Edit) {
    let mid = |m: u8| format!("{m:064}");
    let lab = |l: u8| format!("l{l}");
    match e {
        Edit::Tag { media, label, ai } => s.tag_media(&mid(*media), &lab(*label), if *ai { Origin::AI } else { Origin::USER }).unwrap(),
        Edit::Untag { media, label } => s.untag_media(&mid(*media), &lab(*label)).unwrap(),
        Edit::Retag { media, model, labels, replace } => {
            let ls: Vec<String> = labels.iter().map(|l| lab(*l)).collect();
            s.retag(&mid(*media), &format!("m{model}"), &ls, *replace).unwrap()
        }
        Edit::ImportPost { post, text, url, author } => s.upsert_post(&PostMeta {
            id: format!("p{post}"), text: text.map(|t| format!("正文{t}")), url: url.map(|u| format!("https://x.com/a/status/{u}")),
            author_name: author.map(|a| format!("作者{a}")), ..Default::default() }).unwrap(),
        Edit::Bin { media, action } => {
            let a = [TrashAction::Trash, TrashAction::Restore, TrashAction::Purge][*action as usize];
            s.trash_action(&mid(*media), a).unwrap();
        }
        Edit::Rename { from, to } => { s.rename_tag(&lab(*from), &lab(*to)).unwrap(); }
        Edit::UndoRename { label } => s.undo_rename(&lab(*label)).unwrap(),
        Edit::FolderCreate { f } => { s.create_folder(&format!("文件夹{f}")).unwrap(); }
        Edit::FolderDelete { f } => s.delete_folder(&format!("文件夹{f}")).unwrap(),
        Edit::FolderAdd { f, media } => { s.add_to_folder(&format!("文件夹{f}"), &[mid(*media)]).unwrap(); }
        Edit::FolderRemove { f, media } => { s.remove_from_folder(&format!("文件夹{f}"), &[mid(*media)]).unwrap(); }
        Edit::Reimport { media } => { s.add_media(&mid(*media), "p0", *media as i64, &MediaKind::Photo, &format!("blobs/00/{}.jpg", mid(*media)), true).unwrap(); }
        Edit::GcTags => { s.gc_dead_tags().unwrap(); }
        Edit::Recent { post, at } => s.mark_recent(&format!("p{post}"), 1_700_000_000_000 + *at as u64 * 3_600_000).unwrap(),
        Edit::ClaimMedia { media, post, ordinal } => s.add_media(&mid(*media), &format!("p{post}"), *ordinal as i64, &MediaKind::Photo, &format!("blobs/00/{}.jpg", mid(*media)), false).map(|_| ()).unwrap(),
    }
}

/// Observable state: tags with origins and sources, plus analysed-by records.
fn state(s: &Store) -> Vec<String> {
    let mut v = vec![];
    let mut st = s.conn().prepare("SELECT tm.media_id, t.label, tm.origin FROM tag_media tm JOIN tag t ON t.id=tm.tag_id ORDER BY 1,2").unwrap();
    for r in st.query_map([], |r| Ok(format!("T {} {} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))).unwrap() { v.push(r.unwrap()); }
    let mut st = s.conn().prepare("SELECT s.media_id, t.label, s.model, s.present FROM tag_src s JOIN tag t ON t.id=s.tag_id ORDER BY 1,2,3").unwrap();
    for r in st.query_map([], |r| Ok(format!("S {} {} {} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?))).unwrap() { v.push(r.unwrap()); }
    let mut st = s.conn().prepare("SELECT id, coalesce(author_name,'-'), coalesce(text,'-'), coalesce(url,'-') FROM post ORDER BY 1").unwrap();
    for r in st.query_map([], |r| Ok(format!("P {} {} {} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?))).unwrap() { v.push(r.unwrap()); }
    let mut st = s.conn().prepare("SELECT id, post_id, ordinal FROM media ORDER BY 1").unwrap();
    for r in st.query_map([], |r| Ok(format!("M {} {} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))).unwrap() { v.push(r.unwrap()); }
    let mut st = s.conn().prepare("SELECT media_id, inc, state, hlc FROM trash ORDER BY 1").unwrap();
    for r in st.query_map([], |r| Ok(format!("B {} {} {} {}", r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, i64>(3)?))).unwrap() { v.push(r.unwrap()); }
    // what the app shows: tags under their current names, and the rename rules
    for m in 0..4u8 {
        let id = format!("{m:064}");
        let t: Vec<String> = s.media_tags(&id).unwrap().into_iter().filter(|(_, o)| *o != 0).map(|(l, o)| format!("{l}:{o}")).collect();
        v.push(format!("E {} {}", m, t.join(",")));
    }
    v.push(format!("R {:?}", s.renames().unwrap()));
    v.push(format!("F {:?}", s.folders().unwrap()));
    for m in 0..4u8 { v.push(format!("FM {} {:?}", m, s.folders_of(&format!("{m:064}")).unwrap())); }
    let mut st = s.conn().prepare("SELECT src, coalesce(dst,'-'), hlc FROM tag_alias ORDER BY 1").unwrap();
    for r in st.query_map([], |r| Ok(format!("AL {} {} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))).unwrap() { v.push(r.unwrap()); }
    // what the feed shows
    let mut ids: Vec<String> = s.feed_filtered(&[], &[], tl_core::model::SearchScope::Both, Default::default(), &Default::default()).unwrap().into_iter().map(|i| i.media_id).collect();
    ids.sort();
    v.push(format!("V {}", ids.join(",")));
    for p in 0..3u8 { v.push(format!("RA p{} {}", p, s.recent_at(&format!("p{p}")).unwrap())); }
    let mut st = s.conn().prepare("SELECT media_id, model FROM ai_done ORDER BY 1,2").unwrap();
    for r in st.query_map([], |r| Ok(format!("A {} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?))).unwrap() { v.push(r.unwrap()); }
    v
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// Three devices edit concurrently; exchanging logs pairwise in any order converges.
    #[test]
    fn replicas_converge(edits in proptest::collection::vec((0..3usize, edit()), 1..24), order in proptest::collection::vec((0..3usize, 0..3usize), 1..10)) {
        let reps = [replica(), replica(), replica()];
        for (who, e) in &edits { run(&reps[*who], e); }
        let sync = |a: &Store, b: &Store| {
            let ops = a.ops_since(&b.version_vector().unwrap(), 100_000).unwrap();
            b.apply_remote(&ops, |_, _| true).unwrap();
        };
        for (a, b) in &order { if a != b { sync(&reps[*a], &reps[*b]); } }
        // finish with a full round so everyone has everything
        for a in 0..3 { for b in 0..3 { if a != b { sync(&reps[a], &reps[b]); } } }
        let s0 = state(&reps[0]);
        prop_assert_eq!(&s0, &state(&reps[1]));
        prop_assert_eq!(&s0, &state(&reps[2]));
        // the recycle-bin register is the merge (maximum) of every recorded bin write
        let all = reps[0].ops_since(&VersionVector::new(), 100_000).unwrap();
        for m in 0..4u8 {
            let id = format!("{m:064}");
            let expect = all.iter().filter_map(|o| match &o.op {
                tl_core::oplog::Op::Trash { media_id, inc, state, hlc } if *media_id == id => Some(TrashReg { inc: *inc, state: *state, hlc: *hlc }),
                _ => None }).fold(TrashReg::default(), tl_core::rules::merge_trash);
            prop_assert_eq!(reps[0].trash_reg(&id).unwrap(), expect);
        }
        // re-applying everything is a no-op (idempotence at the store level)
        prop_assert_eq!(reps[1].apply_remote(&all, |_, _| true).unwrap(), 0);
        prop_assert_eq!(&s0, &state(&reps[1]));
    }

    /// The SQL filters (review state, exact tags) agree with the pure rules on every media.
    #[test]
    fn sql_filters_agree_with_rules(pre in proptest::collection::vec(edit(), 0..16), label in 0..4u8) {
        let s = replica();
        for e in &pre { run(&s, e); }
        let feed = |f: tl_core::library::FeedFilter| -> Vec<String> {
            let mut v: Vec<String> = s.feed_filtered(&[], &[], tl_core::model::SearchScope::Both, Default::default(), &f).unwrap().into_iter().map(|i| i.media_id).collect();
            v.sort(); v
        };
        let live = feed(Default::default());
        for (rv, name) in [(Review::Unreviewed, "unreviewed"), (Review::Reviewed, "reviewed")] {
            let got = feed(tl_core::library::FeedFilter { review: rv, ..Default::default() });
            let want: Vec<String> = live.iter().filter(|m| tl_core::rules::review_matches(&s.media_tags(m).unwrap(), rv)).cloned().collect();
            prop_assert_eq!(got, want, "{} filter", name);
        }
        let got = feed(tl_core::library::FeedFilter { labels: vec![format!("l{label}")], ..Default::default() });
        let want: Vec<String> = live.iter().filter(|m| s.media_tags(m).unwrap().iter().any(|(l, o)| *l == format!("l{label}") && *o != 0)).cloned().collect();
        prop_assert_eq!(got, want, "exact tag filter");
        // tag search in each scope agrees with rules::scope_matches (the SQL uses `origin & mask`)
        let l = format!("l{label}");
        for (scope, mask) in [(tl_core::model::SearchScope::Mine, 1u8), (tl_core::model::SearchScope::Ai, 2), (tl_core::model::SearchScope::Both, 3)] {
            let mut got: Vec<String> = s.feed_filtered(&[vec![l.clone()]], &[l.clone()], scope, Default::default(), &Default::default()).unwrap()
                .into_iter().map(|i| i.media_id).collect();
            got.sort(); got.dedup();
            let want: Vec<String> = live.iter().filter(|m| s.media_tags(m).unwrap().iter()
                .any(|(t, o)| *t == l && tl_core::rules::scope_matches(*o, mask))).cloned().collect();
            prop_assert_eq!(got, want, "tag search, scope {:?}", scope);
        }
        // the export's media lookup never includes media outside the live set
        let sel: Vec<String> = s.export_items(&[], &[]).unwrap().into_iter().map(|i| i.media_id).collect();
        for m in &sel { prop_assert!(live.contains(m)); }
        prop_assert_eq!(sel.len(), live.len());
    }

    /// The latest import of a post wins for every field it carries; absent fields never erase.
    #[test]
    fn latest_import_wins_and_absent_fields_never_erase(t1 in 0..3u8, t2 in 0..3u8) {
        let s = replica();
        run(&s, &Edit::ImportPost { post: 1, text: Some(t1), url: Some(1), author: None });
        run(&s, &Edit::ImportPost { post: 1, text: Some(t2), url: None, author: Some(0) });
        let (text, url, author): (String, String, String) = s.conn().query_row("SELECT text, url, author_name FROM post WHERE id='p1'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
        prop_assert_eq!(text, format!("正文{t2}"));
        prop_assert_eq!(url, "https://x.com/a/status/1".to_string(), "absent url kept the old one");
        prop_assert_eq!(author, "作者0".to_string());
    }

    /// Re-tagging never strips the user's bit from any tag.
    #[test]
    fn retag_preserves_user_bits(pre in proptest::collection::vec(edit(), 0..12), labels in proptest::collection::vec(0..4u8, 0..4), replace in any::<bool>()) {
        let s = replica();
        for e in &pre { run(&s, e); }
        let before: Vec<(String, u8)> = s.media_tags(&format!("{:064}", 0)).unwrap();
        run(&s, &Edit::Retag { media: 0, model: 9, labels: labels.clone(), replace });
        let after: Vec<(String, u8)> = s.media_tags(&format!("{:064}", 0)).unwrap();
        for (l, o) in &before {
            let a = after.iter().find(|(x, _)| x == l).map_or(0, |(_, o)| *o);
            if o & 1 != 0 { prop_assert!(a & 1 != 0, "user bit of {} lost", l); }
            if !replace { prop_assert_eq!(a & o, *o); }
        }
        for l in &labels {
            let name = s.canonical(&format!("l{l}")).unwrap();   // proposed names are shown under their current name
            let a = after.iter().find(|(x, _)| *x == name).map_or(0, |(_, o)| *o);
            prop_assert!(a & 2 != 0);
        }
    }
}

fn eff(s: &Store, m: u8) -> Vec<(String, u8)> { s.media_tags(&format!("{m:064}")).unwrap().into_iter().filter(|(_, o)| *o != 0).collect() }
fn sync_all(reps: &[&Store]) {
    for a in reps { for b in reps {
        if std::ptr::eq(*a, *b) { continue; }
        let ops = a.ops_since(&b.version_vector().unwrap(), 100_000).unwrap();
        b.apply_remote(&ops, |_, _| true).unwrap();
    } }
}

/// A rename on one device while an AI tagging run on another keeps writing the old name:
/// after sync every device shows only the new name, on every media, and the rename can be undone.
#[test]
fn rename_during_ai_tagging_on_another_device() {
    let (a, b) = (replica(), replica());
    sync_all(&[&a, &b]);
    a.retag(&format!("{:064}", 0), "m", &["墙".into()], false).unwrap();
    sync_all(&[&a, &b]);
    // B renames 墙 → 白墙 while A (not yet synced) keeps tagging with the old name
    b.rename_tag("墙", "白墙").unwrap();
    a.retag(&format!("{:064}", 1), "m", &["墙".into(), "室内".into()], false).unwrap();
    a.tag_media(&format!("{:064}", 2), "墙", tl_core::model::Origin::USER).unwrap();
    sync_all(&[&a, &b]);
    for s in [&a, &b] {
        for m in 0..3 { assert!(eff(s, m).iter().all(|(l, _)| l != "墙"), "old name never shown: {:?}", eff(s, m)); }
        assert_eq!(eff(s, 0), vec![("白墙".to_string(), 2)]);
        assert!(eff(s, 1).contains(&("白墙".to_string(), 2)) && eff(s, 1).contains(&("室内".to_string(), 2)));
        assert_eq!(eff(s, 2), vec![("白墙".to_string(), 1)]);
        let all = s.all_tags().unwrap();
        assert_eq!(all.iter().find(|t| t.label == "白墙").map(|t| t.count), Some(3));
        assert!(all.iter().all(|t| t.label != "墙"));
        // the AI keeps using the new name after sync
        s.retag(&format!("{:064}", 1), "m2", &["墙".into()], false).unwrap();
        assert!(s.tag_sources(&format!("{:064}", 1), "白墙").unwrap().contains(&"m2".to_string()));
    }
    sync_all(&[&a, &b]);
    // undo on A: the old name is back everywhere
    a.undo_rename("墙").unwrap();
    sync_all(&[&a, &b]);
    for s in [&a, &b] { assert!(eff(s, 0).iter().any(|(l, _)| l == "墙"), "undo restores the old name"); }
}

/// Deleting a tag on one device removes it (also under its old name, and whoever added it)
/// from every media on every device; other tags stay.
#[test]
fn deleting_a_tag_removes_it_everywhere() {
    let (a, b) = (replica(), replica());
    a.retag(&format!("{:064}", 0), "m", &["墙".into(), "室内".into()], false).unwrap();
    a.tag_media(&format!("{:064}", 1), "墙", tl_core::model::Origin::USER).unwrap();
    b.tag_media(&format!("{:064}", 2), "墙", tl_core::model::Origin::USER).unwrap();
    sync_all(&[&a, &b]);
    b.rename_tag("墙", "白墙").unwrap();
    sync_all(&[&a, &b]);
    // deleted by its old name on A
    assert_eq!(a.delete_label("墙").unwrap(), 3);
    sync_all(&[&a, &b]);
    for s in [&a, &b] {
        for m in 0..3 { assert!(eff(s, m).iter().all(|(l, _)| l != "白墙" && l != "墙"), "gone: {:?}", eff(s, m)); }
        assert_eq!(eff(s, 0), vec![("室内".to_string(), 2)], "other tags stay");
        assert!(s.all_tags().unwrap().iter().all(|t| t.label != "白墙"));
    }
    assert_eq!(a.delete_label("白墙").unwrap(), 0, "nothing left to delete");
}

/// Removing all AI tags on one device: AI-only tags go everywhere, endorsed ones stay as mine,
/// tags I added stay, and no model provenance is left.
#[test]
fn removing_ai_tags_keeps_mine_everywhere() {
    let (a, b) = (replica(), replica());
    a.retag(&format!("{:064}", 0), "m", &["墙".into(), "室内".into()], false).unwrap();
    a.tag_media(&format!("{:064}", 0), "墙", tl_core::model::Origin::USER).unwrap();     // endorsed
    b.tag_media(&format!("{:064}", 1), "猫", tl_core::model::Origin::USER).unwrap();     // mine only
    b.retag(&format!("{:064}", 1), "m", &["狗".into()], false).unwrap();                 // AI only
    sync_all(&[&a, &b]);
    assert_eq!(b.remove_ai_tags().unwrap(), 3);
    sync_all(&[&a, &b]);
    for s in [&a, &b] {
        assert_eq!(eff(s, 0), vec![("墙".to_string(), 1)], "endorsed stays as mine, AI-only goes");
        assert_eq!(eff(s, 1), vec![("猫".to_string(), 1)]);
        assert!(s.tag_sources(&format!("{:064}", 0), "墙").unwrap().is_empty(), "no model provenance left");
    }
    assert_eq!(a.remove_ai_tags().unwrap(), 0, "nothing left");
}

/// Two devices rename in opposite directions at the same time: both settle on one name.
#[test]
fn concurrent_opposite_renames_converge() {
    let (a, b) = (replica(), replica());
    a.tag_media(&format!("{:064}", 0), "猫", tl_core::model::Origin::USER).unwrap();
    a.tag_media(&format!("{:064}", 1), "猫咪", tl_core::model::Origin::AI).unwrap();
    sync_all(&[&a, &b]);
    a.rename_tag("猫", "猫咪").unwrap();
    b.rename_tag("猫咪", "猫").unwrap();
    sync_all(&[&a, &b]);
    let (ea, eb) = ((eff(&a, 0), eff(&a, 1)), (eff(&b, 0), eff(&b, 1)));
    assert_eq!(ea, eb);
    assert_eq!(ea.0[0].0, ea.1[0].0, "both media show the same single name");
}

/// A v3 database (no per-field clocks) upgrades in place without losing anything.
#[test]
fn v3_database_migrates_in_place() {
    let dir = std::env::temp_dir().join(format!("tl-mig-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("db.sqlite");
    {
        let s = Store::open(path.to_str().unwrap()).unwrap();
        s.upsert_post(&PostMeta { id: "keep".into(), text: Some("原文".into()), ..Default::default() }).unwrap();
        s.add_media(&format!("{:064}", 7), "keep", 0, &MediaKind::Photo, "blobs/00/x.jpg", false).unwrap();
        s.tag_media(&format!("{:064}", 7), "猫", Origin::USER).unwrap();
        s.conn().execute_batch("ALTER TABLE post DROP COLUMN h_author; ALTER TABLE post DROP COLUMN h_screen; ALTER TABLE post DROP COLUMN h_text;
            ALTER TABLE post DROP COLUMN h_created; ALTER TABLE post DROP COLUMN h_url; PRAGMA user_version=3;").unwrap();
    }
    let s = Store::open(path.to_str().unwrap()).unwrap();
    let text: String = s.conn().query_row("SELECT text FROM post WHERE id='keep'", [], |r| r.get(0)).unwrap();
    assert_eq!(text, "原文");
    assert_eq!(s.conn().query_row("SELECT count(*) FROM media", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
    assert_eq!(s.media_tags(&format!("{:064}", 7)).unwrap(), vec![("猫".to_string(), 1)]);
    s.upsert_post(&PostMeta { id: "keep".into(), text: Some("新正文".into()), ..Default::default() }).unwrap();
    let text: String = s.conn().query_row("SELECT text FROM post WHERE id='keep'", [], |r| r.get(0)).unwrap();
    assert_eq!(text, "新正文");
    std::fs::remove_dir_all(&dir).unwrap();
}


/// A device on an older app version receives a record of a kind it does not know (a newer
/// version made it): sync does not fail; the record is kept, passed on unchanged to a third
/// device, and applied as soon as the device understands it. A record of a known kind that is
/// malformed still fails loudly.
#[test]
fn records_from_a_newer_version_are_kept_and_passed_on() {
    use tl_core::oplog::{LoggedOp, Op};
    let newer = r#"{"device":"dev-new","seq":1,"op":{"t":"somethingnew","x":1,"label":"未来"}}"#;
    let lo: LoggedOp = serde_json::from_str(newer).unwrap();
    assert!(matches!(lo.op, Op::Unknown(_)));
    let old = replica();
    assert_eq!(old.apply_remote(&[lo.clone()], |_, _| true).unwrap(), 1);
    assert_eq!(old.pending_op_count().unwrap(), 1);
    assert_eq!(old.stats().unwrap().newer_ops, 1);
    // passed on exactly as it arrived
    let out = old.ops_since(&VersionVector::new(), 100).unwrap();
    let relayed = out.iter().find(|o| o.device == "dev-new").unwrap();
    assert_eq!(serde_json::to_value(relayed).unwrap(), serde_json::from_str::<serde_json::Value>(newer).unwrap());
    let third = replica();
    third.apply_remote(&out, |_, _| true).unwrap();
    assert_eq!(third.ops_since(&VersionVector::new(), 100).unwrap().iter().filter(|o| o.device == "dev-new").count(), 1);
    // re-delivery is idempotent
    assert_eq!(old.apply_remote(&[lo], |_, _| true).unwrap(), 0);
    // "after the update": a pending record whose kind is now known gets applied
    let s = replica();
    let known = LoggedOp { device: "dev-x".into(), seq: 1, op: Op::Recent { post_id: "p1".into(), at: 42 } };
    s.conn().execute("INSERT INTO op VALUES('dev-x', 1, ?1)", [serde_json::to_string(&tl_core::oplog::op_value(&known.op)).unwrap()]).unwrap();
    s.conn().execute("INSERT INTO op_pending VALUES('dev-x', 1)", []).unwrap();
    assert_eq!(s.retry_pending_ops(|_, _| true).unwrap(), 1);
    assert_eq!(s.recent_at("p1").unwrap(), 42);
    assert_eq!(s.pending_op_count().unwrap(), 0);
    // a known kind with broken fields is an error, never skipped
    assert!(serde_json::from_str::<LoggedOp>(r#"{"device":"d","seq":1,"op":{"t":"tag","media_id":5}}"#).is_err());
    // every kind this version writes is in the known list (so nothing of ours is ever "unknown")
    let samples = [Op::Album { media_id: "m".into() }, Op::Recent { post_id: "p".into(), at: 1 }, Op::AiDone { media_id: "m".into(), model: "x".into() },
        Op::Folder { name: "f".into(), deleted: false, hlc: 1 }, Op::FolderMedia { folder: "f".into(), media_id: "m".into(), present: true, hlc: 1 },
        Op::Alias { src: "a".into(), dst: None, hlc: 1 }, Op::Trash { media_id: "m".into(), inc: 0, state: 0, hlc: 1 },
        Op::TagSrc { media_id: "m".into(), label: "l".into(), model: "x".into(), present: true, hlc: 1 }, Op::Tag { media_id: "m".into(), label: "l".into(), origin: 1, mask: 3, hlc: 1 },
        Op::Media { id: "m".into(), post_id: "p".into(), ordinal: 0, kind: MediaKind::Photo, ext: "jpg".into() }, Op::Post { meta: PostMeta::default(), hlc: 1 }, Op::Setting { key: "k".into(), value: None, hlc: 1 }];
    for o in samples {
        let t = tl_core::oplog::op_value(&o)["t"].as_str().unwrap().to_string();
        assert!(tl_core::oplog::KNOWN_OPS.contains(&t.as_str()), "{t} missing from KNOWN_OPS");
    }
    assert_eq!(tl_core::oplog::KNOWN_OPS.len(), 12, "one entry per kind");
}


proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]
    /// A tag exists for the user exactly while some media in the library carries it: the tag
    /// list and the search labels hold precisely the tags with a live media, and cleaning up
    /// dead tag names never changes anything that is shown (or what sync compares).
    #[test]
    fn tags_exist_exactly_while_a_live_media_carries_them(pre in proptest::collection::vec(edit(), 0..24)) {
        let s = replica();
        for e in &pre { run(&s, e); }
        let live: Vec<String> = s.feed_filtered(&[], &[], tl_core::model::SearchScope::Both, Default::default(), &Default::default()).unwrap().into_iter().map(|i| i.media_id).collect();
        let mut want: Vec<String> = live.iter().flat_map(|m| s.media_tags(m).unwrap().into_iter().filter(|(_, o)| *o != 0).map(|(l, _)| l)).collect();
        want.sort(); want.dedup();
        let mut listed: Vec<String> = s.all_tags().unwrap().into_iter().map(|t| t.label).collect(); listed.sort();
        let mut labels = s.all_labels().unwrap(); labels.sort();
        prop_assert_eq!(&listed, &want);
        prop_assert_eq!(&labels, &want);
        let before = state(&s);
        s.gc_dead_tags().unwrap();
        prop_assert_eq!(state(&s), before, "clean-up changed something visible");
        prop_assert_eq!(s.gc_dead_tags().unwrap(), 0, "clean-up is idempotent");
    }
}

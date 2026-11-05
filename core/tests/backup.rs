//! Cold backup, share-inbox imports (HEIC / MOV), import-record deletion and the "最近添加"
//! mark (sync order, expiry, filters).
use std::path::{Path, PathBuf};
use tl_core::library::{FeedItem, FeedRequest, Library};
use tl_core::model::{MediaKind, Origin, PostMeta};
use tl_core::rules::{recent_active, TrashAction, RECENT_MS, TRASHED};
use tl_core::store::Store;

fn jpg(b: &[u8]) -> Vec<u8> { [&[0xFF, 0xD8, 0xFF, 0xE0][..], b].concat() }
fn heic(b: &[u8]) -> Vec<u8> { [&b"\0\0\0\x18ftypheic\0\0\0\0mif1heic"[..], b].concat() }
fn mov(b: &[u8]) -> Vec<u8> { [&b"\0\0\0\x14ftypqt  \0\0\0\0qt  "[..], b].concat() }
fn sha(b: &[u8]) -> String { use sha2::Digest; hex::encode(sha2::Sha256::digest(b)) }
fn tmp(name: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU32, Ordering}; static N: AtomicU32 = AtomicU32::new(0);
    let d = std::env::temp_dir().join(format!("tl-bak-{name}-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap(); d
}
fn post(root: &Path, folder: &str, id: &str, files: &[(&str, Vec<u8>)]) {
    let d = root.join(folder);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join("推文内容.txt"), format!("推文 ID: {id}\n【推文完整正文】\n{folder}")).unwrap();
    for (n, b) in files { std::fs::write(d.join(n), b).unwrap(); }
}
fn feed(lib: &Library, filter: serde_json::Value) -> Vec<FeedItem> {
    let req: FeedRequest = serde_json::from_value(serde_json::json!({ "scope": "both", "fuzzy": false, "filter": filter })).unwrap();
    let mut v = lib.feed(&req).unwrap();
    v.sort_by(|a, b| a.media_id.cmp(&b.media_id));
    v
}
fn now() -> u64 { tl_core::store::now_ms() }

/// Everything a backup should carry survives a round trip into an empty library; damaged and
/// missing files are left out and listed; models are not included.
#[test]
fn backup_round_trip_restores_the_library() {
    let d = tmp("round");
    let src = d.join("src");
    post(&src, "帖子A", "1", &[("1.jpg", jpg(b"a1")), ("2.jpg", jpg(b"a2")), ("3.jpg", jpg(b"a3"))]);
    post(&src, "帖子B", "2", &[("1.jpg", jpg(b"b1"))]);
    post(&src, "帖子C", "3", &[("1.jpg", jpg(b"c1")), ("2.jpg", jpg(b"c2"))]);
    let lib = Library::open(d.join("lib")).unwrap();
    lib.import_legacy_dir(&src).unwrap();
    let loose = d.join("loose");
    std::fs::create_dir_all(&loose).unwrap();
    std::fs::write(loose.join("IMG_1.HEIC"), heic(b"h")).unwrap();
    tl_core::import::import_loose_dir(&lib, &loose, None, false).unwrap();

    let (a1, a2, a3, b1, c1, c2) = (sha(&jpg(b"a1")), sha(&jpg(b"a2")), sha(&jpg(b"a3")), sha(&jpg(b"b1")), sha(&jpg(b"c1")), sha(&jpg(b"c2")));
    lib.tag(&a1, "墙", Origin::AI).unwrap();
    lib.db().set_tag_source(&a1, "墙", "qwen", true).unwrap();
    lib.db().mark_ai_done(&a1, "qwen").unwrap();
    lib.tag(&b1, "猫", Origin::USER).unwrap();
    lib.db().rename_tag("墙", "白墙").unwrap();
    lib.db().create_folder("空文件夹").unwrap();
    lib.db().add_to_folder("好看", &[b1.clone()]).unwrap();
    lib.trash_apply(&[a2.clone()], TrashAction::Trash).unwrap();
    lib.db().mark_recent("2", now()).unwrap();
    // a3 damaged, c2 missing on this device
    std::fs::write(lib.dir.join(lib.db().media_row(&a3).unwrap().unwrap().3), b"broken").unwrap();
    std::fs::remove_file(lib.dir.join(lib.db().media_row(&c2).unwrap().unwrap().3)).unwrap();

    let out = d.join("备份.tlpack");
    let rep = tl_core::archive::export_backup(&lib, &out).unwrap();
    assert_eq!(rep.skipped.len(), 2, "{:?}", rep.skipped);
    assert!(rep.skipped.iter().any(|s| s.media_id == a3 && s.reason.contains("损坏")));
    assert!(rep.skipped.iter().any(|s| s.media_id == c2 && s.reason.contains("不在")));
    assert_eq!((rep.media, rep.trashed), (5, 1), "a1 b1 c1 heic + a2 from the bin");
    assert!(!out.with_extension("tlpack.partial").exists());
    // the archive is readable even though a damaged entry was cut out
    let z = zip::ZipArchive::new(std::fs::File::open(&out).unwrap()).unwrap();
    assert_eq!(z.len(), 6, "5 media + manifest");

    let lib2 = Library::open(d.join("lib2")).unwrap();
    let r = tl_core::archive::import_pack(&lib2, &out).unwrap();
    assert!(r.issues.iter().all(|i| i.category != "unreadable"), "{:?}", r.issues);
    assert_eq!((r.to_bin, r.renames_restored, r.folders_restored), (1, 1, 1));
    let live: Vec<String> = feed(&lib2, serde_json::json!({})).into_iter().map(|i| i.media_id).collect();
    let mut want = vec![a1.clone(), b1.clone(), c1.clone(), sha(&heic(b"h"))]; want.sort();
    assert_eq!(live, want);
    assert_eq!(lib2.db().trash_reg(&a2).unwrap().state, TRASHED, "binned media go back to the bin");
    assert_eq!(lib2.db().media_tags(&a1).unwrap(), vec![("白墙".to_string(), 2)]);
    assert_eq!(lib2.db().renames().unwrap(), vec![("墙".to_string(), "白墙".to_string())], "rename rule restored (undo works)");
    assert_eq!(lib2.db().tag_sources(&a1, "白墙").unwrap(), vec!["qwen".to_string()]);
    assert!(lib2.db().ai_models_for(&a1).unwrap().contains(&"qwen".to_string()));
    assert_eq!(lib2.db().folders_of(&b1).unwrap(), vec!["好看".to_string()]);
    assert!(lib2.db().folders().unwrap().iter().any(|(n, c)| n == "空文件夹" && *c == 0), "empty folder restored");
    assert_eq!(feed(&lib2, serde_json::json!({ "recent_only": true })).len(), 1, "最近添加 mark restored");
    assert_eq!(feed(&lib2, serde_json::json!({ "loose_only": true })).len(), 1);

    // restoring into the original library never deletes or bins anything that is live there
    lib.trash_apply(&[a2.clone()], TrashAction::Restore).unwrap();
    let r = tl_core::archive::import_pack(&lib, &out).unwrap();
    assert_eq!(r.to_bin, 0);
    assert_ne!(lib.db().trash_reg(&a2).unwrap().state, TRASHED);
}

/// A damaged entry in a pack is reported and the rest is imported (it used to abort everything).
#[test]
fn damaged_pack_entry_is_reported_not_fatal() {
    let d = tmp("dmg");
    let src = d.join("src");
    post(&src, "帖子A", "1", &[("1.jpg", jpg(b"x")), ("2.jpg", jpg(b"y"))]);
    let lib = Library::open(d.join("lib")).unwrap();
    lib.import_legacy_dir(&src).unwrap();
    let out = d.join("p.tlpack");
    tl_core::archive::export_backup(&lib, &out).unwrap();
    // rewrite the pack with one media's bytes changed
    let bad = d.join("bad.tlpack");
    {
        use std::io::{Read, Write};
        let mut z = zip::ZipArchive::new(std::fs::File::open(&out).unwrap()).unwrap();
        let mut w = zip::ZipWriter::new(std::fs::File::create(&bad).unwrap());
        for i in 0..z.len() {
            let mut e = z.by_index(i).unwrap();
            let name = e.name().to_string();
            let mut b = vec![]; e.read_to_end(&mut b).unwrap();
            if name.contains(&sha(&jpg(b"x"))) { b.push(0); }
            w.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
            w.write_all(&b).unwrap();
        }
        w.finish().unwrap();
    }
    let lib2 = Library::open(d.join("lib2")).unwrap();
    let r = tl_core::archive::import_pack(&lib2, &bad).unwrap();
    assert_eq!(r.media, 1);
    assert_eq!(r.issues.iter().filter(|i| i.category == "unreadable").count(), 1);
    assert!(r.report_file.is_some(), "the problem is in the saved report");
}

/// Photos-app shares: HEIC stills and QuickTime movies are recognised by content; problem
/// files stay in the inbox (exportable), everything else is removed; deleting the record
/// deletes the leftovers only because they are inside an app-owned folder.
#[test]
fn share_inbox_heic_mov_and_record_deletion() {
    let d = tmp("inbox");
    let inbox = d.join("Inbox");
    let batch = inbox.join("share-1");
    std::fs::create_dir_all(&batch).unwrap();
    std::fs::write(batch.join("IMG_0001.HEIC"), heic(b"1")).unwrap();
    std::fs::write(batch.join("IMG_0002.MOV"), mov(b"2")).unwrap();
    std::fs::write(batch.join("IMG_0003.JPG"), jpg(b"3")).unwrap();
    std::fs::write(batch.join("IMG_0004.DNG"), b"raw").unwrap();
    std::fs::write(batch.join("page.jpg"), b"<html>error</html>").unwrap();
    std::fs::write(batch.join("copy.jpg"), jpg(b"3")).unwrap();
    let lib = Library::open(d.join("lib")).unwrap();
    let r = tl_core::import::import_loose_dir(&lib, &batch, Some("分享"), true).unwrap();
    let items = feed(&lib, serde_json::json!({ "loose_only": true }));
    assert_eq!(items.len(), 3);
    assert_eq!(items.iter().filter(|i| i.kind == MediaKind::Video).count(), 1, "MOV is a video");
    assert!(items.iter().any(|i| i.path.ends_with(".heic")) && items.iter().any(|i| i.path.ends_with(".mov")));
    assert!(items.iter().all(|i| lib.db().folders_of(&i.media_id).unwrap() == vec!["分享".to_string()]));
    let cats: Vec<&str> = r.issues.iter().map(|i| i.category.as_str()).collect();
    assert!(cats.contains(&"unsupported") && cats.contains(&"not_media") && cats.contains(&"duplicate"), "{cats:?}");
    assert!(!cats.contains(&"post_merged"), "a repeated loose file is listed once, as a duplicate: {cats:?}");
    let mut left: Vec<String> = std::fs::read_dir(&batch).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    left.sort();
    assert_eq!(left, vec!["IMG_0004.DNG".to_string(), "page.jpg".to_string()], "only problem files stay");
    // the problem files can still be exported as they are
    let issues_zip = d.join("issues.zip");
    assert_eq!(tl_core::import::export_issues(Path::new(r.report_file.as_ref().unwrap()), &issues_zip).unwrap(), 2);
    // a record whose source is outside the owned folders keeps the source
    let outside = d.join("用户的文件");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("a.jpg"), jpg(b"o")).unwrap();
    let r2 = tl_core::import::import_loose_dir(&lib, &outside, None, false).unwrap();
    let del = tl_core::import::delete_reports(&lib, &[PathBuf::from(r.report_file.unwrap()), PathBuf::from(r2.report_file.unwrap())], &[inbox.clone()]).unwrap();
    assert_eq!((del.reports, del.sources), (2, 1));
    assert!(!batch.exists(), "the app's own leftovers are gone");
    assert!(outside.join("a.jpg").exists(), "the user's own files are never deleted");
    assert!(tl_core::import::reports(&lib).is_empty());
    // only report files can be deleted through this
    assert!(tl_core::import::delete_reports(&lib, &[outside.join("a.jpg")], &[]).is_err());
    assert!(outside.join("a.jpg").exists());
    // a share with problem files moves them out of the inbox; the report follows them
    let b3 = inbox.join("share-3");
    std::fs::create_dir_all(&b3).unwrap();
    std::fs::write(b3.join("ok.jpg"), jpg(b"ok3")).unwrap();
    std::fs::write(b3.join("bad.jpg"), b"<html>").unwrap();
    let kept = d.join("Kept/share-3");
    let r3 = tl_core::import::import_loose_dir_keep(&lib, &b3, None, true, Some(&kept), true).unwrap();
    assert!(!b3.exists() && kept.join("bad.jpg").exists() && !kept.join("ok.jpg").exists());
    let saved = tl_core::import::load_report(Path::new(r3.report_file.as_ref().unwrap())).unwrap();
    assert_eq!(saved.source, kept.to_string_lossy());
    assert_eq!(tl_core::import::export_issues(Path::new(r3.report_file.as_ref().unwrap()), &d.join("i3.zip")).unwrap(), 1, "still exportable after the move");
    // a clean share leaves nothing behind
    let b2 = inbox.join("share-2");
    std::fs::create_dir_all(&b2).unwrap();
    std::fs::write(b2.join("x.jpg"), jpg(b"clean")).unwrap();
    tl_core::import::import_loose_dir(&lib, &b2, None, true).unwrap();
    assert!(!b2.exists());
}

fn store_with(posts: &[&str]) -> Store {
    let s = Store::open(":memory:").unwrap();
    for (i, p) in posts.iter().enumerate() {
        s.upsert_post(&PostMeta { id: p.to_string(), ..Default::default() }).unwrap();
        s.add_media(&format!("{i:064}"), p, 0, &MediaKind::Photo, &format!("blobs/00/{i:064}.jpg"), false).unwrap();
    }
    s
}

/// The mark syncs as a grow-only register: any delivery order (and duplicates) converges, it
/// expires on every device by its own clock without any op, and a re-delivered old mark stays
/// expired.
#[test]
fn recent_marks_converge_and_expire_without_ops() {
    let t = now();
    let a = store_with(&["p1", "p2"]);
    let b = store_with(&["p1", "p2"]);
    a.mark_recent("p1", t - 1000).unwrap();
    b.mark_recent("p1", t - 5000).unwrap();
    b.mark_recent("p2", t - RECENT_MS - 10).unwrap();   // already expired
    let oa = a.ops_since(&Default::default(), 1000).unwrap();
    let ob = b.ops_since(&Default::default(), 1000).unwrap();
    let mut ob_rev = ob.clone(); ob_rev.reverse();
    a.apply_remote(&ob_rev, |_, _| true).unwrap();
    a.apply_remote(&ob, |_, _| true).unwrap();              // duplicates are ignored
    b.apply_remote(&oa, |_, _| true).unwrap();
    for s in [&a, &b] {
        assert_eq!(s.recent_at("p1").unwrap(), t - 1000, "max wins");
        assert_eq!(s.recent_posts(t).unwrap().into_iter().collect::<Vec<_>>(), vec!["p1".to_string()]);
        assert!(s.recent_posts(t - 1000 + RECENT_MS).unwrap().is_empty(), "expired 5 days after the mark, no op needed");
    }
    let before = a.ops_since(&Default::default(), 1000).unwrap().len();
    a.prune_recent(t + 30 * 86_400_000).unwrap();
    assert_eq!(a.ops_since(&Default::default(), 1000).unwrap().len(), before, "pruning writes no op");
    b.apply_remote(&oa, |_, _| true).unwrap();
    assert!(!recent_active(a.recent_at("p1").unwrap(), t + 30 * 86_400_000));
    // a peer with a clock days ahead cannot pin a post as "recent" for a week
    let c = store_with(&["p3"]);
    c.mark_recent("p3", t + 3 * 86_400_000).unwrap();
    assert!(c.recent_posts(t).unwrap().is_empty());
}


use proptest::prelude::*;

/// Everything a library shows, for comparing a restore with its source.
fn snapshot(lib: &Library, ids: &[String], posts: &[String]) -> Vec<String> {
    let db = lib.db();
    let mut v = vec![];
    for id in ids {
        let state = if db.media_row(id).unwrap().is_none() { "absent".to_string() } else { format!("{}", db.trash_reg(id).unwrap().state) };
        v.push(format!("{} state={} tags={:?} folders={:?}", &id[..8], state, db.media_tags(id).unwrap(), db.folders_of(id).unwrap()));
    }
    for p in posts { v.push(format!("{p} recent={}", db.recent_at(p).unwrap())); }
    v.push(format!("folders={:?}", db.folders().unwrap().into_iter().map(|(n, _)| n).collect::<Vec<_>>()));
    v.push(format!("renames={:?}", db.renames().unwrap()));
    v
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(24))]

    /// Random libraries (tags, renames, folders, bin, marks, damaged and missing files — also the
    /// last one in the archive): restoring the backup into an empty library reproduces every
    /// media that was intact, and exactly the damaged or missing ones are listed and left out.
    #[test]
    fn backup_restores_random_libraries(
        posts in proptest::collection::vec(1..4usize, 1..5),
        tags in proptest::collection::vec((0..12usize, 0..4u8, 1..4u8), 0..14),
        renames in proptest::collection::vec((0..4u8, 0..5u8), 0..3),
        folders in proptest::collection::vec((0..12usize, 0..3u8), 0..8),
        empty_folder in any::<bool>(),
        binned in proptest::collection::vec(0..12usize, 0..3),
        marks in proptest::collection::vec((0..5usize, 0..3u64), 0..3),
        broken in proptest::collection::vec((0..12usize, any::<bool>()), 0..3),
    ) {
        let d = tmp("prop");
        let src = d.join("src");
        let mut ids = vec![];
        let mut post_ids = vec![];
        for (p, n) in posts.iter().enumerate() {
            let files: Vec<(String, Vec<u8>)> = (0..*n).map(|k| (format!("{k}.jpg"), jpg(format!("p{p}m{k}").as_bytes()))).collect();
            for (_, b) in &files { ids.push(sha(b)); }
            let refs: Vec<(&str, Vec<u8>)> = files.iter().map(|(a, b)| (a.as_str(), b.clone())).collect();
            post(&src, &format!("帖子{p}"), &format!("{}", 100 + p), &refs);
            post_ids.push(format!("{}", 100 + p));
        }
        let lib = Library::open(d.join("lib")).unwrap();
        lib.import_legacy_dir(&src).unwrap();
        let pick = |i: usize| ids[i % ids.len()].clone();
        for (m, l, o) in &tags { lib.tag(&pick(*m), &format!("标签{l}"), Origin(*o)).unwrap(); }
        for (a, b) in &renames { let _ = lib.db().rename_tag(&format!("标签{a}"), &format!("标签{b}")); }
        for (m, f) in &folders { lib.db().add_to_folder(&format!("夹{f}"), &[pick(*m)]).unwrap(); }
        if empty_folder { lib.db().create_folder("空的").unwrap(); }
        for m in &binned { lib.trash_apply(&[pick(*m)], TrashAction::Trash).unwrap(); }
        for (p, h) in &marks { lib.db().mark_recent(&post_ids[p % post_ids.len()], now() - h * 3_600_000).unwrap(); }
        let mut bad: Vec<String> = vec![];
        for (m, missing) in &broken {
            let id = pick(*m);
            if bad.contains(&id) { continue; }
            let rel = lib.db().media_row(&id).unwrap().unwrap().3;
            if *missing { std::fs::remove_file(lib.dir.join(&rel)).unwrap(); } else { std::fs::write(lib.dir.join(&rel), b"damaged bytes that are longer than before").unwrap(); }
            bad.push(id);
        }
        let out = d.join("b.tlpack");
        let r = tl_core::archive::export_backup(&lib, &out);
        let all_bad = bad.len() == ids.len();
        if all_bad { prop_assert!(r.is_err()); return Ok(()); }
        let r = r.unwrap();
        let mut skipped: Vec<String> = r.skipped.iter().map(|s| s.media_id.clone()).collect();
        skipped.sort(); bad.sort();
        prop_assert_eq!(&skipped, &bad, "exactly the damaged or missing files are listed");
        let lib2 = Library::open(d.join("lib2")).unwrap();
        let r2 = tl_core::archive::import_pack(&lib2, &out).unwrap();
        prop_assert!(r2.issues.iter().all(|i| i.category != "unreadable"), "the archive is intact: {:?}", r2.issues);
        let good: Vec<String> = ids.iter().filter(|i| !bad.contains(i)).cloned().collect();
        // a post whose every media was left out does not exist in the restore (marks included)
        let kept_posts: Vec<String> = post_ids.iter().filter(|p| good.iter().any(|g| lib.db().media_row(g).unwrap().map_or(false, |r| &r.0 == *p))).cloned().collect();
        prop_assert_eq!(snapshot(&lib2, &good, &kept_posts), snapshot(&lib, &good, &kept_posts));
        for b in &bad { prop_assert!(lib2.db().media_row(b).unwrap().is_none()); }
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A share holding random good files, copies, duplicates of the library, broken and
    /// unsupported files: afterwards the library has every good one, and exactly the problem
    /// files are left in the share.
    #[test]
    fn share_inbox_keeps_exactly_the_problem_files(files in proptest::collection::vec((0..5u8, 0..6u8), 1..12)) {
        let d = tmp("pin");
        let lib = Library::open(d.join("lib")).unwrap();
        let pre = d.join("pre"); std::fs::create_dir_all(&pre).unwrap();
        std::fs::write(pre.join("x.jpg"), jpg(b"in-library")).unwrap();
        tl_core::import::import_loose_dir(&lib, &pre, None, true).unwrap();
        let share = d.join("Inbox/s"); std::fs::create_dir_all(&share).unwrap();
        let mut problems = vec![];
        let mut good = std::collections::BTreeSet::new();
        for (i, (kind, v)) in files.iter().enumerate() {
            let (name, bytes, problem) = match kind {
                0 => (format!("{i}.jpg"), jpg(&[*v]), false),
                1 => (format!("{i}.HEIC"), heic(&[*v]), false),
                2 => (format!("{i}.MOV"), mov(&[*v]), false),
                3 => (format!("{i}.jpg"), b"<html>no</html>".to_vec(), true),
                _ => (format!("{i}.dng"), vec![1, 2, 3, *v], true),
            };
            if !problem { good.insert(sha(&bytes)); }
            if problem { problems.push(name.clone()); }
            std::fs::write(share.join(&name), bytes).unwrap();
        }
        std::fs::write(share.join("dup.jpg"), jpg(b"in-library")).unwrap();
        tl_core::import::import_loose_dir(&lib, &share, None, true).unwrap();
        for g in &good { prop_assert!(lib.db().media_row(g).unwrap().is_some()); }
        let mut left: Vec<String> = if share.exists() { std::fs::read_dir(&share).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect() } else { vec![] };
        left.sort(); problems.sort();
        prop_assert_eq!(left, problems);
        let _ = std::fs::remove_dir_all(&d);
    }
}

/// A large damaged file that would have been the archive's last entry is cut out without
/// leaving its bytes behind: the archive ends exactly with its end-of-directory record (so
/// every unzip tool finds it), and it restores.
#[test]
fn cut_out_last_entry_leaves_no_trailing_bytes() {
    let d = tmp("tail");
    let src = d.join("src");
    let big: Vec<u8> = jpg(&vec![7u8; 2_000_000]);
    post(&src, "帖子A", "1", &[("1.jpg", jpg(b"small"))]);
    post(&src, "帖子Z", "9", &[("1.jpg", big.clone())]);      // sorts last
    let lib = Library::open(d.join("lib")).unwrap();
    lib.import_legacy_dir(&src).unwrap();
    let rel = lib.db().media_row(&sha(&big)).unwrap().unwrap().3;
    let mut damaged = big.clone(); damaged[1_000_000] ^= 1;
    std::fs::write(lib.dir.join(rel), damaged).unwrap();
    let out = d.join("t.tlpack");
    let r = tl_core::archive::export_backup(&lib, &out).unwrap();
    assert_eq!((r.media, r.skipped.len()), (1, 1));
    let bytes = std::fs::read(&out).unwrap();
    assert!(bytes.len() < 100_000, "the 2 MB damaged entry left nothing behind ({} bytes)", bytes.len());
    assert_eq!(&bytes[bytes.len() - 22..bytes.len() - 18], &[0x50, 0x4b, 0x05, 0x06], "ends with the end-of-directory record");
    let lib2 = Library::open(d.join("lib2")).unwrap();
    assert_eq!(tl_core::archive::import_pack(&lib2, &out).unwrap().media, 1);
}

/// The diagnostics export holds logs and numbers, never library content: tag names, post text
/// and file names of the library do not appear anywhere in it.
#[test]
fn diagnostics_export_has_no_library_content() {
    let d = tmp("diag");
    let src = d.join("src");
    post(&src, "秘密帖子正文", "77", &[("私人文件名.jpg", jpg(b"x")), ("bad.jpg", b"<html>".to_vec())]);
    let lib = Library::open(d.join("lib")).unwrap();
    lib.import_legacy_dir(&src).unwrap();
    lib.tag(&sha(&jpg(b"x")), "隐私标签", Origin::USER).unwrap();
    lib.diag("download_error", serde_json::json!({ "error": tl_core::diagnostics::scrub("error sending request for url (https://x.com/someone/status/77)") }));
    std::fs::write(lib.dir.join("logs/app.log"), "{\"t\":1,\"level\":\"error\",\"cat\":\"core\",\"msg\":\"feed：失败\"}\n").unwrap();
    let out = d.join("diag.zip");
    let n = tl_core::diagnostics::export(&lib, &out, r#"{"app_version":"1.0"}"#).unwrap();
    assert!(n >= 4);
    let mut z = zip::ZipArchive::new(std::fs::File::open(&out).unwrap()).unwrap();
    let mut all = String::new();
    for i in 0..z.len() { use std::io::Read; let mut e = z.by_index(i).unwrap(); all += e.name(); let mut s = String::new(); let _ = e.read_to_string(&mut s); all += &s; }
    for secret in ["隐私标签", "秘密帖子正文", "私人文件名", "someone", "x.com/"] { assert!(!all.contains(secret), "{secret} leaked into the diagnostics"); }
    assert!(all.contains("summary.json") && all.contains("not_media"), "issue categories are counted");
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]
    /// Logged error text never carries a link (links name the user's posts), whatever surrounds it.
    #[test]
    fn scrubbed_errors_never_contain_links(pre in "[a-z ：:()（）]{0,40}", host in "[a-z]{1,10}", path in "[a-z0-9/._-]{0,30}", post in "[a-z ：:)]{0,40}", https in any::<bool>()) {
        let s = format!("{pre}{}://{host}.com/{path}{post}", if https { "https" } else { "http" });
        let out = tl_core::diagnostics::scrub(&s);
        prop_assert!(!out.contains("://"), "{}", out);
        prop_assert!(out.chars().count() <= 200);
    }
}

/// 存储空间: media count by kind (binned ones apart), each file once; the database and the
/// front end's places are groups of their own and never counted twice.
#[test]
fn storage_usage_groups() {
    let d = tmp("storage");
    let src = d.join("src");
    post(&src, "帖子A", "1", &[("1.jpg", jpg(&[1; 1000])), ("2.jpg", jpg(&[2; 500])), ("3.mp4", mov(&[3; 2000]))]);
    let lib = Library::open(d.join("lib")).unwrap();
    lib.import_legacy_dir(&src).unwrap();
    lib.trash_apply(&[sha(&jpg(&[2; 500]))], TrashAction::Trash).unwrap();
    let cache = d.join("lib").join(".thumbs");
    std::fs::create_dir_all(&cache).unwrap();
    std::fs::write(cache.join("t.jpg"), [0u8; 300]).unwrap();
    let u = tl_core::storage::usage(&lib, &[tl_core::storage::ExtraPlace { key: "thumbnails".into(), path: cache.to_string_lossy().into() }]).unwrap();
    let g = |k: &str| u.groups.iter().find(|g| g.key == k).cloned().unwrap();
    assert_eq!((g("photos").bytes, g("photos").files), (1004, 1));
    assert_eq!((g("bin").bytes, g("bin").files), (504, 1));
    assert_eq!(g("videos").files, 1);
    assert!(g("database").bytes > 0);
    assert_eq!(g("thumbnails").bytes, 300, "the cache is its own group…");
    assert!(g("libraryOther").bytes < 300 || !std::fs::read_dir(d.join("lib")).unwrap().any(|e| e.unwrap().path() == cache.join("t.jpg")), "…and not part of the library's other data");
    assert_eq!(u.total, u.groups.iter().map(|g| g.bytes).sum::<u64>());
}

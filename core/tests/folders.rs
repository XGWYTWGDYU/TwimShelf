//! Folders: imports into a folder merge with what is already there and bring the whole post
//! along; folders travel through export/import; the tag switch of export is honoured.
use proptest::prelude::*;
use std::path::{Path, PathBuf};
use tl_core::library::Library;

fn jpg(b: &[u8]) -> Vec<u8> { [&[0xFF, 0xD8, 0xFF, 0xE0][..], b].concat() }
fn sha(b: &[u8]) -> String { use sha2::Digest; hex::encode(sha2::Sha256::digest(b)) }
fn tmp(name: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU32, Ordering}; static N: AtomicU32 = AtomicU32::new(0);
    let d = std::env::temp_dir().join(format!("tl-fold-{name}-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap(); d
}
/// One post folder with a sidecar giving it a fixed post ID.
fn post(root: &Path, folder: &str, id: &str, files: &[(&str, &[u8])]) {
    let d = root.join(folder);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join("推文内容.txt"), format!("推文 ID: {id}\n【推文完整正文】\n{folder}")).unwrap();
    for (n, b) in files { std::fs::write(d.join(n), jpg(b)).unwrap(); }
}
fn zip_dir(src: &Path, out: &Path) {
    use std::io::Write;
    let mut z = zip::ZipWriter::new(std::fs::File::create(out).unwrap());
    for e in walk(src) {
        let rel = e.strip_prefix(src).unwrap().to_string_lossy().into_owned();
        z.start_file(rel.as_str(), zip::write::SimpleFileOptions::default()).unwrap();
        z.write_all(&std::fs::read(&e).unwrap()).unwrap();
    }
    z.finish().unwrap();
}
fn walk(d: &Path) -> Vec<PathBuf> {
    let mut v = vec![];
    for e in std::fs::read_dir(d).unwrap() { let p = e.unwrap().path(); if p.is_dir() { v.extend(walk(&p)) } else { v.push(p) } }
    v.sort(); v
}

/// The case from the spec: the library has post A with media B, C, D; an import contains post A
/// with C and D. They merge (nothing duplicated, B kept), and A with B, C, D all go into the folder.
#[test]
fn partial_overlap_merges_and_whole_post_goes_into_the_folder() {
    let d = tmp("overlap");
    let lib = Library::open(d.join("lib")).unwrap();
    let first = d.join("first");
    post(&first, "帖子A", "100", &[("1.jpg", b"B"), ("2.jpg", b"C"), ("3.jpg", b"D")]);
    post(&first, "帖子Z", "999", &[("1.jpg", b"Z")]);
    lib.import_legacy_dir(&first).unwrap();
    // the new import: A with C and D only, plus a new post E
    let second = d.join("second");
    post(&second, "帖子A", "100", &[("1.jpg", b"C"), ("2.jpg", b"D")]);
    post(&second, "帖子E", "200", &[("1.jpg", b"E")]);
    let zp = d.join("in.zip");
    zip_dir(&second, &zp);
    let r = tl_core::import::import_zip(&lib, &zp, Some("导入批次")).unwrap();
    assert_eq!(r.folder.as_deref(), Some("导入批次"));
    assert_eq!((r.new_media, r.duplicate_media, r.merged_posts), (1, 2, 1), "C, D are the library's own files; A merged");
    let mut inside: Vec<String> = lib.db().feed_filtered(&[], &[], tl_core::model::SearchScope::Both, Default::default(),
        &tl_core::library::FeedFilter { folder: Some("导入批次".into()), ..Default::default() }).unwrap().into_iter().map(|i| i.media_id).collect();
    inside.sort();
    let mut want = vec![sha(&jpg(b"B")), sha(&jpg(b"C")), sha(&jpg(b"D")), sha(&jpg(b"E"))];
    want.sort();
    assert_eq!(inside, want, "post A with B, C, D and post E — not the untouched Z");
    let st = lib.db().stats().unwrap();
    assert_eq!((st.posts, st.photos), (3, 5), "nothing duplicated");
    // each file is accounted for
    assert!(r.issues.iter().filter(|i| i.category == "duplicate").all(|i| i.same_as.is_some()));
}

/// Folders and the tag switch through export → import.
#[test]
fn export_carries_folders_and_honours_the_tag_switch() {
    let d = tmp("pack");
    let lib = Library::open(d.join("lib")).unwrap();
    let src = d.join("src");
    post(&src, "帖子A", "1", &[("1.jpg", b"a"), ("2.jpg", b"b")]);
    lib.import_legacy_dir(&src).unwrap();
    let (a, b) = (sha(&jpg(b"a")), sha(&jpg(b"b")));
    lib.db().add_to_folder("旅行", &[a.clone()]).unwrap();
    lib.tag(&a, "海", tl_core::model::Origin::USER).unwrap();
    // only the folder, without tags
    let out = d.join("x.tlpack");
    let r = tl_core::archive::export_media(&lib, &[a.clone()],
        tl_core::archive::ExportOptions { tags: false, folders: true, media_only: false }, &out).unwrap();
    assert_eq!(r.media, 1, "only the media asked for");
    let lib2 = Library::open(d.join("lib2")).unwrap();
    tl_core::archive::import_pack(&lib2, &out).unwrap();
    assert_eq!(lib2.db().folders_of(&a).unwrap(), vec!["旅行".to_string()], "folder restored");
    assert!(lib2.db().media_tags(&a).unwrap().is_empty(), "no tag information exported");
    assert!(lib2.db().folders_of(&b).unwrap().is_empty());
    // with tags
    let out2 = d.join("y.tlpack");
    tl_core::archive::export_media(&lib, &[a.clone(), b.clone()], Default::default(), &out2).unwrap();
    let lib3 = Library::open(d.join("lib3")).unwrap();
    tl_core::archive::import_pack_into(&lib3, &out2, Some("来自导出")).unwrap();
    assert_eq!(lib3.db().media_tags(&a).unwrap(), vec![("海".to_string(), 1)]);
    let mut f = lib3.db().folders_of(&a).unwrap(); f.sort();
    assert_eq!(f, vec!["旅行".to_string(), "来自导出".to_string()]);
}

/// Downloads into a folder: a link whose post is already in the library still lands in the
/// folder (no network needed for that), and a second request while a batch runs joins it.
#[test]
fn download_of_known_posts_goes_into_the_folder_and_requests_join() {
    let d = tmp("dl");
    let lib = std::sync::Arc::new(Library::open(d.join("lib")).unwrap());
    let src = d.join("src");
    post(&src, "帖子A", "111", &[("1.jpg", b"x")]);
    post(&src, "帖子B", "222", &[("1.jpg", b"y")]);
    lib.import_legacy_dir(&src).unwrap();
    let req = |u: &str| tl_core::download::DownloadRequest { urls: vec![u.into()], concurrency: 1, interval_ms: 300, route: tl_core::download::Route::Fx, revive: false, folder: Some("收藏夹".into()), mark_recent: true };
    tl_core::download::start(lib.clone(), req("https://x.com/a/status/111")).unwrap();
    tl_core::download::start(lib.clone(), req("https://x.com/b/status/222")).unwrap();   // joins the running batch
    for _ in 0..200 { if !tl_core::download::status().running { break; } std::thread::sleep(std::time::Duration::from_millis(20)); }
    let st = tl_core::download::status();
    assert_eq!((st.skipped, st.failed), (2, 0), "both known, both handled in one batch");
    let mut f: Vec<String> = [sha(&jpg(b"x")), sha(&jpg(b"y"))].into_iter().filter(|m| lib.db().folders_of(m).unwrap() == vec!["收藏夹".to_string()]).collect();
    f.sort();
    assert_eq!(f.len(), 2);
    // posts that were already in the library are not "recently added"
    assert_eq!(lib.db().recent_at("111").unwrap(), 0);
    // the same link asked for again later (another folder) runs again: a finished job used to be
    // ignored, so the second request silently did nothing
    let mut again = req("https://x.com/a/status/111");
    again.folder = Some("第二个".into());
    tl_core::download::start(lib.clone(), again).unwrap();
    for _ in 0..200 { if !tl_core::download::status().running { break; } std::thread::sleep(std::time::Duration::from_millis(20)); }
    assert!(lib.db().folders_of(&sha(&jpg(b"x"))).unwrap().contains(&"第二个".to_string()), "a repeated request is processed");
    assert!(lib.db().pending_jobs().unwrap().is_empty());
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]
    /// Import into a folder puts exactly the live media of every touched post there.
    #[test]
    fn import_folder_is_exactly_the_touched_posts(existing in proptest::collection::vec((0..4u8, 0..6u8), 1..10),
                                                  incoming in proptest::collection::vec((0..5u8, 0..6u8), 1..8),
                                                  binned in proptest::collection::vec(0..6u8, 0..2)) {
        let d = tmp("prop");
        let lib = Library::open(d.join("lib")).unwrap();
        let mk = |root: &Path, items: &[(u8, u8)]| {
            let mut by: std::collections::BTreeMap<u8, Vec<u8>> = Default::default();
            for (p, m) in items { let v = by.entry(*p).or_default(); if !v.contains(m) { v.push(*m) } }
            for (p, ms) in by {
                let files: Vec<(String, Vec<u8>)> = ms.iter().enumerate().map(|(i, m)| (format!("{i}.jpg"), vec![*m])).collect();
                let refs: Vec<(&str, &[u8])> = files.iter().map(|(n, b)| (n.as_str(), b.as_slice())).collect();
                post(root, &format!("帖子{p}"), &format!("{p}"), &refs);
            }
        };
        let first = d.join("first"); mk(&first, &existing);
        lib.import_legacy_dir(&first).unwrap();
        for m in &binned { lib.trash_apply(&[sha(&jpg(&[*m]))], tl_core::rules::TrashAction::Trash).unwrap(); }
        let second = d.join("second"); mk(&second, &incoming);
        let r = tl_core::import::import_dir(&lib, &second, Some("批次")).unwrap();
        let touched: std::collections::BTreeSet<String> = r.ids.iter().cloned().collect();
        let mut want: Vec<String> = vec![];
        for p in &touched { want.extend(lib.db().live_media_of_post(p).unwrap()); }
        // plus every live file of this import (even when another post owns it)
        for (_, m) in &incoming {
            let id = sha(&jpg(&[*m]));
            if lib.db().trash_reg(&id).unwrap().state == tl_core::rules::LIVE && lib.db().media_row(&id).unwrap().is_some() { want.push(id); }
        }
        want.sort(); want.dedup();
        let mut got: Vec<String> = lib.db().feed_filtered(&[], &[], tl_core::model::SearchScope::Both, Default::default(),
            &tl_core::library::FeedFilter { folder: Some("批次".into()), ..Default::default() }).unwrap().into_iter().map(|i| i.media_id).collect();
        got.sort();
        prop_assert_eq!(got, want);
        let _ = std::fs::remove_dir_all(&d);
    }
}

/// 按添加时间: the post added last comes first, whole, its media in their order.
#[test]
fn feed_can_be_ordered_by_when_things_were_added() {
    let d = tmp("added");
    let lib = Library::open(d.join("lib")).unwrap();
    for (i, id) in ["201", "202", "203"].iter().enumerate() {
        let src = d.join(format!("src{i}"));
        post(&src, &format!("p{i}"), id, &[("1.jpg", format!("{id}a").as_bytes()), ("2.jpg", format!("{id}b").as_bytes())]);
        lib.import_legacy_dir(&src).unwrap();
    }
    let req = tl_core::library::FeedRequest { newest_first: true, terms: vec![], scope: tl_core::model::SearchScope::Both, seed: Some(9), fuzzy: false, term_vectors: vec![], embed_model: None,
        threshold: 0.5, fields: Default::default(), filter: Default::default() };
    let got: Vec<(String, i64)> = lib.feed(&req).unwrap().into_iter().map(|i| (i.post_id, i.ordinal)).collect();
    let want: Vec<(String, i64)> = ["203", "203", "202", "202", "201", "201"].iter().enumerate().map(|(i, p)| (p.to_string(), (i % 2) as i64)).collect();
    assert_eq!(got, want);
    let packed = serde_json::to_value(lib.feed_packed(&req).unwrap()).unwrap();
    let posts: Vec<String> = packed["posts"].as_array().unwrap().iter().map(|p| p["id"].as_str().unwrap_or_default().to_string()).collect();
    assert_eq!(posts.first().map(String::as_str), Some("203"), "the packed form the apps read keeps the order");
}

/// Loose media: every file its own loose post; a file that belongs to a real post stays there;
/// identical loose files are stored once; HTML pages are refused; nested folders don't matter.
#[test]
fn loose_media_import() {
    use std::io::Write;
    let d = tmp("loose");
    let lib = Library::open(d.join("lib")).unwrap();
    let src = d.join("src");
    post(&src, "帖子A", "77", &[("1.jpg", b"shared")]);
    lib.import_legacy_dir(&src).unwrap();
    let zp = d.join("loose.zip");
    {
        let mut z = zip::ZipWriter::new(std::fs::File::create(&zp).unwrap());
        let o = zip::write::SimpleFileOptions::default();
        for (n, b) in [("a.jpg", jpg(b"one")), ("深/层/b.jpg", jpg(b"two")), ("c.jpg", jpg(b"one")), ("d.jpg", jpg(b"shared")),
                       ("e.mp4", b"<!DOCTYPE html>".to_vec()), (".DS_Store", b"x".to_vec()), ("f.txt", b"note".to_vec())] {
            z.start_file(n, o).unwrap(); z.write_all(&b).unwrap();
        }
        z.finish().unwrap();
    }
    let r = tl_core::import::import_loose_zip(&lib, &zp, Some("散图")).unwrap();
    assert_eq!((r.new_media, r.duplicate_media, r.system_files), (2, 2, 1));
    let cats: Vec<&str> = r.issues.iter().map(|i| i.category.as_str()).collect();
    assert!(cats.contains(&"not_media") && cats.contains(&"unsupported"));
    let file_issues = r.issues.iter().filter(|i| !i.category.starts_with("post_") && i.category != "duplicate").count();
    assert_eq!(r.entries, r.system_files + r.new_media + r.duplicate_media + file_issues, "every entry accounted for");
    // the shared file stays with the real post; loose posts are the two new files
    let st = lib.db().stats().unwrap();
    assert_eq!((st.posts, st.photos), (3, 3));
    let loose = lib.db().feed_filtered(&[], &[], tl_core::model::SearchScope::Both, Default::default(),
        &tl_core::library::FeedFilter { loose_only: true, ..Default::default() }).unwrap();
    assert_eq!(loose.len(), 2);
    assert!(loose.iter().all(|i| i.post_id.starts_with("loose:") && i.text.is_none() && i.author_name.is_none()));
    let shared = sha(&jpg(b"shared"));
    assert_eq!(lib.db().media_row(&shared).unwrap().unwrap().0, "77", "real post keeps its file");
    // the folder holds the loose media and (as a touched post's media) the shared file
    assert_eq!(lib.db().folders().unwrap(), vec![("散图".to_string(), 3)]);
}

/// A loose ZIP may hold post folders too (a 推文内容.txt beside the media): those become posts
/// with their text, the rest loose media, and the sidecars are never reported as unsupported.
#[test]
fn loose_zip_keeps_post_folders_as_posts() {
    let d = tmp("loose-posts");
    let lib = Library::open(d.join("lib")).unwrap();
    let src = d.join("src");
    post(&src.join("posts"), "post-0", "90", &[("1.jpg", b"p0")]);
    post(&src.join("posts"), "post-1", "91", &[("1.jpg", b"p1"), ("2.jpg", b"p1b")]);
    std::fs::create_dir_all(src.join("loose")).unwrap();
    std::fs::write(src.join("loose/x.jpg"), jpg(b"loose")).unwrap();
    let zp = d.join("mixed.zip");
    zip_dir(&src, &zp);
    let r = tl_core::import::import_loose_zip(&lib, &zp, None).unwrap();
    assert!(r.issues.iter().all(|i| i.category != "unsupported"), "{:?}", r.issues);
    assert_eq!((r.folders, r.sidecars, r.new_media), (2, 2, 4));
    let st = lib.db().stats().unwrap();
    assert_eq!((st.posts, st.photos), (3, 4));
    assert_eq!(lib.db().media_row(&sha(&jpg(b"p1b"))).unwrap().unwrap().0, "91", "post folder's media stay with its post");
    assert!(lib.db().media_row(&sha(&jpg(b"loose"))).unwrap().unwrap().0.starts_with("loose:"));
}

/// "全部加入文件夹" from the tag list: exactly the live media carrying the tag (under its
/// current name after a rename) go into the folder; media in the bin do not.
#[test]
fn tag_to_folder_takes_exactly_the_live_media_with_the_tag() {
    let s = tl_core::store::Store::open(":memory:").unwrap();
    s.upsert_post(&tl_core::model::PostMeta { id: "p".into(), ..Default::default() }).unwrap();
    for m in 0..4u8 { s.add_media(&format!("{m:064}"), "p", m as i64, &tl_core::model::MediaKind::Photo, &format!("blobs/00/{m:064}.jpg"), false).unwrap(); }
    let id = |m: u8| format!("{m:064}");
    s.tag_media(&id(0), "墙", tl_core::model::Origin::AI).unwrap();
    s.tag_media(&id(1), "白墙", tl_core::model::Origin::USER).unwrap();
    s.tag_media(&id(2), "墙", tl_core::model::Origin::USER).unwrap();
    s.trash_action(&id(2), tl_core::rules::TrashAction::Trash).unwrap();
    s.rename_tag("墙", "白墙").unwrap();
    let ids: Vec<String> = s.export_items(&["白墙".into()], &[]).unwrap().into_iter().map(|i| i.media_id).collect();
    s.add_to_folder("墙面", &ids).unwrap();
    let mut got: Vec<String> = (0..4u8).filter(|m| s.folders_of(&id(*m)).unwrap().contains(&"墙面".to_string())).map(id).collect();
    got.sort();
    assert_eq!(got, vec![id(0), id(1)]);
}

//! Regressions for the backend review of 2026-10-21 (each test names the finding it pins down).
use std::{fs, io::Read, path::PathBuf, sync::Arc};
use tl_core::{
    library::Library, model::{MediaKind, PostMeta}, oplog::{LoggedOp, Op}, rules, store::Store,
    sync::SyncNode,
};

/// Imports and model transfers share process-wide state (a running import, the model status):
/// the tests that touch it take turns.
static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());
fn serial() -> std::sync::MutexGuard<'static, ()> { SERIAL.lock().unwrap_or_else(|e| e.into_inner()) }

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn post(id: &str) -> PostMeta { PostMeta { id: id.into(), ..Default::default() } }
fn op(seq: i64, op: Op) -> LoggedOp { LoggedOp { device: "remote-review".into(), seq, op } }
fn media_op(id: &str, post_id: &str) -> Op { Op::Media { id: id.into(), post_id: post_id.into(), ordinal: 0, kind: MediaKind::Photo, ext: "jpg".into() } }
fn purge_op(id: &str) -> Op { Op::Trash { media_id: id.into(), inc: 0, state: rules::PURGED, hlc: 1 } }
fn dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("tl-review-{name}-{}", rand::random::<u64>()));
    fs::create_dir_all(&d).unwrap();
    d
}
fn blob_path(id: &str) -> String { format!("blobs/{}/{id}.jpg", &id[..2]) }

/// A post whose media `A` is here and whose media `B` another device recorded (file not here yet).
fn post_with_awaited_media() -> Store {
    let s = Store::open(":memory:").unwrap();
    s.upsert_post(&post("p")).unwrap();
    s.add_media(A, "p", 0, &MediaKind::Photo, &blob_path(A), false).unwrap();
    s.apply_remote(&[op(1, media_op(B, "p"))], |_, _| false).unwrap();
    s
}


// ---- finding 9: whole-post folder actions leave awaited media out ----

#[test]
fn whole_post_folder_actions_include_media_still_awaited() {
    let s = post_with_awaited_media();
    s.add_posts_to_folder("f", &["p".into()]).unwrap();
    s.blob_arrived(B).unwrap();
    assert_eq!(s.folders_of(B).unwrap(), vec!["f".to_string()]);
}

// ---- finding 4: a post that arrives locally is treated like one that arrives from a peer ----

#[test]
fn local_post_arrival_refreshes_claims_like_remote_arrival() {
    let a = Store::open(":memory:").unwrap();
    let b = Store::open(":memory:").unwrap();
    a.upsert_post(&post("z")).unwrap();
    a.add_media(A, "z", 0, &MediaKind::Photo, &blob_path(A), false).unwrap();
    b.apply_remote(&a.ops_since(&Default::default(), 100).unwrap(), |_, _| true).unwrap();
    // both learn of a claim by a post neither knows yet
    let claim = op(1, media_op(A, "a"));
    for db in [&a, &b] { db.apply_remote(&[claim.clone()], |_, _| true).unwrap(); }
    a.upsert_post(&post("a")).unwrap();
    b.apply_remote(&a.ops_since(&b.version_vector().unwrap(), 100).unwrap(), |_, _| true).unwrap();
    assert_eq!(a.version_vector().unwrap(), b.version_vector().unwrap());
    assert_eq!(a.media_row(A).unwrap().unwrap().0, b.media_row(A).unwrap().unwrap().0, "identical logs give the same owner");
}

// ---- finding 5: a permanent deletion that arrives before the media's post removes the file ----

#[test]
fn purge_before_post_arrival_deletes_the_awaited_file() {
    let root = dir("purge");
    let l = Library::open(&root).unwrap();
    let (id, rel) = l.put_blob(b"\xff\xd8\xff\xe0test", "jpg").unwrap();
    l.db().apply_remote(&[op(1, media_op(&id, "p")), op(2, purge_op(&id))], |_, _| true).unwrap();
    l.settle().unwrap();
    assert!(!root.join(&rel).exists(), "the file is removed although no media row was ever made for it");
    l.db().apply_remote(&[op(3, Op::Post { meta: post("p"), hlc: 2 })], |_, _| true).unwrap();
    l.settle().unwrap();
    assert!(l.db().media_row(&id).unwrap().is_none(), "a deleted media does not come back as a row");
    assert!(l.db().gc_pending().unwrap().is_empty());
}

#[test]
fn purge_after_the_file_arrived_but_before_its_post_still_removes_it() {
    // the post arrives while the removal is still waiting
    let root = dir("purge-late-post");
    let l = Library::open(&root).unwrap();
    let (id, rel) = l.put_blob(b"\xff\xd8\xff\xe0test2", "jpg").unwrap();
    l.db().apply_remote(&[op(1, media_op(&id, "p")), op(2, purge_op(&id)), op(3, Op::Post { meta: post("p"), hlc: 2 })], |_, _| true).unwrap();
    l.settle().unwrap();
    assert!(!root.join(&rel).exists());
    assert!(l.db().media_row(&id).unwrap().is_none());
}

// ---- finding 2: an import's cleanup removes a copy only while the media is still deleted ----

#[test]
fn import_cleanup_keeps_the_file_of_a_revived_media() {
    let root = dir("cleanup");
    let l = Library::open(&root).unwrap();
    let (revived, revived_rel) = l.put_blob(b"\xff\xd8\xff\xe0revived", "jpg").unwrap();
    let (gone, gone_rel) = l.put_blob(b"\xff\xd8\xff\xe0gone", "jpg").unwrap();
    l.db().apply_remote(&[op(1, purge_op(&revived)), op(2, purge_op(&gone))], |_, _| true).unwrap();
    {
        let db = l.db();
        // the user asked for this post again: the media is back, with the file just stored
        db.upsert_post(&post("p")).unwrap();
        assert!(db.add_media(&revived, "p", 0, &MediaKind::Photo, &revived_rel, true).unwrap());
        // the cleanup looks at both under the same hold of the store
        assert!(!l.drop_purged_copy(&db, &revived, &revived_rel), "a revived media keeps its file");
        assert!(l.drop_purged_copy(&db, &gone, &gone_rel), "the copy of a media that stays deleted goes");
    }
    assert!(root.join(&revived_rel).exists());
    assert!(!root.join(&gone_rel).exists());
}

#[test]
fn import_cleanup_never_removes_what_is_not_a_blob() {
    let root = dir("cleanup-path");
    let l = Library::open(&root).unwrap();
    let id = "c".repeat(64);
    l.db().apply_remote(&[op(1, purge_op(&id))], |_, _| true).unwrap();
    fs::write(root.join("keep.txt"), b"x").unwrap();
    let db = l.db();
    assert!(!l.drop_purged_copy(&db, &id, "keep.txt"));
    assert!(!l.drop_purged_copy(&db, &id, "../keep.txt"));
    assert!(root.join("keep.txt").exists());
}

// ---- finding 3: an import queued behind another when the library is wiped must not run ----

#[test]
fn wipe_cancels_imports_already_waiting_for_the_lock() {
    let _serial = serial();
    let root = dir("queued-wipe");
    let src = root.join("src/post");
    fs::create_dir_all(&src).unwrap();
    fs::write(src.join("1.jpg"), b"\xff\xd8\xff\xe0old-data").unwrap();
    let l = Arc::new(Library::open(root.join("lib")).unwrap());
    let wipe_guard = tl_core::import::stop_and_wait();
    let worker_lib = l.clone();
    let source = root.join("src");
    let worker = std::thread::spawn(move || worker_lib.import_legacy_dir(&source));
    let until = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while !tl_core::import::progress().waiting {
        assert!(std::time::Instant::now() < until);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    l.wipe(false).unwrap();
    drop(wipe_guard);
    let result = worker.join().unwrap();
    assert!(result.is_err(), "the queued import is cancelled");
    assert_eq!(l.db().stats().unwrap().photos, 0, "an old queued import does not fill the wiped library");
    // an import started afterwards is an ordinary one
    assert!(l.import_legacy_dir(&root.join("src")).is_ok());
    assert_eq!(l.db().stats().unwrap().photos, 1);
}

// ---- finding 6: a post's fields are limited, so one sync record always fits a frame ----

#[tokio::test(flavor = "multi_thread")]
async fn huge_imported_text_is_cut_and_sync_keeps_working() {
    let _serial = serial();
    use sha2::{Digest, Sha256};
    use std::io::Write;
    let root = dir("oversize");
    let a = Arc::new(Library::open(root.join("a")).unwrap());
    let b = Arc::new(Library::open(root.join("b")).unwrap());
    let bytes = b"\xff\xd8\xff\xe0photo";
    let id = hex::encode(Sha256::digest(bytes));
    let pack = root.join("input.tlpack");
    let manifest = serde_json::json!({"format": "twitter-library-pack", "version": 4, "created_at": 1, "posts": [{
        "id": "p", "text": "字".repeat(6 << 20), "media": [{"sha256": id, "kind": "photo", "ordinal": 0, "file": "media/a.jpg", "tags": []}]}]});
    let mut zip = zip::ZipWriter::new(fs::File::create(&pack).unwrap());
    let opt = zip::write::SimpleFileOptions::default();
    zip.start_file("manifest.json", opt).unwrap();
    zip.write_all(manifest.to_string().as_bytes()).unwrap();
    zip.start_file("media/a.jpg", opt).unwrap();
    zip.write_all(bytes).unwrap();
    zip.finish().unwrap();
    let rep = tl_core::archive::import_pack(&a, &pack).unwrap();
    let text = a.db().post_meta("p").unwrap().unwrap().text.unwrap();
    assert!(text.len() <= PostMeta::MAX_TEXT_BYTES && text.len() > PostMeta::MAX_TEXT_BYTES - 4, "cut at a character boundary: {}", text.len());
    assert!(rep.issues.iter().any(|i| i.category == "post_text_truncated"), "the report says what was cut");
    a.db().set_setting("later", Some("must sync")).unwrap();
    let (an, bn) = (SyncNode::new(a), SyncNode::new(b.clone()));
    let (x, y) = tokio::io::duplex(1 << 20);
    let (r1, r2) = tokio::join!(an.simulated_session(x, true), bn.simulated_session(y, false));
    assert!(r1.is_ok() && r2.is_ok(), "{r1:?} / {r2:?}");
    assert_eq!(b.db().setting("later").unwrap().as_deref(), Some("must sync"), "records after the imported post still arrive");
}

#[test]
fn post_fields_are_cut_at_character_boundaries() {
    let p = PostMeta { id: "x".into(), text: Some("é".repeat(PostMeta::MAX_TEXT_BYTES)), author_name: Some("a".repeat(10_000)), ..Default::default() };
    let (c, cut) = p.clamped();
    assert!(std::str::from_utf8(c.text.as_ref().unwrap().as_bytes()).is_ok());
    assert_eq!(c.text.as_ref().unwrap().len(), PostMeta::MAX_TEXT_BYTES);
    assert_eq!(c.author_name.as_ref().unwrap().len(), PostMeta::MAX_FIELD_BYTES);
    assert_eq!(cut, vec!["field.author", "field.text"]);
    let (same, none) = post("short").clamped();
    assert_eq!(same, post("short"));
    assert!(none.is_empty());
}

// ---- finding 7: a backup carries the analysis records and the tags of one moment ----

#[test]
fn backup_does_not_mix_old_tags_with_new_analysis_records() {
    let root = dir("backup-race");
    let l = Arc::new(Library::open(root.join("lib")).unwrap());
    let mut large = vec![0u8; 64 << 20];
    large[..4].copy_from_slice(b"\xff\xd8\xff\xe0");
    let (first, first_rel) = l.put_blob(&large, "jpg").unwrap();
    drop(large);
    let (second, second_rel) = l.put_blob(b"\xff\xd8\xff\xe0small", "jpg").unwrap();
    {
        let db = l.db();
        for (p, id, rel) in [("a", &first, &first_rel), ("z", &second, &second_rel)] {
            db.upsert_post(&post(p)).unwrap();
            db.add_media(id, p, 0, &MediaKind::Photo, rel, false).unwrap();
        }
    }
    let writer = l.clone();
    let pack = root.join("backup.tlpack");
    let out = pack.clone();
    let export = std::thread::spawn(move || tl_core::archive::export_backup(&writer, &out));
    while !tl_core::archive::export_progress().running {
        assert!(!export.is_finished());
        std::thread::yield_now();
    }
    // tagged while the large first file is still being written
    l.apply_ai_tags(&second, "m", &["newtag".into()], false).unwrap();
    export.join().unwrap().unwrap();
    let mut z = zip::ZipArchive::new(fs::File::open(&pack).unwrap()).unwrap();
    let mut raw = String::new();
    z.by_name("manifest.json").unwrap().read_to_string(&mut raw).unwrap();
    let m: tl_core::archive::Manifest = serde_json::from_str(&raw).unwrap();
    let item = &m.posts.iter().find(|p| p.meta.id == "z").unwrap().media[0];
    let analysed = item.ai_models.contains(&"m".to_string());
    let tagged = item.tags.iter().any(|t| t.label == "newtag");
    assert_eq!(analysed, tagged, "the analysis record and its tags are in the backup together (or neither is): {:?} / {:?}", item.ai_models, item.tags.iter().map(|t| &t.label).collect::<Vec<_>>());
}

// ---- finding 12: a zip entry is bounded, stoppable, and refused early when it is not media ----

struct Endless { sent: u64, head: &'static [u8] }
impl Read for Endless {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        for (i, b) in buf.iter_mut().enumerate() { *b = self.head.get((self.sent as usize) + i).copied().unwrap_or(0); }
        self.sent += buf.len() as u64;
        Ok(buf.len())
    }
}
fn leftovers(root: &std::path::Path) -> usize { fs::read_dir(root.join("tmp")).map(|d| d.count()).unwrap_or(0) }

#[test]
fn inflating_entry_stops_at_the_size_limit() {
    let root = dir("bomb");
    let l = Library::open(&root).unwrap();
    let mut endless = Endless { sent: 0, head: b"\xff\xd8\xff\xe0" };
    let e = l.put_reader_limited(&mut endless, &MediaKind::Photo, "jpg", 8 << 20, &|| false).unwrap_err();
    assert!(format!("{e:#}").contains("大小限制"), "{e:#}");
    assert!(endless.sent <= (8 << 20) + (1 << 20), "stopped near the limit, read {}", endless.sent);
    assert_eq!(leftovers(&root), 0, "the partial file is removed");
}

#[test]
fn inflating_entry_that_is_not_media_is_refused_from_its_first_bytes() {
    let root = dir("bomb-html");
    let l = Library::open(&root).unwrap();
    let mut endless = Endless { sent: 0, head: b"<html><body>" };
    let e = l.put_reader_limited(&mut endless, &MediaKind::Photo, "jpg", u64::MAX, &|| false).unwrap_err();
    assert!(format!("{e:#}").contains("内容不是"), "{e:#}");
    assert!(endless.sent <= 2 << 20, "refused after the first chunk, read {}", endless.sent);
    assert_eq!(leftovers(&root), 0);
}

#[test]
fn inflating_entry_honours_a_stop_request_between_chunks() {
    let root = dir("bomb-cancel");
    let l = Library::open(&root).unwrap();
    let mut endless = Endless { sent: 0, head: b"\xff\xd8\xff\xe0" };
    let reads = std::cell::Cell::new(0);
    let e = l.put_reader_limited(&mut endless, &MediaKind::Photo, "jpg", u64::MAX, &|| { reads.set(reads.get() + 1); reads.get() > 3 }).unwrap_err();
    assert!(format!("{e:#}").contains("已取消"), "{e:#}");
    assert_eq!(leftovers(&root), 0);
    // small files and ordinary ones are untouched
    let (id, rel) = l.put_reader(&mut &b"\xff\xd8\xff\xe0ok"[..], &MediaKind::Photo, "jpg").unwrap();
    assert!(root.join(rel).exists() && id.len() == 64);
}

// ---- finding 11: a model pull ends when cancelled, even when the peer never answers ----

#[tokio::test(flavor = "multi_thread")]
async fn cancellation_interrupts_a_stalled_model_handshake() {
    let _serial = serial();
    use std::time::Duration;
    use tokio::io::AsyncReadExt;
    let l = Arc::new(Library::open(dir("stalled-model")).unwrap());
    let n = SyncNode::new(l);
    n.start(Some(tl_core::sync::Account::generate()), "review".into()).await.unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let worker_node = n.clone();
    let worker = tokio::spawn(async move { worker_node.pull_model("127.0.0.1", port, "review-model", "review", 0).await });
    let (mut connection, _) = listener.accept().await.unwrap();
    let size = connection.read_u32().await.unwrap();
    let mut hello = vec![0; size as usize];
    connection.read_exact(&mut hello).await.unwrap();
    // the peer now says nothing at all; the user leaves the account
    tl_core::models::cancel();
    n.reset();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let stuck = !worker.is_finished();
    let running = tl_core::models::status().unwrap().running;
    drop(connection);
    let _ = worker.await;
    assert!(!stuck && !running, "cancel or leaving the account ends the wait without peer traffic");
}

#[tokio::test(flavor = "multi_thread")]
async fn leaving_the_account_alone_interrupts_a_stalled_handshake() {
    let _serial = serial();
    use std::time::Duration;
    use tokio::io::AsyncReadExt;
    let l = Arc::new(Library::open(dir("stalled-account")).unwrap());
    let n = SyncNode::new(l);
    n.start(Some(tl_core::sync::Account::generate()), "review".into()).await.unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let worker_node = n.clone();
    let worker = tokio::spawn(async move { worker_node.peer_models("127.0.0.1", port).await });
    let (mut connection, _) = listener.accept().await.unwrap();
    let size = connection.read_u32().await.unwrap();
    let mut hello = vec![0; size as usize];
    connection.read_exact(&mut hello).await.unwrap();
    n.reset();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let stuck = !worker.is_finished();
    drop(connection);
    let _ = worker.await;
    assert!(!stuck, "the account change ends the wait");
}

// ---- search: a term matches every tag that contains it, with or without the semantic part ----

#[test]
fn search_term_matches_tags_that_contain_it_without_semantic_search() {
    use tl_core::{library::{FeedRequest, SearchFields}, model::{Origin, SearchScope}};
    let l = Library::open(dir("substring")).unwrap();
    let (id, rel) = l.put_blob(b"\xff\xd8\xff\xe0baseball", "jpg").unwrap();
    {
        let db = l.db();
        db.upsert_post(&post("p")).unwrap();
        db.add_media(&id, "p", 0, &MediaKind::Photo, &rel, false).unwrap();
        db.tag_media(&id, "棒球服", Origin::AI).unwrap();
    }
    let run = |term: &str, fuzzy: bool| l.feed(&FeedRequest {
        whole_posts: false, newest_first: false, terms: vec![term.into()], scope: SearchScope::Both, seed: Some(0), fuzzy, term_vectors: vec![], embed_model: None, threshold: 0.7,
        fields: SearchFields { tags: true, text: true, author: true }, filter: Default::default(),
    }).unwrap().len();
    assert_eq!(run("棒球", false), 1, "no embedding model: still a containing match");
    assert_eq!(run("棒球", true), 1);
    assert_eq!(run("棒球服", false), 1);
    assert_eq!(run("篮球", false), 0);
}

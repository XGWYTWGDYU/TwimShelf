//! What a peer (or a broken device) sends can never reach outside the library, break this
//! device's own log, or push its clock to the end of time; wiping is a barrier; and the merge
//! keeps what both devices meant. Each test is one case from the code review.
use std::sync::Arc;
use tl_core::library::{FeedRequest, Library};
use tl_core::model::{MediaKind, Origin, PostMeta};
use tl_core::oplog::{LoggedOp, Op, VersionVector};
use tl_core::store::Store;

fn tmp(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("tl-safety-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

fn op(device: &str, seq: i64, op: Op) -> LoggedOp { LoggedOp { device: device.into(), seq, op } }

/// A media record whose id/extension form a path ("." + "/library.sqlite" → blobs/./../library.sqlite)
/// followed by a permanent deletion: the database file must survive, and nothing is opened.
#[test]
fn forged_media_paths_never_touch_files_outside_blobs() {
    let dir = tmp("path");
    let lib = Library::open(&dir).unwrap();
    let victim = dir.join("library.sqlite");
    assert!(victim.exists());
    let ops = vec![
        op("evil", 1, Op::Post { meta: PostMeta { id: "p".into(), ..Default::default() }, hlc: 1 }),
        op("evil", 2, Op::Media { id: ".".into(), post_id: "p".into(), ordinal: 0, kind: MediaKind::Photo, ext: "/library.sqlite".into() }),
        op("evil", 3, Op::Trash { media_id: ".".into(), inc: 0, state: 2, hlc: 2 }),
        // non-ASCII id: used to panic while forming the path
        op("evil", 4, Op::Media { id: "€".into(), post_id: "p".into(), ordinal: 1, kind: MediaKind::Photo, ext: "jpg".into() }),
    ];
    let d2 = dir.clone();
    let r = lib.db().apply_remote_counted(&ops, |id, ext| d2.join(tl_core::oplog::blob_rel(id, ext)).exists()).unwrap();
    assert_eq!(r.applied, 4, "stored as part of the device's log");
    assert_eq!(r.invalid, 2, "both forged media are without effect");
    lib.settle().unwrap();
    assert!(victim.exists(), "the database file is still there");
    let n: i64 = lib.db().conn().query_row("SELECT count(*) FROM media", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 0);
    assert_eq!(tl_core::oplog::blob_rel("€", "jpg"), "blobs/invalid/invalid");
    // a row that somehow points elsewhere is never deleted either
    lib.db().conn().execute("INSERT INTO media VALUES('x','p',0,'photo','../library.sqlite')", []).unwrap();
    lib.db().conn().execute("INSERT INTO trash VALUES('x',0,2,5)", []).unwrap();
    lib.db().conn().execute("INSERT INTO gc VALUES('x')", []).unwrap();
    lib.settle().unwrap();
    assert!(victim.exists());
    assert_eq!(lib.check_file("x", "../library.sqlite"), Some("missing"), "never read outside blobs/");
    drop(lib);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A record claiming this device's id with seq = i64::MAX: refused, and local writes go on.
#[test]
fn forged_sequence_numbers_are_refused() {
    let s = Store::open(":memory:").unwrap();
    s.upsert_post(&PostMeta { id: "a".into(), ..Default::default() }).unwrap();
    let me = s.device_id().unwrap();
    let forged = op(&me, i64::MAX, Op::Post { meta: PostMeta { id: "b".into(), ..Default::default() }, hlc: 9 });
    let r = s.apply_remote_counted(&[forged], |_, _| false).unwrap();
    assert_eq!((r.applied, r.refused), (0, 1));
    for i in 0..3 { s.upsert_post(&PostMeta { id: format!("c{i}"), ..Default::default() }).unwrap(); }
    assert_eq!(s.version_vector().unwrap()[&me], 4, "the local log keeps counting 1, 2, 3, 4");
    // another device's log with a gap: only the contiguous part is taken
    let other = [op("dev-b", 1, Op::Recent { post_id: "a".into(), at: 1 }), op("dev-b", 3, Op::Recent { post_id: "a".into(), at: 3 })];
    let r = s.apply_remote_counted(&other, |_, _| false).unwrap();
    assert_eq!((r.applied, r.refused), (1, 1));
    assert_eq!(s.version_vector().unwrap()["dev-b"], 1);
    // malformed device ids are refused
    let r = s.apply_remote_counted(&[op("../x", 1, Op::Recent { post_id: "a".into(), at: 1 })], |_, _| false).unwrap();
    assert_eq!(r.refused, 1);
}

/// A record stamped at the end of time does not become our clock: later local edits still win.
#[test]
fn far_future_clocks_do_not_poison_ours() {
    let s = Store::open(":memory:").unwrap();
    let r = s.apply_remote_counted(&[op("dev-b", 1, Op::Tag { media_id: "m".into(), label: "x".into(), origin: 1, mask: 3, hlc: u64::MAX })], |_, _| false).unwrap();
    assert_eq!(r.applied, 1);
    let h = s.next_hlc().unwrap();
    assert!(h < u64::MAX / 2, "our clock stays near wall time");
    // a peer a few seconds ahead is still followed
    let soon = (tl_core::store::now_ms() + 5_000) << 16;
    s.apply_remote_counted(&[op("dev-b", 2, Op::Recent { post_id: "p".into(), at: 1 }), op("dev-b", 3, Op::Folder { name: "f".into(), deleted: false, hlc: soon })], |_, _| false).unwrap();
    assert!(s.next_hlc().unwrap() > soon);
}

/// Other devices' logs arrive device by device, so a media can come before its post. It used to
/// break the whole batch (foreign key) on every retry; now it waits and appears with the post.
#[test]
fn media_before_its_post_waits_instead_of_failing() {
    let id = "c".repeat(64);
    let s = Store::open(":memory:").unwrap();
    let r = s.apply_remote_counted(&[op("dev-a", 1, Op::Media { id: id.clone(), post_id: "p".into(), ordinal: 0, kind: MediaKind::Photo, ext: "jpg".into() })], |_, _| true).unwrap();
    assert_eq!(r.applied, 1);
    let n: i64 = s.conn().query_row("SELECT count(*) FROM media", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 0, "not yet: its post is unknown");
    s.apply_remote_counted(&[op("dev-b", 1, Op::Post { meta: PostMeta { id: "p".into(), ..Default::default() }, hlc: 1 })], |_, _| true).unwrap();
    let path: String = s.conn().query_row("SELECT path FROM media WHERE id=?1", [&id], |r| r.get(0)).unwrap();
    assert_eq!(path, format!("blobs/cc/{id}.jpg"));
}

/// The same tag added by hand on one device and by AI on another keeps both bits, in any order.
#[test]
fn hand_and_ai_tags_from_two_devices_keep_both_bits() {
    let id = "d".repeat(64);
    let a = Store::open(":memory:").unwrap();
    let b = Store::open(":memory:").unwrap();
    for s in [&a, &b] {
        s.upsert_post(&PostMeta { id: "p".into(), ..Default::default() }).unwrap();
        s.add_media(&id, "p", 0, &MediaKind::Photo, &format!("blobs/dd/{id}.jpg"), false).unwrap();
    }
    a.tag_media(&id, "猫", Origin::AI).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(3));
    b.tag_media(&id, "猫", Origin::USER).unwrap();   // newer, and b never saw the AI tag
    let (oa, ob) = (a.ops_since(&VersionVector::new(), 1000).unwrap(), b.ops_since(&VersionVector::new(), 1000).unwrap());
    a.apply_remote(&ob, |_, _| true).unwrap();
    b.apply_remote(&oa, |_, _| true).unwrap();
    for s in [&a, &b] { assert_eq!(s.media_tags(&id).unwrap(), vec![("猫".to_string(), 3)]); }
    // a removal after both removes it everywhere
    std::thread::sleep(std::time::Duration::from_millis(3));
    a.untag_media(&id, "猫").unwrap();
    let have = b.version_vector().unwrap();
    b.apply_remote(&a.ops_since(&have, 1000).unwrap(), |_, _| true).unwrap();
    for s in [&a, &b] { assert_eq!(s.media_tags(&id).unwrap(), vec![("猫".to_string(), 0)]); }
}

/// Fuzzy search fills the vector cache while a wipe runs: the two used to take their locks in
/// opposite orders (search: cache, then store; wipe: store, then cache) and could freeze each
/// other forever. Checked deterministically: while the store is held, a search with a cold cache
/// must wait for the store without holding the cache.
#[test]
fn search_never_holds_the_cache_while_waiting_for_the_store() {
    let dir = tmp("lock");
    let lib = Arc::new(Library::open(&dir).unwrap());
    lib.set_vectors("m", &[("猫".into(), vec![1.0, 0.0])]).unwrap();   // leaves the cache cold
    let store = lib.db();   // like a wipe in progress
    let l = lib.clone();
    // (the vector lookup itself: a search reaches it after reading the labels)
    let search = std::thread::spawn(move || l.load_vectors_for_test("m"));
    std::thread::sleep(std::time::Duration::from_millis(300));   // the search is now waiting for the store
    assert!(!lib.vector_cache_busy(), "the waiting search must not hold the cache (a wipe needs it next)");
    drop(store);
    assert_eq!(search.join().unwrap(), 1);
    let req: FeedRequest = serde_json::from_value(serde_json::json!({ "terms": ["猫"], "scope": "both", "term_vectors": [[1.0, 0.0]], "embed_model": "m" })).unwrap();
    lib.feed(&req).unwrap();
    // and wipes interleaved with searches finish
    for _ in 0..20 { lib.wipe(false).unwrap(); lib.set_vectors("m", &[("猫".into(), vec![1.0, 0.0])]).unwrap(); }
    let _ = std::fs::remove_dir_all(&dir);
}

/// Work started before a wipe (a download that already fetched its files, a sync session) can
/// no longer write: the store refuses it after the wipe.
#[test]
fn wipe_is_a_barrier_for_earlier_work() {
    let dir = tmp("epoch");
    let lib = Library::open(&dir).unwrap();
    let before = lib.epoch();
    assert!(lib.db_at(before).is_ok());
    lib.wipe(false).unwrap();
    assert!(lib.db_at(before).is_err(), "old work stops");
    assert!(lib.db_at(lib.epoch()).is_ok(), "new work goes on");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Startup removes files nothing refers to (a download that stopped between storing a file and
/// recording it) and leaves every referenced or unrecognized file alone.
#[test]
fn orphan_files_are_swept_at_startup() {
    let dir = tmp("orphan");
    {
        let lib = Library::open(&dir).unwrap();
        let (sha, rel) = lib.put_blob(b"\xFF\xD8\xFF\xE0 jpeg bytes", "jpg").unwrap();
        lib.db().upsert_post(&PostMeta { id: "p".into(), ..Default::default() }).unwrap();
        lib.db().add_media(&sha, "p", 0, &MediaKind::Photo, &rel, false).unwrap();
        let orphan = format!("{}", "e".repeat(64));
        std::fs::create_dir_all(dir.join("blobs/ee")).unwrap();
        std::fs::write(dir.join(format!("blobs/ee/{orphan}.jpg")), b"x").unwrap();
        std::fs::write(dir.join("blobs/ee/notes.txt"), b"x").unwrap();
    }
    let lib = Library::open(&dir).unwrap();
    assert!(!dir.join(format!("blobs/ee/{}.jpg", "e".repeat(64))).exists(), "orphan removed");
    assert!(dir.join("blobs/ee/notes.txt").exists(), "unrecognized names are never touched");
    let n: i64 = lib.db().conn().query_row("SELECT count(*) FROM media", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 1);
    let rel: String = lib.db().conn().query_row("SELECT path FROM media", [], |r| r.get(0)).unwrap();
    assert!(dir.join(rel).exists(), "referenced file kept");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The migration is one transaction: a database left half-migrated (columns added, version not
/// yet written) opens normally, and one written by a newer app is refused instead of downgraded.
#[test]
fn migration_is_atomic_and_never_downgrades() {
    let dir = tmp("mig");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("db.sqlite");
    {
        let s = Store::open(path.to_str().unwrap()).unwrap();
        s.upsert_post(&PostMeta { id: "keep".into(), text: Some("原文".into()), ..Default::default() }).unwrap();
        // the v3 → v4 columns are present but the version still says 3 (a crash right after them)
        s.conn().execute_batch("PRAGMA user_version=3;").unwrap();
    }
    let s = Store::open(path.to_str().unwrap()).unwrap();
    let text: String = s.conn().query_row("SELECT text FROM post WHERE id='keep'", [], |r| r.get(0)).unwrap();
    assert_eq!(text, "原文");
    s.conn().execute_batch("PRAGMA user_version=99;").unwrap();
    drop(s);
    let e = Store::open(path.to_str().unwrap()).err().expect("a newer library is refused");
    assert!(e.to_string().contains("更新版本"), "{e}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Awaited files: the same content under another extension is not requested forever, a smaller
/// owner claim that arrived from a peer survives a local import, and deleting a post also
/// deletes its media that are still on the way.
#[test]
fn awaited_files_follow_the_same_rules_as_stored_ones() {
    let dir = tmp("want");
    let lib = Library::open(&dir).unwrap();
    let (sha, rel) = lib.put_blob(b"\x00\x00\x00\x18ftypmp42 video", "mp4").unwrap();
    {
        let db = lib.db();
        db.upsert_post(&PostMeta { id: "p200".into(), ..Default::default() }).unwrap();
        db.add_media(&sha, "p200", 0, &MediaKind::Video, &rel, false).unwrap();
        // another device stored the same content as .mov
        db.apply_remote_counted(&[op("dev-b", 1, Op::Post { meta: PostMeta { id: "p100".into(), ..Default::default() }, hlc: 1 }),
            op("dev-b", 2, Op::Media { id: sha.clone(), post_id: "p100".into(), ordinal: 0, kind: MediaKind::Video, ext: "mov".into() })], |_, _| false).unwrap();
        assert!(db.wanted_blobs(10).unwrap().is_empty(), "nothing to fetch: the file is here");
        let owner: String = db.conn().query_row("SELECT post_id FROM media WHERE id=?1", [&sha], |r| r.get(0)).unwrap();
        assert_eq!(owner, "p100", "the smaller claim wins as on every device");
    }
    // a post whose media is still on the way, deleted here before it arrives
    let id = "f".repeat(64);
    lib.db().apply_remote_counted(&[op("dev-b", 3, Op::Post { meta: PostMeta { id: "gone".into(), ..Default::default() }, hlc: 2 }),
        op("dev-b", 4, Op::Media { id: id.clone(), post_id: "gone".into(), ordinal: 0, kind: MediaKind::Photo, ext: "jpg".into() })], |_, _| false).unwrap();
    lib.trash_post("gone").unwrap();
    std::fs::create_dir_all(dir.join("blobs/ff")).unwrap();
    std::fs::write(dir.join(format!("blobs/ff/{id}.jpg")), b"x").unwrap();
    lib.db().blob_arrived(&id).unwrap();
    let live = lib.db().live_media_of_post("gone").unwrap();
    assert!(live.is_empty(), "the deleted post does not come back when its file arrives");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Media are fetched from X's media servers only.
#[test]
fn media_addresses_are_x_media_servers_only() {
    use tl_core::rules::media_url_ok;
    for ok in ["https://pbs.twimg.com/media/abc?format=jpg&name=orig", "https://video.twimg.com/ext_tw_video/1/pu/vid/720x1280/a.mp4?tag=12"] { assert!(media_url_ok(ok), "{ok}"); }
    for bad in ["http://pbs.twimg.com/media/a.jpg", "https://127.0.0.1:8080/a.jpg", "https://evil.com/twimg.com/a.jpg",
                "https://pbs.twimg.com.evil.com/a.jpg", "https://user@pbs.twimg.com/a.jpg", "https://pbs.twimg.com:444/a.jpg", "file:///etc/passwd", "https://eviltwimg.com/a.jpg"] {
        assert!(!media_url_ok(bad), "{bad}");
    }
}


/// A rename rule from a backup never clears a newer rule of this library (backup: a → b;
/// here, later: b → c): a ends up shown as c and b → c stays.
#[test]
fn restored_renames_do_not_clobber_newer_rules() {
    let s = Store::open(":memory:").unwrap();
    let m = "b".repeat(64);
    for l in ["a", "b"] { s.tag_media(&m, l, Origin::USER).unwrap(); }
    s.rename_tag("b", "c").unwrap();
    assert!(s.restore_rename("a", "b").unwrap());
    assert_eq!(s.canonical("a").unwrap(), "c");
    assert_eq!(s.canonical("b").unwrap(), "c", "the newer rule is kept");
    // a name with a rule of its own (or one the user removed) is left alone
    assert!(!s.restore_rename("b", "x").unwrap());
}

//! UI contracts: the same target set for preview/execution, exact undo, durable cancellation.
use std::{sync::Arc, time::{Instant, Duration}};
use tl_core::{actions::{ActionKind as K, ActionRequest}, library::Library, model::{PostMeta, MediaKind, Origin}, oplog::{Op, LoggedOp}, rules::{self, TrashAction}, store::Store};
struct Fixture { lib: Arc<Library> }
impl Fixture {
    fn new(n: usize) -> Self {
        let lib = Arc::new(Library::open(std::env::temp_dir().join(format!("tl-frontend-{}", rand::random::<u64>()))).unwrap());
        lib.db().upsert_post(&PostMeta { id: "p".into(), ..Default::default() }).unwrap();
        for i in 0..n { let id = id(i); lib.db().add_media(&id, "p", i as i64, &MediaKind::Photo, &format!("blobs/{id}.jpg"), false).unwrap(); }
        Self { lib }
    }
    fn pending(&self) -> String {
        let id = "f".repeat(64);
        self.lib.db().apply_remote(&[LoggedOp { device: "remote".into(), seq: 1, op: Op::Media { id: id.clone(), post_id: "p".into(), ordinal: 100, kind: MediaKind::Photo, ext: "jpg".into() } }], |_, _| false).unwrap(); id
    }
}
impl Drop for Fixture { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.lib.dir); } }
fn id(i: usize) -> String { format!("{:064x}", i + 1) }
fn action(kind: K, media: Vec<String>, posts: Vec<String>) -> ActionRequest { ActionRequest { kind, media, posts, folder: Some("f".into()), label: Some("label".into()), expected: None, epoch: None } }
fn wait(mut done: impl FnMut() -> bool) { let until = Instant::now() + Duration::from_secs(8); while !done() { assert!(Instant::now() < until); std::thread::sleep(Duration::from_millis(5)); } }
#[test] fn delete_undo_preserves_preexisting_trash_and_restores_pending() {
    let f = Fixture::new(2); let p = f.pending();
    f.lib.trash_apply(&[id(0)], TrashAction::Trash).unwrap();
    let r = f.lib.apply_action(&action(K::Trash, vec![], vec!["p".into()])).unwrap(); assert_eq!(r.changes.len(), 2);
    assert_eq!(f.lib.undo_action(&r).unwrap(), 2);
    assert_eq!(f.lib.db().trash_reg(&id(0)).unwrap().state, rules::TRASHED);
    assert_eq!(f.lib.db().trash_reg(&p).unwrap().state, rules::LIVE);
}
#[test] fn folder_undo_preserves_old_members_and_later_edits() {
    let f = Fixture::new(3); f.lib.db().add_to_folder("f", &[id(0)]).unwrap();
    let r = f.lib.apply_action(&action(K::FolderAdd, vec![], vec!["p".into()])).unwrap(); assert_eq!(r.changes.len(), 2);
    f.lib.db().remove_from_folder("f", &[id(1)]).unwrap(); f.lib.db().add_to_folder("f", &[id(1)]).unwrap();
    assert_eq!(f.lib.undo_action(&r).unwrap(), 1);
    for i in [0, 1] { assert_eq!(f.lib.db().folders_of(&id(i)).unwrap(), vec!["f"]); }
    assert!(f.lib.db().folders_of(&id(2)).unwrap().is_empty());
}
#[test] fn folder_removal_undo_does_not_recreate_a_deleted_folder() {
    let f = Fixture::new(1); f.lib.db().add_to_folder("f", &[id(0)]).unwrap();
    let r = f.lib.apply_action(&action(K::FolderRemove, vec![id(0)], vec![])).unwrap();
    f.lib.db().delete_folder("f").unwrap();
    assert_eq!(f.lib.undo_action(&r).unwrap(), 0); assert!(f.lib.db().folders().unwrap().is_empty());
}
#[test] fn trash_undo_does_not_overwrite_a_later_remote_delete() {
    let f = Fixture::new(1); let r = f.lib.apply_action(&action(K::Trash, vec![id(0)], vec![])).unwrap();
    let stamp = &r.changes[0];
    f.lib.db().apply_remote(&[LoggedOp { device: "remote".into(), seq: 1, op: Op::Trash { media_id: id(0), inc: stamp.inc, state: rules::TRASHED, hlc: stamp.hlc + 100 } }], |_, _| false).unwrap();
    assert_eq!(f.lib.undo_action(&r).unwrap(), 0); assert_eq!(f.lib.db().trash_reg(&id(0)).unwrap().state, rules::TRASHED);
}
#[test] fn bin_confirmation_freezes_ids_and_skips_changed_incarnations() {
    let f = Fixture::new(3); let p = f.pending(); f.lib.trash_apply(&[id(0), id(1), p.clone()], TrashAction::Trash).unwrap();
    let snapshot = f.lib.bin_snapshot().unwrap(); assert_eq!(snapshot.entries.len(), 3); assert_eq!(snapshot.pending_count, 1);
    f.lib.trash_apply(&[id(2)], TrashAction::Trash).unwrap(); // after the confirmation
    f.lib.trash_apply(&[id(0)], TrashAction::Restore).unwrap(); f.lib.trash_apply(&[id(0)], TrashAction::Trash).unwrap();
    let mut a = action(K::Purge, vec![], vec![]); a.expected = Some(snapshot.entries); a.epoch = Some(snapshot.epoch);
    assert_eq!(f.lib.apply_action(&a).unwrap().changes.len(), 2);
    assert_eq!(f.lib.db().trash_reg(&p).unwrap().state, rules::PURGED);
    for i in [0, 2] { assert_eq!(f.lib.db().trash_reg(&id(i)).unwrap().state, rules::TRASHED); }
}
#[test] fn restore_all_includes_pending_and_undo_respects_newer_changes() {
    let f = Fixture::new(1); let p = f.pending(); f.lib.trash_post("p").unwrap(); let snapshot = f.lib.bin_snapshot().unwrap();
    let mut a = action(K::Restore, vec![], vec![]); a.expected = Some(snapshot.entries);
    let r = f.lib.apply_action(&a).unwrap(); assert_eq!(r.changes.len(), 2);
    f.lib.trash_apply(&[p.clone()], TrashAction::Trash).unwrap(); f.lib.trash_apply(&[p.clone()], TrashAction::Restore).unwrap();
    assert_eq!(f.lib.undo_action(&r).unwrap(), 1); assert_eq!(f.lib.db().trash_reg(&p).unwrap().state, rules::LIVE);
}
#[test] fn whole_post_tags_and_folders_include_hidden_and_pending_media() {
    let f = Fixture::new(3); let pending = f.pending(); f.lib.db().tag_media(&id(0), "label", Origin::USER).unwrap();
    let scope = f.lib.db().post_scope("p").unwrap(); assert_eq!(scope.ids.len(), 4); assert_eq!(scope.pending_count, 1);
    f.lib.apply_action(&action(K::Tag, vec![], vec!["p".into()])).unwrap();
    for id in &scope.ids { assert!(f.lib.db().media_tags(id).unwrap().iter().any(|(l,o)| l == "label" && o & 1 != 0)); }
    f.lib.apply_action(&action(K::FolderAdd, vec![], vec!["p".into()])).unwrap();
    assert_eq!(f.lib.apply_action(&action(K::FolderRemove, vec![], vec!["p".into()])).unwrap().changes.len(), 4);
    f.lib.db().blob_arrived(&pending).unwrap(); assert!(f.lib.db().folders_of(&pending).unwrap().is_empty());
}
#[test] fn bulk_action_rolls_back_on_database_failure() {
    let f = Fixture::new(2);
    f.lib.db().conn().execute_batch(&format!("CREATE TRIGGER fail_second BEFORE INSERT ON trash WHEN NEW.media_id='{}' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;", id(1))).unwrap();
    assert!(f.lib.apply_action(&action(K::Trash, vec![], vec!["p".into()])).is_err());
    assert_eq!(f.lib.db().trash_reg(&id(0)).unwrap().state, rules::LIVE);
}
#[test] fn old_receipts_and_confirmations_cannot_cross_a_wipe() {
    let f = Fixture::new(1); let r = f.lib.apply_action(&action(K::Trash, vec![id(0)], vec![])).unwrap(); let b = f.lib.bin_snapshot().unwrap();
    f.lib.wipe(false).unwrap(); assert!(f.lib.undo_action(&r).is_err());
    let mut a = action(K::Purge, vec![], vec![]); a.expected = Some(b.entries); a.epoch = Some(b.epoch);
    assert!(f.lib.apply_action(&a).is_err());
}
#[test] fn paused_and_cancelled_jobs_survive_reopen_without_becoming_pending() {
    let path = std::env::temp_dir().join(format!("tl-jobs-{}.db", rand::random::<u64>()));
    { let s = Store::open(path.to_str().unwrap()).unwrap(); s.enqueue_job("a").unwrap(); let epoch = s.pending_jobs_epoch().unwrap()[0].1; s.stop_jobs(true).unwrap(); assert!(!s.finish_job_epoch("a", epoch, None).unwrap()); }
    { let s = Store::open(path.to_str().unwrap()).unwrap(); assert!(s.pending_jobs().unwrap().is_empty()); assert_eq!(s.paused_jobs().unwrap(), 1); s.resume_jobs().unwrap(); assert_eq!(s.pending_jobs().unwrap(), vec!["a"]); s.stop_jobs(false).unwrap(); }
    { let s = Store::open(path.to_str().unwrap()).unwrap(); assert!(s.pending_jobs().unwrap().is_empty()); assert_eq!(s.paused_jobs().unwrap(), 0); assert_eq!(s.resume_jobs().unwrap(), 0); }
    let _ = std::fs::remove_file(path);
}
#[test] fn cancel_running_download_removes_unfinished_jobs() {
    let f = Fixture::new(0);
    let req = serde_json::from_value(serde_json::json!({"urls":(0..8).map(|i|format!("invalid-synthetic-{i}")).collect::<Vec<_>>(),"concurrency":1,"interval_ms":500})).unwrap();
    tl_core::download::start(f.lib.clone(), req).unwrap(); wait(|| tl_core::download::status().failed > 0);
    assert!(tl_core::download::stop(&f.lib, false).unwrap() > 0); wait(|| !tl_core::download::status().running);
    assert_eq!(tl_core::download::status().outcome, "cancelled"); assert!(f.lib.db().pending_jobs().unwrap().is_empty());
    let req = serde_json::from_value(serde_json::json!({"urls":(0..8).map(|i|format!("invalid-pause-{i}")).collect::<Vec<_>>(),"concurrency":1,"interval_ms":500})).unwrap();
    tl_core::download::start(f.lib.clone(), req).unwrap(); wait(|| tl_core::download::status().failed > 0);
    assert!(tl_core::download::stop(&f.lib, true).unwrap() > 0); wait(|| !tl_core::download::status().running);
    let paused = f.lib.db().paused_jobs().unwrap(); assert!(paused > 0); assert!(f.lib.db().pending_jobs().unwrap().is_empty());
    let resume = serde_json::from_value(serde_json::json!({"urls":[],"interval_ms":0})).unwrap();
    assert_eq!(tl_core::download::resume(f.lib.clone(), resume).unwrap(), paused);
    wait(|| !tl_core::download::status().running);
    assert_eq!(f.lib.db().paused_jobs().unwrap(), 0); assert_eq!(tl_core::download::status().failed, paused);
}
#[test] fn verification_records_unknown_partial_and_new_media() {
    let f = Fixture::new(1);
    let initial = tl_core::verify::summary(&f.lib).unwrap(); assert!(initial.last.is_none()); assert_eq!(initial.unchecked, 1); assert_eq!(initial.bad, 0);
    tl_core::verify::start(f.lib.clone()).unwrap(); wait(|| !tl_core::verify::status().running);
    let checked = tl_core::verify::summary(&f.lib).unwrap(); assert_eq!(checked.bad, 1); assert_eq!(checked.unchecked, 0); assert_eq!(checked.last.unwrap().outcome, "partial");
    f.lib.db().add_media(&id(1), "p", 1, &MediaKind::Photo, "missing2.jpg", false).unwrap();
    assert_eq!(tl_core::verify::summary(&f.lib).unwrap().unchecked, 1);
    let bytes = vec![42; 32 << 20]; let (sha, rel) = f.lib.put_blob(&bytes, "jpg").unwrap();
    f.lib.db().add_media(&sha, "p", 3, &MediaKind::Photo, &rel, false).unwrap();
    tl_core::verify::start(f.lib.clone()).unwrap(); tl_core::verify::cancel();
    wait(|| !tl_core::verify::status().running);
    let cancelled = tl_core::verify::summary(&f.lib).unwrap().last.unwrap();
    assert_eq!(cancelled.outcome, "cancelled"); assert!(!cancelled.finished);
}
#[test] fn schema_migration_preserves_v13_data() {
    let path = std::env::temp_dir().join(format!("tl-migration-{}.db", rand::random::<u64>()));
    { let s = Store::open(path.to_str().unwrap()).unwrap(); s.upsert_post(&PostMeta { id: "keep".into(), ..Default::default() }).unwrap(); s.conn().execute_batch("DROP TABLE verified_media; PRAGMA user_version=13;").unwrap(); }
    { let s = Store::open(path.to_str().unwrap()).unwrap(); assert_eq!(s.conn().query_row("SELECT count(*) FROM post WHERE id='keep'", [], |r|r.get::<_,i64>(0)).unwrap(), 1); assert_eq!(s.conn().query_row("SELECT count(*) FROM verified_media", [], |r|r.get::<_,i64>(0)).unwrap(), 0); }
    let _ = std::fs::remove_file(path);
}

/// Triage mode was removed in schema 15: a library from an older version (with its local
/// `triage` table) opens without it, whatever version it comes from; a current one is untouched.
#[test] fn old_triage_records_are_dropped_on_upgrade() {
    let d = std::env::temp_dir().join(format!("tl-triage-drop-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap();
    let path = d.join("library.sqlite").to_string_lossy().into_owned();
    drop(Store::open(&path).unwrap());
    {
        let c = rusqlite::Connection::open(&path).unwrap();
        c.execute_batch("CREATE TABLE triage(post_id TEXT PRIMARY KEY, decision TEXT NOT NULL, folder TEXT, moved TEXT NOT NULL, at INTEGER NOT NULL);
            INSERT INTO triage VALUES('p','keep',NULL,'[]',0); PRAGMA user_version=12;").unwrap();
    }
    let s = Store::open(&path).unwrap();
    let left: i64 = s.conn().query_row("SELECT count(*) FROM sqlite_master WHERE name='triage'", [], |r| r.get(0)).unwrap();
    assert_eq!(left, 0);
    drop(s);
    let _ = std::fs::remove_dir_all(&d);
}

#[test] fn tag_undo_preserves_existing_user_and_ai_tags_and_later_edits() {
    let f = Fixture::new(3);
    f.lib.db().tag_media(&id(0), "label", tl_core::model::Origin::USER).unwrap();
    f.lib.db().tag_media(&id(1), "label", tl_core::model::Origin::AI).unwrap();
    let r = f.lib.apply_action(&action(K::Tag, vec![], vec!["p".into()])).unwrap();
    assert_eq!(r.changes.len(), 2);
    f.lib.db().untag_media(&id(2), "label").unwrap();
    f.lib.db().tag_media(&id(2), "label", tl_core::model::Origin::USER).unwrap();
    assert_eq!(f.lib.undo_action(&r).unwrap(), 1);
    assert_eq!(f.lib.db().media_tags(&id(0)).unwrap(), vec![("label".into(), 1)]);
    assert_eq!(f.lib.db().media_tags(&id(1)).unwrap(), vec![("label".into(), 2)]);
    assert_eq!(f.lib.db().media_tags(&id(2)).unwrap(), vec![("label".into(), 1)]);
    assert_eq!(f.lib.undo_action(&r).unwrap(), 0);
}

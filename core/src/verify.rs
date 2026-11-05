//! Background check of every stored media file: its SHA-256 must equal its id. Damaged or
//! missing files are recorded locally (`bad_media`, never synced); sync then fetches a verified
//! copy from a peer, and the app offers to download the post again.
use crate::library::Library;
use serde::{Serialize, Deserialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct VerifyStatus {
    #[serde(default)] pub outcome: String,
    #[serde(default)] pub completed_at: u64,
    pub running: bool,
    pub checked: u64,
    pub total: u64,
    pub bytes: u64,
    /// Damaged or missing files found in this run.
    pub bad: u64,
    /// Files found intact again (an earlier damage record was cleared).
    pub fixed: u64,
    pub finished: bool,
    /// Absolute path of the file being checked (for the progress card).
    pub current: Option<String>,
}

static STATUS: Mutex<Option<VerifyStatus>> = Mutex::new(None);
static START_LOCK: Mutex<()> = Mutex::new(());
static CANCEL: AtomicBool = AtomicBool::new(false);

pub fn status() -> VerifyStatus { STATUS.lock().unwrap().clone().unwrap_or_default() }
pub fn cancel() { CANCEL.store(true, Ordering::SeqCst); }
fn update(f: impl FnOnce(&mut VerifyStatus)) { f(STATUS.lock().unwrap().get_or_insert_with(Default::default)) }

/// Starts checking all live media in the background; returns how many will be checked.
pub fn start(lib: Arc<Library>) -> anyhow::Result<usize> {
    let _start = START_LOCK.lock().unwrap();
    if status().running { anyhow::bail!(tr!("verify.running")); }
    let list = lib.db().live_media_paths()?;
    let n = list.len();
    CANCEL.store(false, Ordering::SeqCst);
    let initial = VerifyStatus { running: true, outcome: "running".into(), total: n as u64, ..Default::default() };
    let epoch = lib.epoch();
    lib.db().meta_set("verification_status", &serde_json::to_string(&initial)?)?;
    *STATUS.lock().unwrap() = Some(initial);
    let worker_lib = lib.clone();
    let spawned = std::thread::Builder::new().name("tl-verify".into()).spawn(move || {
        let lib = worker_lib;
        for (id, rel) in list {
            if CANCEL.load(Ordering::SeqCst) { break; }
            let abs = lib.dir.join(&rel);
            update(|s| s.current = Some(abs.to_string_lossy().into_owned()));
            let size = std::fs::metadata(&abs).map_or(0, |m| m.len());
            let found = lib.check_file(&id, &rel);
            let Ok(db) = lib.db_at(epoch) else { update(|s| s.outcome = "cancelled".into()); break; };
            // The library changed while checking (deleted, binned, replaced): skip this media.
            let still = db.media_row(&id).ok().flatten().map_or(false, |r| r.3 == rel) && db.trash_reg(&id).map_or(false, |t| t.state == crate::rules::LIVE);
            if !still { drop(db); update(|s| s.checked += 1); continue; }
            let prev = db.bad_reason(&id).ok().flatten();
            // the mark and the record together: one disk flush per file, not two
            let written = (|| -> rusqlite::Result<(bool, bool)> {
                let tx = db.conn().unchecked_transaction()?;
                let (mut bad, mut fixed) = (false, false);
                match found {
                    Some(reason) => { db.set_bad(&id, Some(reason))?; bad = true; }
                    // An intact file that does not decode stays flagged ('decode'): it was broken at the source.
                    None if prev.as_deref().map_or(false, |p| p == "missing" || p == "hash") => { db.set_bad(&id, None)?; fixed = true; }
                    None => {}
                }
                db.conn().execute("INSERT OR REPLACE INTO verified_media VALUES(?1,?2,unixepoch())", rusqlite::params![id, rel])?;
                tx.commit()?;
                Ok((bad, fixed))
            })();
            let Ok((bad, fixed)) = written else { update(|s| s.outcome = "failed".into()); break; };
            if bad { update(|s| s.bad += 1); }
            if fixed { update(|s| s.fixed += 1); }
            drop(db);
            update(|s| { s.checked += 1; s.bytes += size; });
        }
        let mut final_state = status();
        final_state.running = false; final_state.current = None;
        if final_state.outcome == "running" { final_state.outcome = if CANCEL.load(Ordering::SeqCst) { "cancelled" } else if final_state.bad > 0 { "partial" } else { "succeeded" }.into(); }
        final_state.finished = matches!(final_state.outcome.as_str(), "succeeded" | "partial") && final_state.checked == final_state.total;
        if final_state.finished { final_state.completed_at = crate::store::now_ms(); }
        if let Ok(db) = lib.db_at(epoch) {
            if db.meta_set("verification_status", &serde_json::to_string(&final_state).unwrap()).is_err() { final_state.outcome = "failed".into(); final_state.finished = false; }
        }
        *STATUS.lock().unwrap() = Some(final_state);
    });
    if let Err(e) = spawned {
        update(|s| { s.running = false; s.outcome = "failed".into(); });
        let _ = lib.db().meta_set("verification_status", &serde_json::to_string(&status())?);
        return Err(e.into());
    }
    Ok(n)
}

#[derive(Serialize)]
pub struct IntegritySummary { pub total: i64, pub unchecked: i64, pub bad: i64, pub last: Option<VerifyStatus> }
pub fn summary(lib: &Library) -> anyhow::Result<IntegritySummary> {
    let db = lib.db();
    let total = db.conn().query_row(&format!("SELECT count(*) FROM media m WHERE {}", crate::store::LIVE_SQL), [], |r| r.get(0))?;
    let unchecked = db.conn().query_row(&format!("SELECT count(*) FROM media m WHERE {} AND NOT EXISTS(SELECT 1 FROM verified_media v WHERE v.media_id=m.id AND v.path=m.path)", crate::store::LIVE_SQL), [], |r| r.get(0))?;
    let mut last: Option<VerifyStatus> = db.meta_get("verification_status")?.and_then(|v| serde_json::from_str(&v).ok());
    if status().running { last = Some(status()); }
    else if let Some(s) = &mut last { if s.running { s.running = false; s.outcome = "interrupted".into(); s.finished = false; } }
    Ok(IntegritySummary { total, unchecked, bad: db.stats()?.bad, last })
}

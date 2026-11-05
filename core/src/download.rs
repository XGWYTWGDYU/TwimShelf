//! Resumable download queue with user-set concurrency and launch interval.
use crate::library::Library;
use crate::model::MediaKind;
use crate::net::{self, RemotePost};
use crate::protected::Credentials;
use anyhow::{anyhow, bail};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::io::AsyncWriteExt;

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Route { #[default] Auto, Fx, Cookie }

#[derive(Debug, Deserialize)]
pub struct DownloadRequest {
    pub urls: Vec<String>,
    #[serde(default = "one")] pub concurrency: usize,
    #[serde(default)] pub interval_ms: u64,
    #[serde(default)] pub route: Route,
    /// The user asked for these posts explicitly (a pasted link): media of them that are in the
    /// recycle bin or were deleted come back. Batch imports leave deleted media deleted.
    #[serde(default)] pub revive: bool,
    /// Put every downloaded post (and posts of these links already in the library) into this folder.
    #[serde(default)] pub folder: Option<String>,
    /// Mark newly downloaded posts "最近添加" (batch download from a bookmarks JSON).
    #[serde(default)] pub mark_recent: bool,
}
fn one() -> usize { 1 }

#[derive(Debug, Clone, Serialize, Default)]
pub struct DownloadStatus {
    pub outcome: String,
    pub paused: usize,
    pub running: bool,
    pub total: usize,
    pub done: usize,
    pub skipped: usize,
    pub failed: usize,
    pub active: Vec<String>,
    pub errors: VecDeque<(String, String)>,
    pub generation: u64,
    /// Absolute paths of the most recently stored media (newest last), for progress previews.
    pub recent: VecDeque<String>,
}

static STATUS: Mutex<Option<DownloadStatus>> = Mutex::new(None);
static CANCEL: AtomicBool = AtomicBool::new(false);
/// One media file is never larger than this (X's own limit is far lower).
const MAX_MEDIA_BYTES: u64 = 8 << 30;
static GENERATION: AtomicU64 = AtomicU64::new(0);
static COOKIES: Mutex<Option<Credentials>> = Mutex::new(None);

pub fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().expect("tokio"))
}

pub fn set_cookies(c: Option<Credentials>) { *COOKIES.lock().unwrap() = c; }
pub fn status() -> DownloadStatus { STATUS.lock().unwrap().clone().unwrap_or_default() }
pub fn cancel() { CANCEL.store(true, Ordering::SeqCst); update(|s| s.outcome = "cancelled".into()); }
pub fn stop(lib: &Library, pause: bool) -> anyhow::Result<usize> {
    let _guard = RUN_GUARD.lock().unwrap();
    let n = lib.db().stop_jobs(pause)?;
    CANCEL.store(true, Ordering::SeqCst);
    update(|s| s.outcome = if pause { "paused" } else { "cancelled" }.into());
    Ok(n)
}
async fn stopped() {
    while !CANCEL.load(Ordering::SeqCst) { tokio::time::sleep(std::time::Duration::from_millis(30)).await; }
}

fn update(f: impl FnOnce(&mut DownloadStatus)) {
    let mut g = STATUS.lock().unwrap();
    f(g.get_or_insert_with(Default::default));
}

/// Per-link options (each request may differ in route, revive, target folder and mark). Stored
/// with the job, so links left over from an interrupted run keep them after a restart.
#[derive(Clone, Serialize, Deserialize, Default)]
struct LinkOpts { #[serde(default)] route: Route, #[serde(default)] revive: bool, #[serde(default)] folder: Option<String>, #[serde(default)] recent: bool, #[serde(skip)] staged: bool }
/// Held while deciding whether the worker keeps running, so a request arriving just as the
/// worker finishes is never left waiting.
static RUN_GUARD: Mutex<bool> = Mutex::new(false);

/// Queues the URLs (plus any unfinished jobs from earlier runs) and works through them in the
/// background. A request made while a batch is running joins it (its links are appended).
/// Returns how many links are waiting now.
pub fn start(lib: Arc<Library>, req: DownloadRequest) -> anyhow::Result<usize> { start_impl(lib, req, false) }
pub fn resume(lib: Arc<Library>, req: DownloadRequest) -> anyhow::Result<usize> { start_impl(lib, req, true) }
fn start_impl(lib: Arc<Library>, req: DownloadRequest, resume_paused: bool) -> anyhow::Result<usize> {
    let opts = LinkOpts { route: req.route, revive: req.revive, folder: req.folder.clone().filter(|f| !f.trim().is_empty()), recent: req.mark_recent, staged: false };
    let opts_json = serde_json::to_string(&opts)?;
    let mut running = RUN_GUARD.lock().unwrap();
    if *running && CANCEL.load(Ordering::SeqCst) { bail!(tr!("download.stopping")); }
    let pending = {
        let db = lib.db();
        let tx = db.conn().unchecked_transaction()?;
        if resume_paused { db.resume_jobs()?; }
        for u in &req.urls { db.enqueue_job_with(u.trim(), Some(&opts_json))?; }
        tx.commit()?;
        db.pending_jobs()?
    };
    let n = pending.len();
    if *running {
        // join the running batch
        update(|s| s.total = s.done + s.skipped + s.failed + pending.len());   // in-flight links are still pending
        return Ok(n);
    }
    *running = true;
    let gen = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    CANCEL.store(false, Ordering::SeqCst);
    *STATUS.lock().unwrap() = Some(DownloadStatus { running: true, outcome: "running".into(), total: n, generation: gen, ..Default::default() });
    // only now: a stop or a joining download in between would be overwritten by the lines above
    drop(running);
    let concurrency = req.concurrency.clamp(1, 16);
    let interval = std::time::Duration::from_millis(req.interval_ms.min(600_000));
    runtime().spawn(async move {
        let sem = Arc::new(tokio::sync::Semaphore::new(concurrency));
        let mut tasks = vec![];
        // (link, request epoch) already started in this run: a link asked for again runs again
        let mut seen: std::collections::HashSet<(String, i64)> = std::collections::HashSet::new();
        let mut first = true;
        loop {
            // an unreadable queue is not an empty one: said in the diagnostics, tried again on the next start
            let fresh: Vec<(String, i64, Option<String>)> = lib.db().pending_jobs_epoch().inspect_err(|e| lib.diag("download_queue_unreadable", serde_json::json!({ "error": crate::diagnostics::scrub(&e.to_string()) }))).unwrap_or_default().into_iter().filter(|(u, e, _)| !seen.contains(&(u.clone(), *e))).collect();
            if fresh.is_empty() || CANCEL.load(Ordering::SeqCst) {
                for t in tasks.drain(..) { let _ = t.await; }
                // finish only if nothing new arrived meanwhile (checked under the guard)
                let mut g = RUN_GUARD.lock().unwrap();
                let more = !CANCEL.load(Ordering::SeqCst) && lib.db().pending_jobs_epoch().unwrap_or_default().iter().any(|(u, e, _)| !seen.contains(&(u.clone(), *e)));
                if more { drop(g); continue; }
                *g = false;
                update(|s| {
                    s.running = false;
                    if s.outcome == "running" { s.outcome = if s.failed == 0 { "succeeded" } else if s.done + s.skipped > 0 { "partial" } else { "failed" }.into(); }
                });
                break;
            }
            for (url, epoch, opts) in fresh {
                if CANCEL.load(Ordering::SeqCst) { break; }
                seen.insert((url.clone(), epoch));
                if !first && !interval.is_zero() { tokio::select! { _ = tokio::time::sleep(interval) => {}, _ = stopped() => { break; } } }
                first = false;
                let permit = sem.clone().acquire_owned().await.unwrap();
                if CANCEL.load(Ordering::SeqCst) { break; }
                let lib = lib.clone();
                let o: LinkOpts = opts.as_deref().and_then(|j| serde_json::from_str(j).ok()).unwrap_or_default();
                tasks.push(tokio::spawn(async move {
                    update(|s| s.active.push(url.clone()));
                    let r = tokio::select! { r = process(&lib, &url, &o) => r, _ = stopped() => Err(anyhow!(tr!("download.stopped"))) };
                    // the cause only (the link itself is the user's content)
                    if let Err(e) = &r { if !CANCEL.load(Ordering::SeqCst) { lib.diag("download_error", serde_json::json!({ "route": format!("{:?}", o.route), "error": crate::diagnostics::scrub(&format!("{e:#}")) })); } }
                    let counts = lib.db().finish_job_epoch(&url, epoch, r.as_ref().err().map(|e| e.to_string())).unwrap_or(true);
                    update(|s| {
                        s.active.retain(|u| u != &url);
                        if !counts { return; }   // superseded by a newer request of the same link
                        match r {
                            Ok(true) => s.done += 1,
                            Ok(false) => s.skipped += 1,
                            Err(e) => { s.failed += 1; s.errors.push_back((url.clone(), e.to_string())); if s.errors.len() > 100 { s.errors.pop_front(); } }
                        }
                    });
                    drop(permit);
                }));
            }
        }
    });
    Ok(n)
}

/// Downloads one post into `lib`, a library of its own (`share`), outside the download queue:
/// stopping the queue does not touch it, and it shows in no status.
pub fn stage_link(lib: &Library, url: &str, route: Route) -> anyhow::Result<()> {
    let o = LinkOpts { route, revive: false, folder: None, recent: false, staged: true };
    runtime().block_on(process(lib, url, &o)).map(|_| ())
}

/// Ok(true) = downloaded, Ok(false) = already in the library.
async fn process(lib: &Library, url: &str, o: &LinkOpts) -> anyhow::Result<bool> {
    let (route, revive, folder) = (o.route, o.revive, o.folder.as_deref());
    // a wipe meanwhile: nothing fetched for the old library may be written into the new one
    let epoch = lib.epoch();
    let (_, id) = net::parse_status_url(url).ok_or_else(|| anyhow!(tr!("download.badLink")))?;
    let known = {
        let db = lib.db_at(epoch)?;
        let total = db.post_media_count(&id)?;
        let live = db.post_live_count(&id)?;
        let known = if revive { live > 0 && live == total } else { total > 0 };
        if known { if let Some(f) = folder { db.add_posts_to_folder(f, &[id.clone()])?; } }
        known
    };
    if known {
        // already in the library: still goes into the chosen folder (with all its media)
        return Ok(false);
    }
    let post = fetch_post(url, route).await?;
    // the post returned must be the one asked for (a wrong or tampered answer must not overwrite another post)
    if post.meta.id != id { bail!(tr!("download.mismatch")); }
    let mut stored = vec![];
    for m in &post.media {
        if (!o.staged && CANCEL.load(Ordering::SeqCst)) || lib.epoch() != epoch { bail!(tr!("common.cancelled")); }
        stored.push(fetch_blob(lib, &m.url, &m.kind, &m.headers, epoch, !o.staged).await?);
    }
    {
        let db = lib.db_at(epoch)?;
        // A revival brings back a media that was permanently deleted, whose old file an import or
        // a sync may have removed after this download found it already there. Removals of such
        // files happen under this same lock, so what is seen here stays true until the media is
        // recorded: a media must never come back without its file.
        if revive { for (_, rel, _) in &stored { if !lib.dir.join(rel).exists() { bail!(tr!("download.cleanedUp")); } } }
        let tx = db.conn().unchecked_transaction()?;
        db.upsert_post_checked(&post.meta, |id, ext| lib.dir.join(crate::oplog::blob_rel(id, ext)).exists())?;
        let mut added = false;
        for (i, (sha, rel, kind)) in stored.iter().enumerate() { added |= db.add_media(sha, &post.meta.id, i as i64, kind, rel, revive)?; }
        if let Some(f) = folder { db.add_posts_to_folder(f, &[post.meta.id.clone()])?; }
        // only posts that really gained media are "recently added"
        if o.recent && added { db.mark_recent(&post.meta.id, crate::store::now_ms())?; }
        tx.commit()?;
    }
    if o.staged { return Ok(true); }
    update(|s| for (_, rel, _) in &stored {
        s.recent.push_back(lib.dir.join(rel).to_string_lossy().into_owned());
        if s.recent.len() > 12 { s.recent.pop_front(); }
    });
    Ok(true)
}

/// Fetches a post's metadata and media list by the chosen route (auto: FxTwitter, then the
/// account cookie if set, then guest GraphQL).
async fn fetch_post(url: &str, route: Route) -> anyhow::Result<RemotePost> {
    let cookies = COOKIES.lock().unwrap().clone();
    let protected = |c: Option<Credentials>| async move {
        let c = c.ok_or_else(|| anyhow!(tr!("download.noCookie")))?;
        crate::protected::fetch_post(url, &c).await.map_err(|e| anyhow!("{e}"))
    };
    let post: RemotePost = match route {
        Route::Fx => net::fetch_fx(url).await?,
        Route::Cookie => protected(cookies).await?,
        // public mirror first; posts it cannot reach (protected accounts) through the module
        Route::Auto => match net::fetch_fx(url).await {
            Ok(p) if !p.media.is_empty() => p,
            first => match cookies {
                Some(_) => protected(cookies).await.map_err(|e| anyhow!(tr!("download.bothFailed", e = e)))?,
                None => { first?; bail!(tr!("download.noMediaMaybeLocked")) }
            },
        },
    };
    if post.media.is_empty() { bail!(tr!("download.noMedia")); }
    Ok(post)
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Repair {
    /// The original bytes were downloaded again and replaced the damaged file.
    Replaced,
    /// The source now serves a different file: it was added in the same place, with the old
    /// media's tags; the old one went to the recycle bin (restore it from there if wanted).
    ReplacedNew,
    /// No link to download from: the file will be fetched from another device on the next sync.
    FromPeers,
}

/// The status link of a post, from its stored link or its numeric id.
pub fn post_link(meta: &crate::model::PostMeta) -> Option<String> {
    if let Some(u) = meta.url.as_deref().filter(|u| net::parse_status_url(u).is_some()) { return Some(u.to_string()); }
    (!meta.id.is_empty() && meta.id.chars().all(|c| c.is_ascii_digit())).then(|| format!("https://x.com/i/status/{}", meta.id))
}

/// Downloads one media again. The damaged file is only ever replaced by a copy whose hash is
/// its id (verified), or by a new media while the old one stays recoverable in the recycle bin.
pub async fn repair(lib: &Library, media_id: &str) -> anyhow::Result<Repair> {
    let epoch = lib.epoch();
    let (post_id, ordinal, kind, cur_rel) = lib.db().media_row(media_id)?.ok_or_else(|| anyhow!(tr!("repair.notFound")))?;
    let kind = if kind == "video" { MediaKind::Video } else { MediaKind::Photo };
    let meta = lib.db().post_meta(&post_id)?.unwrap_or_default();
    let Some(link) = post_link(&meta) else {
        // No source link (e.g. a legacy import): ask peers for a verified copy instead.
        match lib.check_file(media_id, &cur_rel) {
            Some(reason) => { lib.db_at(epoch)?.set_bad(media_id, Some(reason))?; return Ok(Repair::FromPeers) }
            None => bail!(tr!("repair.noLink")),
        }
    };
    let post = fetch_post(&link, Route::Auto).await?;
    let src = post.media.get(ordinal as usize).filter(|m| m.kind == kind)
        .or_else(|| post.media.iter().find(|m| m.kind == kind && post.media.len() == 1))
        .ok_or_else(|| anyhow!(tr!("repair.goneFromPost")))?;
    let (tmp, sha, ext) = fetch_tmp(lib, &src.url, &kind, &src.headers, false).await?;
    let _tmp_cleanup = crate::library::TempFile(tmp.clone());
    let db = lib.db_at(epoch)?;
    if db.media_row(media_id)?.is_none() || db.trash_reg(media_id)?.state != crate::rules::LIVE { bail!(tr!("repair.deleted")); }
    if sha == media_id {
        let dst = lib.dir.join(&cur_rel);
        std::fs::create_dir_all(dst.parent().unwrap())?;
        std::fs::rename(&tmp, &dst)?; // atomic replace of the damaged file
        db.set_bad(media_id, None)?;
        return Ok(Repair::Replaced);
    }
    let rel = lib.commit_tmp_locked(&db, &tmp, &sha, ext)?;
    let tx = db.conn().unchecked_transaction()?;
    db.add_media(&sha, &post_id, ordinal, &kind, &rel, true)?;
    for (label, origin) in db.media_tags(media_id)? {
        if origin == 0 { continue; }
        db.tag_media(&sha, &label, crate::model::Origin(origin))?;
        for m in db.tag_sources(media_id, &label)? { db.set_tag_source(&sha, &label, &m, true)?; }
    }
    for m in db.ai_models_for(media_id)? { db.mark_ai_done(&sha, &m)?; }
    // where the old one was shown, the new one is shown
    let folders = db.folders_of(media_id)?;
    for f in &folders { db.add_to_folder(f, std::slice::from_ref(&sha))?; }
    db.trash_action(media_id, crate::rules::TrashAction::Trash)?;
    tx.commit()?;
    Ok(Repair::ReplacedNew)
}

/// Streams a URL into the blob store, hashing as it goes. Only MP4 is accepted for video.
async fn fetch_blob(lib: &Library, url: &str, kind: &MediaKind, headers: &[(String, String)], epoch: u64, queue_cancel: bool) -> anyhow::Result<(String, String, MediaKind)> {
    let mut last = None;
    for attempt in 0..3u32 {
        if attempt > 0 { tokio::time::sleep(std::time::Duration::from_millis(800 * 2u64.pow(attempt))).await; }
        match fetch_once(lib, url, kind, headers, epoch, queue_cancel).await { Ok(v) => return Ok(v), Err(e) => last = Some(e) }
    }
    Err(last.unwrap())
}

async fn fetch_once(lib: &Library, url: &str, kind: &MediaKind, headers: &[(String, String)], epoch: u64, queue_cancel: bool) -> anyhow::Result<(String, String, MediaKind)> {
    let (tmp, sha, ext) = fetch_tmp(lib, url, kind, headers, queue_cancel).await?;
    let _cleanup = crate::library::TempFile(tmp.clone());
    let db = lib.db_at(epoch)?;
    let rel = lib.commit_tmp_locked(&db, &tmp, &sha, ext)?;
    Ok((sha, rel, kind.clone()))
}

/// Streams a URL into a temp file (fsynced), hashing as it goes: (temp path, sha256, ext).
async fn fetch_tmp(lib: &Library, url: &str, kind: &MediaKind, headers: &[(String, String)], queue_cancel: bool) -> anyhow::Result<(std::path::PathBuf, String, &'static str)> {
    // media come from X's media servers only: a wrong or tampered answer cannot make this
    // device fetch from the local network or anywhere else
    if !crate::rules::media_url_ok(url) { bail!(tr!("download.notXMedia")); }
    let mut rq = net::client().get(url);
    for (k, v) in headers { rq = rq.header(k.as_str(), v.as_str()); }
    let resp = rq.send().await?.error_for_status()?;
    let ext = match kind {
        MediaKind::Video => "mp4",
        MediaKind::Photo => if url.contains("format=png") || url.contains(".png") { "png" } else { "jpg" },
    };
    let tmp = lib.tmp_path();
    let cleanup = crate::library::TempFile(tmp.clone());
    let mut f = tokio::fs::File::create(&tmp).await?;
    let mut hasher = Sha256::new();
    let mut head = Vec::with_capacity(16);
    let mut stream = resp.bytes_stream();
    let result: anyhow::Result<()> = async {
        let mut total: u64 = 0;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            total += chunk.len() as u64;
            if total > MAX_MEDIA_BYTES { bail!(tr!("download.tooLarge", gb = MAX_MEDIA_BYTES >> 30)); }
            if queue_cancel && CANCEL.load(Ordering::SeqCst) { bail!(tr!("common.cancelled")); }
            if head.len() < 16 { head.extend_from_slice(&chunk[..chunk.len().min(16 - head.len())]); }
            hasher.update(&chunk);
            f.write_all(&chunk).await?;
        }
        f.sync_all().await?;
        let photo = *kind == MediaKind::Photo;
        let sn = crate::rules::sniff(&head);
        if !crate::rules::sniff_ok(sn, photo) { bail!(crate::library::NotMedia(Library::not_media_reason(sn, photo))); }
        Ok(())
    }.await;
    if let Err(e) = result { let _ = tokio::fs::remove_file(&tmp).await; return Err(e); }
    Ok((cleanup.into_path(), hex::encode(hasher.finalize()), ext))
}

#[cfg(test)]
mod chatgpt_regressions {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn existing_live_post_returns_without_relocking_or_network() {
        let dir = std::env::temp_dir().join(format!("tl-known-{}", rand::random::<u64>()));
        let lib = Arc::new(Library::open(&dir).unwrap());
        let id = "a".repeat(64);
        {
            let db = lib.db();
            db.upsert_post(&crate::model::PostMeta { id: "123".into(), ..Default::default() }).unwrap();
            db.add_media(&id, "123", 0, &MediaKind::Photo, &format!("blobs/aa/{id}.jpg"), false).unwrap();
        }
        let worker = lib.clone();
        let task = tokio::spawn(async move {
            process(&worker, "https://x.com/test/status/123", &LinkOpts { revive: true, ..Default::default() }).await
        });
        assert!(!tokio::time::timeout(std::time::Duration::from_secs(2), task).await.unwrap().unwrap().unwrap());
        drop(lib);
        std::fs::remove_dir_all(dir).unwrap();
    }
}

//! C ABI surface for the Swift apps. Complex values cross as UTF-8 JSON in an
//! `{"ok": …}` / `{"error": "…"}` envelope; every returned string is freed with `tl_string_free`.
use crate::archive;
use crate::download::{self, DownloadRequest};
use crate::library::{FeedRequest, Library};
use crate::model::Origin;
use serde::Deserialize;
use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::sync::{Arc, Mutex};

static LIB: Mutex<Option<Arc<Library>>> = Mutex::new(None);

fn s(p: *const c_char) -> String {
    if p.is_null() { return String::new(); }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}
fn out(v: String) -> *mut c_char { CString::new(v).map_or(std::ptr::null_mut(), CString::into_raw) }
fn lib() -> anyhow::Result<Arc<Library>> {
    LIB.lock().unwrap().clone().ok_or_else(|| anyhow::anyhow!("library not open"))
}
fn with<T: serde::Serialize>(f: impl FnOnce(Arc<Library>) -> anyhow::Result<T>) -> *mut c_char {
    // A Rust panic must never unwind into Swift (that aborts the app): report it as an error.
    let r = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| lib().and_then(f))) {
        Ok(r) => r,
        Err(p) => Err(anyhow::anyhow!(tr!("ffi.internal", msg = p.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| p.downcast_ref::<String>().cloned()).unwrap_or_default()))),
    };
    out(match r {
        Ok(v) => serde_json::json!({ "ok": v }).to_string(),
        Err(e) => serde_json::json!({ "error": format!("{e:#}") }).to_string(),
    })
}

/// The open library, for the core's own listeners (the browser extension's).
pub(crate) fn current_library() -> Option<Arc<Library>> { LIB.lock().ok()?.clone() }

/// `with` for functions that need no open library.
fn respond<T: serde::Serialize>(f: impl FnOnce() -> anyhow::Result<T>) -> *mut c_char {
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| Err(anyhow::anyhow!(tr!("ffi.internal", msg = ""))));
    out(match r {
        Ok(v) => serde_json::json!({ "ok": v }).to_string(),
        Err(e) => serde_json::json!({ "error": format!("{e:#}") }).to_string(),
    })
}

/// Every exported function runs under `catch_unwind` (directly or through `with`): a Rust panic
/// unwinding into Swift aborts the app. These are for functions that do not use `with`.
fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(fallback)
}
fn guard_ptr(f: impl FnOnce() -> *mut c_char) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|p| {
        let m = p.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| p.downcast_ref::<String>().cloned()).unwrap_or_default();
        out(serde_json::json!({ "error": tr!("ffi.internal", msg = m) }).to_string())
    })
}

/// The app's language for the core's messages (errors, reports): a language tag such as
/// "en", "zh-Hans" or "ja". Called once at launch, before anything else.
#[no_mangle]
pub extern "C" fn tl_set_language(tag: *const c_char) { guard((), || crate::i18n::set_language(&s(tag))) }

/// This build's name, for the core's messages. Called once at launch.
#[no_mangle]
pub extern "C" fn tl_set_app_name(name: *const c_char) { guard((), || crate::i18n::set_app_name(&s(name))) }

/// A setting shared by every device (`null` = the default).
#[no_mangle]
pub extern "C" fn tl_setting(key: *const c_char) -> *mut c_char { with(|l| Ok(l.db().setting(&s(key))?)) }

/// Changes a shared setting on every device; `value` NULL = back to the default.
#[no_mangle]
pub extern "C" fn tl_set_setting(key: *const c_char, value: *const c_char) -> *mut c_char {
    with(|l| { let v = (!value.is_null()).then(|| s(value)); l.db().set_setting(&s(key), v.as_deref())?; Ok(()) })
}

/// Returns the FxTwitter API URL for a status link, or NULL.
#[no_mangle]
pub extern "C" fn tl_fx_api_url(url: *const c_char) -> *mut c_char { guard_ptr(|| {
    crate::bookmarks::to_fx_api(&s(url)).map_or(std::ptr::null_mut(), out)
}) }

/// Opens (or creates) the library at `dir`. Returns true on success.
#[no_mangle]
pub extern "C" fn tl_open(dir: *const c_char) -> bool { guard(false, || {
    let d = s(dir);
    crate::diagnostics::install_panic_hook(Path::new(&d));
    match Library::open(&d) {
        Ok(l) => { *LIB.lock().unwrap() = Some(Arc::new(l)); true }
        Err(e) => { crate::diagnostics::log_open_failure(Path::new(&d), &format!("{e:#}")); false }
    }
}) }

#[no_mangle]
pub extern "C" fn tl_thumbnail_items() -> *mut c_char {
    with(|l| {
        let db = l.db();
        let mut st = db.conn().prepare("SELECT m.id,m.path,m.kind FROM media m WHERE NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state!=0)")?;
        let items = st.query_map([], |r| Ok(serde_json::json!({"media_id": r.get::<_, String>(0)?, "path": l.dir.join(r.get::<_, String>(1)?).to_string_lossy(), "kind": r.get::<_, String>(2)?})))?.collect::<Result<Vec<_>, _>>()?;
        Ok(items)
    })
}

#[no_mangle]
pub extern "C" fn tl_feed(request_json: *const c_char) -> *mut c_char {
    with(|l| { let req: FeedRequest = serde_json::from_str(&s(request_json))?; l.feed(&req) })
}

/// The same feed in the compact form (`PackedFeed`: each post and tag list once, relative
/// paths): what the apps use, a fraction of the size for a large library.
#[no_mangle]
pub extern "C" fn tl_feed_packed(request_json: *const c_char) -> *mut c_char {
    with(|l| {
        let req: FeedRequest = serde_json::from_str(&s(request_json))?;
        let feed = l.feed_packed(&req)?;
        crate::media_size::fill_in_background(l);
        Ok(feed)
    })
}

/// Whether media sizes are still being read in the background (the next feed has more of them).
#[no_mangle]
pub extern "C" fn tl_media_sizes_filling() -> bool { guard(false, crate::media_size::filling) }

#[no_mangle]
pub extern "C" fn tl_import_legacy_dir(dir: *const c_char) -> *mut c_char {
    with(|l| l.import_legacy_dir(Path::new(&s(dir))))
}

#[no_mangle]
pub extern "C" fn tl_import_legacy_zip(path: *const c_char, folder: *const c_char) -> *mut c_char {
    with(|l| { let f = s(folder); crate::import::import_zip(&l, Path::new(&s(path)), (!f.is_empty()).then_some(f.as_str())) })
}

/// Imports a ZIP of loose media (no structure; every file becomes its own loose-media post).
#[no_mangle]
pub extern "C" fn tl_import_loose_zip(path: *const c_char, folder: *const c_char) -> *mut c_char {
    with(|l| { let f = s(folder); crate::import::import_loose_zip(&l, Path::new(&s(path)), (!f.is_empty()).then_some(f.as_str())) })
}

#[no_mangle]
pub extern "C" fn tl_import_pack(path: *const c_char, folder: *const c_char) -> *mut c_char {
    with(|l| { let f = s(folder); archive::import_pack_into(&l, Path::new(&s(path)), (!f.is_empty()).then_some(f.as_str())) })
}

#[derive(Deserialize)]
struct ExportArgs { media_ids: Vec<String>, #[serde(default)] options: archive::ExportOptions, #[serde(default)] out: String }

/// args: {"media_ids": [...], "options": {"tags", "folders", "media_only"}, "out": path}. Exports
/// exactly those media (the result of a search); there is no other way to select.
#[no_mangle]
pub extern "C" fn tl_export_media(args_json: *const c_char) -> *mut c_char {
    with(|l| { let a: ExportArgs = serde_json::from_str(&s(args_json))?; archive::export_media(&l, &a.media_ids, a.options, Path::new(&a.out)) })
}

/// Extracts the post links from a bookmark-export JSON file.
#[no_mangle]
pub extern "C" fn tl_parse_bookmarks(path: *const c_char) -> *mut c_char {
    with(|_| Ok(crate::bookmarks::parse_urls(&std::fs::read_to_string(s(path))?)?))
}

#[no_mangle]
pub extern "C" fn tl_download_start(request_json: *const c_char) -> *mut c_char {
    with(|l| { let req: DownloadRequest = serde_json::from_str(&s(request_json))?; download::start(l, req) })
}

#[no_mangle]
pub extern "C" fn tl_download_status() -> *mut c_char { with(|l| { let mut s = download::status(); s.paused = l.db().paused_jobs()?; Ok(s) }) }

#[no_mangle]
pub extern "C" fn tl_download_cancel() { let p = tl_download_stop(false); tl_string_free(p); }
#[no_mangle]
pub extern "C" fn tl_download_stop(pause: bool) -> *mut c_char { with(|l| download::stop(&l, pause)) }
#[no_mangle]
pub extern "C" fn tl_download_resume(json: *const c_char) -> *mut c_char { with(|l| download::resume(l, serde_json::from_str(&s(json))?)) }

/// Sets the session cookies held in memory for the cookie route; empty values clear them.
#[no_mangle]
pub extern "C" fn tl_set_cookies(auth_token: *const c_char, ct0: *const c_char) { guard((), || {
    let (a, c) = (s(auth_token), s(ct0));
    download::set_cookies((!a.is_empty() && !c.is_empty()).then(|| crate::protected::Credentials { auth_token: a, ct0: c }));
}) }

/// origin: 1 = user, 2 = AI. Adding a user tag to an AI tag endorses it.
#[no_mangle]
pub extern "C" fn tl_tag(media_id: *const c_char, label: *const c_char, origin: u8) -> *mut c_char {
    with(|l| l.tag(&s(media_id), &s(label), Origin(origin & 3)))
}

#[no_mangle]
pub extern "C" fn tl_untag(media_id: *const c_char, label: *const c_char) -> *mut c_char {
    with(|l| l.untag(&s(media_id), &s(label)))
}

/// Renames (or merges) a tag everywhere; synced, works during AI tagging.
/// Returns the new name.
#[no_mangle]
pub extern "C" fn tl_rename_tag(from: *const c_char, to: *const c_char) -> *mut c_char { with(|l| l.rename_tag(&s(from), &s(to))) }

/// Removes a tag from every media: returns how many media lost it.
#[no_mangle]
pub extern "C" fn tl_delete_tag(label: *const c_char) -> *mut c_char { with(|l| Ok(l.db().delete_label(&s(label))?)) }

/// Removes every AI tag (endorsed ones stay as mine): returns how many tags lost their AI part.
#[no_mangle]
pub extern "C" fn tl_remove_ai_tags() -> *mut c_char { with(|l| Ok(l.db().remove_ai_tags()?)) }

/// Current tags of one media (names after renames), live only: [[label, origin], …].
#[no_mangle]
pub extern "C" fn tl_media_tags(media_id: *const c_char) -> *mut c_char {
    with(|l| Ok(l.db().media_tags(&s(media_id))?.into_iter().filter(|(_, o)| *o != 0).collect::<Vec<_>>()))
}

#[no_mangle]
pub extern "C" fn tl_all_tags() -> *mut c_char { with(|l| Ok(l.db().all_tags()?)) }

#[no_mangle]
pub extern "C" fn tl_stats() -> *mut c_char { with(|l| Ok(l.db().stats()?)) }

/// 检查更新: the newer release for this build (null when current). `query_json` is an
/// `update::UpdateQuery`. Blocks on the network: call it off the main thread. Needs no library.
#[no_mangle]
pub extern "C" fn tl_update_check(query_json: *const c_char) -> *mut c_char {
    respond(|| { let q: crate::update::UpdateQuery = serde_json::from_str(&s(query_json))?; crate::update::check(&q) })
}

/// Downloads the installer of `info_json` (what `tl_update_check` returned) into `dir`; the
/// file's path. Blocks: call it off the main thread.
#[no_mangle]
pub extern "C" fn tl_update_download(info_json: *const c_char, dir: *const c_char) -> *mut c_char {
    respond(|| {
        let v: serde_json::Value = serde_json::from_str(&s(info_json))?;
        let info = crate::update::UpdateInfo {
            version: v["version"].as_str().unwrap_or_default().into(), page_url: v["page_url"].as_str().unwrap_or_default().into(),
            notes: String::new(), asset_name: v["asset_name"].as_str().map(Into::into), asset_url: v["asset_url"].as_str().map(Into::into),
            asset_size: v["asset_size"].as_u64().unwrap_or(0), asset_digest: v["asset_digest"].as_str().map(Into::into),
        };
        Ok(crate::update::download(&info, std::path::Path::new(&s(dir)))?.to_string_lossy().into_owned())
    })
}

/// Windows / Linux secrets (`sealed.rs`): a new key, and values sealed / opened with one.
#[no_mangle]
pub extern "C" fn tl_secret_key() -> *mut c_char { respond(|| Ok(crate::sealed::new_key())) }
#[no_mangle]
pub extern "C" fn tl_secret_seal(key: *const c_char, text: *const c_char) -> *mut c_char { respond(|| crate::sealed::seal(&s(key), &s(text))) }
#[no_mangle]
pub extern "C" fn tl_secret_open(key: *const c_char, blob: *const c_char) -> *mut c_char { respond(|| crate::sealed::open(&s(key), &s(blob))) }

/// 存储空间: sizes by group. `extra_json` lists the front end's own places
/// (`[{"key":"app","path":…}]`); reading a large library's sizes takes a moment, so call it off
/// the main thread.
#[no_mangle]
pub extern "C" fn tl_storage_usage(extra_json: *const c_char) -> *mut c_char {
    with(|l| {
        let extra: Vec<crate::storage::ExtraPlace> = serde_json::from_str(&s(extra_json)).unwrap_or_default();
        crate::storage::usage(&l, &extra)
    })
}

/// A shared link: downloads into the staging folder `dir`, which is not the library (`share`).
/// `urls_json` is a list of links, `route` "auto", "fx" or "cookie". Blocks: off the main thread.
#[no_mangle]
pub extern "C" fn tl_share_stage(dir: *const c_char, urls_json: *const c_char, route: *const c_char) -> *mut c_char {
    let (dir, urls, route) = (s(dir), s(urls_json), s(route));
    respond(|| {
        let urls: Vec<String> = serde_json::from_str(&urls)?;
        let route = serde_json::from_value(serde_json::json!(route)).unwrap_or_default();
        crate::share::stage(Path::new(&dir), &urls, route)
    })
}

/// The staging folder `dir` as a `.tlpack` at `out_path`, to import when the person says so.
#[no_mangle]
pub extern "C" fn tl_share_pack(dir: *const c_char, out_path: *const c_char) -> *mut c_char {
    let (dir, out_path) = (s(dir), s(out_path));
    respond(|| crate::share::pack(Path::new(&dir), Path::new(&out_path)))
}

/// Stops a running import after the current post; what came in stays, the report says so.
#[no_mangle]
pub extern "C" fn tl_import_cancel() { guard((), crate::import::cancel) }

/// Free bytes on the volume of `path`, or null when the system does not say.
#[no_mangle]
pub extern "C" fn tl_free_space(path: *const c_char) -> *mut c_char {
    guard_ptr(|| out(serde_json::json!({ "ok": crate::storage::free_space(std::path::Path::new(&s(path))) }).to_string()))
}

/// Deletes all local data (AI models only when `include_models`). Never synced.
#[no_mangle]
pub extern "C" fn tl_wipe(include_models: bool) -> *mut c_char { guard_ptr(|| {
    download::cancel();
    crate::models::cancel();
    crate::verify::cancel();
    if let Some(n) = SYNC.lock().unwrap().as_ref() { n.reset(); }
    // a running import stops after its current post folder; wipe only once it has left
    let _import = crate::import::stop_and_wait();
    with(|l| l.wipe(include_models))
}) }

// ---------- Folders ----------

#[derive(Deserialize)]
struct FolderArgs { name: String, #[serde(default)] media: Vec<String>, #[serde(default)] posts: Vec<String> }

/// Live folders with their media counts: [[name, count], …].
#[no_mangle]
pub extern "C" fn tl_folders() -> *mut c_char { with(|l| Ok(l.db().folders()?)) }

/// The folders page: {"folders":[{name,count,videos,cover_id,cover_path,cover_video}],"photos","videos"}.
#[no_mangle]
pub extern "C" fn tl_folder_overview() -> *mut c_char { with(|l| l.folder_overview()) }

#[no_mangle]
pub extern "C" fn tl_media_folders(media_id: *const c_char) -> *mut c_char { with(|l| Ok(l.db().folders_of(&s(media_id))?)) }

#[no_mangle]
pub extern "C" fn tl_create_folder(name: *const c_char) -> *mut c_char { with(|l| Ok(l.db().create_folder(&s(name))?)) }

#[no_mangle]
pub extern "C" fn tl_delete_folder(name: *const c_char) -> *mut c_char {
    with(|l| { let db = l.db(); let tx = db.conn().unchecked_transaction()?; db.delete_folder(&s(name))?; tx.commit()?; Ok(()) })
}

/// Adds media, and every live media of the given posts, to a folder (created if needed).
#[derive(Deserialize)]
struct FolderRename { old: String, new: String }

/// Renames a folder (merging into an existing one of that name); returns the media moved.
#[no_mangle]
pub extern "C" fn tl_rename_folder(json: *const c_char) -> *mut c_char {
    with(|l| { let a: FolderRename = serde_json::from_str(&s(json))?; Ok(l.db().rename_folder(&a.old, &a.new)?) })
}

#[no_mangle]
pub extern "C" fn tl_folder_add(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: FolderArgs = serde_json::from_str(&s(json))?;
        let db = l.db(); let tx = db.conn().unchecked_transaction()?;
        let n = db.add_to_folder(&a.name, &a.media)? + db.add_posts_to_folder(&a.name, &a.posts)?;
        tx.commit()?; Ok(n)
    })
}

#[no_mangle]
pub extern "C" fn tl_folder_remove(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: FolderArgs = serde_json::from_str(&s(json))?;
        let db = l.db(); let tx = db.conn().unchecked_transaction()?;
        let mut media = a.media.clone();
        for p in &a.posts { media.extend(db.action_ids(&[], &[p.clone()])?); }
        let n = db.remove_from_folder(&a.name, &media)?;
        tx.commit()?; Ok(n)
    })
}

// ---------- Recycle bin ----------

#[derive(Deserialize)]
struct Ids { #[serde(default)] media: Vec<String>, #[serde(default)] post: Option<String> }

/// Moves media (and/or every live media of a post) to the recycle bin. Returns how many moved.
#[no_mangle]
pub extern "C" fn tl_trash(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: Ids = serde_json::from_str(&s(json))?;
        let mut n = l.trash_apply(&a.media, crate::rules::TrashAction::Trash)?;
        if let Some(p) = a.post { n += l.trash_post(&p)?; }
        Ok(n)
    })
}

#[no_mangle]
pub extern "C" fn tl_trash_restore(json: *const c_char) -> *mut c_char {
    with(|l| { let a: Ids = serde_json::from_str(&s(json))?; l.trash_apply(&a.media, crate::rules::TrashAction::Restore) })
}

/// Permanently deletes media that are in the recycle bin (on every device).
#[no_mangle]
pub extern "C" fn tl_trash_purge(json: *const c_char) -> *mut c_char {
    with(|l| { let a: Ids = serde_json::from_str(&s(json))?; l.trash_apply(&a.media, crate::rules::TrashAction::Purge) })
}

#[no_mangle]
pub extern "C" fn tl_trash_empty() -> *mut c_char { with(|l| l.empty_trash()) }

#[no_mangle]
pub extern "C" fn tl_trash_list() -> *mut c_char { with(|l| l.trash_list()) }

#[no_mangle]
pub extern "C" fn tl_trash_keep_days() -> *mut c_char { with(|l| Ok(l.trash_keep_days())) }

#[no_mangle]
pub extern "C" fn tl_set_trash_keep_days(days: u32) -> *mut c_char { with(|l| l.set_trash_keep_days(days)) }

/// Deletes media that stayed in the bin longer than the retention period.
#[no_mangle]
pub extern "C" fn tl_trash_expire() -> *mut c_char {
    with(|l| l.expire_trash(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)))
}


// ---------- Import progress and reports ----------

#[no_mangle]
pub extern "C" fn tl_import_status() -> *mut c_char { guard_ptr(|| { out(serde_json::json!({ "ok": crate::import::progress() }).to_string()) }) }

/// Saved import reports, newest first: [[file, created_ms, source, issue_count], …].
#[no_mangle]
pub extern "C" fn tl_import_reports() -> *mut c_char { with(|l| Ok(crate::import::reports(&l))) }

#[no_mangle]
pub extern "C" fn tl_import_report(path: *const c_char) -> *mut c_char { with(|_| crate::import::load_report(Path::new(&s(path)))) }

/// Writes the problem files of a report (unchanged) plus 说明.txt into a ZIP; returns the file count.
#[no_mangle]
pub extern "C" fn tl_import_export_issues(report: *const c_char, out_zip: *const c_char) -> *mut c_char {
    with(|_| crate::import::export_issues(Path::new(&s(report)), Path::new(&s(out_zip))))
}

// ---------- Verification and repair ----------

#[no_mangle]
pub extern "C" fn tl_verify_start() -> *mut c_char { with(|l| crate::verify::start(l)) }

#[no_mangle]
pub extern "C" fn tl_verify_status() -> *mut c_char { guard_ptr(|| { out(serde_json::json!({ "ok": crate::verify::status() }).to_string()) }) }

#[no_mangle]
pub extern "C" fn tl_verify_cancel() { guard((), || { crate::verify::cancel() }) }

/// The app failed to decode a media: verify its file and record the damage. Returns the reason.
#[no_mangle]
pub extern "C" fn tl_report_bad(media_id: *const c_char) -> *mut c_char { with(|l| l.report_bad(&s(media_id))) }

#[no_mangle]
pub extern "C" fn tl_report_thumbnail_failed(media_id: *const c_char) -> *mut c_char { with(|l| l.report_thumbnail_failed(&s(media_id))) }

/// A consistent copy of the database at `out_path`, whatever is being written: moving the data
/// folder of the running app copies this instead of the live files.
#[no_mangle]
pub extern "C" fn tl_db_snapshot(out_path: *const c_char) -> *mut c_char {
    let out = s(out_path);
    with(|l| { l.db().conn().execute("VACUUM INTO ?1", [&out])?; Ok(()) })
}

/// Downloads a damaged media again (blocking; call off the main thread).
#[no_mangle]
pub extern "C" fn tl_repair(media_id: *const c_char) -> *mut c_char {
    with(|l| {
        let id = s(media_id);
        download::runtime().block_on(async { tokio::time::timeout(std::time::Duration::from_secs(300), download::repair(&l, &id)).await })
            .map_err(|_| anyhow::anyhow!(tr!("ffi.downloadTimeout")))?
    })
}

// ---------- Models (standard Hugging Face / MLX folders) ----------

#[no_mangle]
pub extern "C" fn tl_set_models_dir(dir: *const c_char) -> *mut c_char { with(|l| l.set_models_dir(s(dir).into())) }

#[no_mangle]
pub extern "C" fn tl_model_download(repo: *const c_char) -> *mut c_char {
    with(|l| crate::models::start_download(s(repo), None, l.models_dir()))
}

/// The models offered for download in `format` (`mlx` or `gguf`), with the folder each installs into.
#[no_mangle]
pub extern "C" fn tl_model_catalog(format: *const c_char) -> *mut c_char {
    // read once at launch, possibly before a library is open
    let d = crate::hub::memory_profile();
    respond(|| Ok(crate::catalog::for_format(&s(format)).into_iter().map(|m| {
        let folder = crate::catalog::folder(&m);
        let tier = crate::hub::tier(m.bytes, &d);
        let mut v = serde_json::to_value(&m).unwrap(); v["folder"] = folder.into(); v["tier"] = tier.into(); v
    }).collect::<Vec<_>>()))
}

/// This device as the model store sees it.
#[no_mangle]
pub extern "C" fn tl_hub_device() -> *mut c_char { with(|l| Ok(crate::hub::device(&l.models_dir()))) }

/// The model store's results. Network: call off the main thread. `json` =
/// `{"format","query","uncensored","next"}`.
#[no_mangle]
pub extern "C" fn tl_hub_search(json: *const c_char) -> *mut c_char {
    #[derive(Deserialize)] struct A { format: String, #[serde(default)] query: String, #[serde(default)] uncensored: bool, #[serde(default)] next: Option<String> }
    with(|l| { let a: A = serde_json::from_str(&s(json))?; crate::hub::search(&l.models_dir(), &a.format, &a.query, a.uncensored, a.next.as_deref()) })
}

/// One repo's real files and sizes, as what can be installed. Network: off the main thread.
#[no_mangle]
pub extern "C" fn tl_hub_repo(format: *const c_char, repo: *const c_char) -> *mut c_char {
    with(|l| crate::hub::detail(&l.models_dir(), &s(format), &s(repo)))
}

/// Starts a model's download from the store; progress via `tl_model_status`.
#[no_mangle]
pub extern "C" fn tl_hub_install(json: *const c_char) -> *mut c_char {
    with(|l| crate::hub::install(&l.models_dir(), serde_json::from_str(&s(json))?))
}

/// llama.cpp models (Flutter on Android, Windows, Linux): `json` = `{"repo","weights","projector"}`.
#[no_mangle]
pub extern "C" fn tl_model_download_gguf(json: *const c_char) -> *mut c_char {
    #[derive(Deserialize)] struct A { repo: String, weights: String, #[serde(default)] projector: Option<String> }
    with(|l| { let a: A = serde_json::from_str(&s(json))?; crate::models::start_download_gguf(a.repo, None, a.weights, a.projector, l.models_dir()) })
}

#[no_mangle]
pub extern "C" fn tl_model_status() -> *mut c_char { guard_ptr(|| { out(serde_json::json!({ "ok": crate::models::status() }).to_string()) }) }

#[no_mangle]
pub extern "C" fn tl_model_cancel() { guard((), || { crate::models::cancel() }) }

#[no_mangle]
pub extern "C" fn tl_models_interrupted() -> *mut c_char { with(|l| Ok(crate::models::interrupted(&l.models_dir()))) }
#[no_mangle]
pub extern "C" fn tl_models_installed() -> *mut c_char { with(|l| Ok(crate::models::installed(&l.models_dir()))) }

#[no_mangle]
pub extern "C" fn tl_model_delete(id: *const c_char) -> *mut c_char { with(|l| crate::models::delete(&l.models_dir(), &s(id))) }

/// Writes the model folder as a plain ZIP.
#[no_mangle]
pub extern "C" fn tl_model_export_zip(id: *const c_char, out_path: *const c_char) -> *mut c_char {
    with(|l| crate::models::export_zip(&l.models_dir(), &s(id), Path::new(&s(out_path))))
}

/// Imports a standard model folder or a ZIP of one.
#[no_mangle]
pub extern "C" fn tl_model_import(path: *const c_char) -> *mut c_char {
    with(|l| crate::models::import(&l.models_dir(), Path::new(&s(path))))
}

// ---------- AI tagging & semantic vectors ----------

/// Media no model has analysed yet (the default model can change without re-tagging).
#[no_mangle]
pub extern "C" fn tl_ai_pending(limit: i64) -> *mut c_char {
    with(|l| Ok(abs(&l, l.db().media_needing_ai(limit)?)))
}

/// All media, paged, for "re-tag all".
#[no_mangle]
pub extern "C" fn tl_media_page(after: *const c_char, limit: i64) -> *mut c_char {
    with(|l| Ok(abs(&l, l.db().media_page(&s(after), limit)?)))
}

fn abs(l: &Library, v: Vec<crate::store::MediaRef>) -> Vec<crate::store::MediaRef> {
    v.into_iter().map(|mut m| { m.path = l.dir.join(&m.path).to_string_lossy().into_owned(); m }).collect()
}

/// Media not analysed yet that this device should try with `model`: leaves out media that
/// failed here too often, or once since `since` (unix seconds; 0 = no run limit).
#[no_mangle]
pub extern "C" fn tl_ai_pending_for(model: *const c_char, since: i64, limit: i64) -> *mut c_char {
    with(|l| Ok(abs(&l, l.db().media_needing_ai_for(&s(model), since, limit)?)))
}

#[derive(Deserialize)]
struct AiAttempt { step: String, media_id: String, model: String, #[serde(default)] reason: String, #[serde(default)] now: i64 }

/// An analysis attempt on this device (local only, never synced): `begin` before the model
/// runs (counted even if the app then crashes), `failed` with the reason, `undo` when the run
/// stopped for a reason that is not the media's.
#[no_mangle]
pub extern "C" fn tl_ai_attempt(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: AiAttempt = serde_json::from_str(&s(json))?;
        match a.step.as_str() {
            "begin" => l.db().ai_attempt_begin(&a.media_id, &a.model, a.now)?,
            "failed" => l.db().ai_attempt_failed(&a.media_id, &a.model, &a.reason)?,
            "undo" => l.db().ai_attempt_undo(&a.media_id, &a.model)?,
            other => anyhow::bail!("unknown step {other}"),
        }
        Ok(())
    })
}

/// Media this device gave up analysing, with the reason.
#[no_mangle]
pub extern "C" fn tl_ai_failures() -> *mut c_char { with(|l| Ok(l.db().ai_failures()?)) }

/// Try them again on this device.
#[no_mangle]
pub extern "C" fn tl_ai_failures_clear() -> *mut c_char { with(|l| Ok(l.db().ai_failures_clear()?)) }

/// (analysed by any model, total).
#[no_mangle]
pub extern "C" fn tl_ai_counts() -> *mut c_char { with(|l| Ok(l.db().ai_counts()?)) }

#[derive(Deserialize)]
struct AiApply { epoch: u64, media_id: String, model: String, labels: Vec<String>, #[serde(default)] replace_old: bool }

/// Applies one model's labels; `replace_old` removes unendorsed AI tags not proposed again.
#[no_mangle]
pub extern "C" fn tl_ai_apply(json: *const c_char) -> *mut c_char {
    with(|l| { let a: AiApply = serde_json::from_str(&s(json))?; l.apply_ai_tags_at(a.epoch, &a.media_id, &a.model, &a.labels, a.replace_old) })
}

#[no_mangle]
pub extern "C" fn tl_labels_missing_vectors(model: *const c_char) -> *mut c_char { with(|l| Ok(l.db().labels_missing_vectors(&s(model))?)) }

#[derive(Deserialize)]
struct SetVectors { epoch: u64, model: String, items: Vec<(String, Vec<f32>)> }

#[no_mangle]
pub extern "C" fn tl_set_vectors(json: *const c_char) -> *mut c_char {
    with(|l| { let a: SetVectors = serde_json::from_str(&s(json))?; l.set_vectors_at(a.epoch, &a.model, &a.items) })
}

/// Capture before starting asynchronous work; writes must supply this generation.
#[no_mangle]
pub extern "C" fn tl_epoch() -> *mut c_char { with(|l| Ok(l.epoch())) }

// ---------- LAN sync ----------

static SYNC: Mutex<Option<Arc<crate::sync::SyncNode>>> = Mutex::new(None);

fn node() -> anyhow::Result<Arc<crate::sync::SyncNode>> {
    let mut g = SYNC.lock().unwrap();
    if g.is_none() { *g = Some(crate::sync::SyncNode::new(lib()?)); }
    Ok(g.clone().unwrap())
}
fn key_from_hex(h: &str) -> anyhow::Result<[u8; 32]> {
    hex::decode(h.trim())?.try_into().map_err(|_| anyhow::anyhow!("bad account key"))
}

/// Generates a new account key (hex). The app stores it in the Keychain.
#[no_mangle]
pub extern "C" fn tl_sync_new_account() -> *mut c_char { guard_ptr(|| {
    out(serde_json::json!({ "ok": hex::encode(crate::sync::Account::generate().key) }).to_string())
}) }

/// Starts (or reconfigures) the node; empty key = not yet joined. Returns the listening port.
#[no_mangle]
pub extern "C" fn tl_sync_start(account_key_hex: *const c_char, device_name: *const c_char) -> *mut c_char {
    with(|_| {
        let n = node()?;
        let k = s(account_key_hex);
        let acct = if k.is_empty() { None } else { Some(crate::sync::Account::from_key(key_from_hex(&k)?)) };
        download::runtime().block_on(n.start(acct, s(device_name)))
    })
}

#[no_mangle]
pub extern "C" fn tl_sync_restart_listener() -> *mut c_char {
    with(|_| { let n = node()?; download::runtime().block_on(n.restart_listener()) })
}

#[no_mangle]
pub extern "C" fn tl_sync_status() -> *mut c_char { with(|_| Ok(node()?.status())) }

#[no_mangle]
pub extern "C" fn tl_sync_pair_begin() -> *mut c_char { with(|_| node()?.begin_pairing()) }

#[no_mangle]
pub extern "C" fn tl_sync_pair_cancel() { guard((), || { if let Ok(n) = node() { n.cancel_pairing() } }) }

#[no_mangle]
pub extern "C" fn tl_sync_join(host: *const c_char, port: u16, code: *const c_char) -> *mut c_char {
    with(|_| { let n = node()?; let _g = download::runtime().enter(); n.join(s(host), port, s(code)); Ok(()) })
}

/// Fire-and-forget sync with one peer; progress shows up in `tl_sync_status`.
#[no_mangle]
pub extern "C" fn tl_sync_with(host: *const c_char, port: u16) -> *mut c_char {
    with(|_| {
        let n = node()?;
        let host = s(host);
        download::runtime().spawn(async move { let _ = n.sync_with(&host, port).await; });
        Ok(())
    })
}

/// Models installed on a same-account peer (blocking, ≤ 10 s; call off the main thread).
#[no_mangle]
pub extern "C" fn tl_sync_peer_models(host: *const c_char, port: u16) -> *mut c_char {
    with(|_| {
        let n = node()?;
        let host = s(host);
        download::runtime().block_on(async { tokio::time::timeout(std::time::Duration::from_secs(10), n.peer_models(&host, port)).await })
            .map_err(|_| anyhow::anyhow!(tr!("sync.timeout")))?
    })
}

/// Starts copying one model from a peer; progress via `tl_model_status`.
#[no_mangle]
pub extern "C" fn tl_sync_pull_model(host: *const c_char, port: u16, id: *const c_char, label: *const c_char, total: u64) -> *mut c_char {
    with(|_| {
        let n = node()?;
        let (host, id, label) = (s(host), s(id), s(label));
        if crate::models::status().map_or(false, |st| st.running) { anyhow::bail!(tr!("models.busy")); }
        download::runtime().spawn(async move { let _ = n.pull_model(&host, port, &id, &label, total).await; });
        Ok(())
    })
}

/// Leaves sync entirely (used by wipe). Never sends anything to peers.
#[no_mangle]
pub extern "C" fn tl_sync_reset() { guard((), || { if let Ok(n) = node() { n.reset() } }) }

#[no_mangle]
pub extern "C" fn tl_string_free(p: *mut c_char) {
    if !p.is_null() { unsafe { drop(CString::from_raw(p)) } }
}

// ---------- Backup, share inbox, import records ----------

/// Whole-library cold backup into a `.tlpack` (everything but AI models).
#[no_mangle]
pub extern "C" fn tl_export_backup(out_path: *const c_char) -> *mut c_char {
    with(|l| archive::export_backup(&l, Path::new(&s(out_path))))
}

#[no_mangle]
pub extern "C" fn tl_export_status() -> *mut c_char { guard_ptr(|| { out(serde_json::json!({ "ok": archive::export_progress() }).to_string()) }) }

#[no_mangle]
pub extern "C" fn tl_export_cancel() -> *mut c_char { guard_ptr(|| { archive::cancel_export(); out(serde_json::json!({ "ok": true }).to_string()) }) }

fn yes() -> bool { true }

#[derive(Deserialize)]
struct LooseDirArgs { dir: String, #[serde(default)] folder: Option<String>, #[serde(default)] consume: bool, #[serde(default)] keep_to: Option<String>, #[serde(default = "yes")] album: bool }

/// Imports a folder of loose media (a share from Photos / Files); with `consume`, imported files
/// are removed from it afterwards and only problem files stay.
#[no_mangle]
pub extern "C" fn tl_import_loose_dir(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: LooseDirArgs = serde_json::from_str(&s(json))?;
        crate::import::import_loose_dir_keep(&l, Path::new(&a.dir), a.folder.as_deref().filter(|f| !f.trim().is_empty()), a.consume, a.keep_to.as_deref().map(Path::new), a.album)
    })
}

#[derive(Deserialize)]
struct DeleteReportsArgs { reports: Vec<String>, #[serde(default)] owned: Vec<String> }

/// Deletes import records (and their source when it is one of the app's own copies, see
/// `import::delete_reports`).
#[no_mangle]
pub extern "C" fn tl_delete_import_reports(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: DeleteReportsArgs = serde_json::from_str(&s(json))?;
        let r: Vec<std::path::PathBuf> = a.reports.iter().map(std::path::PathBuf::from).collect();
        let o: Vec<std::path::PathBuf> = a.owned.iter().map(std::path::PathBuf::from).collect();
        crate::import::delete_reports(&l, &r, &o)
    })
}

/// Diagnostics ZIP for the developer (logs, crash reports, numbers-only summary).
#[no_mangle]
pub extern "C" fn tl_export_diagnostics(out_path: *const c_char, app_info_json: *const c_char) -> *mut c_char {
    with(|l| crate::diagnostics::export(&l, Path::new(&s(out_path)), &s(app_info_json)))
}

#[derive(Deserialize)]
struct TagFolderArgs { label: String, folder: String }

/// Puts every media in the library that carries a tag (under its current name, any origin)
/// into a folder (created if needed). Returns how many were newly added.
#[no_mangle]
pub extern "C" fn tl_tag_to_folder(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: TagFolderArgs = serde_json::from_str(&s(json))?;
        let db = l.db();
        let ids: Vec<String> = db.export_items(&[a.label.clone()], &[])?.into_iter().map(|i| i.media_id).collect();
        let tx = db.conn().unchecked_transaction()?;
        let name = db.create_folder(&a.folder)?;
        let n = db.add_to_folder(&name, &ids)?;
        tx.commit()?;
        Ok(n)
    })
}

/// Checks the stored cookies (Settings → 检查 Cookie): {"screen_name", "name"?} or {"error"}.
#[no_mangle]
pub extern "C" fn tl_check_cookies(auth_token: *const c_char, ct0: *const c_char) -> *mut c_char { guard_ptr(|| {
    let c = crate::protected::Credentials { auth_token: s(auth_token), ct0: s(ct0) };
    let v = match crate::protected::check(&c) {
        Ok(a) => serde_json::json!({ "screen_name": a.screen_name, "name": a.name }),
        Err(e) => serde_json::json!({ "error": e.to_string() }),
    };
    out(serde_json::json!({ "ok": v }).to_string())
}) }

// UI actions: explicit scope, frozen confirmations, and conditional undo receipts.
#[no_mangle]
pub extern "C" fn tl_post_scope(post: *const c_char) -> *mut c_char { with(|l| Ok(l.db().post_scope(&s(post))?)) }
#[no_mangle]
pub extern "C" fn tl_bin_snapshot() -> *mut c_char { with(|l| l.bin_snapshot()) }
#[no_mangle]
pub extern "C" fn tl_action(json: *const c_char) -> *mut c_char { with(|l| l.apply_action(&serde_json::from_str(&s(json))?)) }
#[no_mangle]
pub extern "C" fn tl_action_undo(json: *const c_char) -> *mut c_char { with(|l| l.undo_action(&serde_json::from_str(&s(json))?)) }

#[no_mangle]
pub extern "C" fn tl_integrity_summary() -> *mut c_char { with(|l| crate::verify::summary(&l)) }

// ---------- photo grid zoom (shared by every front end) ----------
//
// The engine lives behind an opaque pointer owned by the caller (`tl_grid_new` … `tl_grid_free`)
// and is driven every frame, so nothing here allocates per frame or goes through JSON: tiles are
// written into the caller's buffer as 9 doubles each — x, y, side, alpha, index, then the corner
// radii top-left, top-right, bottom-right, bottom-left (screen points). Not thread-safe: one
// engine per grid, used from the thread that draws it.

use crate::grid::{GridConfig, RestState, ZoomEngine};

fn grid<'a>(p: *mut ZoomEngine) -> Option<&'a mut ZoomEngine> { unsafe { p.as_mut() } }

/// A grid of `count` items in a view of the given size; `phase` < 0 = the phase that fills the
/// last row (the library opens at its bottom).
#[no_mangle]
pub extern "C" fn tl_grid_new(width: f64, height: f64, scale: f64, inset_top: f64, inset_bottom: f64, count: u64, level: u32, phase: i32, offset: f64) -> *mut ZoomEngine {
    guard(std::ptr::null_mut(), || {
        let cfg = GridConfig::new(width, height, scale.max(1.0), inset_top, inset_bottom, count as usize);
        let level = (level as usize).min(cfg.levels() - 1);
        let phase = if phase < 0 { cfg.bottom_phase(level) } else { phase as usize % cfg.columns[level] };
        let offset = offset.clamp(0.0, cfg.max_offset(level, phase));
        Box::into_raw(Box::new(ZoomEngine::new(cfg, RestState { level, phase, offset })))
    })
}

#[no_mangle]
pub extern "C" fn tl_grid_free(p: *mut ZoomEngine) { if !p.is_null() { guard((), || drop(unsafe { Box::from_raw(p) })) } }

/// New view size or item count. A zoom in progress is finished first; the level is kept and the
/// offset kept within the content.
#[no_mangle]
pub extern "C" fn tl_grid_configure(p: *mut ZoomEngine, width: f64, height: f64, scale: f64, inset_top: f64, inset_bottom: f64, count: u64) {
    guard((), || if let Some(e) = grid(p) {
        e.release(0.0, 1.0);
        e.finish_now();
        let cfg = GridConfig::new(width, height, scale.max(1.0), inset_top, inset_bottom, count as usize);
        let level = e.rest.level.min(cfg.levels() - 1);
        let phase = e.rest.phase % cfg.columns[level];
        let offset = e.rest.offset.clamp(0.0, cfg.max_offset(level, phase));
        e.cfg = cfg;
        e.rest = RestState { level, phase, offset };
    })
}

/// The resting layout into `out`: level, phase, offset.
#[no_mangle]
pub extern "C" fn tl_grid_rest(p: *mut ZoomEngine, out: *mut f64) {
    guard((), || if let (Some(e), false) = (grid(p), out.is_null()) {
        let o = unsafe { std::slice::from_raw_parts_mut(out, 3) };
        o.copy_from_slice(&[e.rest.level as f64, e.rest.phase as f64, e.rest.offset]);
    })
}

/// Scrolling: the front end owns the scroll physics and sets the offset (clamped here).
#[no_mangle]
pub extern "C" fn tl_grid_set_offset(p: *mut ZoomEngine, offset: f64) {
    guard((), || if let Some(e) = grid(p) { e.rest.offset = offset.clamp(0.0, e.cfg.max_offset(e.rest.level, e.rest.phase)); })
}

#[no_mangle]
pub extern "C" fn tl_grid_max_offset(p: *mut ZoomEngine) -> f64 {
    guard(0.0, || grid(p).map_or(0.0, |e| e.cfg.max_offset(e.rest.level, e.rest.phase)))
}

/// How many zoom levels the grid has at this width (level 0 is the densest).
#[no_mangle]
pub extern "C" fn tl_grid_levels(p: *mut ZoomEngine) -> u64 { guard(0, || grid(p).map_or(0, |e| e.cfg.levels() as u64)) }

/// The side of a tile at `level`.
#[no_mangle]
pub extern "C" fn tl_grid_side(p: *mut ZoomEngine, level: u64) -> f64 { guard(0.0, || grid(p).map_or(0.0, |e| if (level as usize) < e.cfg.levels() { e.cfg.side(level as usize) } else { 0.0 })) }

#[no_mangle]
pub extern "C" fn tl_grid_begin_pinch(p: *mut ZoomEngine, x: f64, y: f64, time: f64) { guard((), || if let Some(e) = grid(p) { e.begin_pinch((x, y), time) }) }

#[no_mangle]
pub extern "C" fn tl_grid_pinch_changed(p: *mut ZoomEngine, scale: f64, x: f64, y: f64) { guard((), || if let Some(e) = grid(p) { e.pinch_changed(scale, (x, y)) }) }

/// `velocity` in scale per second, as gesture recognisers report it.
#[no_mangle]
pub extern "C" fn tl_grid_release(p: *mut ZoomEngine, velocity: f64, scale: f64) { guard((), || if let Some(e) = grid(p) { e.release(velocity, scale) }) }

/// Advances a zoom to `time` (seconds, any monotonic clock): -1 nothing zooming, 0 still
/// zooming, 1 the zoom came to rest in this frame.
#[no_mangle]
pub extern "C" fn tl_grid_tick(p: *mut ZoomEngine, time: f64) -> i32 {
    guard(-1, || match grid(p) { Some(e) if e.is_zooming() => i32::from(e.tick(time).is_some()), _ => -1 })
}

/// Ends a settling zoom at once (the user started scrolling); false while fingers are down.
#[no_mangle]
pub extern "C" fn tl_grid_finish_now(p: *mut ZoomEngine) -> bool { guard(false, || grid(p).is_some_and(|e| e.finish_now().is_some())) }

/// Drops a leftover phase when the first row is within `rows` rows of the screen (see
/// `ZoomEngine::realign_near_top`); true when the layout changed.
#[no_mangle]
pub extern "C" fn tl_grid_realign_top(p: *mut ZoomEngine, rows: f64) -> bool { guard(false, || grid(p).is_some_and(|e| e.realign_near_top(rows))) }

/// The frame's side, cross-fade level, latched level and column count into `out` (4 doubles).
#[no_mangle]
pub extern "C" fn tl_grid_info(p: *mut ZoomEngine, out: *mut f64) {
    guard((), || if let (Some(e), false) = (grid(p), out.is_null()) {
        let i = e.info();
        unsafe { std::slice::from_raw_parts_mut(out, 4) }.copy_from_slice(&[i.side, i.level, i.target as f64, i.columns as f64]);
    })
}

/// Writes up to `capacity` tiles of the current frame (9 doubles each, back to front) and
/// returns how many there are; call again with a larger buffer if that is more than `capacity`.
#[no_mangle]
pub extern "C" fn tl_grid_tiles(p: *mut ZoomEngine, buffer: *mut f64, capacity: u64) -> u64 {
    guard(0, || {
        let Some(e) = grid(p) else { return 0 };
        let mut tiles = Vec::with_capacity(256);
        e.tiles(&mut tiles);
        if !buffer.is_null() {
            let n = tiles.len().min(capacity as usize);
            let b = unsafe { std::slice::from_raw_parts_mut(buffer, n * 9) };
            for (t, o) in tiles.iter().zip(b.chunks_exact_mut(9)) {
                o.copy_from_slice(&[t.x, t.y, t.side, t.alpha, t.index as f64, t.radii[0], t.radii[1], t.radii[2], t.radii[3]]);
            }
        }
        tiles.len() as u64
    })
}

/// The item under a screen point at rest, or -1.
#[no_mangle]
pub extern "C" fn tl_grid_index_at(p: *mut ZoomEngine, x: f64, y: f64) -> i64 {
    guard(-1, || grid(p).and_then(|e| e.rest_index((x, y))).map_or(-1, |i| i as i64))
}

/// An item's resting frame into `out`: x, y, side (screen points).
#[no_mangle]
pub extern "C" fn tl_grid_frame(p: *mut ZoomEngine, index: u64, out: *mut f64) {
    guard((), || if let (Some(e), false) = (grid(p), out.is_null()) {
        let (x, y, s) = e.rest_frame(index as usize, e.rest);
        unsafe { std::slice::from_raw_parts_mut(out, 3) }.copy_from_slice(&[x, y, s]);
    })
}

/// An item not drawn (lifted out by a context menu), or -1 for none.
#[no_mangle]
pub extern "C" fn tl_grid_set_hidden(p: *mut ZoomEngine, index: i64) {
    guard((), || if let Some(e) = grid(p) { e.hidden = (index >= 0).then_some(index as usize) })
}

// Portable grid thumbnails. One coordinator coalesces queued generations, so
// rapid requests do not create a backlog of threads waiting for the warm lock.
struct ThumbWarmJob {
    lib: Arc<Library>,
    ids: Vec<String>,
    side: u32,
    directory: std::path::PathBuf,
    cancel: Arc<std::sync::atomic::AtomicBool>,
}
#[derive(Default)]
struct ThumbWarmState {
    pending: Option<ThumbWarmJob>,
    cancel: Option<Arc<std::sync::atomic::AtomicBool>>,
}
#[derive(Default)]
struct ThumbWarmQueue {
    state: Mutex<ThumbWarmState>,
    ready: std::sync::Condvar,
}
static THUMB_WARM_QUEUE: Mutex<Option<Arc<ThumbWarmQueue>>> = Mutex::new(None);

fn thumb_warm_queue() -> anyhow::Result<Arc<ThumbWarmQueue>> {
    let mut initialized = THUMB_WARM_QUEUE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(queue) = initialized.as_ref() { return Ok(queue.clone()); }
    let queue = Arc::new(ThumbWarmQueue::default());
    let worker = queue.clone();
    std::thread::Builder::new().name("tl-thumbnails-warm".into()).spawn(move || loop {
        let job = {
            let mut state = worker.state.lock().unwrap_or_else(|e| e.into_inner());
            while state.pending.is_none() {
                state = worker.ready.wait(state).unwrap_or_else(|e| e.into_inner());
            }
            state.pending.take().unwrap()
        };
        guard((), || {
            crate::thumbs::warm(&job.lib, &job.ids, job.side, &job.directory, &job.cancel);
        });
    })?;
    *initialized = Some(queue.clone());
    Ok(queue)
}

#[no_mangle]
pub extern "C" fn tl_thumbnail(media_id: *const c_char, side: u32, cache_dir: *const c_char) -> *mut c_char {
    with(|l| crate::thumbs::thumbnail(&l, &s(media_id), side, Path::new(&s(cache_dir))))
}

/// A HEIC or AVIF file as a JPEG the front end can show; needs no open library.
#[no_mangle]
pub extern "C" fn tl_display_image(path: *const c_char, max_side: u32, cache_dir: *const c_char) -> *mut c_char {
    respond(|| crate::thumbs::display_image(Path::new(&s(path)), max_side, Path::new(&s(cache_dir))))
}

#[no_mangle]
pub extern "C" fn tl_thumbnails_warm(ids_json: *const c_char, side: u32, cache_dir: *const c_char) -> *mut c_char {
    with(|l| {
        crate::thumbs::check_side(side)?;
        let ids: Vec<String> = serde_json::from_str(&s(ids_json))?;
        let directory = std::path::PathBuf::from(s(cache_dir));
        let cancel = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let queue = thumb_warm_queue()?;
        let mut state = queue.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(previous) = state.cancel.replace(cancel.clone()) {
            previous.store(true, std::sync::atomic::Ordering::Release);
        }
        state.pending = Some(ThumbWarmJob { lib: l, ids, side, directory, cancel });
        queue.ready.notify_one();
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn tl_thumbnails_warm_cancel() {
    guard((), || {
        let queue = THUMB_WARM_QUEUE.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(queue) = queue {
            let mut state = queue.state.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(cancel) = state.cancel.as_ref() {
                cancel.store(true, std::sync::atomic::Ordering::Release);
            }
            state.pending = None;
        }
    })
}

// ---------- LAN discovery and sync scheduling (shared by every front end) ----------

static DISCOVERY: Mutex<Option<Arc<crate::discovery::Discovery>>> = Mutex::new(None);

/// Starts advertising this device and finding the account's others, and syncing with them on
/// its own (after `tl_sync_start`: the listener's port is advertised). `service_type` like
/// `_twlib._tcp`. Restarting replaces a running discovery.
#[no_mangle]
pub extern "C" fn tl_discovery_start(service_type: *const c_char, device_name: *const c_char, device_kind: *const c_char) -> *mut c_char {
    with(|_| {
        let kind = if device_kind.is_null() { String::new() } else { s(device_kind) };
        let d = crate::discovery::Discovery::start_as(node()?, &s(service_type), &s(device_name), &kind).map_err(|_| anyhow::anyhow!("sync.err.paused"))?;
        if let Some(old) = DISCOVERY.lock().unwrap().replace(d) { old.stop(); }
        Ok(())
    })
}

/// The devices found, and whether discovery runs (`{"running":false,…}` before it started).
#[no_mangle]
pub extern "C" fn tl_discovery_status() -> *mut c_char {
    with(|_| Ok(match DISCOVERY.lock().unwrap().as_ref() {
        Some(d) => d.status(),
        None => crate::discovery::DiscoveryStatus { running: false, network_ok: false, peers: vec![], error: None },
    }))
}

/// The library changed here: sync in a few seconds.
#[no_mangle]
pub extern "C" fn tl_discovery_changed() { guard((), || if let Some(d) = DISCOVERY.lock().unwrap().as_ref() { d.changed() }) }

/// 立即同步: look every device up again and sync with each.
#[no_mangle]
pub extern "C" fn tl_discovery_sync_now() { guard((), || if let Some(d) = DISCOVERY.lock().unwrap().as_ref() { d.sync_now() }) }

/// The network may have changed (wake, back to the foreground): advertise and look up again.
#[no_mangle]
pub extern "C" fn tl_discovery_rediscover() { guard((), || if let Some(d) = DISCOVERY.lock().unwrap().as_ref() { d.rediscover() }) }

#[no_mangle]
pub extern "C" fn tl_discovery_stop() { guard((), || if let Some(d) = DISCOVERY.lock().unwrap().take() { d.stop() }) }

// ---------- the mascot (see pet.rs) ----------

fn pet<'a>(p: *mut crate::pet::Pet) -> Option<&'a mut crate::pet::Pet> { unsafe { p.as_mut() } }

#[no_mangle]
pub extern "C" fn tl_pet_new(seed: u64) -> *mut crate::pet::Pet { Box::into_raw(Box::new(crate::pet::Pet::new(seed))) }

#[no_mangle]
pub extern "C" fn tl_pet_free(p: *mut crate::pet::Pet) { if !p.is_null() { guard((), || drop(unsafe { Box::from_raw(p) })) } }

#[no_mangle]
pub extern "C" fn tl_pet_set_bounds(p: *mut crate::pet::Pet, width: f64, height: f64, margin_right: f64, margin_bottom: f64) {
    guard((), || if let Some(e) = pet(p) { e.set_bounds(width, height, margin_right, margin_bottom) })
}

#[no_mangle]
pub extern "C" fn tl_pet_pointer(p: *mut crate::pet::Pet, x: f64, y: f64) { guard((), || if let Some(e) = pet(p) { e.pointer_moved(x, y) }) }

#[no_mangle]
pub extern "C" fn tl_pet_pointer_gone(p: *mut crate::pet::Pet) { guard((), || if let Some(e) = pet(p) { e.pointer_gone() }) }

/// Whether a point is on it (a front end takes the tap there, and lets others through).
#[no_mangle]
pub extern "C" fn tl_pet_hit(p: *mut crate::pet::Pet, x: f64, y: f64) -> bool { guard(false, || pet(p).map_or(false, |e| e.hit(x, y))) }

#[no_mangle]
pub extern "C" fn tl_pet_tap(p: *mut crate::pet::Pet, x: f64, y: f64) -> bool { guard(false, || pet(p).map_or(false, |e| e.tap(x, y))) }

/// Advances `dt` seconds and writes the picture: x, y, w, h, ARGB (five doubles per rectangle,
/// back to front), at most `capacity` rectangles. Returns how many there are.
#[no_mangle]
pub extern "C" fn tl_pet_tick(p: *mut crate::pet::Pet, dt: f64, buffer: *mut f64, capacity: u64) -> u64 {
    guard(0, || {
        let Some(e) = pet(p) else { return 0 };
        e.tick(dt);
        let mut rects = Vec::with_capacity(64);
        e.draw(&mut rects);
        if !buffer.is_null() {
            let out = unsafe { std::slice::from_raw_parts_mut(buffer, capacity as usize * 5) };
            for (i, r) in rects.iter().take(capacity as usize).enumerate() {
                out[i * 5..i * 5 + 5].copy_from_slice(&[r.x, r.y, r.w, r.h, r.color as f64]);
            }
        }
        rects.len() as u64
    })
}


// ---------------------------------------------------------------------------------------------
// the browser extension (see extension.rs)

/// This device for the browser extension: its name, platform and download settings, and with
/// `"listen": true` the listener (started once). `{"ok": port or null}`.
#[no_mangle]
pub extern "C" fn tl_ext_serve(options_json: *const c_char) -> *mut c_char {
    respond(|| crate::extension::serve(serde_json::from_str(&s(options_json))?))
}

/// A new binding code: `{code, link, addresses, expires_in}`. `addresses_json`: a JSON array of
/// "host:port" the browser reaches this device at, or null for this device's own LAN addresses.
#[no_mangle]
pub extern "C" fn tl_ext_pair_begin(addresses_json: *const c_char) -> *mut c_char {
    with(|l| crate::extension::pair_begin(&l, serde_json::from_str::<Option<Vec<String>>>(&s(addresses_json)).unwrap_or(None)))
}

#[no_mangle]
pub extern "C" fn tl_ext_pair_cancel() { guard((), crate::extension::pair_cancel) }

/// `{clients: [{id, name, added, seen}], pairing: {code, link, expires_in} | null, port}`
#[no_mangle]
pub extern "C" fn tl_ext_clients() -> *mut c_char { with(|l| Ok(crate::extension::clients(&l))) }

/// Unbinds a browser. `{"ok": whether it was bound}`
#[no_mangle]
pub extern "C" fn tl_ext_remove(id: *const c_char) -> *mut c_char { with(|l| crate::extension::remove(&l, &s(id))) }

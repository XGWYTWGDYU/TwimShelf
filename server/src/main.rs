//! TwimShelf Linux server (in Docker, or on its own): the same Rust core as the apps, and the Flutter
//! app built for the web, on one port.
//!
//! * `/` — the web app (`TL_WEB`, default `/app/web`).
//! * `POST /api/call/<function>` — one call of the core: a JSON array of arguments in, `{"r": …}`
//!   out (the functions and their order are the C ABI's, see `dispatch.rs`, generated).
//! * `GET /api/info` — where the data lives, for the web app to pass on to the core.
//! * `GET /f/<path>` — a file of the data folder (media, thumbnails, exports), with ranges, so
//!   videos stream and seek.
//! * `POST /api/upload?name=…` — a file from the browser into the data folder (imports).
//! * `GET /gfonts/<path>` — the fonts the web app falls back on for scripts and emoji its own
//!   font lacks (Chinese, Japanese, …): fetched once from Google Fonts and kept in
//!   `cache/fonts`, so browsers on a LAN without internet show them once the server has.
//! * `POST /api/proxy` — an HTTPS request on the browser's behalf (external AI services, which a
//!   page cannot call itself across origins).
//!
//! * `/ext/…` — the browser extension (token of its own, see the core's `extension.rs`).
//!
//! Everything is kept in `TL_DATA` (default `/data`): `library`, `models`, `cache`, `uploads`,
//! `exports`, `app`. `TL_PORT` (default 2778) is the port. Signing in: see `auth.rs` (a password,
//! `twimshelf passwd` to set it); who may connect: see `gate.rs` (the local network, or anyone
//! with `TL_ALLOW_PUBLIC=true`).
mod auth;
mod dispatch;
mod gate;
mod llama;
mod secrets;
mod wire;

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Path as UrlPath, Query, Request, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::middleware;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use futures_util::TryStreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tower::ServiceExt;
use tower_http::services::{ServeDir, ServeFile};

pub struct Config {
    data: PathBuf,
    web: PathBuf,
    auth: auth::Auth,
    secrets: secrets::Secrets,
    /// Answer requests from the internet too (`TL_ALLOW_PUBLIC`); the local network only otherwise.
    public: bool,
    /// The window that runs the web app's own background work (see `gate::lease`).
    lease: std::sync::Mutex<Option<(String, std::time::Instant)>>,
    /// The desktop (Electron) app's server: its window carries this token as a cookie instead of
    /// signing in (`TL_DESKTOP_TOKEN`, made by the app at each start).
    desktop: Option<String>,
}

impl Config {
    /// A data folder; the desktop app may keep the library and models where the Flutter app had
    /// them (`TL_LIBRARY`, `TL_MODELS`), so an upgrade finds them.
    fn dir(&self, name: &str) -> PathBuf {
        let over = match name { "library" => std::env::var_os("TL_LIBRARY"), "models" => std::env::var_os("TL_MODELS"), _ => None };
        over.filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| self.data.join(name))
    }
}

pub type Shared = Arc<Config>;

fn env(name: &str, default: &str) -> String { std::env::var(name).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| default.into()) }

fn c(s: &Path) -> CString { CString::new(s.to_string_lossy().as_bytes()).unwrap_or_default() }

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // absolute: paths handed to the web app come back in requests (`/f/<path>`)
    let data = std::path::absolute(env("TL_DATA", "/data"))?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    // `twimshelf passwd`: in the container, sets the web password
    if args.first().map(String::as_str) == Some("passwd") {
        if let Err(e) = auth::passwd_command(&data, &args[1..]) { eprintln!("{e:#}"); std::process::exit(1); }
        return Ok(());
    }
    let public = matches!(env("TL_ALLOW_PUBLIC", "").to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on");
    let config = Arc::new(Config {
        auth: auth::Auth::new(&data),
        secrets: secrets::Secrets::new(data.join("app")),
        data,
        web: PathBuf::from(env("TL_WEB", "/app/web")),
        public,
        lease: std::sync::Mutex::new(None),
        desktop: std::env::var("TL_DESKTOP_TOKEN").ok().filter(|t| t.len() >= 32),
    });
    let port: u16 = env("TL_PORT", "2778").parse()?;
    // the container's health check: is the server answering?
    if std::env::args().any(|a| a == "--health") {
        let ok = std::net::TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), std::time::Duration::from_secs(3)).is_ok();
        std::process::exit(if ok { 0 } else { 1 });
    }
    for d in ["library", "models", "cache", "uploads", "exports", "app"] { std::fs::create_dir_all(config.dir(d))?; }
    // video frames are taken by the page now: what earlier versions made here is not used any more
    let _ = std::fs::remove_dir_all(config.dir("cache").join("posters"));
    // the desktop app signs its window in with its token: no web password there
    if config.desktop.is_none() { config.auth.prepare(&config.data)?; }
    if config.public { eprintln!("access: from anywhere (TL_ALLOW_PUBLIC); put it behind HTTPS"); } else { eprintln!("access: local network only (TL_ALLOW_PUBLIC=true to allow the internet)"); }

    // the library is the server's: opened once here (a web client's own `tl_open` is answered
    // with this one, see `call`)
    tl_core::ffi::tl_set_app_name(c(Path::new("TwimShelf")).as_ptr());
    if !tl_core::ffi::tl_open(c(&config.dir("library")).as_ptr()) { anyhow::bail!("cannot open the library in {}", config.dir("library").display()); }
    wire::take(tl_core::ffi::tl_set_models_dir(c(&config.dir("models")).as_ptr()));
    // (the core runs its own async runtime: called from a plain thread)
    { let cfg = config.clone(); tokio::task::spawn_blocking(move || { apply_cookies(&cfg); start_sync(&cfg); gate::refresh_extension_options(&cfg); }).await?; }

    let api = file_routes()
        .route("/api/info", get(info))
        .route("/api/proxy", post(proxy).layer(DefaultBodyLimit::max(64 << 20)))
        .route("/api/scaled", get(scaled))
        .route("/api/ai/describe", post(ai_describe).layer(DefaultBodyLimit::max(32 << 20)))
        .route("/api/ai/unload", post(ai_unload))
        .route("/gfonts/{*path}", get(gfont))
        .route("/api/lease", post(gate::lease))
        .route("/login", get(gate::login_page).post(gate::login).layer(DefaultBodyLimit::max(64 << 10)))
        .route("/logout", get(gate::logout))
        .route("/ext/{*rest}", axum::routing::any(gate::ext).layer(DefaultBodyLimit::max(1 << 20)))
        .layer(DefaultBodyLimit::max(64 << 20));
    let web = ServeDir::new(&config.web).fallback(ServeFile::new(config.web.join("index.html")));
    let app = api
        .fallback_service(web)
        .layer(middleware::from_fn_with_state(config.clone(), gate::gate))
        .layer(tower_http::compression::CompressionLayer::new())
        .with_state(config.clone());

    // the desktop app's server ends with the app, even when the app was killed: the app holds
    // its standard input open, and it closes when the app is gone
    if config.desktop.is_some() {
        std::thread::spawn(|| { let mut sink = Vec::new(); let _ = std::io::Read::read_to_end(&mut std::io::stdin(), &mut sink); std::process::exit(0); });
    }
    // the desktop app's server answers only this computer
    let host = if config.desktop.is_some() { "127.0.0.1" } else { "0.0.0.0" };
    let listener = tokio::net::TcpListener::bind((host, port)).await?;
    eprintln!("TwimShelf {VERSION} on port {port}, data in {}", config.data.display());
    axum::serve(listener, app.into_make_service_with_connect_info::<std::net::SocketAddr>()).with_graceful_shutdown(async { let _ = tokio::signal::ctrl_c().await; }).await?;
    Ok(())
}

fn file_routes() -> Router<Shared> {
    Router::new()
        .route("/api/call/{name}", post(call))
        .route("/api/secrets", post(secrets::update).delete(secrets::clear).layer(DefaultBodyLimit::max(256 << 10)))
        .route("/api/secrets/{name}", get(secrets::read))
        .route("/api/upload", post(upload).layer(DefaultBodyLimit::disable()))
        .route("/f/{*path}", get(file).put(put_file).delete(delete_file))
        .route("/api/move", post(move_file))
}

/// config.yaml's version (the image build passes it), or the crate's for a plain `cargo build`.
const VERSION: &str = match option_env!("TL_VERSION") { Some(v) if !v.is_empty() => v, _ => env!("CARGO_PKG_VERSION") };

/// The name the account's other devices show for this server (`TL_DEVICE_NAME`).
pub fn device_name() -> String { env("TL_DEVICE_NAME", "TwimShelf Linux Server") }

/// The server is a device of its own: once the web app has joined it to a sync account (the key
/// sealed in `app/secrets.json`, as the desktop apps keep it), it syncs from start-up on, with
/// no browser open.
fn start_sync(cfg: &Config) {
    let account = cfg.secrets.read(["sync.key"]).inspect_err(|_| eprintln!("secrets: sync key cannot be read"));
    let Ok([Some(account)]) = account else { return };
    let name = device_name();
    let service = env("TL_SYNC_SERVICE", "_twlib._tcp");
    let r = wire::take(tl_core::ffi::tl_sync_start(c(Path::new(&account)).as_ptr(), c(Path::new(&name)).as_ptr()));
    let d = wire::take(tl_core::ffi::tl_discovery_start(c(Path::new(&service)).as_ptr(), c(Path::new(&name)).as_ptr(), c(Path::new("linux")).as_ptr()));
    eprintln!("sync: started as \"{name}\" ({r}, {d})");
}

/// The X session cookies the web app stored: downloads (from the browser extension too) can use
/// them with no browser open.
fn apply_cookies(cfg: &Config) {
    let cookies = cfg.secrets.read(["auth_token", "ct0"]).inspect_err(|_| eprintln!("secrets: download cookies cannot be read"));
    if let Ok([Some(a), Some(t)]) = cookies {
        tl_core::ffi::tl_set_cookies(c(Path::new(&a)).as_ptr(), c(Path::new(&t)).as_ptr());
    }
}

async fn info(State(cfg): State<Shared>) -> Json<Value> {
    let d = |n: &str| cfg.dir(n).to_string_lossy().into_owned();
    let (local_ai_supported, local_ai_devices) = tokio::task::spawn_blocking(llama::info).await.unwrap_or((false, None));
    Json(json!({
        "data": cfg.data.to_string_lossy(), "library": d("library"), "models": d("models"),
        "cache": d("cache"), "uploads": d("uploads"), "exports": d("exports"),
        "version": VERSION, "functions": dispatch::NAMES, "device_name": device_name(), "sync_service": env("TL_SYNC_SERVICE", "_twlib._tcp"),
        "local_ai": { "supported": local_ai_supported, "devices": local_ai_devices },
        // a GitHub build's repository (the page tells of newer releases); none for other builds
        "update_repo": option_env!("TL_UPDATE_REPO").filter(|r| r.contains('/')),
    }))
}

/// One call of the core, on a blocking thread (some calls import or export for minutes).
async fn call(State(cfg): State<Shared>, UrlPath(name): UrlPath<String>, body: axum::body::Bytes) -> Response {
    if !dispatch::NAMES.contains(&name.as_str()) { return (StatusCode::NOT_FOUND, "no such function").into_response(); }
    let args: Vec<Value> = if body.is_empty() { vec![] } else {
        match serde_json::from_slice(&body) { Ok(Value::Array(a)) => a, _ => return (StatusCode::BAD_REQUEST, "arguments: a JSON array").into_response() }
    };
    // the library was opened at start-up: opening it again would replace it under running work
    if name == "tl_open" { return Json(json!({ "r": true })).into_response(); }
    if !paths_allowed(&cfg, &name, &args) { return (StatusCode::FORBIDDEN, "outside the data folder").into_response(); }
    let models = cfg.dir("models").to_string_lossy().into_owned();
    let storage_paths = (name == "tl_storage_usage").then(|| {
        let desktop_paths: Option<Vec<PathBuf>> = cfg.desktop.as_ref().and_then(|_| {
            serde_json::from_str(&std::env::var("TL_DESKTOP_APP_PATHS").ok()?).ok()
        });
        desktop_paths.unwrap_or_else(|| {
            let mut paths = vec![cfg.web.clone()];
            paths.extend(std::env::current_exe().ok());
            paths
        })
    });
    let r = tokio::task::spawn_blocking(move || {
        let mut args = args;
        // the data folders are the server's: a client cannot point the core elsewhere
        if name == "tl_set_models_dir" { args = vec![Value::String(models)]; }
        if name == "tl_delete_import_reports" {
            let mut options: serde_json::Map<String, Value> = serde_json::from_str(args.first().and_then(Value::as_str).unwrap_or_default())?;
            let uploads = data_subpath(&cfg, "uploads", &cfg.dir("uploads"), true);
            options.insert("owned".into(), json!(uploads.into_iter().collect::<Vec<_>>()));
            args = vec![Value::String(serde_json::to_string(&options)?)];
        }
        if let Some(paths) = storage_paths {
            let mut extra: Vec<Value> = args.first().and_then(Value::as_str)
                .and_then(|text| serde_json::from_str(text).ok()).unwrap_or_default();
            extra.extend(paths.into_iter().map(|path| json!({ "key": "app", "path": path })));
            args = vec![Value::String(serde_json::to_string(&extra)?)];
        }
        dispatch::call(&name, &wire::Args(args))
    }).await;
    match r {
        Ok(Ok(v)) => Json(json!({ "r": v })).into_response(),
        Ok(Err(e)) => (StatusCode::BAD_REQUEST, format!("{e:#}")).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("{e}")).into_response(),
    }
}

/// Where the server's files are: the data folder, and the library and models where the desktop
/// app keeps them apart from it after an upgrade (`Config::dir`).
fn roots(cfg: &Config) -> Vec<PathBuf> {
    [cfg.data.clone(), cfg.dir("library"), cfg.dir("models")].iter().filter_map(|p| std::fs::canonicalize(p).ok()).collect()
}

/// An absolute path as it really is, links resolved, also when its last parts do not exist yet.
fn resolved(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() || path.as_os_str().as_encoded_bytes().contains(&0)
        || path.components().any(|c| matches!(c, std::path::Component::ParentDir)) { return None; }
    let mut rest = Vec::new();
    let mut at = path;
    loop {
        if let Ok(real) = std::fs::canonicalize(at) { return Some(rest.iter().rev().fold(real, |p, part| p.join(part))); }
        rest.push(at.file_name()?);
        at = at.parent()?;
    }
}

/// A path a read-only argument may use.
fn core_path_allowed(cfg: &Config, path: &str) -> bool {
    let Some(real) = resolved(Path::new(path)) else { return false };
    roots(cfg).iter().any(|r| real.starts_with(r)) && !private(cfg, &real)
}

/// Resolve a path within a specific directory. Its descendants must be ordinary path entries.
fn scoped_path(root: &Path, path: &Path, allow_root: bool) -> Option<PathBuf> {
    let mut target = resolved(root)?;
    let relative = path.strip_prefix(root).or_else(|_| path.strip_prefix(&target)).ok()?;
    if !allow_root && relative.as_os_str().is_empty() { return None; }
    for part in relative.components() {
        let std::path::Component::Normal(name) = part else { return None };
        target.push(name);
        match std::fs::symlink_metadata(&target) {
            Ok(info) if !info.is_symlink() => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            _ => return None,
        }
    }
    Some(target)
}

fn data_subpath(cfg: &Config, name: &str, path: &Path, allow_root: bool) -> Option<PathBuf> {
    let root = cfg.data.join(name);
    // Staging directories are managed by the server. A link at their root would give their
    // permissions to a different directory, including when it points inside the data folder.
    if root.is_symlink() { return None; }
    let real_root = resolved(&root)?;
    for protected in ["library", "models", "app"] {
        let protected = cfg.dir(protected);
        let protected = std::fs::canonicalize(&protected).ok().or_else(|| resolved(&protected))?;
        if real_root.starts_with(&protected) || protected.starts_with(&real_root) { return None; }
    }
    scoped_path(&root, path, allow_root)
}

/// Whether every file path among a call's arguments stays inside the server's folders.
fn paths_allowed(cfg: &Config, name: &str, args: &[Value]) -> bool {
    let text = |i: usize| args.get(i).and_then(Value::as_str).unwrap_or("");
    let json = |i: usize| serde_json::from_str::<Value>(text(i)).unwrap_or(Value::Null);
    let read = |i| core_path_allowed(cfg, text(i));
    let in_dir = |dir, path, allow_root| data_subpath(cfg, dir, Path::new(path), allow_root).is_some();
    let output = |path| in_dir("exports", path, false);
    match name {
        "tl_import_legacy_dir" | "tl_import_legacy_zip" | "tl_import_loose_zip" | "tl_import_pack" | "tl_parse_bookmarks"
        | "tl_model_import" | "tl_import_report" => read(0),
        "tl_db_snapshot" | "tl_export_backup" | "tl_export_diagnostics" => output(text(0)),
        "tl_update_download" => in_dir("exports", text(1), true),
        "tl_model_export_zip" => output(text(1)),
        "tl_share_stage" => in_dir("uploads", text(0), false),
        "tl_share_pack" => in_dir("uploads", text(0), false) && (output(text(1)) || in_dir("uploads", text(1), false)),
        "tl_thumbnail" | "tl_thumbnails_warm" => in_dir("cache", text(2), true),
        "tl_display_image" => read(0) && in_dir("cache", text(2), true),
        // a report names the folder its problem files are copied from
        "tl_import_export_issues" => read(0) && output(text(1)) && std::fs::read(text(0)).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .is_none_or(|r| r["source"].as_str().is_none_or(|s| core_path_allowed(cfg, s))),
        "tl_export_media" => {
            let args = json(0);
            output(args["out"].as_str().unwrap_or(""))
        }
        "tl_import_loose_dir" => {
            let args = json(0);
            let dir = args["dir"].as_str().unwrap_or("");
            let keep_to = args["keep_to"].as_str();
            if args["consume"].as_bool() == Some(true) || keep_to.is_some() {
                in_dir("uploads", dir, false) && keep_to.is_none_or(|p| in_dir("uploads", p, false))
            } else {
                core_path_allowed(cfg, dir)
            }
        }
        "tl_storage_usage" => json(0).as_array().is_none_or(|a| a.iter().all(|e|
            e["path"].as_str().filter(|p| !p.is_empty()).is_none_or(|p| core_path_allowed(cfg, p)))),
        "tl_delete_import_reports" => json(0)["reports"].as_array().is_some_and(|reports|
            reports.iter().all(|p| p.as_str().is_some_and(|p| core_path_allowed(cfg, p)))),
        _ => true,
    }
}

/// `path` resolved inside the server's folders, or None (outside them, or missing).
fn inside_data(cfg: &Config, path: &str) -> Option<PathBuf> {
    let real = std::fs::canonicalize(file_path(path)).ok()?;
    (roots(cfg).iter().any(|r| real.starts_with(r)) && !private(cfg, &real)).then_some(real)
}

fn file_path(path: &str) -> PathBuf {
    Path::new("/").join(path)
}

/// Internal application state is accessed through its own API.
fn private(cfg: &Config, p: &Path) -> bool {
    resolved(&cfg.dir("app")).is_some_and(|app| p.starts_with(app))
}

/// A file of the data folder, with ranges and conditional requests (a video seeks by ranges).
async fn file(State(cfg): State<Shared>, UrlPath(path): UrlPath<String>, req: Request) -> Response {
    let Some(p) = inside_data(&cfg, &path) else { return StatusCode::NOT_FOUND.into_response() };
    if !p.is_file() { return StatusCode::NOT_FOUND.into_response(); }
    let mut res = match ServeFile::new(&p).oneshot(req).await {
        Ok(r) => r.into_response(),
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    // whatever was uploaded is shown as a file, never run as a page of this site
    res.headers_mut().insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_static("sandbox"));
    res.headers_mut().insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    // media files are named by their hash: they never change under the same name
    if p.starts_with(cfg.dir("library").join("blobs")) || p.starts_with(cfg.dir("cache")) {
        res.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("private, max-age=31536000, immutable"));
    }
    res
}

fn library_file(cfg: &Config, path: &Path, relative: &str) -> Option<PathBuf> {
    let library = cfg.dir("library");
    let file = scoped_path(&library, &library.join(relative), false)?;
    (scoped_path(&library, path, false)? == file).then_some(file)
}

/// Browser-managed download options. Central library files are only written by the core.
async fn put_file(State(cfg): State<Shared>, UrlPath(path): UrlPath<String>, body: axum::body::Bytes) -> Response {
    let Some(p) = library_file(&cfg, &file_path(&path), "downloads.queue.json") else { return StatusCode::FORBIDDEN.into_response() };
    let tmp = p.with_extension(format!("tmp{:08x}", rand::random::<u32>()));
    let mut file = match tokio::fs::File::create_new(&tmp).await {
        Ok(file) => file,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };
    let r = async {
        file.write_all(&body).await?;
        file.sync_all().await?;
        drop(file);
        tokio::fs::rename(&tmp, &p).await
    }.await;
    match r { Ok(()) => StatusCode::NO_CONTENT.into_response(), Err(e) => { let _ = tokio::fs::remove_file(&tmp).await; (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response() } }
}

async fn delete_file(State(cfg): State<Shared>, UrlPath(path): UrlPath<String>) -> Response {
    let path = file_path(&path);
    let staging = ["uploads", "exports", "cache"].into_iter().find_map(|name| {
        let path = data_subpath(&cfg, name, &path, true)?;
        let root = data_subpath(&cfg, name, &cfg.dir(name), true)?;
        Some((path == root, path))
    });
    let result = if let Some((keep_root, staged)) = staging {
        remove_staging(&staged, keep_root).await
    } else if let Some(file) = ["downloads.queue.json", "logs/app.log", "logs/app.1.log", "logs/diagnostics.log"]
        .into_iter().find_map(|name| library_file(&cfg, &path, name))
    {
        tokio::fs::remove_file(file).await
    } else {
        return StatusCode::FORBIDDEN.into_response();
    };
    match result {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn remove_staging(path: &Path, keep_root: bool) -> std::io::Result<()> {
    async fn remove_entry(path: &Path) -> std::io::Result<()> {
        let meta = tokio::fs::symlink_metadata(path).await?;
        if meta.is_dir() { tokio::fs::remove_dir_all(path).await } else { tokio::fs::remove_file(path).await }
    }
    if !keep_root { return remove_entry(path).await; }
    let mut entries = tokio::fs::read_dir(path).await?;
    while let Some(entry) = entries.next_entry().await? {
        match remove_entry(&entry.path()).await {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            result => result?,
        }
    }
    Ok(())
}

#[derive(Deserialize)]
struct MoveRequest { from: String, to: String }

async fn move_file(State(cfg): State<Shared>, Json(m): Json<MoveRequest>) -> Response {
    let staged = |path: &str| data_subpath(&cfg, "uploads", Path::new(path), false);
    let (Some(from), Some(to)) = (staged(&m.from), staged(&m.to)) else { return StatusCode::FORBIDDEN.into_response() };
    if !from.is_file() || !to.parent().is_some_and(|p| p.is_dir()) { return StatusCode::NOT_FOUND.into_response(); }
    // Publish the new name without replacing an existing upload, then release the old name.
    let result = async { tokio::fs::hard_link(&from, &to).await?; tokio::fs::remove_file(&from).await }.await;
    match result {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => StatusCode::CONFLICT.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct ScaledQuery { path: String, side: u32, #[serde(default)] whole: Option<u8> }

/// Pictures scaled at the same time.
static PICTURES: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(6);
/// The largest picture decoded here (the core's own limit for HEIF).
const MAX_PIXELS: u64 = 200_000_000;

/// Fits a picture for vision models (same rules as native macOS ModelInput & Windows TaggingImage):
/// long side <= `side`, short side >= 112 (without exceeding `side`), black-padded to <= 4:1.
fn fit_for_model(picture: image::DynamicImage, side: u32) -> image::DynamicImage {
    use image::imageops::FilterType;
    let (mut w, mut h) = (picture.width() as f64, picture.height() as f64);
    if w <= 0.0 || h <= 0.0 { return picture; }
    let limit = side as f64;
    let fit = (limit / w.max(h)).min(1.0);
    w *= fit;
    h *= fit;
    let short_side = w.min(h);
    let long_side = w.max(h);
    let max_grow = if long_side > 0.0 { (limit / long_side).max(1.0) } else { 1.0 };
    let grow = (112.0 / short_side).clamp(1.0, max_grow);
    let sw = (w * grow).round().max(1.0) as u32;
    let sh = (h * grow).round().max(1.0) as u32;
    let scaled = if sw != picture.width() || sh != picture.height() {
        picture.resize_exact(sw, sh, FilterType::Triangle)
    } else {
        picture
    };
    let cw = sw.max((sh as f64 / 4.0).ceil() as u32);
    let ch = sh.max((sw as f64 / 4.0).ceil() as u32);
    if cw == sw && ch == sh { return scaled; }
    let mut canvas = image::RgbImage::new(cw, ch);
    let rgb = scaled.to_rgb8();
    let ox = (cw - sw) / 2;
    let oy = (ch - sh) / 2;
    image::imageops::overlay(&mut canvas, &rgb, i64::from(ox), i64::from(oy));
    image::DynamicImage::ImageRgb8(canvas)
}

/// A picture of the data folder upright (its EXIF orientation applied) and no longer than
/// `side` on its long edge, as a JPEG: what AI tagging sends, made here so the page decodes a
/// small picture rather than the original (the apps do this in a background isolate).
async fn scaled(State(cfg): State<Shared>, Query(q): Query<ScaledQuery>) -> Response {
    let Some(src) = inside_data(&cfg, &q.path) else { return StatusCode::NOT_FOUND.into_response() };
    let side = q.side.clamp(32, 4096);
    let whole = q.whole.unwrap_or(0) != 0;
    let Some(cache_dir) = data_subpath(&cfg, "cache", &cfg.dir("cache"), true) else { return StatusCode::FORBIDDEN.into_response(); };
    // a page of cards asks for many at once: each one decodes a whole picture
    let Ok(_turn) = PICTURES.acquire().await else { return StatusCode::SERVICE_UNAVAILABLE.into_response() };
    let made = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<u8>> {
        use image::ImageDecoder;
        // HEIC/HEIF/AVIF go through the core's libheif first so `image` can decode the JPEG
        let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
        let decode_path = if matches!(ext.as_str(), "heic" | "heif" | "avif") {
            let raw = wire::take(tl_core::ffi::tl_display_image(
                c(&src).as_ptr(),
                side,
                c(&cache_dir).as_ptr(),
            ));
            raw.as_str()
                .and_then(|s| serde_json::from_str::<Value>(s).ok())
                .and_then(|v| v.get("ok").and_then(Value::as_str).map(PathBuf::from))
                .unwrap_or_else(|| src.clone())
        } else {
            src.clone()
        };
        let mut decoder = image::ImageReader::open(&decode_path)?.with_guessed_format()?.into_decoder()?;
        let (w, h) = decoder.dimensions();
        anyhow::ensure!(u64::from(w) * u64::from(h) <= MAX_PIXELS, "picture too large");
        let orientation = decoder.orientation().unwrap_or(image::metadata::Orientation::NoTransforms);
        let mut picture = image::DynamicImage::from_decoder(decoder)?;
        picture.apply_orientation(orientation);
        let quality = if whole {
            picture = fit_for_model(picture, side);
            80
        } else {
            if picture.width().max(picture.height()) > side { picture = picture.thumbnail(side, side); }
            95
        };
        let mut out = std::io::Cursor::new(Vec::new());
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality).encode_image(&picture.to_rgb8())?;
        Ok(out.into_inner())
    }).await;
    match made {
        Ok(Ok(bytes)) => ([(header::CONTENT_TYPE, "image/jpeg")], bytes).into_response(),
        Ok(Err(e)) => (StatusCode::UNPROCESSABLE_ENTITY, format!("{e:#}")).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct LocalDescribeRequest {
    model_id: String,
    image_b64: String,
    system: String,
    question: String,
    #[serde(default)]
    max_tokens: Option<i32>,
}


fn find_local_gguf(model_id: &str) -> anyhow::Result<(PathBuf, Option<PathBuf>, bool)> {
    let raw = wire::take(tl_core::ffi::tl_models_installed());
    let envelope: Value = serde_json::from_str(raw.as_str().unwrap_or("{}"))?;
    let list = envelope.get("ok").and_then(Value::as_array).ok_or_else(|| anyhow::anyhow!("models unavailable"))?;
    let m = list.iter().find(|x| x.get("id").and_then(Value::as_str) == Some(model_id))
        .ok_or_else(|| anyhow::anyhow!("models.external.err.noModel"))?;
    let format = m.get("format").and_then(Value::as_str).unwrap_or("");
    anyhow::ensure!(format == "gguf", "only gguf local models are supported");
    let dir = PathBuf::from(m.get("path").and_then(Value::as_str).unwrap_or(""));
    let weights_name = m.get("weights").and_then(Value::as_str).filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow::anyhow!("models.external.err.noModel"))?;
    let weights = dir.join(weights_name);
    let projector = m.get("projector").and_then(Value::as_str).filter(|s| !s.is_empty()).map(|p| dir.join(p));
    let vision = m.get("vision").and_then(Value::as_bool).unwrap_or(false);
    Ok((weights, projector, vision))
}

async fn ai_describe(State(cfg): State<Shared>, Json(req): Json<LocalDescribeRequest>) -> Response {
    let cache = cfg.dir("cache");
    let res = tokio::task::spawn_blocking(move || -> anyhow::Result<String> {
        let (weights, projector, _vision) = find_local_gguf(&req.model_id)?;
        let bytes = base64::engine::general_purpose::STANDARD.decode(&req.image_b64)?;
        let tmp = cache.join(format!("ai-frame-{:016x}.jpg", rand::random::<u64>()));
        std::fs::write(&tmp, &bytes)?;
        struct Cleanup(PathBuf);
        impl Drop for Cleanup { fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); } }
        let _guard = Cleanup(tmp.clone());
        llama::describe(&weights, projector.as_deref(), &tmp, &req.system, &req.question, req.max_tokens.unwrap_or(160))
    }).await;
    match res {
        Ok(Ok(text)) => Json(json!({ "ok": text })).into_response(),
        Ok(Err(e)) => Json(json!({ "error": format!("{e:#}") })).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn ai_unload() -> Response {
    let _ = tokio::task::spawn_blocking(llama::unload_all).await;
    StatusCode::NO_CONTENT.into_response()
}

#[derive(Deserialize)]
struct UploadQuery { name: String }

/// A file from the browser, streamed to `uploads/<random>/<name>`; answers its path on the server.
async fn upload(State(cfg): State<Shared>, Query(q): Query<UploadQuery>, body: Body) -> Response {
    let name: String = Path::new(&q.name).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if name.is_empty() || name.starts_with('.') { return (StatusCode::BAD_REQUEST, "file name").into_response(); }
    let uploads = cfg.dir("uploads");
    let Some(uploads) = data_subpath(&cfg, "uploads", &uploads, true) else { return StatusCode::FORBIDDEN.into_response(); };
    let dir = uploads.join(format!("{:016x}", rand::random::<u64>()));
    if let Err(e) = tokio::fs::create_dir(&dir).await {
        return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
    }
    // a browser that goes away mid-upload ends this request here: nothing half-written stays
    struct Unfinished(Option<PathBuf>);
    impl Drop for Unfinished { fn drop(&mut self) { if let Some(d) = self.0.take() { let _ = std::fs::remove_dir_all(d); } } }
    let mut unfinished = Unfinished(Some(dir.clone()));
    let r: anyhow::Result<PathBuf> = async {
        let path = dir.join(&name);
        let mut f = tokio::fs::File::create_new(&path).await?;
        let mut stream = body.into_data_stream();
        while let Some(chunk) = stream.try_next().await? { f.write_all(&chunk).await?; }
        f.sync_all().await?;
        Ok(path)
    }.await;
    match r {
        Ok(p) => { unfinished.0 = None; Json(json!({ "path": p.to_string_lossy() })).into_response() }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")).into_response(),
    }
}

#[derive(Deserialize)]
struct ProxyRequest {
    url: String,
    #[serde(default = "get_method")] method: String,
    #[serde(default)] headers: Vec<(String, String)>,
    /// base64
    #[serde(default)] body: Option<String>,
}
fn get_method() -> String { "GET".into() }

/// A response's body, refused when it grows past `max` bytes (it is held in memory).
async fn read_capped(mut resp: reqwest::Response, max: usize) -> anyhow::Result<Vec<u8>> {
    let mut body = Vec::new();
    while let Some(chunk) = resp.chunk().await? {
        anyhow::ensure!(body.len() + chunk.len() <= max, "the answer is too large");
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// A fallback font for the web app (see the top): from `cache/fonts`, or fetched from Google
/// Fonts the first time and kept there.
async fn gfont(State(cfg): State<Shared>, UrlPath(path): UrlPath<String>) -> Response {
    let ok = !path.is_empty()
        && path.len() < 300
        && path.split('/').all(|p| !p.is_empty() && p != "." && p != "..")
        && path.chars().all(|c| c.is_ascii_alphanumeric() || "._-/".contains(c));
    if !ok { return StatusCode::NOT_FOUND.into_response(); }
    let file = cfg.dir("cache").join("fonts").join(&path);
    let Some(file) = data_subpath(&cfg, "cache", &file, false) else { return StatusCode::FORBIDDEN.into_response(); };
    let bytes = match tokio::fs::read(&file).await {
        Ok(b) => b,
        Err(_) => {
            let fetched: anyhow::Result<Vec<u8>> = async {
                let resp = reqwest::Client::builder().timeout(std::time::Duration::from_secs(60)).build()?
                    .get(format!("https://fonts.gstatic.com/s/{path}")).send().await?.error_for_status()?;
                read_capped(resp, 32 << 20).await
            }.await;
            match fetched {
                Ok(b) => {
                    // written aside and moved in: a half-written font is never served
                    if let Some(dir) = file.parent() { let _ = tokio::fs::create_dir_all(dir).await; }
                    let tmp = file.with_extension(format!("part{:08x}", rand::random::<u32>()));
                    if tokio::fs::write(&tmp, &b).await.is_ok() { let _ = tokio::fs::rename(&tmp, &file).await; }
                    b
                }
                Err(e) => return (StatusCode::BAD_GATEWAY, format!("{e:#}")).into_response(),
            }
        }
    };
    let kind = if path.ends_with(".woff2") { "font/woff2" } else if path.ends_with(".ttf") { "font/ttf" } else { "application/octet-stream" };
    ([(header::CONTENT_TYPE, kind), (header::CACHE_CONTROL, "public, max-age=31536000, immutable")], bytes).into_response()
}

/// An HTTPS request for the page (external AI services cannot be called from another origin).
async fn proxy(Json(r): Json<ProxyRequest>) -> Response {
    let res: anyhow::Result<Value> = async {
        let url = reqwest::Url::parse(&r.url)?;
        anyhow::ensure!(matches!(url.scheme(), "https" | "http"), "only web addresses");
        let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(600)).build()?;
        let mut req = client.request(r.method.parse()?, url);
        for (k, v) in &r.headers {
            if !matches!(k.to_ascii_lowercase().as_str(), "host" | "content-length" | "connection") { req = req.header(k, v); }
        }
        if let Some(b) = &r.body { req = req.body(base64::engine::general_purpose::STANDARD.decode(b)?); }
        let resp = req.send().await?;
        let status = resp.status().as_u16();
        let headers: Vec<(String, String)> = resp.headers().iter().filter_map(|(k, v)| Some((k.to_string(), v.to_str().ok()?.to_string()))).collect();
        let body = read_capped(resp, 128 << 20).await?;
        Ok(json!({ "status": status, "headers": headers, "body": base64::engine::general_purpose::STANDARD.encode(&body) }))
    }.await;
    match res {
        Ok(v) => Json(v).into_response(),
        Err(e) => (StatusCode::BAD_GATEWAY, format!("{e:#}")).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(data: &Path) -> Config {
        Config { auth: auth::Auth::new(data), secrets: secrets::Secrets::new(data.join("app")), data: data.to_path_buf(), web: PathBuf::new(), public: false, lease: std::sync::Mutex::new(None), desktop: Some("test-desktop-token".into()) }
    }

    fn data_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tl-paths-{:016x}", rand::random::<u64>()));
        for d in ["library", "models", "cache", "uploads", "exports", "app"] { std::fs::create_dir_all(dir.join(d)).unwrap(); }
        std::fs::canonicalize(dir).unwrap()
    }

    #[test]
    fn calls_of_the_core_stay_inside_the_data_folder() {
        let dir = data_dir();
        let cfg = config(&dir);
        let p = |s: &str| dir.join(s).to_string_lossy().into_owned();
        assert!(paths_allowed(&cfg, "tl_export_backup", &[json!(p("exports/new/a.tlpack"))]));
        assert!(paths_allowed(&cfg, "tl_import_pack", &[json!(p("uploads/1/a.tlpack")), json!("")]));
        assert!(paths_allowed(&cfg, "tl_stats", &[]));
        assert!(!paths_allowed(&cfg, "tl_export_backup", &[json!("/etc/x.tlpack")]));
        assert!(!paths_allowed(&cfg, "tl_export_backup", &[json!(p("exports/../../x"))]));
        assert!(!paths_allowed(&cfg, "tl_db_snapshot", &[json!(p("app/auth.json"))]));
        assert!(!paths_allowed(&cfg, "tl_update_download", &[json!("{}"), json!("/root/.ssh")]));
        assert!(!paths_allowed(&cfg, "tl_import_loose_dir", &[json!(json!({ "dir": p("app") }).to_string())]));
        assert!(!paths_allowed(&cfg, "tl_export_media", &[json!(json!({ "media_ids": [], "out": "/tmp/x" }).to_string())]));
        std::fs::write(dir.join("exports/r.json"), json!({ "source": p("app") }).to_string()).unwrap();
        assert!(!paths_allowed(&cfg, "tl_import_export_issues", &[json!(p("exports/r.json")), json!(p("exports/o.zip"))]));
        // refused writes make nothing, and the top folders cannot be deleted
        let outside = std::env::temp_dir().join(format!("tl-outside-{:08x}", rand::random::<u32>()));
        assert!(library_file(&cfg, &outside.join("a/b"), "downloads.queue.json").is_none());
        assert!(!outside.exists());
        assert!(!paths_allowed(&cfg, "tl_export_backup", &[json!(p("library/library.sqlite"))]));
        assert!(!paths_allowed(&cfg, "tl_thumbnail", &[json!("media"), json!(256), json!(p("library"))]));
        assert!(!paths_allowed(&cfg, "tl_share_stage", &[json!(p("library"))]));
        assert!(!paths_allowed(&cfg, "tl_import_loose_dir", &[json!(json!({ "dir": p("library/blobs"), "consume": true }).to_string())]));
        assert!(paths_allowed(&cfg, "tl_import_loose_dir", &[json!(json!({ "dir": p("uploads/share"), "consume": true }).to_string())]));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn routes(dir: &Path) -> Router {
        let cfg = Arc::new(config(dir));
        file_routes().layer(middleware::from_fn_with_state(cfg.clone(), gate::gate)).with_state(cfg)
    }

    async fn request(app: &Router, method: &str, uri: &str, body: impl Into<Body>, signed_in: bool) -> Response {
        let mut request = Request::builder().method(method).uri(uri)
            .header(header::CONTENT_TYPE, "application/json")
            .extension(axum::extract::ConnectInfo(std::net::SocketAddr::from(([127, 0, 0, 1], 1000))));
        if signed_in { request = request.header(header::COOKIE, "tl_desktop=test-desktop-token"); }
        app.clone().oneshot(request.body(body.into()).unwrap()).await.unwrap()
    }

    #[tokio::test]
    async fn file_routes_protect_library_data_and_keep_staged_operations_working() {
        let dir = data_dir();
        let app = routes(&dir);
        let path = |rel| dir.join(rel).to_string_lossy().into_owned();
        let uri = |rel| format!("/f{}", path(rel));
        let mv = |from, to| json!({ "from": path(from), "to": path(to) }).to_string();
        for (rel, bytes) in [
            ("library/library.sqlite", "database"),
            ("library/blobs/example.jpg", "media"),
            ("library/logs/app.log", "log"),
            ("app/secrets.key", "key"),
            ("app/secrets.json", "{}"),
            ("uploads/one/a.jpg", "a"),
            ("uploads/two/b.jpg", "b"),
            ("exports/old.tlpack", "backup"),
        ] {
            let file = dir.join(rel);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, bytes).unwrap();
        }
        assert_eq!(request(&app, "PUT", &uri("library/library.sqlite"), "overwritten", true).await.status(), StatusCode::FORBIDDEN);
        assert_eq!(request(&app, "DELETE", &uri("library/blobs"), Body::empty(), true).await.status(), StatusCode::FORBIDDEN);
        assert_eq!(request(&app, "POST", "/api/move", mv("uploads/one/a.jpg", "library/library.sqlite"), true).await.status(), StatusCode::FORBIDDEN);
        assert_eq!(request(&app, "POST", "/api/move", mv("library/blobs/example.jpg", "uploads/two/out.jpg"), true).await.status(), StatusCode::FORBIDDEN);
        assert_eq!(request(&app, "GET", &uri("app/secrets.key"), Body::empty(), true).await.status(), StatusCode::NOT_FOUND);
        assert_eq!(request(&app, "GET", &uri("app/secrets.json"), Body::empty(), true).await.status(), StatusCode::NOT_FOUND);
        assert_eq!(request(&app, "DELETE", &uri("app/secrets.json"), Body::empty(), true).await.status(), StatusCode::FORBIDDEN);
        assert_eq!(std::fs::read_to_string(dir.join("library/library.sqlite")).unwrap(), "database");
        let response = request(&app, "GET", &uri("library/blobs/example.jpg"), Body::empty(), true).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(axum::body::to_bytes(response.into_body(), 100).await.unwrap(), "media");

        assert_eq!(request(&app, "POST", "/api/move", mv("uploads/one/a.jpg", "uploads/two/b.jpg"), true).await.status(), StatusCode::CONFLICT);
        assert_eq!(std::fs::read_to_string(dir.join("uploads/two/b.jpg")).unwrap(), "b");
        assert_eq!(request(&app, "POST", "/api/move", mv("uploads/one/a.jpg", "uploads/two/a.jpg"), true).await.status(), StatusCode::NO_CONTENT);
        assert!(!dir.join("uploads/one/a.jpg").exists());
        assert_eq!(std::fs::read_to_string(dir.join("uploads/two/a.jpg")).unwrap(), "a");
        assert_eq!(request(&app, "PUT", &uri("library/downloads.queue.json"), "{}", true).await.status(), StatusCode::NO_CONTENT);
        assert_eq!(request(&app, "DELETE", &uri("library/logs/app.log"), Body::empty(), true).await.status(), StatusCode::NO_CONTENT);
        assert_eq!(request(&app, "DELETE", &uri("exports"), Body::empty(), true).await.status(), StatusCode::NO_CONTENT);
        assert!(dir.join("exports").is_dir());
        assert!(!dir.join("exports/old.tlpack").exists());
        let uploaded = request(&app, "POST", "/api/upload?name=upload.jpg", "upload", true).await;
        assert_eq!(uploaded.status(), StatusCode::OK);
        let body = axum::body::to_bytes(uploaded.into_body(), 4096).await.unwrap();
        let reply: Value = serde_json::from_slice(&body).unwrap();
        let uploaded_path = Path::new(reply["path"].as_str().unwrap());
        assert!(uploaded_path.starts_with(dir.join("uploads")));
        assert_eq!(std::fs::read_to_string(uploaded_path).unwrap(), "upload");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn deleting_a_report_only_deletes_server_owned_uploads() {
        let dir = data_dir();
        let library = dir.join("library");
        assert!(tl_core::ffi::tl_open(c(&library).as_ptr()));
        let reports = library.join("logs/import-reports");
        std::fs::create_dir_all(&reports).unwrap();
        let archive = dir.join("exports/keep.tlpack");
        let upload = dir.join("uploads/remove.zip");
        for path in [&archive, &upload] { std::fs::write(path, "contents").unwrap(); }
        let mut paths = vec![];
        for (n, source) in [archive.as_path(), upload.as_path()].into_iter().enumerate() {
            let path = reports.join(format!("import-{n}.json"));
            let mut report = tl_core::import::ImportReport::default();
            report.source = source.to_string_lossy().into_owned();
            std::fs::write(&path, serde_json::to_vec(&report).unwrap()).unwrap();
            paths.push(path);
        }
        let payload = json!([json!({ "reports": paths, "owned": [dir] }).to_string()]).to_string();
        let result = request(&routes(&dir), "POST", "/api/call/tl_delete_import_reports", payload, true).await;
        assert_eq!(result.status(), StatusCode::OK);
        assert!(paths.iter().all(|path| !path.exists()));
        assert!(archive.is_file());
        assert!(!upload.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn scoped_paths_refuse_symlinks_even_inside_the_data_folder() {
        let dir = data_dir();
        let cfg = config(&dir);
        let link = dir.join("exports/link");
        std::os::unix::fs::symlink(dir.join("library"), &link).unwrap();
        assert!(data_subpath(&cfg, "exports", &link.join("library.sqlite"), false).is_none());
        assert!(data_subpath(&cfg, "exports", &dir.join("exports/../library"), false).is_none());
        std::fs::remove_dir(dir.join("uploads")).unwrap();
        std::os::unix::fs::symlink(dir.join("library"), dir.join("uploads")).unwrap();
        assert!(data_subpath(&cfg, "uploads", &dir.join("uploads"), true).is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn concurrent_first_secret_writes_survive_reopen() {
        let dir = data_dir();
        let app = routes(&dir);
        let account = r#"{"sync.key":"account"}"#;
        assert_eq!(request(&app, "POST", "/api/secrets", account, false).await.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(request(&app, "GET", "/api/secrets/sync.key", Body::empty(), false).await.status(), StatusCode::UNAUTHORIZED);
        let (sync, cookies) = tokio::join!(
            request(&app, "POST", "/api/secrets", account, true),
            request(&app, "POST", "/api/secrets", r#"{"auth_token":"token","ct0":"cookie"}"#, true)
        );
        assert_eq!(sync.status(), StatusCode::NO_CONTENT);
        assert_eq!(cookies.status(), StatusCode::NO_CONTENT);
        drop(app);
        let reopened = routes(&dir);
        for (name, expected) in [("sync.key", "account"), ("auth_token", "token"), ("ct0", "cookie")] {
            let response = request(&reopened, "GET", &format!("/api/secrets/{name}"), Body::empty(), true).await;
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
            let body = axum::body::to_bytes(response.into_body(), 100).await.unwrap();
            assert_eq!(serde_json::from_slice::<String>(&body).unwrap(), expected);
        }
        assert_eq!(request(&reopened, "POST", "/api/secrets", r#"{"auth_token":null}"#, true).await.status(), StatusCode::NO_CONTENT);
        assert_eq!(config(&dir).secrets.read(["auth_token", "sync.key"]).unwrap(), [None, Some("account".into())]);
        assert_eq!(request(&reopened, "DELETE", "/api/secrets", Body::empty(), true).await.status(), StatusCode::NO_CONTENT);
        assert_eq!(config(&dir).secrets.read(["sync.key", "ct0"]).unwrap(), [None, None]);
        std::fs::remove_dir_all(dir).unwrap();
    }
}

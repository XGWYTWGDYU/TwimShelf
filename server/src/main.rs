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

    let api = Router::new()
        .route("/api/info", get(info))
        .route("/api/call/{name}", post(call))
        .route("/api/upload", post(upload).layer(DefaultBodyLimit::disable()))
        .route("/api/proxy", post(proxy).layer(DefaultBodyLimit::max(64 << 20)))
        .route("/f/{*path}", get(file).put(put_file).delete(delete_file))
        .route("/api/move", post(move_file))
        .route("/api/poster", get(poster))
        .route("/api/scaled", get(scaled))
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

/// config.yaml's version (the image build passes it), or the crate's for a plain `cargo build`.
const VERSION: &str = match option_env!("TL_VERSION") { Some(v) if !v.is_empty() => v, _ => env!("CARGO_PKG_VERSION") };

/// The name the account's other devices show for this server (`TL_DEVICE_NAME`).
pub fn device_name() -> String { env("TL_DEVICE_NAME", "TwimShelf Linux Server") }

/// The server is a device of its own: once the web app has joined it to a sync account (the key
/// sealed in `app/secrets.json`, as the desktop apps keep it), it syncs from start-up on, with
/// no browser open.
fn start_sync(cfg: &Config) {
    let Some(account) = secret(cfg, "sync.key") else { return };
    let name = device_name();
    let service = env("TL_SYNC_SERVICE", "_twlib._tcp");
    let r = wire::take(tl_core::ffi::tl_sync_start(c(Path::new(&account)).as_ptr(), c(Path::new(&name)).as_ptr()));
    let d = wire::take(tl_core::ffi::tl_discovery_start(c(Path::new(&service)).as_ptr(), c(Path::new(&name)).as_ptr(), c(Path::new("linux")).as_ptr()));
    eprintln!("sync: started as \"{name}\" ({r}, {d})");
}

/// A secret the web app keeps (sealed in `app/secrets.json` with `app/secrets.key`, as the
/// desktop apps keep theirs).
fn secret(cfg: &Config, name: &str) -> Option<String> {
    let app = cfg.dir("app");
    let key = std::fs::read_to_string(app.join("secrets.key")).ok()?;
    let secrets = std::fs::read_to_string(app.join("secrets.json")).ok()?;
    let blob = serde_json::from_str::<Value>(&secrets).ok()?.get(name)?.as_str()?.to_string();
    let opened = wire::take(tl_core::ffi::tl_secret_open(c(Path::new(key.trim())).as_ptr(), c(Path::new(&blob)).as_ptr()));
    let v = opened.as_str().and_then(|s| serde_json::from_str::<Value>(s).ok()).and_then(|v| v.get("ok").and_then(|k| k.as_str()).map(str::to_string));
    if v.is_none() { eprintln!("secrets: {name} cannot be read"); }
    v
}

/// The X session cookies the web app stored: downloads (from the browser extension too) can use
/// them with no browser open.
fn apply_cookies(cfg: &Config) {
    if let (Some(a), Some(t)) = (secret(cfg, "auth_token"), secret(cfg, "ct0")) {
        tl_core::ffi::tl_set_cookies(c(Path::new(&a)).as_ptr(), c(Path::new(&t)).as_ptr());
    }
}

async fn info(State(cfg): State<Shared>) -> Json<Value> {
    let d = |n: &str| cfg.dir(n).to_string_lossy().into_owned();
    Json(json!({
        "data": cfg.data.to_string_lossy(), "library": d("library"), "models": d("models"),
        "cache": d("cache"), "uploads": d("uploads"), "exports": d("exports"),
        "version": VERSION, "functions": dispatch::NAMES, "device_name": device_name(), "sync_service": env("TL_SYNC_SERVICE", "_twlib._tcp"),
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
    let r = tokio::task::spawn_blocking(move || {
        let mut args = args;
        // the data folders are the server's: a client cannot point the core elsewhere
        if name == "tl_set_models_dir" { args = vec![Value::String(models)]; }
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
    if !path.is_absolute() || path.components().any(|c| matches!(c, std::path::Component::ParentDir)) { return None; }
    let mut rest = Vec::new();
    let mut at = path;
    loop {
        if let Ok(real) = std::fs::canonicalize(at) { return Some(rest.iter().rev().fold(real, |p, part| p.join(part))); }
        rest.push(at.file_name()?);
        at = at.parent()?;
    }
}

/// A path a call of the core may use: inside the server's folders, and never the sign-in and
/// secret files in `app` (only the web app's own `/f` requests reach those).
fn core_path_allowed(cfg: &Config, path: &str) -> bool {
    let Some(real) = resolved(Path::new(path)) else { return false };
    let app = std::fs::canonicalize(cfg.dir("app")).unwrap_or_else(|_| cfg.dir("app"));
    roots(cfg).iter().any(|r| real.starts_with(r)) && !real.starts_with(app)
}

/// Whether every file path among a call's arguments stays inside the server's folders.
fn paths_allowed(cfg: &Config, name: &str, args: &[Value]) -> bool {
    let text = |i: usize| args.get(i).and_then(Value::as_str).unwrap_or("");
    let json = |i: usize| serde_json::from_str::<Value>(text(i)).unwrap_or(Value::Null);
    let at = |list: &[usize]| list.iter().all(|&i| core_path_allowed(cfg, text(i)));
    let optional = |v: &Value| v.as_str().filter(|p| !p.is_empty()).is_none_or(|p| core_path_allowed(cfg, p));
    let every = |v: &Value| v.as_array().is_none_or(|a| a.iter().all(|p| p.as_str().is_some_and(|p| core_path_allowed(cfg, p))));
    match name {
        "tl_import_legacy_dir" | "tl_import_legacy_zip" | "tl_import_loose_zip" | "tl_import_pack" | "tl_parse_bookmarks"
        | "tl_share_stage" | "tl_db_snapshot" | "tl_model_import" | "tl_import_report" | "tl_export_backup" | "tl_export_diagnostics" => at(&[0]),
        "tl_update_download" | "tl_model_export_zip" => at(&[1]),
        "tl_share_pack" => at(&[0, 1]),
        "tl_thumbnail" | "tl_thumbnails_warm" => at(&[2]),
        "tl_display_image" => at(&[0, 2]),
        // a report names the folder its problem files are copied from
        "tl_import_export_issues" => at(&[0, 1]) && std::fs::read(text(0)).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .is_none_or(|r| r["source"].as_str().is_none_or(|s| core_path_allowed(cfg, s))),
        "tl_export_media" => core_path_allowed(cfg, json(0)["out"].as_str().unwrap_or("")),
        "tl_import_loose_dir" => { let a = json(0); core_path_allowed(cfg, a["dir"].as_str().unwrap_or("")) && optional(&a["keep_to"]) }
        "tl_storage_usage" => json(0).as_array().is_none_or(|a| a.iter().all(|e| optional(&e["path"]))),
        "tl_delete_import_reports" => { let a = json(0); every(&a["reports"]) && every(&a["owned"]) }
        _ => true,
    }
}

/// `path` resolved inside the server's folders, or None (outside them, or missing).
fn inside_data(cfg: &Config, path: &str) -> Option<PathBuf> {
    let p = PathBuf::from(if path.starts_with('/') { path.to_string() } else { format!("/{path}") });
    let real = std::fs::canonicalize(&p).ok()?;
    (roots(cfg).iter().any(|r| real.starts_with(r)) && !private(cfg, &real)).then_some(real)
}

/// The folders everything else lives in: never deleted or moved as a whole through `/f`.
fn is_top_folder(cfg: &Config, p: &Path) -> bool {
    roots(cfg).iter().any(|r| r == p) || std::fs::canonicalize(cfg.dir("app")).is_ok_and(|a| a == p)
}

/// The sign-in files are the server's alone: never read, written or moved through `/f`.
fn private(cfg: &Config, p: &Path) -> bool {
    let app = std::fs::canonicalize(cfg.dir("app")).unwrap_or_else(|_| cfg.dir("app"));
    [auth::file(&cfg.data), auth::initial_file(&cfg.data)].iter().any(|f| f.file_name() == p.file_name() && p.parent() == Some(app.as_path()))
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

/// `path` for writing: inside the server's folders (its folder made when missing), never a link out.
fn writable(cfg: &Config, path: &str) -> Option<PathBuf> {
    let p = PathBuf::from(if path.starts_with('/') { path.to_string() } else { format!("/{path}") });
    let parent = p.parent()?;
    let roots = roots(cfg);
    // checked before anything is made: a refused request leaves nothing behind
    if !roots.iter().any(|r| resolved(parent).is_some_and(|real| real.starts_with(r))) { return None; }
    std::fs::create_dir_all(parent).ok()?;
    let real_parent = std::fs::canonicalize(parent).ok()?;
    if !roots.iter().any(|r| real_parent.starts_with(r)) { return None; }
    if p.is_symlink() { return None; }
    let target = real_parent.join(p.file_name()?);
    if private(cfg, &target) { return None; }
    Some(target)
}

/// The web app's own small files (a download queue, settings it keeps beside the library).
async fn put_file(State(cfg): State<Shared>, UrlPath(path): UrlPath<String>, body: axum::body::Bytes) -> Response {
    let Some(p) = writable(&cfg, &path) else { return StatusCode::FORBIDDEN.into_response() };
    let tmp = p.with_extension(format!("tmp{:08x}", rand::random::<u32>()));
    let r = async { tokio::fs::write(&tmp, &body).await?; tokio::fs::rename(&tmp, &p).await }.await;
    match r { Ok(()) => StatusCode::NO_CONTENT.into_response(), Err(e) => { let _ = tokio::fs::remove_file(&tmp).await; (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response() } }
}

async fn delete_file(State(cfg): State<Shared>, UrlPath(path): UrlPath<String>) -> Response {
    let Some(p) = inside_data(&cfg, &path) else { return StatusCode::NO_CONTENT.into_response() };
    if is_top_folder(&cfg, &p) { return StatusCode::FORBIDDEN.into_response(); }
    let r = if p.is_dir() { tokio::fs::remove_dir_all(&p).await } else { tokio::fs::remove_file(&p).await };
    match r { Ok(()) => StatusCode::NO_CONTENT.into_response(), Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response() }
}

#[derive(Deserialize)]
struct MoveRequest { from: String, to: String }

async fn move_file(State(cfg): State<Shared>, Json(m): Json<MoveRequest>) -> Response {
    let (Some(from), Some(to)) = (inside_data(&cfg, &m.from), writable(&cfg, &m.to)) else { return StatusCode::FORBIDDEN.into_response() };
    if is_top_folder(&cfg, &from) { return StatusCode::FORBIDDEN.into_response(); }
    match tokio::fs::rename(&from, &to).await { Ok(()) => StatusCode::NO_CONTENT.into_response(), Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response() }
}

#[derive(Deserialize)]
struct ScaledQuery { path: String, side: u32 }

/// Pictures scaled at the same time, and video frames taken at the same time.
static PICTURES: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(6);
static POSTERS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
/// The largest picture decoded here (the core's own limit for HEIF).
const MAX_PIXELS: u64 = 200_000_000;

/// A picture of the data folder upright (its EXIF orientation applied) and no longer than
/// `side` on its long edge, as a JPEG: what AI tagging sends, made here so the page decodes a
/// small picture rather than the original (the apps do this in a background isolate).
async fn scaled(State(cfg): State<Shared>, Query(q): Query<ScaledQuery>) -> Response {
    let Some(src) = inside_data(&cfg, &q.path) else { return StatusCode::NOT_FOUND.into_response() };
    let side = q.side.clamp(32, 4096);
    // a page of cards asks for many at once: each one decodes a whole picture
    let Ok(_turn) = PICTURES.acquire().await else { return StatusCode::SERVICE_UNAVAILABLE.into_response() };
    let made = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<u8>> {
        use image::ImageDecoder;
        let mut decoder = image::ImageReader::open(&src)?.with_guessed_format()?.into_decoder()?;
        let (w, h) = decoder.dimensions();
        anyhow::ensure!(u64::from(w) * u64::from(h) <= MAX_PIXELS, "picture too large");
        let orientation = decoder.orientation().unwrap_or(image::metadata::Orientation::NoTransforms);
        let mut picture = image::DynamicImage::from_decoder(decoder)?;
        picture.apply_orientation(orientation);
        if picture.width().max(picture.height()) > side { picture = picture.thumbnail(side, side); }
        let mut out = std::io::Cursor::new(Vec::new());
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 95).encode_image(&picture.to_rgb8())?;
        Ok(out.into_inner())
    }).await;
    match made {
        Ok(Ok(bytes)) => ([(header::CONTENT_TYPE, "image/jpeg")], bytes).into_response(),
        Ok(Err(e)) => (StatusCode::UNPROCESSABLE_ENTITY, format!("{e:#}")).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct PosterQuery { path: String, side: u32, #[serde(default)] whole: u8 }

/// A video's frame at half a second as a JPEG (the apps take it with the system's decoder; a
/// browser cannot hand frames back): square `side`, or the whole frame with `side` as its long
/// edge. Made once with ffmpeg, cached under `cache/posters`.
async fn poster(State(cfg): State<Shared>, Query(q): Query<PosterQuery>) -> Response {
    let Some(src) = inside_data(&cfg, &q.path) else { return StatusCode::NOT_FOUND.into_response() };
    let side = q.side.clamp(32, 4096);
    // named after the whole path: posts keep their files under the same names (video.mp4)
    let name = { use sha2::Digest; hex::encode(sha2::Sha256::digest(src.to_string_lossy().as_bytes())) };
    let kind = if q.whole == 1 { format!("whole{side}") } else { side.to_string() };
    let out = cfg.dir("cache").join("posters").join(kind).join(format!("{name}.jpg"));
    let turn = if out.exists() { None } else { POSTERS.acquire().await.ok() };
    // (made by another request while this one waited)
    if turn.is_some() && !out.exists() {
        let _ = tokio::fs::create_dir_all(out.parent().unwrap()).await;
        let filter = if q.whole == 1 {
            format!("scale='if(gt(iw,ih),{side},-2)':'if(gt(iw,ih),-2,{side})'")
        } else {
            format!("scale={side}:{side}:force_original_aspect_ratio=increase,crop={side}:{side}")
        };
        let tmp = out.with_extension(format!("{:08x}.jpg", rand::random::<u32>()));
        let made = async {
            for at in ["0.5", "0"] {
                let status = tokio::process::Command::new("ffmpeg")
                    .args(["-nostdin", "-loglevel", "error", "-y", "-ss", at, "-i"]).arg(&src)
                    .args(["-frames:v", "1", "-vf", &filter, "-q:v", "3"]).arg(&tmp)
                    .status().await;
                if matches!(status, Ok(s) if s.success()) && tmp.metadata().map_or(false, |m| m.len() > 0) { return true; }
            }
            false
        }.await;
        if !made || tokio::fs::rename(&tmp, &out).await.is_err() {
            let _ = tokio::fs::remove_file(&tmp).await;
            return StatusCode::UNPROCESSABLE_ENTITY.into_response();
        }
    }
    Json(json!({ "path": out.to_string_lossy() })).into_response()
}

#[derive(Deserialize)]
struct UploadQuery { name: String }

/// A file from the browser, streamed to `uploads/<random>/<name>`; answers its path on the server.
async fn upload(State(cfg): State<Shared>, Query(q): Query<UploadQuery>, body: Body) -> Response {
    let name: String = Path::new(&q.name).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if name.is_empty() || name.starts_with('.') { return (StatusCode::BAD_REQUEST, "file name").into_response(); }
    let dir = cfg.dir("uploads").join(format!("{:016x}", rand::random::<u64>()));
    // a browser that goes away mid-upload ends this request here: nothing half-written stays
    struct Unfinished(Option<PathBuf>);
    impl Drop for Unfinished { fn drop(&mut self) { if let Some(d) = self.0.take() { let _ = std::fs::remove_dir_all(d); } } }
    let mut unfinished = Unfinished(Some(dir.clone()));
    let r: anyhow::Result<PathBuf> = async {
        tokio::fs::create_dir_all(&dir).await?;
        let path = dir.join(&name);
        let mut f = tokio::fs::File::create(&path).await?;
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
        Config { auth: auth::Auth::new(data), data: data.to_path_buf(), web: PathBuf::new(), public: false, lease: std::sync::Mutex::new(None), desktop: None }
    }

    #[test]
    fn calls_of_the_core_stay_inside_the_data_folder() {
        let dir = std::env::temp_dir().join(format!("tl-paths-{:08x}", rand::random::<u32>()));
        for d in ["library", "models", "cache", "uploads", "exports", "app"] { std::fs::create_dir_all(dir.join(d)).unwrap(); }
        let dir = std::fs::canonicalize(&dir).unwrap();
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
        assert!(writable(&cfg, &outside.join("a/b").to_string_lossy()).is_none());
        assert!(!outside.exists());
        assert!(is_top_folder(&cfg, &dir) && is_top_folder(&cfg, &dir.join("library")) && !is_top_folder(&cfg, &dir.join("cache")));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

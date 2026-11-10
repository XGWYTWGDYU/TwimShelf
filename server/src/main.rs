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
}

impl Config {
    fn dir(&self, name: &str) -> PathBuf { self.data.join(name) }
}

pub type Shared = Arc<Config>;

fn env(name: &str, default: &str) -> String { std::env::var(name).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| default.into()) }

fn c(s: &Path) -> CString { CString::new(s.to_string_lossy().as_bytes()).unwrap_or_default() }

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let data = PathBuf::from(env("TL_DATA", "/data"));
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
    });
    let port: u16 = env("TL_PORT", "2778").parse()?;
    // the container's health check: is the server answering?
    if std::env::args().any(|a| a == "--health") {
        let ok = std::net::TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), std::time::Duration::from_secs(3)).is_ok();
        std::process::exit(if ok { 0 } else { 1 });
    }
    for d in ["library", "models", "cache", "uploads", "exports", "app"] { std::fs::create_dir_all(config.dir(d))?; }
    config.auth.prepare(&config.data)?;
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
        .route("/login", get(gate::login_page).post(gate::login))
        .route("/logout", get(gate::logout))
        .route("/ext/{*rest}", axum::routing::any(gate::ext))
        .layer(DefaultBodyLimit::max(64 << 20));
    let web = ServeDir::new(&config.web).fallback(ServeFile::new(config.web.join("index.html")));
    let app = api
        .fallback_service(web)
        .layer(middleware::from_fn_with_state(config.clone(), gate::gate))
        .layer(tower_http::compression::CompressionLayer::new())
        .with_state(config.clone());

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    eprintln!("TwimShelf {VERSION} on port {port}, data in {}", config.data.display());
    axum::serve(listener, app.into_make_service_with_connect_info::<std::net::SocketAddr>()).with_graceful_shutdown(async { let _ = tokio::signal::ctrl_c().await; }).await?;
    Ok(())
}

/// The name the account's other devices show for this server (`TL_DEVICE_NAME`).
/// config.yaml's version (the image build passes it), or the crate's for a plain `cargo build`.
const VERSION: &str = match option_env!("TL_VERSION") { Some(v) if !v.is_empty() => v, _ => env!("CARGO_PKG_VERSION") };

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
    let library = cfg.dir("library").to_string_lossy().into_owned();
    let models = cfg.dir("models").to_string_lossy().into_owned();
    let r = tokio::task::spawn_blocking(move || {
        let mut args = args;
        // the data folders are the server's: a client cannot point the core elsewhere
        match name.as_str() {
            "tl_open" => args = vec![Value::String(library)],
            "tl_set_models_dir" => args = vec![Value::String(models)],
            _ => {}
        }
        dispatch::call(&name, &wire::Args(args))
    }).await;
    match r {
        Ok(Ok(v)) => Json(json!({ "r": v })).into_response(),
        Ok(Err(e)) => (StatusCode::BAD_REQUEST, format!("{e:#}")).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("{e}")).into_response(),
    }
}

/// `path` resolved inside the data folder, or None (outside it, or missing).
fn inside_data(cfg: &Config, path: &str) -> Option<PathBuf> {
    let p = PathBuf::from(if path.starts_with('/') { path.to_string() } else { format!("/{path}") });
    let real = std::fs::canonicalize(&p).ok()?;
    let root = std::fs::canonicalize(&cfg.data).ok()?;
    (real.starts_with(&root) && !private(cfg, &real)).then_some(real)
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
    // media files are named by their hash: they never change under the same name
    if p.starts_with(cfg.dir("library").join("blobs")) || p.starts_with(cfg.dir("cache")) {
        res.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("private, max-age=31536000, immutable"));
    }
    res
}

/// `path` for writing: inside the data folder (its folder made when missing), never a link out.
fn writable(cfg: &Config, path: &str) -> Option<PathBuf> {
    let p = PathBuf::from(if path.starts_with('/') { path.to_string() } else { format!("/{path}") });
    if p.components().any(|c| matches!(c, std::path::Component::ParentDir)) { return None; }
    let parent = p.parent()?;
    std::fs::create_dir_all(parent).ok()?;
    let real_parent = std::fs::canonicalize(parent).ok()?;
    let root = std::fs::canonicalize(&cfg.data).ok()?;
    if !real_parent.starts_with(&root) { return None; }
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
    let r = if p.is_dir() { tokio::fs::remove_dir_all(&p).await } else { tokio::fs::remove_file(&p).await };
    match r { Ok(()) => StatusCode::NO_CONTENT.into_response(), Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response() }
}

#[derive(Deserialize)]
struct MoveRequest { from: String, to: String }

async fn move_file(State(cfg): State<Shared>, Json(m): Json<MoveRequest>) -> Response {
    let (Some(from), Some(to)) = (inside_data(&cfg, &m.from), writable(&cfg, &m.to)) else { return StatusCode::FORBIDDEN.into_response() };
    match tokio::fs::rename(&from, &to).await { Ok(()) => StatusCode::NO_CONTENT.into_response(), Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response() }
}

#[derive(Deserialize)]
struct ScaledQuery { path: String, side: u32 }

/// A picture of the data folder upright (its EXIF orientation applied) and no longer than
/// `side` on its long edge, as a JPEG: what AI tagging sends, made here so the page decodes a
/// small picture rather than the original (the apps do this in a background isolate).
async fn scaled(State(cfg): State<Shared>, Query(q): Query<ScaledQuery>) -> Response {
    let Some(src) = inside_data(&cfg, &q.path) else { return StatusCode::NOT_FOUND.into_response() };
    let side = q.side.clamp(32, 4096);
    let made = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<u8>> {
        use image::ImageDecoder;
        let mut decoder = image::ImageReader::open(&src)?.with_guessed_format()?.into_decoder()?;
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
    let stem = src.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let kind = if q.whole == 1 { format!("whole{side}") } else { side.to_string() };
    let out = cfg.dir("cache").join("posters").join(kind).join(format!("{stem}.jpg"));
    if !out.exists() {
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
        Ok(p) => Json(json!({ "path": p.to_string_lossy() })).into_response(),
        Err(e) => { let _ = tokio::fs::remove_dir_all(&dir).await; (StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")).into_response() }
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

/// An HTTPS request for the page (external AI services cannot be called from another origin).
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
                Ok(resp.bytes().await?.to_vec())
            }.await;
            match fetched {
                Ok(b) => {
                    // written aside and moved in: a half-written font is never served
                    if let Some(dir) = file.parent() { let _ = tokio::fs::create_dir_all(dir).await; }
                    let tmp = file.with_extension(format!("part{}", std::process::id()));
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
        let body = resp.bytes().await?;
        Ok(json!({ "status": status, "headers": headers, "body": base64::engine::general_purpose::STANDARD.encode(&body) }))
    }.await;
    match res {
        Ok(v) => Json(v).into_response(),
        Err(e) => (StatusCode::BAD_GATEWAY, format!("{e:#}")).into_response(),
    }
}


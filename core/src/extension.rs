//! The browser extension's way in (`extension/` at the top of the repository): a small HTTP API
//! on this device that takes post links from X's pages into the download queue and says how each
//! one is doing.
//!
//! * **Binding.** The app shows a six-digit code, and a binding text that also carries this
//!   device's addresses. The extension sends the code once and gets a token, which both sides
//!   keep. A code lasts ten minutes and only one at a time exists; five wrong guesses end it.
//! * **Where.** The desktop apps listen on a port of their own ([`serve`]: 27800, or the next free
//!   one up to 27809), for this computer and the LAN only. The server answers the same requests on
//!   its own port ([`handle`]).
//! * **Web pages.** They cannot use it: a request that carries a web page's origin is refused, and
//!   the desktop listener only answers when the request's host is an IP address, `localhost` or a
//!   `.local` name (a page cannot point a name of its own at this computer: DNS rebinding).
//! * **Tasks.** A link goes into the core's own download queue (it survives a restart). A task is
//!   its link, and its state is the queue's: queued, downloading, done, failed (with why).
//!
//! Requests (JSON in, JSON out; all but `hello` and `pair` need `Authorization: Bearer <token>`):
//! `GET /ext/hello`, `POST /ext/pair {code, name}`, `POST /ext/download {url}`,
//! `POST /ext/status {urls}`, `POST /ext/unbind`.
use crate::download::{self, DownloadRequest, Route};
use crate::library::Library;
use anyhow::bail;
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const FIRST_PORT: u16 = 27800;
const PORTS: u16 = 10;
const CODE_LIFE: Duration = Duration::from_secs(600);
const CODE_TRIES: u32 = 5;
/// The version of these requests; the extension says so when the app is too old or too new.
pub const API: u32 = 1;

/// What the app tells the core: who this device is and how its downloads run (the user's own
/// download settings, so a link from the browser downloads as one pasted in the app would).
#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct Options {
    #[serde(default)] pub name: String,
    /// "macos", "windows", "linux", "server"
    #[serde(default)] pub platform: String,
    /// "native", "flutter" or "server": two apps on one computer share its name, the extension
    /// tells them apart by this.
    #[serde(default)] pub flavor: String,
    #[serde(default)] pub route: Route,
    #[serde(default)] pub concurrency: usize,
    #[serde(default)] pub interval_ms: u64,
    #[serde(default)] pub folder: Option<String>,
    /// Listen on a port of its own (the desktop apps); the server routes requests itself.
    #[serde(default)] pub listen: bool,
}

struct Pairing { code: String, until: Instant, tries: u32, link: String }

#[derive(Default)]
struct State { options: Options, pairing: Option<Pairing>, port: Option<u16> }

fn state() -> &'static Mutex<State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(State::default()))
}
/// Held while the bound browsers' file is read and written.
static FILE: Mutex<()> = Mutex::new(());

fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) }

// ---------------------------------------------------------------------------------------------
// the bound browsers, kept with the library (this device's, never synced)

#[derive(Serialize, Deserialize, Default)]
struct Stored {
    /// This device, as the extension knows it (one device may change its name or address).
    #[serde(default)] device: String,
    #[serde(default)] clients: Vec<StoredClient>,
}
#[derive(Serialize, Deserialize, Clone)]
struct StoredClient { id: String, name: String, /// SHA-256 of the token, hex
    token: String, added: u64, seen: u64 }

/// A bound browser, as the app lists it.
#[derive(Serialize, Clone, Debug)]
pub struct Client { pub id: String, pub name: String, pub added: u64, pub seen: u64 }

fn file(lib: &Library) -> PathBuf { lib.dir.join("extension.json") }

fn load(lib: &Library) -> Stored {
    let mut s: Stored = std::fs::read(file(lib)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    if s.device.is_empty() { s.device = hex::encode(rand::thread_rng().gen::<[u8; 8]>()); }
    s
}
fn save(lib: &Library, s: &Stored) -> anyhow::Result<()> {
    let path = file(lib);
    let tmp = path.with_extension(format!("json.{}.partial", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec_pretty(s)?)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}
fn hash(token: &str) -> String { hex::encode(Sha256::digest(token.as_bytes())) }

/// The bound browser of `token`, its last request noted (at most once a minute: polling writes
/// nothing).
fn client_of(lib: &Library, token: Option<&str>) -> Option<StoredClient> {
    let token = token.filter(|t| !t.is_empty())?;
    let h = hash(token);
    let _g = FILE.lock().unwrap_or_else(|e| e.into_inner());
    let mut s = load(lib);
    let c = s.clients.iter_mut().find(|c| c.token == h)?;
    let found = c.clone();
    if now().saturating_sub(c.seen) >= 60 {
        c.seen = now();
        let _ = save(lib, &s);
    }
    Some(found)
}

pub fn clients(lib: &Library) -> Value {
    let _g = FILE.lock().unwrap_or_else(|e| e.into_inner());
    let s = load(lib);
    let list: Vec<Client> = s.clients.iter().map(|c| Client { id: c.id.clone(), name: c.name.clone(), added: c.added, seen: c.seen }).collect();
    let st = state().lock().unwrap();
    let pairing = st.pairing.as_ref().filter(|p| p.until > Instant::now())
        .map(|p| json!({ "code": p.code, "link": p.link, "expires_in": p.until.saturating_duration_since(Instant::now()).as_secs() }));
    json!({ "clients": list, "pairing": pairing, "port": st.port })
}

pub fn remove(lib: &Library, id: &str) -> anyhow::Result<bool> {
    let _g = FILE.lock().unwrap_or_else(|e| e.into_inner());
    let mut s = load(lib);
    let n = s.clients.len();
    s.clients.retain(|c| c.id != id);
    if s.clients.len() == n { return Ok(false); }
    save(lib, &s)?;
    Ok(true)
}

// ---------------------------------------------------------------------------------------------
// binding

/// This device's LAN addresses with the listener's port, for the binding text.
fn local_addresses(port: u16) -> Vec<String> {
    let mut v: Vec<String> = if_addrs::get_if_addrs().unwrap_or_default().into_iter()
        .filter(|i| !i.is_loopback())
        .filter_map(|i| match i.ip() { IpAddr::V4(a) if !a.is_link_local() => Some(format!("{a}:{port}")), _ => None })
        .collect();
    v.sort();
    v.dedup();
    v
}

/// Starts binding a browser: a new code (any earlier one ends) and the binding text with
/// `addresses` (`host:port`; this device's own LAN addresses when None, for the desktop apps).
pub fn pair_begin(lib: &Library, addresses: Option<Vec<String>>) -> anyhow::Result<Value> {
    let device = { let _g = FILE.lock().unwrap_or_else(|e| e.into_inner()); let s = load(lib); save(lib, &s)?; s.device };
    let mut st = state().lock().unwrap();
    let addresses = match addresses.filter(|a| !a.is_empty()) {
        Some(a) => a,
        None => match st.port { Some(p) => local_addresses(p), None => bail!("the extension receiver is not running") },
    };
    let code = format!("{:06}", rand::rngs::OsRng.gen_range(0..1_000_000u32));
    let text = json!({ "v": API, "n": st.options.name, "i": device, "a": addresses, "c": code }).to_string();
    let link = format!("TWS1:{}", base64url(text.as_bytes()));
    st.pairing = Some(Pairing { code: code.clone(), until: Instant::now() + CODE_LIFE, tries: 0, link: link.clone() });
    Ok(json!({ "code": code, "link": link, "addresses": addresses, "expires_in": CODE_LIFE.as_secs() }))
}

pub fn pair_cancel() { state().lock().unwrap().pairing = None; }

fn pair(lib: &Library, code: &str, name: &str) -> Result<Value, (u16, &'static str)> {
    {
        let mut st = state().lock().unwrap();
        let Some(p) = st.pairing.as_mut() else { return Err((403, "no_code")) };
        if p.until <= Instant::now() { st.pairing = None; return Err((403, "expired")); }
        let right: bool = subtle_eq(p.code.as_bytes(), code.trim().as_bytes());
        if !right {
            p.tries += 1;
            if p.tries >= CODE_TRIES { st.pairing = None; }
            return Err((403, "wrong_code"));
        }
        st.pairing = None;
    }
    let token = hex::encode(rand::rngs::OsRng.gen::<[u8; 32]>());
    let id = hex::encode(rand::thread_rng().gen::<[u8; 6]>());
    let name: String = name.trim().chars().take(80).collect();
    let _g = FILE.lock().unwrap_or_else(|e| e.into_inner());
    let mut s = load(lib);
    s.clients.push(StoredClient { id: id.clone(), name: if name.is_empty() { "Browser".into() } else { name }, token: hash(&token), added: now(), seen: now() });
    save(lib, &s).map_err(|_| (500, "storage"))?;
    let st = state().lock().unwrap();
    Ok(json!({ "token": token, "client": id, "id": s.device, "name": st.options.name, "platform": st.options.platform, "flavor": st.options.flavor, "api": API }))
}

fn subtle_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn base64url(b: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut s = String::with_capacity(b.len() * 4 / 3 + 3);
    for c in b.chunks(3) {
        let n = (u32::from(c[0]) << 16) | (u32::from(*c.get(1).unwrap_or(&0)) << 8) | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..=c.len() { s.push(T[((n >> (18 - 6 * i)) & 63) as usize] as char); }
    }
    s
}

// ---------------------------------------------------------------------------------------------
// tasks

/// `https://x.com/<user>/status/<id>` from any form of a post's link (x.com, twitter.com,
/// mobile., fxtwitter…, /i/web/status/…), as the apps store it; None for anything else.
pub fn canonical_post(url: &str) -> Option<String> {
    let url = url.trim();
    let rest = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://")).unwrap_or(url);
    let (host, path) = rest.split_once('/')?;
    let host = host.to_ascii_lowercase();
    let host = ["www.", "mobile.", "m."].iter().fold(host.as_str(), |h, p| h.strip_prefix(p).unwrap_or(h)).to_string();
    if !["twitter.com", "x.com", "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com"].contains(&host.as_str()) { return None; }
    let path = path.split(['?', '#']).next().unwrap_or("");
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let (user, raw) = match parts.as_slice() {
        ["i", "web", "status", id, ..] => ("i", *id),
        ["i", "status", id, ..] => ("i", *id),
        [user, s, id, ..] if s.eq_ignore_ascii_case("status") || s.eq_ignore_ascii_case("statuses") => (*user, *id),
        _ => return None,
    };
    if user.is_empty() || !user.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') { return None; }
    let id: String = raw.chars().take_while(|c| c.is_ascii_digit()).collect();
    if id.is_empty() || id.len() > 20 { return None; }
    Some(format!("https://x.com/{user}/status/{id}"))
}

fn request(urls: Vec<String>) -> DownloadRequest {
    let o = state().lock().unwrap().options.clone();
    DownloadRequest {
        urls,
        concurrency: o.concurrency.clamp(1, 16),
        interval_ms: o.interval_ms.min(600_000),
        route: o.route,
        // asked for by hand: media of it in the recycle bin come back, as with a pasted link
        revive: true,
        folder: o.folder.filter(|f| !f.trim().is_empty()),
        mark_recent: false,
    }
}

fn task(lib: &Library, url: &str, active: &[String]) -> Value {
    match lib.db().job_state(url) {
        Ok(Some((status, error))) => {
            let state = match status.as_str() {
                "pending" if active.iter().any(|a| a == url) => "downloading",
                "pending" => "queued",
                "done" => "done",
                "failed" => "failed",
                "paused" => "paused",
                "cancelled" => "cancelled",
                _ => "unknown",
            };
            json!({ "url": url, "state": state, "error": error })
        }
        _ => json!({ "url": url, "state": "unknown" }),
    }
}

// ---------------------------------------------------------------------------------------------
// requests

pub struct Request<'a> {
    pub method: &'a str,
    pub path: &'a str,
    /// From `Authorization: Bearer …`
    pub token: Option<&'a str>,
    /// The `Origin` header, when there is one
    pub origin: Option<&'a str>,
    pub body: &'a [u8],
}
pub struct Reply { pub status: u16, pub body: Value }

fn err(status: u16, code: &str) -> Reply { Reply { status, body: json!({ "error": code }) } }

/// Answers one request of the extension (see the top). `lib` is the open library, if any.
pub fn handle(lib: Option<Arc<Library>>, r: &Request) -> Reply {
    // a web page (its origin is http(s)://…) never gets in; the extension's own requests carry
    // chrome-extension:// (or none)
    if let Some(o) = r.origin {
        let o = o.to_ascii_lowercase();
        if o.starts_with("http:") || o.starts_with("https:") || o == "null" { return err(403, "origin"); }
    }
    let Some(lib) = lib else { return err(503, "not_ready") };
    let body: Value = if r.body.is_empty() { Value::Null } else {
        match serde_json::from_slice(r.body) { Ok(v) => v, Err(_) => return err(400, "json") }
    };
    let text = |k: &str| body.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    match (r.method, r.path.trim_end_matches('/')) {
        ("GET", "/ext/hello") => {
            let device = { let _g = FILE.lock().unwrap_or_else(|e| e.into_inner()); let s = load(&lib); if !file(&lib).exists() { let _ = save(&lib, &s); } s.device };
            let bound = client_of(&lib, r.token).is_some();
            let st = state().lock().unwrap();
            Reply { status: 200, body: json!({ "app": "TwimShelf", "api": API, "id": device, "name": st.options.name, "platform": st.options.platform, "flavor": st.options.flavor, "bound": bound }) }
        }
        ("POST", "/ext/pair") => match pair(&lib, &text("code"), &text("name")) {
            Ok(v) => Reply { status: 200, body: v },
            Err((s, c)) => err(s, c),
        },
        (_, path @ ("/ext/download" | "/ext/status" | "/ext/unbind")) => {
            let Some(client) = client_of(&lib, r.token) else { return err(401, "unbound") };
            if r.method != "POST" { return err(405, "method"); }
            match path {
                "/ext/download" => {
                    let Some(url) = canonical_post(&text("url")) else { return err(400, "not_a_post") };
                    if let Err(e) = download::start(lib.clone(), request(vec![url.clone()])) {
                        return Reply { status: 500, body: json!({ "error": "queue", "message": format!("{e:#}") }) };
                    }
                    Reply { status: 200, body: task(&lib, &url, &download::status().active) }
                }
                "/ext/status" => {
                    let urls: Vec<String> = body.get("urls").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).filter_map(canonical_post).take(200).collect()).unwrap_or_default();
                    let status = download::status();
                    let tasks: Vec<Value> = urls.iter().map(|u| task(&lib, u, &status.active)).collect();
                    // links still waiting with the queue not running (the app was quit meanwhile):
                    // it goes on, as the user asked for them
                    if !status.running && tasks.iter().any(|t| t["state"] == "queued") {
                        let _ = download::start(lib.clone(), request(vec![]));
                    }
                    Reply { status: 200, body: json!({ "tasks": tasks }) }
                }
                _ => {
                    let _ = remove(&lib, &client.id);
                    Reply { status: 200, body: json!({ "ok": true }) }
                }
            }
        }
        _ => err(404, "not_found"),
    }
}

/// [`handle`] with the open library (the server routes the extension's requests here).
pub fn handle_open(r: &Request) -> Reply { handle(crate::ffi::current_library(), r) }

/// Headers that let the extension's own pages read the answers (only an extension's origin is
/// named; a web page's never is): CORS and Chrome's private-network preflight.
pub fn cors_headers(origin: Option<&str>) -> Vec<(&'static str, String)> {
    match origin {
        Some(o) if o.starts_with("chrome-extension://") || o.starts_with("moz-extension://") || o.starts_with("safari-web-extension://") => vec![
            ("Access-Control-Allow-Origin", o.to_string()),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS".into()),
            ("Access-Control-Allow-Headers", "authorization, content-type".into()),
            ("Access-Control-Allow-Private-Network", "true".into()),
            ("Access-Control-Max-Age", "600".into()),
            ("Vary", "Origin".into()),
        ],
        _ => vec![],
    }
}

// ---------------------------------------------------------------------------------------------
// the desktop apps' own listener

/// Sets this device's options, and with `listen` starts the listener once (27800, or the next
/// free port). The port, or None without a listener.
pub fn serve(options: Options) -> anyhow::Result<Option<u16>> {
    let listen = options.listen;
    let mut st = state().lock().unwrap();
    st.options = options;
    if !listen || st.port.is_some() { return Ok(st.port); }
    let rt = download::runtime();
    let _enter = rt.enter();
    for port in FIRST_PORT..FIRST_PORT + PORTS {
        let Ok(std) = std::net::TcpListener::bind(("0.0.0.0", port)) else { continue };
        std.set_nonblocking(true)?;
        let listener = tokio::net::TcpListener::from_std(std)?;
        rt.spawn(accept(listener));
        st.port = Some(port);
        return Ok(Some(port));
    }
    bail!("no free port for the browser extension ({FIRST_PORT}–{})", FIRST_PORT + PORTS - 1)
}

/// This computer and the LAN (private, link-local, carrier-grade NAT such as Tailscale).
pub fn is_local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => a.is_loopback() || a.is_private() || a.is_link_local() || (a.octets()[0] == 100 && (a.octets()[1] & 0xc0) == 64),
        IpAddr::V6(a) => match a.to_ipv4_mapped() {
            Some(v4) => is_local(IpAddr::V4(v4)),
            None => a.is_loopback() || (a.segments()[0] & 0xfe00) == 0xfc00 || (a.segments()[0] & 0xffc0) == 0xfe80,
        },
    }
}

/// A host this listener answers to: an IP address, `localhost`, or a `.local` name.
fn host_ok(host: &str) -> bool {
    let h = host.trim();
    let name = if let Some(rest) = h.strip_prefix('[') { rest.split(']').next().unwrap_or("") } else { h.rsplit_once(':').map_or(h, |(n, p)| if p.chars().all(|c| c.is_ascii_digit()) { n } else { h }) };
    let name = name.to_ascii_lowercase();
    name.parse::<IpAddr>().is_ok() || name == "localhost" || name.ends_with(".local")
}

async fn accept(listener: tokio::net::TcpListener) {
    loop {
        let Ok((stream, peer)) = listener.accept().await else { tokio::time::sleep(Duration::from_millis(200)).await; continue };
        if !is_local(peer.ip()) { continue; }
        tokio::spawn(async move { let _ = tokio::time::timeout(Duration::from_secs(15), connection(stream, peer)).await; });
    }
}

async fn connection(mut s: tokio::net::TcpStream, _peer: SocketAddr) -> anyhow::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut buf = Vec::with_capacity(2048);
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        let n = s.read(&mut chunk).await?;
        if n == 0 { return Ok(()); }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") { break i; }
        if buf.len() > 16 * 1024 { return Ok(()); }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let (method, target) = (first.next().unwrap_or("").to_string(), first.next().unwrap_or("").to_string());
    let mut host = None; let mut origin = None; let mut token = None; let mut length = 0usize;
    for l in lines {
        let Some((k, v)) = l.split_once(':') else { continue };
        let v = v.trim().to_string();
        match k.trim().to_ascii_lowercase().as_str() {
            "host" => host = Some(v),
            "origin" => origin = Some(v),
            "authorization" => token = v.strip_prefix("Bearer ").map(str::to_string),
            "content-length" => length = v.parse().unwrap_or(0),
            _ => {}
        }
    }
    if length > 64 * 1024 { return Ok(()); }
    let mut body = buf[head_end + 4..].to_vec();
    while body.len() < length {
        let n = s.read(&mut chunk).await?;
        if n == 0 { break; }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(length);
    let cors: String = cors_headers(origin.as_deref()).iter().map(|(k, v)| format!("{k}: {v}\r\n")).collect();
    let reply = if !host.as_deref().is_some_and(host_ok) {
        err(421, "host")
    } else if method == "OPTIONS" {
        let out = format!("HTTP/1.1 204 No Content\r\n{cors}Content-Length: 0\r\nConnection: close\r\n\r\n");
        s.write_all(out.as_bytes()).await?;
        return Ok(());
    } else {
        let path = target.split('?').next().unwrap_or("").to_string();
        tokio::task::spawn_blocking(move || handle(crate::ffi::current_library(), &Request { method: &method, path: &path, token: token.as_deref(), origin: origin.as_deref(), body: &body }))
            .await.unwrap_or_else(|_| err(500, "internal"))
    };
    let text = reply.body.to_string();
    let reason = match reply.status { 200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 421 => "Misdirected Request", 503 => "Service Unavailable", _ => "Error" };
    let out = format!("HTTP/1.1 {} {reason}\r\n{cors}Content-Type: application/json\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{text}", reply.status, text.len());
    s.write_all(out.as_bytes()).await?;
    s.shutdown().await.ok();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    /// The binding state is the process's: tests that bind take turns.
    static TURN: Mutex<()> = Mutex::new(());

    #[test]
    fn post_links_in_any_form_become_one() {
        for u in ["https://x.com/a_b/status/123", "https://twitter.com/a_b/status/123?s=20", "http://mobile.twitter.com/a_b/statuses/123/photo/1",
                  "https://fxtwitter.com/a_b/status/123#m", "x.com/a_b/status/123"] {
            assert_eq!(canonical_post(u).as_deref(), Some("https://x.com/a_b/status/123"), "{u}");
        }
        assert_eq!(canonical_post("https://x.com/i/web/status/9").as_deref(), Some("https://x.com/i/status/9"));
        for u in ["https://x.com/home", "https://evil.com/a/status/1", "https://x.com/a b/status/1", "https://x.com/a/status/x"] {
            assert_eq!(canonical_post(u), None, "{u}");
        }
    }

    #[test]
    fn only_this_computer_and_the_lan() {
        for ip in ["127.0.0.1", "192.168.1.5", "10.0.0.2", "172.16.4.4", "169.254.3.3", "100.101.102.103", "::1", "fd00::1", "fe80::1", "::ffff:192.168.0.2"] {
            assert!(is_local(ip.parse().unwrap()), "{ip}");
        }
        for ip in ["8.8.8.8", "100.200.1.1", "2001:db8::1", "::ffff:1.1.1.1"] { assert!(!is_local(ip.parse().unwrap()), "{ip}"); }
    }

    #[test]
    fn hosts_a_page_cannot_name() {
        for h in ["127.0.0.1:27800", "localhost:27800", "[::1]:27800", "192.168.1.5", "my-mac.local:27800"] { assert!(host_ok(h), "{h}"); }
        for h in ["evil.example:27800", "example.com", ""] { assert!(!host_ok(h), "{h}"); }
    }

    #[test]
    fn binding_text_is_base64url() {
        assert_eq!(base64url(b"hello"), "aGVsbG8");
        assert_eq!(base64url(b"hi?>"), "aGk_Pg");
    }

    #[test]
    fn a_browser_binds_once_with_the_code_and_then_queues_links() {
        let _t = TURN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("tl-ext-{}", rand::random::<u64>()));
        let lib = Arc::new(Library::open(&dir).unwrap());
        serve(Options { name: "Test Mac".into(), platform: "macos".into(), ..Default::default() }).unwrap();
        let call = |method: &str, path: &str, token: Option<&str>, origin: Option<&str>, body: Value| {
            let b = body.to_string();
            handle(Some(lib.clone()), &Request { method, path, token, origin, body: if body.is_null() { b"" } else { b.as_bytes() } })
        };
        // nothing to bind with before the app shows a code
        assert_eq!(call("POST", "/ext/pair", None, None, json!({"code": "000000"})).body["error"], "no_code");
        let p = pair_begin(&lib, Some(vec!["192.168.1.5:27800".into()])).unwrap();
        let code = p["code"].as_str().unwrap().to_string();
        assert!(p["link"].as_str().unwrap().starts_with("TWS1:"));
        // a web page cannot try codes
        assert_eq!(call("POST", "/ext/pair", None, Some("https://evil.example"), json!({"code": code})).status, 403);
        let wrong = if code == "111111" { "222222" } else { "111111" };
        assert_eq!(call("POST", "/ext/pair", None, None, json!({"code": wrong})).body["error"], "wrong_code");
        let ok = call("POST", "/ext/pair", None, Some("chrome-extension://abc"), json!({"code": code, "name": "Chrome"}));
        assert_eq!(ok.status, 200);
        let token = ok.body["token"].as_str().unwrap().to_string();
        assert_eq!(ok.body["name"], "Test Mac");
        // the code is used up
        assert_eq!(call("POST", "/ext/pair", None, None, json!({"code": code})).body["error"], "no_code");
        assert_eq!(call("GET", "/ext/hello", Some(&token), None, Value::Null).body["bound"], true);
        assert_eq!(call("POST", "/ext/download", Some("nope"), None, json!({"url": "https://x.com/a/status/1"})).status, 401);
        assert_eq!(call("POST", "/ext/download", Some(&token), None, json!({"url": "https://x.com/home"})).body["error"], "not_a_post");
        // a task is its link's row in the core's queue (set here without the network)
        lib.db().enqueue_job_with("https://x.com/a/status/1", None).unwrap();
        lib.db().finish_job("https://x.com/a/status/1", Some("gone".into())).unwrap();
        lib.db().enqueue_job_with("https://x.com/c/status/3", None).unwrap();
        lib.db().finish_job("https://x.com/c/status/3", None).unwrap();
        let st = call("POST", "/ext/status", Some(&token), None, json!({"urls": ["https://twitter.com/a/status/1?s=1", "https://x.com/b/status/2", "x.com/c/status/3"]}));
        let tasks = st.body["tasks"].as_array().unwrap();
        assert_eq!(tasks[0]["url"], "https://x.com/a/status/1");
        assert_eq!(tasks[0]["state"], "failed");
        assert_eq!(tasks[0]["error"], "gone");
        assert_eq!(tasks[1]["state"], "unknown");
        assert_eq!(tasks[2]["state"], "done");
        let listed = clients(&lib);
        assert_eq!(listed["clients"][0]["name"], "Chrome");
        assert!(listed["clients"][0].get("token").is_none());
        assert_eq!(call("POST", "/ext/unbind", Some(&token), None, Value::Null).status, 200);
        assert_eq!(call("GET", "/ext/hello", Some(&token), None, Value::Null).body["bound"], false);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn five_wrong_codes_end_the_code() {
        let _t = TURN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("tl-ext-{}", rand::random::<u64>()));
        let lib = Arc::new(Library::open(&dir).unwrap());
        let code = pair_begin(&lib, Some(vec!["10.0.0.1:2778".into()])).unwrap()["code"].as_str().unwrap().to_string();
        let wrong = if code == "111111" { "222222" } else { "111111" };
        for _ in 0..CODE_TRIES { let _ = pair(&lib, wrong, "x"); }
        assert_eq!(pair(&lib, &code, "x").unwrap_err().1, "no_code");
        let _ = std::fs::remove_dir_all(dir);
    }
}

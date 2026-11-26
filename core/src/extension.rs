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
//! `POST /ext/status {urls}`, `POST /ext/unbind`, `POST /ext/open-settings`.
use crate::download::{self, DownloadRequest, Route};
use crate::library::Library;
use crate::net::client;
use crate::update::newer;
use anyhow::bail;
use futures_util::StreamExt;
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::AsyncWriteExt;

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
    /// True for desktop apps (macOS, Windows, Linux Electron) that can host/manage the extension
    /// and open their own Browser Extension settings page; false for Docker/web servers.
    #[serde(default)] pub desktop: bool,
    /// Optional explicit folder for the app-hosted extension (defaults to `<lib.dir>/../extension`).
    #[serde(default)] pub managed_dir: Option<String>,
}

const DEFAULT_REPO: &str = "XGWYTWGDYU/TwimShelf";
static OPEN_SETTINGS: AtomicBool = AtomicBool::new(false);

/// Returns true once after the browser extension asks this desktop app to open its Extension page.
pub fn take_open_settings() -> bool { OPEN_SETTINGS.swap(false, Ordering::SeqCst) }

fn is_desktop_options(o: &Options) -> bool { o.desktop || o.listen }

/// Folder where this desktop app hosts the downloaded extension (never touches external installs).
pub fn managed_dir(lib: &Library) -> PathBuf {
    let custom = state().lock().unwrap().options.managed_dir.clone().filter(|s| !s.trim().is_empty());
    match custom {
        Some(dir) => PathBuf::from(dir),
        None => lib.dir.parent().unwrap_or(&lib.dir).join("extension"),
    }
}

/// Installed version of the app-hosted extension, or None if the user has not downloaded one here.
pub fn managed_version(dir: &Path) -> Option<String> {
    let text = std::fs::read_to_string(dir.join("manifest.json")).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let ver = v.get("version").and_then(Value::as_str)?.trim();
    if ver.is_empty() { None } else { Some(ver.to_string()) }
}

/// Status of the app-hosted extension: `{installed, version, dir}`.
pub fn managed_status(lib: &Library) -> Value {
    let dir = managed_dir(lib);
    let version = managed_version(&dir);
    json!({
        "installed": version.is_some(),
        "version": version,
        "dir": dir.to_string_lossy(),
    })
}

fn valid_repo(r: &str) -> bool {
    let mut it = r.split('/');
    let ok = |s: Option<&str>| s.map_or(false, |s| !s.is_empty() && s.len() <= 100 && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) && s != "." && s != "..");
    ok(it.next()) && ok(it.next()) && it.next().is_none()
}

#[derive(Deserialize)]
struct ReleaseAsset {
    name: String,
    browser_download_url: String,
    #[serde(default)] size: u64,
    #[serde(default)] digest: Option<String>,
}
#[derive(Deserialize)]
struct ReleaseInfo {
    tag_name: String,
    html_url: String,
    #[serde(default)] draft: bool,
    #[serde(default)] prerelease: bool,
    #[serde(default)] assets: Vec<ReleaseAsset>,
}

struct ExtensionRelease {
    version: String,
    page_url: String,
    asset_url: String,
    asset_size: u64,
    asset_digest: Option<String>,
}

fn fetch_extension_release(repo: &str) -> anyhow::Result<ExtensionRelease> {
    let repo = if repo.trim().is_empty() { DEFAULT_REPO } else { repo.trim() };
    if !valid_repo(repo) { bail!(tr!("update.badRepo")) }
    let url = format!("https://api.github.com/repos/{repo}/releases/latest");
    let r: ReleaseInfo = download::runtime().block_on(async {
        let resp = client().get(&url)
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .timeout(Duration::from_secs(20))
            .send().await?;
        if !resp.status().is_success() { bail!(tr!("update.http", code = resp.status().as_u16())) }
        Ok::<_, anyhow::Error>(resp.json().await?)
    })?;
    if r.draft || r.prerelease { bail!(tr!("update.noInstaller")) }
    let version = r.tag_name.trim_start_matches(['v', 'V']).to_string();
    // Prefer the dedicated small extension zip asset; fall back to the release tag source zip so
    // downloading also works against releases published before the extension zip asset existed.
    let asset = r.assets.iter().find(|a| {
        let n = a.name.to_ascii_lowercase();
        n.contains("extension") && n.ends_with(".zip")
    });
    let (asset_url, asset_size, asset_digest) = match asset {
        Some(a) => (a.browser_download_url.clone(), a.size, a.digest.clone()),
        None => (format!("https://github.com/{repo}/archive/refs/tags/{}.zip", r.tag_name), 0, None),
    };
    Ok(ExtensionRelease { version, page_url: r.html_url, asset_url, asset_size, asset_digest })
}

/// Checks GitHub Releases for the latest extension version vs the app-hosted copy (if any).
pub fn managed_check(lib: &Library, repo: &str) -> anyhow::Result<Value> {
    let dir = managed_dir(lib);
    let current = managed_version(&dir);
    let rel = fetch_extension_release(repo)?;
    let has_update = match current.as_deref() {
        Some(cur) => newer(&rel.version, cur),
        None => true,
    };
    Ok(json!({
        "installed": current.is_some(),
        "current": current,
        "latest": rel.version,
        "has_update": has_update,
        "page_url": rel.page_url,
        "dir": dir.to_string_lossy(),
    }))
}

/// Extracts an extension archive (either flat `manifest.json` at root or `.../extension/manifest.json`)
/// into `target_dir` in-place (preserving `target_dir` itself so an already-loaded Chrome unpacked
/// extension keeps its path/ID and updates without quitting Chrome).
pub fn install_zip_into(zip_path: &Path, target_dir: &Path) -> anyhow::Result<String> {
    let f = std::fs::File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(f)?;

    // Locate the prefix directory containing the browser extension's manifest.json.
    let mut prefix: Option<String> = None;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        if entry.is_dir() { continue; }
        let name = entry.name().replace('\\', "/");
        if name == "manifest.json" || name.ends_with("/manifest.json") {
            let mut text = String::new();
            let _ = (&mut entry).take(256 * 1024).read_to_string(&mut text);
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                if v.get("manifest_version").is_some() && v.get("version").and_then(Value::as_str).is_some() {
                    let p = name.strip_suffix("manifest.json").unwrap_or("").to_string();
                    // Prefer root manifest.json or an `extension/` folder if multiple exist
                    if prefix.is_none() || p.is_empty() || p.ends_with("/extension/") || p == "extension/" {
                        prefix = Some(p);
                        if prefix.as_deref() == Some("") { break; }
                    }
                }
            }
        }
    }
    let Some(prefix) = prefix else { bail!("extension manifest.json not found in archive") };

    let parent = target_dir.parent().unwrap_or(target_dir);
    std::fs::create_dir_all(parent)?;
    let staging = parent.join(format!(".extension-staging-{}-{:08x}", std::process::id(), rand::random::<u32>()));
    std::fs::create_dir_all(&staging)?;
    struct CleanDir(PathBuf);
    impl Drop for CleanDir { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
    let _guard = CleanDir(staging.clone());

    let mut extracted_files = 0usize;
    let mut total_bytes = 0u64;
    const MAX_UNPACKED_BYTES: u64 = 32 << 20;

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        if entry.is_dir() { continue; }
        // Skip symlinks inside archives
        if entry.unix_mode().is_some_and(|m| (m & 0o170000) == 0o120000) { continue; }
        let name = entry.name().replace('\\', "/");
        let Some(rel) = name.strip_prefix(&prefix) else { continue };
        let rel = rel.trim_start_matches('/');
        if rel.is_empty() || rel == "README.md" || rel.starts_with("__MACOSX/") || rel.ends_with("/.DS_Store") || rel == ".DS_Store" { continue; }
        let mut clean = PathBuf::new();
        let mut safe = true;
        for c in Path::new(rel).components() {
            match c {
                Component::Normal(p) => clean.push(p),
                _ => { safe = false; break; }
            }
        }
        if !safe || clean.as_os_str().is_empty() { bail!("unsafe path in extension archive"); }
        let dest = staging.join(&clean);
        if let Some(p) = dest.parent() { std::fs::create_dir_all(p)?; }
        let mut out = std::fs::File::create(&dest)?;
        let mut buf = [0u8; 16384];
        loop {
            let n = entry.read(&mut buf)?;
            if n == 0 { break; }
            total_bytes = total_bytes.saturating_add(n as u64);
            anyhow::ensure!(total_bytes <= MAX_UNPACKED_BYTES, "extension archive too large");
            out.write_all(&buf[..n])?;
        }
        extracted_files += 1;
    }
    anyhow::ensure!(extracted_files > 0, "extension archive contained no files");
    let new_version = managed_version(&staging).ok_or_else(|| anyhow::anyhow!("invalid extension manifest.json"))?;

    // Sync staging into target_dir in-place (preserving target_dir itself so Chrome does not need to quit).
    std::fs::create_dir_all(target_dir)?;
    let mut keep_files = HashSet::<PathBuf>::new();
    let mut keep_dirs = HashSet::<PathBuf>::new();
    fn sync_dir(src: &Path, dst: &Path, rel: &Path, keep_files: &mut HashSet<PathBuf>, keep_dirs: &mut HashSet<PathBuf>) -> anyhow::Result<()> {
        for e in std::fs::read_dir(src)? {
            let e = e?;
            let name = e.file_name();
            let s = e.path();
            let d = dst.join(&name);
            let r = rel.join(&name);
            if e.file_type()?.is_dir() {
                std::fs::create_dir_all(&d)?;
                keep_dirs.insert(r.clone());
                sync_dir(&s, &d, &r, keep_files, keep_dirs)?;
            } else {
                let bytes = std::fs::read(&s)?;
                std::fs::write(&d, bytes)?;
                keep_files.insert(r);
            }
        }
        Ok(())
    }
    sync_dir(&staging, target_dir, Path::new(""), &mut keep_files, &mut keep_dirs)?;

    // Prune stale files/dirs that no longer exist in the new version.
    fn prune_dir(dst: &Path, rel: &Path, keep_files: &HashSet<PathBuf>, keep_dirs: &HashSet<PathBuf>) {
        let Ok(rd) = std::fs::read_dir(dst) else { return };
        for e in rd.flatten() {
            let p = e.path();
            let r = rel.join(e.file_name());
            if e.file_type().is_ok_and(|t| t.is_dir()) {
                if !keep_dirs.contains(&r) {
                    let _ = std::fs::remove_dir_all(&p);
                } else {
                    prune_dir(&p, &r, keep_files, keep_dirs);
                }
            } else if !keep_files.contains(&r) {
                let _ = std::fs::remove_file(&p);
            }
        }
    }
    prune_dir(target_dir, Path::new(""), &keep_files, &keep_dirs);

    Ok(new_version)
}

/// Downloads the latest extension from GitHub Releases and installs/updates it in-place into the
/// app's managed extension folder.
pub fn managed_install(lib: &Library, repo: &str) -> anyhow::Result<Value> {
    let dir = managed_dir(lib);
    let rel = fetch_extension_release(repo)?;
    let u = reqwest::Url::parse(&rel.asset_url).map_err(|_| anyhow::anyhow!(tr!("update.badUrl")))?;
    if u.scheme() != "https" || u.host_str() != Some("github.com") { bail!(tr!("update.badUrl")) }
    const MAX_ZIP_BYTES: u64 = 128 << 20;
    anyhow::ensure!(rel.asset_size <= MAX_ZIP_BYTES, tr!("update.sizeMismatch"));
    let limit = if rel.asset_size > 0 { rel.asset_size } else { MAX_ZIP_BYTES };
    let digest = rel.asset_digest.as_deref().map(|value| {
        value.strip_prefix("sha256:").filter(|d| d.len() == 64 && d.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(|| anyhow::anyhow!(tr!("update.digestMismatch")))
    }).transpose()?;

    let parent = dir.parent().unwrap_or(&dir);
    std::fs::create_dir_all(parent)?;
    let part = parent.join(format!(".extension-dl-{:016x}.zip", rand::random::<u64>()));
    let _cleanup = crate::library::TempFile(part.clone());

    download::runtime().block_on(async {
        let resp = client().get(&rel.asset_url).timeout(Duration::from_secs(60)).send().await?;
        if !resp.status().is_success() { bail!(tr!("update.http", code = resp.status().as_u16())) }
        anyhow::ensure!(resp.content_length().is_none_or(|n| n <= limit), tr!("update.sizeMismatch"));
        let mut file = tokio::fs::File::create_new(&part).await?;
        let mut hash = Sha256::new();
        let mut n = 0u64;
        let mut body = resp.bytes_stream();
        while let Some(chunk) = body.next().await {
            let chunk = chunk?;
            n += chunk.len() as u64;
            anyhow::ensure!(n <= limit, tr!("update.sizeMismatch"));
            hash.update(&chunk);
            file.write_all(&chunk).await?;
        }
        if rel.asset_size > 0 && n != rel.asset_size { bail!(tr!("update.sizeMismatch")) }
        if digest.is_some_and(|want| !hex::encode(hash.finalize()).eq_ignore_ascii_case(want)) {
            bail!(tr!("update.digestMismatch"));
        }
        file.sync_all().await?;
        Ok::<_, anyhow::Error>(())
    })?;

    let version = install_zip_into(&part, &dir)?;
    Ok(json!({
        "installed": true,
        "version": version,
        "dir": dir.to_string_lossy(),
    }))
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
            let (name, platform, flavor, desktop) = {
                let st = state().lock().unwrap();
                (st.options.name.clone(), st.options.platform.clone(), st.options.flavor.clone(), is_desktop_options(&st.options))
            };
            let managed = desktop && managed_version(&managed_dir(&lib)).is_some();
            Reply { status: 200, body: json!({ "app": "TwimShelf", "api": API, "id": device, "name": name, "platform": platform, "flavor": flavor, "bound": bound, "managed": managed }) }
        }
        ("POST", "/ext/pair") => match pair(&lib, &text("code"), &text("name")) {
            Ok(v) => Reply { status: 200, body: v },
            Err((s, c)) => err(s, c),
        },
        (_, path @ ("/ext/download" | "/ext/status" | "/ext/unbind" | "/ext/open-settings")) => {
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
                "/ext/open-settings" => {
                    let desktop = is_desktop_options(&state().lock().unwrap().options);
                    if !desktop { return err(404, "not_supported"); }
                    OPEN_SETTINGS.store(true, Ordering::SeqCst);
                    Reply { status: 200, body: json!({ "ok": true }) }
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
        Some(o) if !o.chars().any(char::is_control) && (o.starts_with("chrome-extension://")
            || o.starts_with("moz-extension://") || o.starts_with("safari-web-extension://")) => vec![
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

    #[test]
    fn managed_extension_zip_install_and_open_settings() {
        let _t = TURN.lock().unwrap_or_else(|e| e.into_inner());
        let root = std::env::temp_dir().join(format!("tl-ext-managed-{}", rand::random::<u64>()));
        let lib_dir = root.join("library");
        let ext_dir = root.join("extension");
        let lib = Arc::new(Library::open(&lib_dir).unwrap());
        serve(Options {
            name: "Test Desktop".into(),
            platform: "macos".into(),
            flavor: "native".into(),
            desktop: true,
            managed_dir: Some(ext_dir.to_string_lossy().into_owned()),
            ..Default::default()
        }).unwrap();

        // Not installed yet: managed=false and hello reports managed=false
        assert_eq!(managed_status(&lib)["installed"], false);
        let call = |method: &str, path: &str, token: Option<&str>, body: Value| {
            let b = body.to_string();
            handle(Some(lib.clone()), &Request { method, path, token, origin: Some("chrome-extension://abc"), body: if body.is_null() { b"" } else { b.as_bytes() } })
        };
        assert_eq!(call("GET", "/ext/hello", None, Value::Null).body["managed"], false);

        // Build a nested source-archive zip (`TwimShelf-2.0.0/extension/...`) and install it
        let zip1 = root.join("src.zip");
        {
            let mut w = zip::ZipWriter::new(std::fs::File::create(&zip1).unwrap());
            let opt = zip::write::SimpleFileOptions::default();
            w.start_file("TwimShelf-2.0.0/extension/manifest.json", opt).unwrap();
            w.write_all(br#"{"manifest_version":3,"name":"TwimShelf","version":"2.0.0"}"#).unwrap();
            w.start_file("TwimShelf-2.0.0/extension/popup.js", opt).unwrap();
            w.write_all(b"console.log('v2.0.0');").unwrap();
            w.start_file("TwimShelf-2.0.0/extension/old_only.txt", opt).unwrap();
            w.write_all(b"stale").unwrap();
            w.finish().unwrap();
        }
        assert_eq!(install_zip_into(&zip1, &ext_dir).unwrap(), "2.0.0");
        assert_eq!(managed_status(&lib)["installed"], true);
        assert_eq!(managed_status(&lib)["version"], "2.0.0");
        assert!(ext_dir.join("old_only.txt").exists());
        assert_eq!(call("GET", "/ext/hello", None, Value::Null).body["managed"], true);

        // In-place update from a flat zip removes stale files and updates manifest.json
        let zip2 = root.join("ext.zip");
        {
            let mut w = zip::ZipWriter::new(std::fs::File::create(&zip2).unwrap());
            let opt = zip::write::SimpleFileOptions::default();
            w.start_file("manifest.json", opt).unwrap();
            w.write_all(br#"{"manifest_version":3,"name":"TwimShelf","version":"2.1.0"}"#).unwrap();
            w.start_file("popup.js", opt).unwrap();
            w.write_all(b"console.log('v2.1.0');").unwrap();
            w.finish().unwrap();
        }
        assert_eq!(install_zip_into(&zip2, &ext_dir).unwrap(), "2.1.0");
        assert_eq!(managed_status(&lib)["version"], "2.1.0");
        assert!(!ext_dir.join("old_only.txt").exists());
        assert_eq!(std::fs::read_to_string(ext_dir.join("popup.js")).unwrap(), "console.log('v2.1.0');");

        // Pair and test /ext/open-settings (requires auth token, flips flag once)
        let code = pair_begin(&lib, Some(vec!["127.0.0.1:27800".into()])).unwrap()["code"].as_str().unwrap().to_string();
        let token = call("POST", "/ext/pair", None, json!({"code": code, "name": "Chrome"})).body["token"].as_str().unwrap().to_string();
        assert_eq!(call("POST", "/ext/open-settings", None, Value::Null).status, 401);
        assert!(!take_open_settings());
        assert_eq!(call("POST", "/ext/open-settings", Some(&token), Value::Null).status, 200);
        assert!(take_open_settings());
        assert!(!take_open_settings());

        // Non-desktop server refuses /ext/open-settings and reports managed=false
        serve(Options { name: "Server".into(), platform: "server".into(), flavor: "server".into(), desktop: false, listen: false, ..Default::default() }).unwrap();
        assert_eq!(call("GET", "/ext/hello", Some(&token), Value::Null).body["managed"], false);
        assert_eq!(call("POST", "/ext/open-settings", Some(&token), Value::Null).status, 404);

        let _ = std::fs::remove_dir_all(root);
    }
}

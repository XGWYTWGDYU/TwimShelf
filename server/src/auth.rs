//! Signing in to the web app: one password (the program has one user), a session cookie.
//!
//! * The password's hash (Argon2id) and the key that signs session cookies are kept in
//!   `<data>/app/auth.json`. On the first start a random password is made, printed in the log
//!   and kept in `<data>/app/initial-password.txt` until it is changed.
//! * `twimshelf passwd` (in the container) sets a new one; every browser signed in so far is
//!   signed out (the signing key changes with it). The running server notices the new file.
//! * `TL_PASSWORD`, when set, is the password (the file follows it at start-up).
//! * Wrong passwords: after five from one address, it waits before trying again (30 s, doubling,
//!   at most an hour).
use argon2::password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use hmac::{Hmac, Mac};
use rand::Rng;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const COOKIE: &str = "tl_session";
/// A sign-in lasts this long (seconds).
pub const LIFE: u64 = 30 * 24 * 3600;

#[derive(Serialize, Deserialize, Clone)]
struct AuthFile {
    /// Argon2id, PHC string
    hash: String,
    /// Signs session cookies (hex); a new one signs everyone out.
    secret: String,
    /// Still the password made on the first start.
    #[serde(default)] initial: bool,
}

pub struct Auth {
    path: PathBuf,
    cache: Mutex<Option<(SystemTime, AuthFile)>>,
    failures: Mutex<HashMap<IpAddr, (u32, Instant)>>,
}

fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) }

pub fn file(data: &Path) -> PathBuf { data.join("app").join("auth.json") }
pub fn initial_file(data: &Path) -> PathBuf { data.join("app").join("initial-password.txt") }

/// 16 letters and digits that cannot be mistaken for one another, in groups of four (~79 bits).
pub fn random_password() -> String {
    const A: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let mut r = rand::rngs::OsRng;
    (0..4).map(|_| (0..4).map(|_| A[r.gen_range(0..A.len())] as char).collect::<String>()).collect::<Vec<_>>().join("-")
}

/// Writes a new password (and a new signing key: everyone signs in again). The file is given to
/// the owner of the `app` folder, so the server (running as PUID) can read what root wrote.
pub fn set_password(data: &Path, password: &str, initial: bool) -> anyhow::Result<()> {
    let salt = SaltString::generate(&mut OsRng);
    let hash = Argon2::default().hash_password(password.as_bytes(), &salt).map_err(|e| anyhow::anyhow!("{e}"))?.to_string();
    let secret = hex::encode(rand::rngs::OsRng.gen::<[u8; 32]>());
    let app = data.join("app");
    std::fs::create_dir_all(&app)?;
    let path = file(data);
    let tmp = path.with_extension("json.partial");
    std::fs::write(&tmp, serde_json::to_vec_pretty(&AuthFile { hash, secret, initial })?)?;
    restrict(&tmp, &app);
    std::fs::rename(&tmp, &path)?;
    let note = initial_file(data);
    if initial {
        std::fs::write(&note, format!("{password}\n"))?;
        restrict(&note, &app);
    } else {
        let _ = std::fs::remove_file(note);
    }
    Ok(())
}

/// Owner-only, and owned by whoever owns the folder.
fn restrict(path: &Path, folder: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        if let Ok(m) = std::fs::metadata(folder) { let _ = std::os::unix::fs::chown(path, Some(m.uid()), Some(m.gid())); }
    }
}

impl Auth {
    pub fn new(data: &Path) -> Self {
        Auth { path: file(data), cache: Mutex::new(None), failures: Mutex::new(HashMap::new()) }
    }

    /// At start-up: the password from `TL_PASSWORD`, or a random one the first time (printed).
    pub fn prepare(&self, data: &Path) -> anyhow::Result<()> {
        if let Some(p) = std::env::var("TL_PASSWORD").ok().filter(|p| !p.is_empty()) {
            if !self.check(&p) { set_password(data, &p, false)?; }
            eprintln!("auth: the password is the one set in TL_PASSWORD");
            return Ok(());
        }
        if self.read().is_none() {
            let p = random_password();
            set_password(data, &p, true)?;
            banner(&p, data);
        } else if self.read().is_some_and(|f| f.initial) {
            if let Ok(p) = std::fs::read_to_string(initial_file(data)) { banner(p.trim(), data); }
        }
        Ok(())
    }

    /// The file as it is now (read again when it changed: `twimshelf passwd` while running).
    fn read(&self) -> Option<AuthFile> {
        let modified = std::fs::metadata(&self.path).and_then(|m| m.modified()).ok()?;
        let mut c = self.cache.lock().unwrap();
        if let Some((t, f)) = c.as_ref() { if *t == modified { return Some(f.clone()); } }
        let f: AuthFile = serde_json::from_slice(&std::fs::read(&self.path).ok()?).ok()?;
        *c = Some((modified, f.clone()));
        Some(f)
    }

    pub fn check(&self, password: &str) -> bool {
        let Some(f) = self.read() else { return false };
        let Ok(h) = PasswordHash::new(&f.hash) else { return false };
        Argon2::default().verify_password(password.as_bytes(), &h).is_ok()
    }

    fn sign(secret: &str, payload: &str) -> Option<Hmac<Sha256>> {
        let mut m = Hmac::<Sha256>::new_from_slice(&hex::decode(secret).ok()?).ok()?;
        m.update(payload.as_bytes());
        Some(m)
    }

    /// A new session cookie's value: `expiry.nonce.signature`.
    pub fn issue(&self) -> Option<String> {
        let f = self.read()?;
        let payload = format!("{}.{}", now() + LIFE, hex::encode(rand::rngs::OsRng.gen::<[u8; 12]>()));
        let sig = hex::encode(Self::sign(&f.secret, &payload)?.finalize().into_bytes());
        Some(format!("{payload}.{sig}"))
    }

    pub fn valid(&self, value: &str) -> bool {
        let Some(f) = self.read() else { return false };
        let Some((payload, sig)) = value.rsplit_once('.') else { return false };
        let Some(exp) = payload.split('.').next().and_then(|e| e.parse::<u64>().ok()) else { return false };
        if exp <= now() { return false; }
        let (Some(m), Ok(sig)) = (Self::sign(&f.secret, payload), hex::decode(sig)) else { return false };
        m.verify_slice(&sig).is_ok()
    }

    /// Seconds to wait before this address may try again, if any.
    pub fn locked(&self, ip: IpAddr) -> Option<u64> {
        let f = self.failures.lock().unwrap();
        let (n, last) = f.get(&ip)?;
        if *n < 5 { return None; }
        let wait = Duration::from_secs((30u64 << (n - 5).min(7)).min(3600));
        let left = wait.saturating_sub(last.elapsed());
        (!left.is_zero()).then(|| left.as_secs().max(1))
    }
    pub fn failed(&self, ip: IpAddr) {
        let mut f = self.failures.lock().unwrap();
        // forgotten after a quiet day; the table cannot grow without end
        if f.len() > 10_000 { f.retain(|_, (_, t)| t.elapsed() < Duration::from_secs(86_400)); }
        let e = f.entry(ip).or_insert((0, Instant::now()));
        e.0 += 1;
        e.1 = Instant::now();
    }
    pub fn succeeded(&self, ip: IpAddr) { self.failures.lock().unwrap().remove(&ip); }
}

fn banner(password: &str, data: &Path) {
    eprintln!();
    eprintln!("============================================================");
    eprintln!("  TwimShelf web password: {password}");
    eprintln!("  (kept in {} until you change it)", initial_file(data).display());
    eprintln!("  Change it:  docker exec -it <container> twimshelf passwd");
    eprintln!("============================================================");
    eprintln!();
}

/// `twimshelf passwd [--random | --stdin]`: sets the web password from the command line.
pub fn passwd_command(data: &Path, args: &[String]) -> anyhow::Result<()> {
    if std::env::var("TL_PASSWORD").is_ok_and(|p| !p.is_empty()) {
        eprintln!("note: TL_PASSWORD is set for this container; it replaces this password at the next start.");
    }
    let password = if args.iter().any(|a| a == "--random") {
        random_password()
    } else if args.iter().any(|a| a == "--stdin") {
        let mut s = String::new();
        std::io::stdin().read_line(&mut s)?;
        s.trim_end_matches(['\r', '\n']).to_string()
    } else {
        let a = rpassword::prompt_password("New password: ")?;
        let b = rpassword::prompt_password("Again: ")?;
        anyhow::ensure!(a == b, "the two passwords differ; nothing changed");
        a
    };
    anyhow::ensure!(password.chars().count() >= 8, "a password needs at least 8 characters; nothing changed");
    set_password(data, &password, false)?;
    if args.iter().any(|a| a == "--random") { println!("New password: {password}"); }
    println!("Password changed. Browsers signed in so far have to sign in again.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_password_signs_in_and_a_new_one_signs_everyone_out() {
        let dir = std::env::temp_dir().join(format!("tl-auth-{}", rand::random::<u64>()));
        set_password(&dir, "first-password", true).unwrap();
        let a = Auth::new(&dir);
        assert!(a.check("first-password"));
        assert!(!a.check("wrong"));
        assert_eq!(std::fs::read_to_string(initial_file(&dir)).unwrap().trim(), "first-password");
        let cookie = a.issue().unwrap();
        assert!(a.valid(&cookie));
        assert!(!a.valid(&cookie.replace('.', ",")));
        let (p, s) = cookie.rsplit_once('.').unwrap();
        assert!(!a.valid(&format!("{p}.{}", "0".repeat(s.len()))));
        // a cookie whose expiry was changed no longer matches its signature
        let forged = format!("{}{}", "9", &cookie[1..]);
        assert!(!a.valid(&forged));
        std::thread::sleep(Duration::from_millis(1100)); // the file's time must differ
        set_password(&dir, "second-password", false).unwrap();
        assert!(!a.valid(&cookie));
        assert!(a.check("second-password"));
        assert!(!initial_file(&dir).exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn many_wrong_passwords_wait() {
        let a = Auth::new(Path::new("/nonexistent"));
        let ip: IpAddr = "192.168.1.9".parse().unwrap();
        for _ in 0..4 { a.failed(ip); }
        assert_eq!(a.locked(ip), None);
        a.failed(ip);
        assert!(a.locked(ip).is_some_and(|s| s <= 30));
        a.succeeded(ip);
        assert_eq!(a.locked(ip), None);
    }

    #[test]
    fn random_passwords_read_well() {
        let p = random_password();
        assert_eq!(p.len(), 19);
        assert!(p.chars().all(|c| c == '-' || "abcdefghjkmnpqrstuvwxyz23456789".contains(c)));
    }
}

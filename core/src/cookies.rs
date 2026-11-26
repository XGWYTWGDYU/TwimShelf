//! Multi-account X/Twitter cookie storage, CRDT sync, and per-author routing cache.
//!
//! Both cookie accounts (`cookie.acc.<id>`) and the author → cookie routing cache
//! (`cookie.author.<screen_name_lower>`) are stored in the library's synced `setting` table
//! (`Op::Setting`), so every device in the sync account automatically shares all cookies and
//! learned author mappings without platform-specific keychain encryption.
//!
//! There is no default or primary cookie: all accounts are equal.
use crate::download::Route;
use crate::library::Library;
use crate::net::{self, RemotePost};
use crate::protected::{Credentials, ProtectedError};
use anyhow::{anyhow, bail};
use serde::{Deserialize, Serialize};
use std::future::Future;

pub const ACCOUNT_PREFIX: &str = "cookie.acc.";
pub const AUTHOR_CACHE_PREFIX: &str = "cookie.author.";

/// When an author's cached cookie was used within this window (24 hours), `Route::Auto` goes
/// straight to that cached cookie without probing FxTwitter first.
pub const AUTHOR_CACHE_FRESH_MS: u64 = 24 * 60 * 60 * 1000;

/// Minimum interval between timestamp-only cache refreshes for the same (author, cookie) pair,
/// keeping the sync oplog quiet during bursts of posts from the same locked author.
const CACHE_TOUCH_MIN_INTERVAL_MS: u64 = 60 * 1000;

/// One X/Twitter account's session cookies, synced across devices.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CookieAccount {
    pub id: String,
    #[serde(default)]
    pub label: String,
    pub auth_token: String,
    pub ct0: String,
    #[serde(default)]
    pub screen_name: Option<String>,
    #[serde(default)]
    pub created_at: u64,
}

impl CookieAccount {
    pub fn credentials(&self) -> Credentials {
        Credentials { auth_token: self.auth_token.clone(), ct0: self.ct0.clone() }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct CookieSaveInput {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub label: String,
    pub auth_token: String,
    pub ct0: String,
    #[serde(default)]
    pub screen_name: Option<String>,
}

/// Synced cache entry remembering which cookie account succeeded for a given locked author.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthorCookieCache {
    pub cookie_id: String,
    pub last_used_ms: u64,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Normalizes an X screen name for use as an author cache key.
/// Returns `None` for empty strings or generic URL placeholders (`i`, `web`).
pub fn author_key(raw: &str) -> Option<String> {
    let s = raw.trim().trim_start_matches('@').to_ascii_lowercase();
    if s.is_empty() || s == "i" || s == "web" || s.len() > 64 {
        return None;
    }
    if !s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
        return None;
    }
    Some(s)
}

pub fn author_key_from_url(url: &str) -> Option<String> {
    net::parse_status_url(url).and_then(|(user, _)| author_key(&user))
}

/// Lists all saved cookie accounts, sorted deterministically by `(created_at, id)`.
pub fn list(lib: &Library) -> anyhow::Result<Vec<CookieAccount>> {
    let rows = lib.db().settings_with_prefix(ACCOUNT_PREFIX)?;
    let mut accounts = Vec::with_capacity(rows.len());
    for (key, value) in rows {
        let Some(suffix) = key.strip_prefix(ACCOUNT_PREFIX) else { continue };
        let Ok(mut acc) = serde_json::from_str::<CookieAccount>(&value) else { continue };
        if acc.id.is_empty() {
            acc.id = suffix.to_string();
        }
        if acc.auth_token.trim().is_empty() || acc.ct0.trim().is_empty() {
            continue;
        }
        accounts.push(acc);
    }
    accounts.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| a.id.cmp(&b.id)));
    Ok(accounts)
}

/// Adds or updates a cookie account and records a synced setting op.
pub fn save(lib: &Library, input: CookieSaveInput) -> anyhow::Result<CookieAccount> {
    let auth_token = input.auth_token.trim().to_string();
    let ct0 = input.ct0.trim().to_string();
    if auth_token.is_empty() || ct0.is_empty() {
        bail!(tr!("protected.noCookie"));
    }
    let label = input.label.trim().chars().take(80).collect::<String>();
    let screen_name = input
        .screen_name
        .as_deref()
        .map(|s| s.trim().trim_start_matches('@'))
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(64).collect::<String>());

    let id = match input.id.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some(existing) if valid_id(existing) => existing.to_string(),
        Some(_) => bail!("invalid cookie id"),
        None => hex::encode(rand::random::<[u8; 8]>()),
    };

    let key = format!("{ACCOUNT_PREFIX}{id}");
    let db = lib.db();
    let existing_created = db
        .setting(&key)?
        .and_then(|v| serde_json::from_str::<CookieAccount>(&v).ok())
        .map(|a| a.created_at)
        .filter(|&t| t > 0);

    let account = CookieAccount {
        id,
        label,
        auth_token,
        ct0,
        screen_name,
        created_at: existing_created.unwrap_or_else(crate::store::now_ms),
    };
    db.set_setting(&key, Some(&serde_json::to_string(&account)?))?;
    Ok(account)
}

/// Deletes a cookie account (records a synced `None` tombstone).
pub fn delete(lib: &Library, id: &str) -> anyhow::Result<bool> {
    let id = id.trim();
    if !valid_id(id) {
        return Ok(false);
    }
    let key = format!("{ACCOUNT_PREFIX}{id}");
    let db = lib.db();
    let existed = db.setting(&key)?.is_some();
    db.set_setting(&key, None)?;
    Ok(existed)
}

pub fn get_author_cache(lib: &Library, author: &str) -> anyhow::Result<Option<AuthorCookieCache>> {
    let Some(author) = author_key(author) else { return Ok(None) };
    let key = format!("{AUTHOR_CACHE_PREFIX}{author}");
    let Some(raw) = lib.db().setting(&key)? else { return Ok(None) };
    Ok(serde_json::from_str(&raw).ok())
}

fn write_author_cache_key(lib: &Library, author: &str, cookie_id: &str, now_ms: u64) -> anyhow::Result<()> {
    let key = format!("{AUTHOR_CACHE_PREFIX}{author}");
    let db = lib.db();
    if let Some(prev) = db.setting(&key)?.and_then(|v| serde_json::from_str::<AuthorCookieCache>(&v).ok()) {
        if prev.cookie_id == cookie_id
            && now_ms >= prev.last_used_ms
            && now_ms.saturating_sub(prev.last_used_ms) < CACHE_TOUCH_MIN_INTERVAL_MS
        {
            return Ok(());
        }
    }
    let entry = AuthorCookieCache { cookie_id: cookie_id.to_string(), last_used_ms: now_ms };
    db.set_setting(&key, Some(&serde_json::to_string(&entry)?))?;
    Ok(())
}

/// Records `author -> cookie_id` (and `last_used_ms`) in the synced setting store.
pub fn record_author_cache(
    lib: &Library,
    url_author: Option<&str>,
    post_screen_name: Option<&str>,
    cookie_id: &str,
    now_ms: u64,
) -> anyhow::Result<()> {
    let a1 = url_author.and_then(author_key);
    let a2 = post_screen_name.and_then(author_key);
    if let Some(ref a) = a1 {
        write_author_cache_key(lib, a, cookie_id, now_ms)?;
    }
    if let Some(ref a) = a2 {
        if a1.as_deref() != Some(a.as_str()) {
            write_author_cache_key(lib, a, cookie_id, now_ms)?;
        }
    }
    Ok(())
}

/// Resolves a post using the live FxTwitter and X GraphQL fetchers.
pub async fn fetch_post(lib: Option<&Library>, url: &str, route: Route) -> anyhow::Result<RemotePost> {
    let now_ms = crate::store::now_ms();
    resolve_post_with(
        lib,
        url,
        route,
        now_ms,
        |u| async move { net::fetch_fx(&u).await },
        |u, creds| async move { crate::protected::fetch_post(&u, &creds).await },
    )
    .await
}

async fn try_cookies_in_order<CkF, CkFut>(
    lib: Option<&Library>,
    url: &str,
    url_author: Option<&str>,
    order: Vec<CookieAccount>,
    now_ms: u64,
    cookie_fn: &mut CkF,
) -> Result<RemotePost, ProtectedError>
where
    CkF: FnMut(String, Credentials) -> CkFut,
    CkFut: Future<Output = Result<RemotePost, ProtectedError>>,
{
    let mut last_err: Option<ProtectedError> = None;
    for acc in order {
        match cookie_fn(url.to_string(), acc.credentials()).await {
            Ok(post) if !post.media.is_empty() => {
                if let Some(l) = lib {
                    let _ = record_author_cache(l, url_author, post.meta.screen_name.as_deref(), &acc.id, now_ms);
                }
                return Ok(post);
            }
            Ok(_) | Err(ProtectedError::NoMedia) => {
                // X returned the post itself and confirmed it contains no media; other cookies won't add media.
                return Err(ProtectedError::NoMedia);
            }
            Err(e) => {
                last_err = Some(e);
            }
        }
    }
    Err(last_err.unwrap_or_else(|| ProtectedError::Other(tr!("protected.noCookie"))))
}

fn cookie_attempt_order(accounts: Vec<CookieAccount>, cached: Option<CookieAccount>) -> Vec<CookieAccount> {
    let Some(first) = cached else { return accounts };
    let mut order = Vec::with_capacity(accounts.len());
    let first_id = first.id.clone();
    order.push(first);
    for acc in accounts {
        if acc.id != first_id {
            order.push(acc);
        }
    }
    order
}

/// Core multi-cookie routing state machine (injectable fetchers and clock for deterministic tests):
///
/// - `Route::Fx`: FxTwitter only, never touches cookies or cache.
/// - `Route::Cookie`: skips FxTwitter; tries cached cookie first (if still present), then remaining
///   cookies; updates synced author cache on success; fails cleanly if all fail.
/// - `Route::Auto`:
///   - If the author has a live cached cookie used within the last 24 hours: skips FxTwitter, tries
///     the cached cookie first, then remaining cookies; updates synced author cache on success;
///     fails cleanly if all fail.
///   - Otherwise (no cache, cached cookie deleted, or >= 24h elapsed): tries FxTwitter first (if
///     FxTwitter succeeds, returns immediately without modifying cache); if FxTwitter fails, tries
///     the cached cookie (if still live) first, then remaining cookies; updates synced author cache
///     on success; fails cleanly if all fail (never reporting that a cached cookie was deleted).
pub async fn resolve_post_with<FxF, FxFut, CkF, CkFut>(
    lib: Option<&Library>,
    url: &str,
    route: Route,
    now_ms: u64,
    mut fx_fn: FxF,
    mut cookie_fn: CkF,
) -> anyhow::Result<RemotePost>
where
    FxF: FnMut(String) -> FxFut,
    FxFut: Future<Output = anyhow::Result<RemotePost>>,
    CkF: FnMut(String, Credentials) -> CkFut,
    CkFut: Future<Output = Result<RemotePost, ProtectedError>>,
{
    if route == Route::Fx {
        let post = fx_fn(url.to_string()).await?;
        if post.media.is_empty() {
            bail!(tr!("download.noMedia"));
        }
        return Ok(post);
    }

    let accounts = match lib {
        Some(l) => list(l)?,
        None => vec![],
    };
    let url_author = author_key_from_url(url);
    let cache = match (lib, url_author.as_deref()) {
        (Some(l), Some(author)) => get_author_cache(l, author).ok().flatten(),
        _ => None,
    };
    let cached_account = cache
        .as_ref()
        .and_then(|c| accounts.iter().find(|a| a.id == c.cookie_id).cloned());

    if route == Route::Cookie {
        if accounts.is_empty() {
            bail!(tr!("download.noCookie"));
        }
        let order = cookie_attempt_order(accounts, cached_account);
        return match try_cookies_in_order(lib, url, url_author.as_deref(), order, now_ms, &mut cookie_fn).await {
            Ok(post) => Ok(post),
            Err(ProtectedError::NoMedia) => bail!(tr!("download.noMedia")),
            Err(e) => bail!("{e}"),
        };
    }

    // Route::Auto
    let use_cache_directly = matches!(
        (&cache, &cached_account),
        (Some(entry), Some(_)) if now_ms.saturating_sub(entry.last_used_ms) < AUTHOR_CACHE_FRESH_MS
    );

    if use_cache_directly {
        let order = cookie_attempt_order(accounts, cached_account);
        return match try_cookies_in_order(lib, url, url_author.as_deref(), order, now_ms, &mut cookie_fn).await {
            Ok(post) => Ok(post),
            Err(ProtectedError::NoMedia) => bail!(tr!("download.noMedia")),
            Err(e) => bail!("{e}"),
        };
    }

    // No fresh live cache: probe FxTwitter first (the author may be public or unlocked).
    match fx_fn(url.to_string()).await {
        Ok(post) if !post.media.is_empty() => Ok(post),
        first => {
            if accounts.is_empty() {
                first?;
                bail!(tr!("download.noMediaMaybeLocked"));
            }
            let order = cookie_attempt_order(accounts, cached_account);
            match try_cookies_in_order(lib, url, url_author.as_deref(), order, now_ms, &mut cookie_fn).await {
                Ok(post) => Ok(post),
                Err(ProtectedError::NoMedia) => bail!(tr!("download.noMedia")),
                Err(e) => Err(anyhow!(tr!("download.bothFailed", e = e))),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{MediaKind, PostMeta};
    use crate::net::RemoteMedia;
    use std::sync::{Arc, Mutex};

    fn temp_lib(name: &str) -> (std::path::PathBuf, Library) {
        let dir = std::env::temp_dir().join(format!("tl-cookies-{name}-{}", rand::random::<u64>()));
        let lib = Library::open(&dir).unwrap();
        (dir, lib)
    }

    fn sample_post(id: &str, author: &str) -> RemotePost {
        RemotePost {
            meta: PostMeta {
                id: id.into(),
                author_name: Some(author.into()),
                screen_name: Some(author.into()),
                text: Some("hello".into()),
                created_at: None,
                url: Some(format!("https://x.com/{author}/status/{id}")),
            },
            media: vec![RemoteMedia {
                kind: MediaKind::Photo,
                url: format!("https://pbs.twimg.com/media/{id}.jpg?name=orig"),
                headers: vec![],
            }],
        }
    }

    fn add_cookie(lib: &Library, id: &str, label: &str, token: &str) -> CookieAccount {
        save(
            lib,
            CookieSaveInput {
                id: Some(id.into()),
                label: label.into(),
                auth_token: token.into(),
                ct0: format!("ct0-{token}"),
                screen_name: Some(label.into()),
            },
        )
        .unwrap()
    }

    #[test]
    fn crud_and_deterministic_ordering() {
        let (dir, lib) = temp_lib("crud");
        assert!(list(&lib).unwrap().is_empty());

        let a = save(
            &lib,
            CookieSaveInput { id: None, label: "Alpha".into(), auth_token: "tok-a".into(), ct0: "ct0-a".into(), screen_name: Some("@alpha_x".into()) },
        )
        .unwrap();
        assert_eq!(a.screen_name.as_deref(), Some("alpha_x"));
        assert!(!a.id.is_empty());

        let b = save(
            &lib,
            CookieSaveInput { id: None, label: "Beta".into(), auth_token: "tok-b".into(), ct0: "ct0-b".into(), screen_name: None },
        )
        .unwrap();

        let all = list(&lib).unwrap();
        assert_eq!(all.len(), 2);

        // Updating preserves created_at and updates fields
        let updated = save(
            &lib,
            CookieSaveInput { id: Some(a.id.clone()), label: "Alpha 2".into(), auth_token: "tok-a2".into(), ct0: "ct0-a2".into(), screen_name: Some("alpha2".into()) },
        )
        .unwrap();
        assert_eq!(updated.id, a.id);
        assert_eq!(updated.created_at, a.created_at);
        assert_eq!(updated.label, "Alpha 2");

        // Empty token/ct0 rejected
        assert!(save(&lib, CookieSaveInput { id: None, label: "".into(), auth_token: " ".into(), ct0: "c".into(), screen_name: None }).is_err());
        assert!(save(&lib, CookieSaveInput { id: None, label: "".into(), auth_token: "a".into(), ct0: "".into(), screen_name: None }).is_err());

        assert!(delete(&lib, &a.id).unwrap());
        let after = list(&lib).unwrap();
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].id, b.id);

        drop(lib);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn auto_learns_cache_skips_fx_within_24h_and_reprobes_fx_after_24h() {
        let (dir, lib) = temp_lib("auto-flow");
        let alpha = add_cookie(&lib, "c1_alpha", "alpha", "tok_alpha");
        let beta = add_cookie(&lib, "c2_beta", "beta", "tok_beta");
        let url = "https://x.com/AuthorA/status/1001";
        let t0 = 1_700_000_000_000u64;

        // 1. First download (no cache): Fx fails -> tries alpha (fails) -> tries beta (succeeds) -> caches authora -> beta.
        let calls: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let c1 = calls.clone();
        let c2 = calls.clone();
        let post = resolve_post_with(
            Some(&lib),
            url,
            Route::Auto,
            t0,
            move |_| {
                let c1 = c1.clone();
                async move {
                    c1.lock().unwrap().push("fx".into());
                    Err(anyhow!("locked"))
                }
            },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    if creds.auth_token == "tok_beta" {
                        Ok(sample_post("1001", "AuthorA"))
                    } else {
                        Err(ProtectedError::NotFound("not following".into()))
                    }
                }
            },
        )
        .await
        .unwrap();
        assert_eq!(post.meta.id, "1001");
        assert_eq!(*calls.lock().unwrap(), vec!["fx", "tok_alpha", "tok_beta"]);
        let cached = get_author_cache(&lib, "authora").unwrap().unwrap();
        assert_eq!(cached.cookie_id, beta.id);
        assert_eq!(cached.last_used_ms, t0);

        // 2. Second download 2 hours later (< 24h): skips Fx completely, goes straight to beta!
        calls.lock().unwrap().clear();
        let t1 = t0 + 2 * 3600 * 1000;
        let c1 = calls.clone();
        let c2 = calls.clone();
        let post2 = resolve_post_with(
            Some(&lib),
            "https://x.com/authora/status/1002",
            Route::Auto,
            t1,
            move |_| {
                let c1 = c1.clone();
                async move {
                    c1.lock().unwrap().push("fx".into());
                    Ok(sample_post("1002", "AuthorA"))
                }
            },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    if creds.auth_token == "tok_beta" {
                        Ok(sample_post("1002", "AuthorA"))
                    } else {
                        Err(ProtectedError::NotFound("nope".into()))
                    }
                }
            },
        )
        .await
        .unwrap();
        assert_eq!(post2.meta.id, "1002");
        assert_eq!(*calls.lock().unwrap(), vec!["tok_beta"]);
        assert_eq!(get_author_cache(&lib, "authora").unwrap().unwrap().last_used_ms, t1);

        // 3. Third download 25 hours after t1 (>= 24h), author STILL locked: tries Fx first, then cached beta first (NOT alpha!).
        calls.lock().unwrap().clear();
        let t2 = t1 + 25 * 3600 * 1000;
        let c1 = calls.clone();
        let c2 = calls.clone();
        let post3 = resolve_post_with(
            Some(&lib),
            "https://x.com/AuthorA/status/1003",
            Route::Auto,
            t2,
            move |_| {
                let c1 = c1.clone();
                async move {
                    c1.lock().unwrap().push("fx".into());
                    Err(anyhow!("still locked"))
                }
            },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    if creds.auth_token == "tok_beta" {
                        Ok(sample_post("1003", "AuthorA"))
                    } else {
                        Err(ProtectedError::NotFound("nope".into()))
                    }
                }
            },
        )
        .await
        .unwrap();
        assert_eq!(post3.meta.id, "1003");
        assert_eq!(*calls.lock().unwrap(), vec!["fx", "tok_beta"]);
        assert_eq!(get_author_cache(&lib, "authora").unwrap().unwrap().last_used_ms, t2);

        // 4. Fourth download 25 hours after t2 (>= 24h), author UNLOCKED: Fx succeeds, zero cookie calls, cache kept intact!
        calls.lock().unwrap().clear();
        let t3 = t2 + 25 * 3600 * 1000;
        let c1 = calls.clone();
        let c2 = calls.clone();
        let post4 = resolve_post_with(
            Some(&lib),
            "https://x.com/AuthorA/status/1004",
            Route::Auto,
            t3,
            move |_| {
                let c1 = c1.clone();
                async move {
                    c1.lock().unwrap().push("fx".into());
                    Ok(sample_post("1004", "AuthorA"))
                }
            },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    Err(ProtectedError::NotFound("should not be called".into()))
                }
            },
        )
        .await
        .unwrap();
        assert_eq!(post4.meta.id, "1004");
        assert_eq!(*calls.lock().unwrap(), vec!["fx"]);
        // Cache untouched (still points to beta at t2)
        assert_eq!(get_author_cache(&lib, "authora").unwrap().unwrap().cookie_id, beta.id);

        // 5. Within 24h of t2: if cached cookie (beta) suddenly fails, falls back to remaining cookies (alpha) and updates cache!
        calls.lock().unwrap().clear();
        let t4 = t2 + 3 * 3600 * 1000;
        let c1 = calls.clone();
        let c2 = calls.clone();
        let post5 = resolve_post_with(
            Some(&lib),
            "https://x.com/AuthorA/status/1005",
            Route::Auto,
            t4,
            move |_| {
                let c1 = c1.clone();
                async move {
                    c1.lock().unwrap().push("fx".into());
                    Err(anyhow!("locked"))
                }
            },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    if creds.auth_token == "tok_alpha" {
                        Ok(sample_post("1005", "AuthorA"))
                    } else {
                        Err(ProtectedError::Unauthorized("expired".into()))
                    }
                }
            },
        )
        .await
        .unwrap();
        assert_eq!(post5.meta.id, "1005");
        assert_eq!(*calls.lock().unwrap(), vec!["tok_beta", "tok_alpha"]);
        let updated_cache = get_author_cache(&lib, "authora").unwrap().unwrap();
        assert_eq!(updated_cache.cookie_id, alpha.id);
        assert_eq!(updated_cache.last_used_ms, t4);

        drop(lib);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn deleted_cached_cookie_is_handled_silently_without_error_mentioning_removal() {
        let (dir, lib) = temp_lib("deleted-cache");
        let alpha = add_cookie(&lib, "c1_alpha", "alpha", "tok_alpha");
        let beta = add_cookie(&lib, "c2_beta", "beta", "tok_beta");
        let t0 = 1_700_000_000_000u64;

        // Seed cache pointing to beta, then delete beta!
        record_author_cache(&lib, Some("AuthorB"), None, &beta.id, t0).unwrap();
        assert!(delete(&lib, &beta.id).unwrap());

        // Case A: Remaining cookie (alpha) works -> Fx fails, tries alpha, updates cache to alpha.
        let calls: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let c1 = calls.clone();
        let c2 = calls.clone();
        let post = resolve_post_with(
            Some(&lib),
            "https://x.com/AuthorB/status/2001",
            Route::Auto,
            t0 + 10_000,
            move |_| {
                let c1 = c1.clone();
                async move {
                    c1.lock().unwrap().push("fx".into());
                    Err(anyhow!("locked"))
                }
            },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    Ok(sample_post("2001", "AuthorB"))
                }
            },
        )
        .await
        .unwrap();
        assert_eq!(post.meta.id, "2001");
        assert_eq!(*calls.lock().unwrap(), vec!["fx", "tok_alpha"]);
        assert_eq!(get_author_cache(&lib, "authorb").unwrap().unwrap().cookie_id, alpha.id);

        // Case B: Delete alpha too so NO cookies remain -> clean download failure, never mentions removed account.
        assert!(delete(&lib, &alpha.id).unwrap());
        let err = resolve_post_with(
            Some(&lib),
            "https://x.com/AuthorB/status/2002",
            Route::Auto,
            t0 + 20_000,
            |_| async { Err(anyhow!("FxTwitter: not found")) },
            |_, _| async { unreachable!("no cookies left") },
        )
        .await
        .unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("FxTwitter"), "unexpected error: {msg}");
        assert!(!msg.contains("c1_alpha") && !msg.contains("removed") && !msg.contains("deleted"));

        drop(lib);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn cookie_only_route_never_calls_fx_and_uses_cache_first() {
        let (dir, lib) = temp_lib("cookie-only");
        let _alpha = add_cookie(&lib, "c1_alpha", "alpha", "tok_alpha");
        let beta = add_cookie(&lib, "c2_beta", "beta", "tok_beta");
        let t0 = 1_700_000_000_000u64;
        // Cache is OLDER than 24h — Cookie route STILL skips Fx and tries cached beta first!
        record_author_cache(&lib, Some("AuthorC"), None, &beta.id, t0).unwrap();

        let calls: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let c2 = calls.clone();
        let post = resolve_post_with(
            Some(&lib),
            "https://x.com/AuthorC/status/3001",
            Route::Cookie,
            t0 + 72 * 3600 * 1000,
            |_| async { panic!("Cookie route must never call FxTwitter") },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    if creds.auth_token == "tok_beta" {
                        Ok(sample_post("3001", "AuthorC"))
                    } else {
                        Err(ProtectedError::NotFound("no".into()))
                    }
                }
            },
        )
        .await
        .unwrap();
        assert_eq!(post.meta.id, "3001");
        assert_eq!(*calls.lock().unwrap(), vec!["tok_beta"]);

        // If all cookies fail in Cookie mode, returns error cleanly without touching Fx.
        calls.lock().unwrap().clear();
        let c2 = calls.clone();
        let err = resolve_post_with(
            Some(&lib),
            "https://x.com/AuthorC/status/3002",
            Route::Cookie,
            t0 + 73 * 3600 * 1000,
            |_| async { panic!("Cookie route must never call FxTwitter") },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    Err(ProtectedError::NotFound("cannot view".into()))
                }
            },
        )
        .await
        .unwrap_err();
        assert!(!err.to_string().is_empty());
        assert_eq!(*calls.lock().unwrap(), vec!["tok_beta", "tok_alpha"]);

        drop(lib);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn fx_only_route_never_touches_cookies_or_cache() {
        let (dir, lib) = temp_lib("fx-only");
        let beta = add_cookie(&lib, "c2_beta", "beta", "tok_beta");
        let t0 = 1_700_000_000_000u64;
        record_author_cache(&lib, Some("AuthorD"), None, &beta.id, t0).unwrap();

        let post = resolve_post_with(
            Some(&lib),
            "https://x.com/AuthorD/status/4001",
            Route::Fx,
            t0 + 1000,
            |_| async { Ok(sample_post("4001", "AuthorD")) },
            |_, _| async { panic!("Fx route must never call cookies") },
        )
        .await
        .unwrap();
        assert_eq!(post.meta.id, "4001");

        drop(lib);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn cookies_and_author_cache_sync_between_devices_via_oplog() {
        let (dir_a, lib_a) = temp_lib("sync-a");
        let (dir_b, lib_b) = temp_lib("sync-b");
        let t0 = 1_700_000_000_000u64;

        // Device A adds two cookies and learns AuthorS -> beta via Auto download
        let alpha = add_cookie(&lib_a, "c_alpha", "Alpha", "tok_alpha");
        let beta = add_cookie(&lib_a, "c_beta", "Beta", "tok_beta");
        resolve_post_with(
            Some(&lib_a),
            "https://x.com/AuthorS/status/5001",
            Route::Auto,
            t0,
            |_| async { Err(anyhow!("locked")) },
            |_, creds| async move {
                if creds.auth_token == "tok_beta" {
                    Ok(sample_post("5001", "AuthorS"))
                } else {
                    Err(ProtectedError::NotFound("no".into()))
                }
            },
        )
        .await
        .unwrap();

        // Sync Device A's oplog -> Device B
        let vv_b = lib_b.db().version_vector().unwrap();
        let ops = lib_a.db().ops_since(&vv_b, 1000).unwrap();
        assert!(!ops.is_empty());
        lib_b.db().apply_remote(&ops, |_, _| false).unwrap();

        // Device B now has both cookies AND the author cache for AuthorS!
        let b_cookies = list(&lib_b).unwrap();
        assert_eq!(b_cookies.len(), 2);
        assert_eq!(b_cookies[0].id, alpha.id);
        assert_eq!(b_cookies[1].id, beta.id);
        let b_cache = get_author_cache(&lib_b, "authors").unwrap().unwrap();
        assert_eq!(b_cache.cookie_id, beta.id);

        // Device B downloads another post from AuthorS 1 hour later: skips Fx and uses beta directly!
        let calls: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let c2 = calls.clone();
        resolve_post_with(
            Some(&lib_b),
            "https://x.com/AuthorS/status/5002",
            Route::Auto,
            t0 + 3600 * 1000,
            |_| async { panic!("Device B should skip Fx because synced cache is < 24h old") },
            move |_, creds| {
                let c2 = c2.clone();
                async move {
                    c2.lock().unwrap().push(creds.auth_token.clone());
                    Ok(sample_post("5002", "AuthorS"))
                }
            },
        )
        .await
        .unwrap();
        assert_eq!(*calls.lock().unwrap(), vec!["tok_beta"]);

        // Device B deletes beta -> sync back to Device A -> Device A no longer sees beta!
        delete(&lib_b, &beta.id).unwrap();
        let vv_a = lib_a.db().version_vector().unwrap();
        let back_ops = lib_b.db().ops_since(&vv_a, 1000).unwrap();
        lib_a.db().apply_remote(&back_ops, |_, _| false).unwrap();

        let a_after = list(&lib_a).unwrap();
        assert_eq!(a_after.len(), 1);
        assert_eq!(a_after[0].id, alpha.id);

        drop(lib_a);
        drop(lib_b);
        std::fs::remove_dir_all(dir_a).unwrap();
        std::fs::remove_dir_all(dir_b).unwrap();
    }

    #[tokio::test]
    async fn generic_i_status_url_still_caches_discovered_screen_name() {
        let (dir, lib) = temp_lib("generic-url");
        let alpha = add_cookie(&lib, "c_alpha", "Alpha", "tok_alpha");
        let t0 = 1_700_000_000_000u64;

        resolve_post_with(
            Some(&lib),
            "https://x.com/i/status/6001",
            Route::Auto,
            t0,
            |_| async { Err(anyhow!("locked")) },
            |_, _| async { Ok(sample_post("6001", "RealLockedAuthor")) },
        )
        .await
        .unwrap();

        // Must NOT pollute cache with "i", MUST cache "reallockedauthor"!
        assert!(get_author_cache(&lib, "i").unwrap().is_none());
        let cached = get_author_cache(&lib, "RealLockedAuthor").unwrap().unwrap();
        assert_eq!(cached.cookie_id, alpha.id);

        drop(lib);
        std::fs::remove_dir_all(dir).unwrap();
    }
}

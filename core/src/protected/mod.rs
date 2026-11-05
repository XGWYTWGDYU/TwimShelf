//! Posts of protected (locked) accounts, which the public mirror cannot reach: fetched with the
//! user's X session cookies, the way x.com's own web client asks for them (GraphQL `TweetDetail`;
//! the session is checked with `Viewer`, then the v1.1 account endpoints).
//!
//!   fetch.rs   the two operations (blocking: called on worker threads, several at once)
//!   http.rs    requests and the cookies; ops.rs the GraphQL operation ids (read from x.com's
//!              scripts, cached); parse.rs the answers; error.rs X's errors as messages;
//!              date.rs, urlx.rs X's dates and links; tests.rs + ../../tests/data/ offline tests
//!
//! Messages are `protected.*` in core/messages.json; nothing here ever logs the cookies.
#![forbid(unsafe_code)]

mod date;
mod error;
mod fetch;
mod http;
mod ops;
mod parse;
mod urlx;
#[cfg(test)]
mod tests;

use crate::net::{RemoteMedia, RemotePost};

/// The user's X session, as entered in Settings (never logged, never sent anywhere but x.com).
#[derive(Clone, PartialEq, Eq)]
pub struct Credentials {
    /// `auth_token` cookie.
    pub auth_token: String,
    /// `ct0` cookie (also the CSRF token).
    pub ct0: String,
}

impl std::fmt::Debug for Credentials {
    // never print the secrets
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str("Credentials { .. }") }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind { Photo, Video }

/// One photo or video of the post, in the post's order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtectedMedia {
    pub kind: MediaKind,
    /// Direct URL of the best quality: the original photo (`…?name=orig`), the highest-bitrate
    /// MP4 for videos and GIFs (never an HLS playlist).
    pub url: String,
    /// Extra HTTP headers the core must send to download `url` (usually none: the media CDN
    /// is public). Never put the cookies here unless the download really requires them.
    pub headers: Vec<(String, String)>,
}

/// A post. Text is the full text with trailing media links (`https://t.co/…` of the media)
/// removed; times are UTC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtectedPost {
    /// Numeric status id ("1900000000000000001").
    pub id: String,
    pub author_name: Option<String>,
    /// Without "@".
    pub screen_name: Option<String>,
    pub text: Option<String>,
    /// "YYYY-MM-DD HH:MM:SS +0000".
    pub created_at: Option<String>,
    /// Canonical link: "https://x.com/<screen_name>/status/<id>".
    pub url: Option<String>,
    pub media: Vec<ProtectedMedia>,
}

/// The signed-in account (for "检查 Cookie" in Settings).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account { pub screen_name: String, pub name: Option<String> }

/// Why a fetch failed. The message is shown to the user (in the app's language: built with
/// `tr!` from `protected.*` in core/messages.json) and written to the app's problem
/// log, so it must never contain the cookies.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtectedError {
    /// The cookies are missing, expired or rejected (HTTP 401/403 for the session).
    Unauthorized(String),
    /// The post does not exist, was deleted, or the account cannot see it.
    NotFound(String),
    /// Rate limited; retry after this many seconds if known.
    RateLimited { retry_after_secs: Option<u64> },
    /// The post exists but has no photo or video.
    NoMedia,
    /// Network or timeout (the core retries these).
    Network(String),
    /// Anything else (e.g. the response format changed).
    Other(String),
}

impl std::fmt::Display for ProtectedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unauthorized(m) => f.write_str(&tr!("protected.unauthorized", m = m)),
            Self::NotFound(m) => f.write_str(&tr!("protected.notFound", m = m)),
            Self::RateLimited { retry_after_secs: Some(s) } => f.write_str(&tr!("protected.rateLimitedFor", s = s)),
            Self::RateLimited { retry_after_secs: None } => f.write_str(&tr!("protected.rateLimited")),
            Self::NoMedia => f.write_str(&tr!("protected.noMedia")),
            Self::Network(m) => f.write_str(&tr!("protected.network", m = m)),
            Self::Other(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for ProtectedError {}


/// Converts a fetched post into the core's.
pub fn to_remote(p: ProtectedPost) -> RemotePost {
    RemotePost {
        meta: crate::model::PostMeta { id: p.id, author_name: p.author_name, screen_name: p.screen_name, text: p.text, created_at: p.created_at, url: p.url },
        media: p.media.into_iter().map(|m| RemoteMedia {
            kind: match m.kind { MediaKind::Photo => crate::model::MediaKind::Photo, MediaKind::Video => crate::model::MediaKind::Video },
            url: m.url, headers: m.headers,
        }).collect(),
    }
}

/// Fetches a post (off the async runtime's threads).
pub async fn fetch_post(url: &str, creds: &Credentials) -> Result<RemotePost, ProtectedError> {
    let (u, c) = (url.to_string(), creds.clone());
    match tokio::task::spawn_blocking(move || fetch::fetch_post(&u, &c)).await {
        Ok(r) => r.map(to_remote),
        Err(e) => Err(ProtectedError::Other(tr!("protected.crashed", e = e))),
    }
}

/// Checks the cookies (Settings → 检查 Cookie).
pub fn check(creds: &Credentials) -> Result<Account, ProtectedError> { fetch::check_credentials(creds) }


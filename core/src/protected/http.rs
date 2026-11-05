//! HTTP plumbing shared by the two public functions.
//!
//! The module uses `reqwest::blocking`, which owns its Tokio runtime on a background thread. That
//! is important: the core calls us from `spawn_blocking` workers and there is no runtime on the
//! calling thread. One client is shared by every call; `reqwest::blocking::Client` is `Send` and
//! `Sync` and keeps a connection pool, so sixteen concurrent calls are fine.

use std::sync::OnceLock;
use std::time::Duration;

use reqwest::blocking::Client;
use super::{Credentials, ProtectedError};

/// The public bearer token of the X web client. It is not a secret and is the same for everyone.
pub(crate) const BEARER: &str = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// The only two cookies the interface gives us. Kept in a type without `Debug` on purpose.
pub(crate) struct Cookies {
    auth_token: String,
    ct0: String,
}

impl Cookies {
    pub(crate) fn new(credentials: &Credentials) -> Result<Self, ProtectedError> {
        let auth_token = credentials.auth_token.trim();
        let ct0 = credentials.ct0.trim();
        if auth_token.is_empty() || ct0.is_empty() {
            return Err(ProtectedError::Unauthorized(
                tr!("protected.noCookie"),
            ));
        }
        if !valid_cookie_value(auth_token) || !valid_cookie_value(ct0) {
            return Err(ProtectedError::Unauthorized(
                tr!("protected.badCookie"),
            ));
        }
        Ok(Self {
            auth_token: auth_token.to_string(),
            ct0: ct0.to_string(),
        })
    }

    /// The `Cookie:` header. Never put this in a log or an error message.
    pub(crate) fn header(&self) -> String {
        format!("auth_token={}; ct0={}", self.auth_token, self.ct0)
    }

    /// Removes the two secrets from text that came from the server before it is shown to the user.
    pub(crate) fn scrub(&self, text: &str) -> String {
        let mut out = text.to_string();
        for secret in [&self.auth_token, &self.ct0] {
            if !secret.is_empty() {
                out = out.replace(secret.as_str(), &tr!("protected.hidden"));
            }
        }
        out
    }
}

fn valid_cookie_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 4096
        && !value
            .chars()
            .any(|c| c == '\r' || c == '\n' || c == ';' || c == '\0' || c.is_control())
}

/// One shared blocking client.
pub(crate) fn client() -> Result<&'static Client, ProtectedError> {
    static CLIENT: OnceLock<Result<Client, String>> = OnceLock::new();
    match CLIENT.get_or_init(|| {
        Client::builder()
            .user_agent(USER_AGENT)
            .timeout(Duration::from_secs(15))
            .connect_timeout(Duration::from_secs(6))
            .redirect(reqwest::redirect::Policy::limited(5))
            .gzip(true)
            .build()
            .map_err(|e| e.without_url().to_string())
    }) {
        Ok(client) => Ok(client),
        Err(e) => Err(ProtectedError::Other(tr!("protected.netInit", e = e))),
    }
}

/// Headers every x.com API request needs.
pub(crate) fn api_headers(cookies: &Cookies) -> Vec<(String, String)> {
    vec![
        ("accept".into(), "*/*".into()),
        ("accept-language".into(), "en-US,en;q=0.9".into()),
        ("authorization".into(), format!("Bearer {BEARER}")),
        ("cookie".into(), cookies.header()),
        ("referer".into(), "https://x.com/".into()),
        ("user-agent".into(), USER_AGENT.into()),
        ("x-csrf-token".into(), cookies.ct0.clone()),
        ("x-twitter-active-user".into(), "yes".into()),
        ("x-twitter-auth-type".into(), "OAuth2Session".into()),
        ("x-twitter-client-language".into(), "en".into()),
    ]
}

/// The media CDN only checks the session for posts of protected accounts.
pub(crate) fn media_headers(cookies: &Cookies) -> Vec<(String, String)> {
    vec![("Cookie".into(), cookies.header())]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Method {
    Get,
    Post,
}

#[derive(Debug, Clone)]
pub(crate) struct HttpRequest {
    pub method: Method,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
    pub timeout: Duration,
}

#[derive(Debug, Clone)]
pub(crate) struct HttpResponse {
    pub status: u16,
    /// Lower-case header names.
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl HttpResponse {
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

#[derive(Debug, Clone)]
pub(crate) enum HttpError {
    Timeout,
    Connect(String),
    Other(String),
}

impl HttpError {
    pub(crate) fn into_protected(self) -> ProtectedError {
        let detail = match self {
            HttpError::Timeout => tr!("protected.timeout"),
            HttpError::Connect(m) => tr!("protected.connect", m = truncate(&m, 160)),
            HttpError::Other(m) => tr!("protected.requestFailed", m = truncate(&m, 160)),
        };
        ProtectedError::Network(detail)
    }
}

pub(crate) trait Transport: Sync {
    fn send(&self, request: &HttpRequest) -> Result<HttpResponse, HttpError>;
}

pub(crate) struct ReqwestTransport {
    client: &'static Client,
}

impl ReqwestTransport {
    pub(crate) fn new(client: &'static Client) -> Self {
        Self { client }
    }
}

impl Transport for ReqwestTransport {
    fn send(&self, request: &HttpRequest) -> Result<HttpResponse, HttpError> {
        let mut builder = match request.method {
            Method::Get => self.client.get(&request.url),
            Method::Post => self.client.post(&request.url),
        };
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        if let Some(body) = &request.body {
            builder = builder.body(body.clone());
        }
        let response = builder.timeout(request.timeout).send().map_err(|e| {
            let timeout = e.is_timeout();
            let connect = e.is_connect();
            let message = e.without_url().to_string();
            if timeout {
                HttpError::Timeout
            } else if connect {
                HttpError::Connect(message)
            } else {
                HttpError::Other(message)
            }
        })?;
        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .map(|(name, value)| {
                (
                    name.as_str().to_ascii_lowercase(),
                    String::from_utf8_lossy(value.as_bytes()).into_owned(),
                )
            })
            .collect();
        let body = response.text().unwrap_or_default();
        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }
}

pub(crate) fn truncate(text: &str, max_chars: usize) -> String {
    let mut out = String::new();
    for (i, ch) in text.chars().enumerate() {
        if i >= max_chars {
            out.push('…');
            break;
        }
        out.push(if ch.is_control() && ch != '\n' && ch != '\t' {
            ' '
        } else {
            ch
        });
    }
    out
}

pub(crate) fn now_secs() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

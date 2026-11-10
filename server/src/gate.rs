//! Who gets in: the local network only (unless `TL_ALLOW_PUBLIC`), and only after signing in —
//! except the browser extension's requests, which carry a token of their own (see the core's
//! `extension.rs`).
use crate::{Config, Shared};
use axum::extract::{ConnectInfo, Form, Query, Request, State};
use axum::http::{header, HeaderMap, HeaderValue, Method, StatusCode};
use axum::middleware::Next;
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::net::{IpAddr, SocketAddr};
use std::time::{Duration, Instant};
use tl_core::extension;

/// Every address the request came from: the connection, and what proxies in front said
/// (`X-Forwarded-For`, `X-Real-IP`, `CF-Connecting-IP`, `Forwarded`).
fn origins(peer: IpAddr, headers: &HeaderMap) -> Vec<IpAddr> {
    let mut v = vec![peer];
    let text = |n: &str| headers.get_all(n).iter().filter_map(|h| h.to_str().ok()).map(str::to_string).collect::<Vec<_>>();
    for n in ["x-forwarded-for", "x-real-ip", "cf-connecting-ip", "true-client-ip"] {
        for h in text(n) { v.extend(h.split(',').filter_map(|s| s.trim().parse::<IpAddr>().ok())); }
    }
    for h in text("forwarded") {
        for part in h.split([',', ';']) {
            if let Some(f) = part.trim().strip_prefix("for=").or_else(|| part.trim().strip_prefix("For=")) {
                let f = f.trim_matches('"');
                let f = f.strip_prefix('[').and_then(|r| r.split(']').next()).unwrap_or_else(|| f.split(':').next().unwrap_or(f));
                if let Ok(ip) = f.parse() { v.push(ip); }
            }
        }
    }
    v
}

/// The address a sign-in is counted against: the first one proxies name, or the connection's.
fn client_ip(peer: IpAddr, headers: &HeaderMap) -> IpAddr {
    origins(peer, headers).into_iter().rev().find(|ip| !extension::is_local(*ip)).unwrap_or(peer)
}

fn cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    headers.get_all(header::COOKIE).iter().filter_map(|h| h.to_str().ok())
        .flat_map(|h| h.split(';')).filter_map(|c| c.trim().split_once('='))
        .find(|(k, _)| *k == name).map(|(_, v)| v.to_string())
}

/// Paths open without signing in: the sign-in page and what it shows, and the extension's.
fn open_path(path: &str) -> bool {
    path == "/login" || path == "/logout" || path == "/favicon.png" || path.starts_with("/icons/") || path.starts_with("/ext/")
}

pub async fn gate(State(cfg): State<Shared>, ConnectInfo(peer): ConnectInfo<SocketAddr>, req: Request, next: Next) -> Response {
    let lang = Lang::of(req.headers());
    if !cfg.public && !origins(peer.ip(), req.headers()).iter().all(|ip| extension::is_local(*ip)) {
        return (StatusCode::FORBIDDEN, Html(page(lang, lang.t(T::LanOnlyTitle), &format!("<p>{}</p>", lang.t(T::LanOnly))))).into_response();
    }
    let path = req.uri().path().to_string();
    if open_path(&path) { return next.run(req).await; }
    if cookie(req.headers(), crate::auth::COOKIE).is_some_and(|c| cfg.auth.valid(&c)) { return next.run(req).await; }
    // the app's own requests get a plain answer (the page reloads into the sign-in); a page is sent there
    let api = path.starts_with("/api/") || path.starts_with("/f/") || path.starts_with("/gfonts/") || req.method() != Method::GET;
    if api { return (StatusCode::UNAUTHORIZED, "sign in first").into_response(); }
    let next_path = req.uri().path_and_query().map(|p| p.as_str()).unwrap_or("/");
    Redirect::to(&format!("/login?next={}", urlencode(next_path))).into_response()
}

fn urlencode(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.~/".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

/// Only a path of this site (never `//other.host`): no redirect elsewhere after signing in.
fn safe_next(n: Option<&str>) -> String {
    match n { Some(n) if n.starts_with('/') && !n.starts_with("//") && !n.starts_with("/\\") && !n.starts_with("/login") => n.to_string(), _ => "/".into() }
}

#[derive(Deserialize)]
pub struct LoginQuery { next: Option<String> }
#[derive(Deserialize)]
pub struct LoginForm { password: String, next: Option<String> }

pub async fn login_page(State(cfg): State<Shared>, headers: HeaderMap, Query(q): Query<LoginQuery>) -> Response {
    let next = safe_next(q.next.as_deref());
    // signed in already: straight on
    if cookie(&headers, crate::auth::COOKIE).is_some_and(|c| cfg.auth.valid(&c)) { return Redirect::to(&next).into_response(); }
    Html(login_html(Lang::of(&headers), None, &next)).into_response()
}

pub async fn login(State(cfg): State<Shared>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, Form(f): Form<LoginForm>) -> Response {
    let lang = Lang::of(&headers);
    let next = safe_next(f.next.as_deref());
    let ip = client_ip(peer.ip(), &headers);
    if let Some(wait) = cfg.auth.locked(ip) {
        return (StatusCode::TOO_MANY_REQUESTS, Html(login_html(lang, Some(&lang.t(T::Locked).replace("{n}", &wait.to_string())), &next))).into_response();
    }
    let auth = cfg.clone();
    let password = f.password.clone();
    let ok = tokio::task::spawn_blocking(move || auth.auth.check(&password)).await.unwrap_or(false);
    if !ok {
        cfg.auth.failed(ip);
        // a wrong password always costs a moment (guessing is slow even before the lock)
        tokio::time::sleep(Duration::from_millis(600)).await;
        return (StatusCode::UNAUTHORIZED, Html(login_html(lang, Some(lang.t(T::Wrong)), &next))).into_response();
    }
    cfg.auth.succeeded(ip);
    let Some(value) = cfg.auth.issue() else { return StatusCode::INTERNAL_SERVER_ERROR.into_response() };
    let secure = headers.get("x-forwarded-proto").and_then(|v| v.to_str().ok()).is_some_and(|p| p.eq_ignore_ascii_case("https"));
    let c = format!("{}={value}; Path=/; Max-Age={}; HttpOnly; SameSite=Lax{}", crate::auth::COOKIE, crate::auth::LIFE, if secure { "; Secure" } else { "" });
    let mut res = Redirect::to(&next).into_response();
    res.headers_mut().insert(header::SET_COOKIE, HeaderValue::from_str(&c).unwrap());
    res
}

pub async fn logout() -> Response {
    let mut res = Redirect::to("/login").into_response();
    res.headers_mut().insert(header::SET_COOKIE, HeaderValue::from_str(&format!("{}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax", crate::auth::COOKIE)).unwrap());
    res
}

// ---------------------------------------------------------------------------------------------
// several browsers at once

#[derive(Deserialize)]
pub struct LeaseRequest { id: String }

/// Several windows may be open at once (one person, several devices or tabs); what runs on its
/// own in the web app (AI tagging, handing queued downloads to the core) runs in one of them only:
/// the one holding this lease. A window asks every 15 s; a lease not renewed for 40 s (the window
/// was closed) goes to the next one that asks.
pub async fn lease(State(cfg): State<Shared>, Json(r): Json<LeaseRequest>) -> Json<Value> {
    let mut l = cfg.lease.lock().unwrap();
    let free = match l.as_ref() { None => true, Some((id, t)) => *id == r.id || t.elapsed() > Duration::from_secs(40) };
    if free { *l = Some((r.id.clone(), Instant::now())); }
    Json(json!({ "holder": free }))
}

// ---------------------------------------------------------------------------------------------
// the browser extension

pub async fn ext(State(cfg): State<Shared>, method: Method, headers: HeaderMap, uri: axum::http::Uri, body: axum::body::Bytes) -> Response {
    let path = uri.path().to_string();
    if path == "/ext/download" { refresh_extension_options(&cfg); }
    let token = headers.get(header::AUTHORIZATION).and_then(|h| h.to_str().ok()).and_then(|h| h.strip_prefix("Bearer ")).map(str::to_string);
    let origin = headers.get(header::ORIGIN).and_then(|h| h.to_str().ok()).map(str::to_string);
    let cors = extension::cors_headers(origin.as_deref());
    let mut res = if method == Method::OPTIONS {
        StatusCode::NO_CONTENT.into_response()
    } else {
        let m = method.to_string();
        let reply = tokio::task::spawn_blocking(move || extension::handle_open(&extension::Request { method: &m, path: &path, token: token.as_deref(), origin: origin.as_deref(), body: &body })).await;
        match reply {
            Ok(r) => (StatusCode::from_u16(r.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR), [(header::CACHE_CONTROL, "no-store")], Json(r.body)).into_response(),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        }
    };
    for (k, v) in cors { if let Ok(v) = HeaderValue::from_str(&v) { res.headers_mut().insert(k, v); } }
    res
}

/// The download settings the web app keeps (its queue file): a link from the browser downloads
/// as one pasted in the web app.
pub fn refresh_extension_options(cfg: &Config) {
    let q: Value = std::fs::read(cfg.dir("library").join("downloads.queue.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    let route = match q.get("route").and_then(Value::as_str) { Some("fx") => "fx", Some("cookie") => "cookie", _ => "auto" };
    let options = json!({
        "name": crate::device_name(), "platform": "server", "flavor": "server", "route": route,
        "concurrency": q.get("concurrency").and_then(Value::as_u64).unwrap_or(3),
        "interval_ms": q.get("intervalMs").and_then(Value::as_u64).unwrap_or(500),
        "folder": q.get("folder").and_then(Value::as_str),
        "listen": false,
    });
    if let Ok(o) = serde_json::from_value(options) { let _ = extension::serve(o); }
}

// ---------------------------------------------------------------------------------------------
// pages

#[derive(Clone, Copy)]
pub enum Lang { En, Hans, Hant, Ja }
enum T { Title, Password, SignIn, Wrong, Locked, Forgot, LanOnlyTitle, LanOnly }

impl Lang {
    fn of(h: &HeaderMap) -> Lang {
        let a = h.get(header::ACCEPT_LANGUAGE).and_then(|v| v.to_str().ok()).unwrap_or("").to_ascii_lowercase();
        for tag in a.split(',').map(|t| t.split(';').next().unwrap_or("").trim()) {
            if tag.starts_with("zh-tw") || tag.starts_with("zh-hk") || tag.starts_with("zh-mo") || tag.starts_with("zh-hant") { return Lang::Hant; }
            if tag.starts_with("zh") { return Lang::Hans; }
            if tag.starts_with("ja") { return Lang::Ja; }
            if tag.starts_with("en") { return Lang::En; }
        }
        Lang::En
    }
    fn code(self) -> &'static str { match self { Lang::En => "en", Lang::Hans => "zh-Hans", Lang::Hant => "zh-Hant", Lang::Ja => "ja" } }
    fn t(self, t: T) -> &'static str {
        use Lang::*;
        match (t, self) {
            (T::Title, En) => "Sign in to TwimShelf", (T::Title, Hans) => "登录 TwimShelf", (T::Title, Hant) => "登入 TwimShelf", (T::Title, Ja) => "TwimShelf にサインイン",
            (T::Password, En) => "Password", (T::Password, Hans) => "密码", (T::Password, Hant) => "密碼", (T::Password, Ja) => "パスワード",
            (T::SignIn, En) => "Sign In", (T::SignIn, Hans) => "登录", (T::SignIn, Hant) => "登入", (T::SignIn, Ja) => "サインイン",
            (T::Wrong, En) => "Wrong password", (T::Wrong, Hans) => "密码错误", (T::Wrong, Hant) => "密碼錯誤", (T::Wrong, Ja) => "パスワードが違います",
            (T::Locked, En) => "Too many attempts. Try again in {n} s.", (T::Locked, Hans) => "尝试次数过多，请 {n} 秒后再试。", (T::Locked, Hant) => "嘗試次數過多，請 {n} 秒後再試。", (T::Locked, Ja) => "試行回数が多すぎます。{n} 秒後にもう一度お試しください。",
            (T::Forgot, En) => "The first password is in the container's log. To set your own, run <code>twimshelf passwd</code> in the container.",
            (T::Forgot, Hans) => "初始密码在容器日志里。要设置自己的密码，请在容器中执行 <code>twimshelf passwd</code>。",
            (T::Forgot, Hant) => "初始密碼在容器日誌裡。要設定自己的密碼，請在容器中執行 <code>twimshelf passwd</code>。",
            (T::Forgot, Ja) => "初期パスワードはコンテナのログにあります。自分のパスワードにするには、コンテナで <code>twimshelf passwd</code> を実行してください。",
            (T::LanOnlyTitle, En) => "Local network only", (T::LanOnlyTitle, Hans) => "仅限局域网", (T::LanOnlyTitle, Hant) => "僅限區域網路", (T::LanOnlyTitle, Ja) => "ローカルネットワークのみ",
            (T::LanOnly, En) => "This TwimShelf only answers on its local network. To reach it from the internet, its owner sets <code>TL_ALLOW_PUBLIC=true</code> (best behind HTTPS).",
            (T::LanOnly, Hans) => "这台 TwimShelf 只接受局域网访问。如需从公网访问，请由管理者设置 <code>TL_ALLOW_PUBLIC=true</code>（建议配合 HTTPS）。",
            (T::LanOnly, Hant) => "這台 TwimShelf 只接受區域網路存取。如需從網際網路存取，請由管理者設定 <code>TL_ALLOW_PUBLIC=true</code>（建議搭配 HTTPS）。",
            (T::LanOnly, Ja) => "この TwimShelf はローカルネットワークからのみ利用できます。インターネットから使うには、管理者が <code>TL_ALLOW_PUBLIC=true</code> を設定してください（HTTPS 推奨）。",
        }
    }
}

fn escape(s: &str) -> String { s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;") }

fn login_html(lang: Lang, error: Option<&str>, next: &str) -> String {
    let error = error.map(|e| format!("<p class=\"error\" role=\"alert\">{}</p>", escape(e))).unwrap_or_default();
    let body = format!(r#"<form method="post" action="/login">
  <input type="hidden" name="next" value="{next}">
  <label for="p">{label}</label>
  <input id="p" name="password" type="password" autocomplete="current-password" autofocus required>
  {error}
  <button type="submit">{button}</button>
</form>
<p class="hint">{forgot}</p>"#, next = escape(next), label = lang.t(T::Password), button = lang.t(T::SignIn), forgot = lang.t(T::Forgot));
    page(lang, lang.t(T::Title), &body)
}

fn page(lang: Lang, title: &str, body: &str) -> String {
    format!(r#"<!doctype html>
<html lang="{lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title><link rel="icon" href="/favicon.png">
<style>
:root {{ --bg:#f4f6fb; --card:#fff; --text:#1b1d22; --muted:#5d6370; --line:#d5d9e2; --accent:#3a5ba0; --on-accent:#fff; --error:#b3261e; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#111318; --card:#1c1f26; --text:#e3e5ea; --muted:#9aa1ad; --line:#383d48; --accent:#a9c2ff; --on-accent:#0b1c3d; --error:#ffb4ab; }} }}
* {{ box-sizing:border-box; }}
body {{ margin:0; min-height:100vh; display:grid; place-items:center; background:var(--bg); color:var(--text); font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,"PingFang SC","Hiragino Sans","Microsoft YaHei",sans-serif; padding:16px; }}
main {{ width:100%; max-width:360px; background:var(--card); border-radius:20px; padding:32px 28px; box-shadow:0 1px 2px rgba(0,0,0,.06),0 8px 24px rgba(0,0,0,.06); }}
img {{ width:56px; height:56px; border-radius:14px; display:block; margin:0 auto 16px; }}
h1 {{ font-size:20px; font-weight:600; text-align:center; margin:0 0 24px; }}
label {{ display:block; font-size:14px; color:var(--muted); margin-bottom:6px; }}
input[type=password] {{ width:100%; font:inherit; padding:12px 14px; border:1px solid var(--line); border-radius:12px; background:transparent; color:inherit; }}
input[type=password]:focus {{ outline:2px solid var(--accent); outline-offset:-1px; border-color:transparent; }}
button {{ width:100%; margin-top:20px; font:inherit; font-weight:600; padding:12px; border:0; border-radius:999px; background:var(--accent); color:var(--on-accent); cursor:pointer; }}
.error {{ color:var(--error); font-size:14px; margin:10px 0 0; }}
.hint {{ color:var(--muted); font-size:13px; margin:20px 0 0; }}
code {{ font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.92em; background:rgba(127,127,127,.14); padding:1px 5px; border-radius:6px; }}
p {{ margin:0; }}
</style></head>
<body><main><img src="/icons/Icon-192.png" alt=""><h1>{title}</h1>
{body}
</main></body></html>"#, lang = lang.code(), title = escape(title))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_proxy_naming_an_internet_address_counts_as_the_internet() {
        let lan: IpAddr = "172.17.0.1".parse().unwrap();
        let mut h = HeaderMap::new();
        assert!(origins(lan, &h).iter().all(|ip| extension::is_local(*ip)));
        h.insert("x-forwarded-for", "203.0.113.9, 10.0.0.2".parse().unwrap());
        assert!(!origins(lan, &h).iter().all(|ip| extension::is_local(*ip)));
        assert_eq!(client_ip(lan, &h), "203.0.113.9".parse::<IpAddr>().unwrap());
        let mut f = HeaderMap::new();
        f.insert("forwarded", "for=\"[2001:db8::7]:4711\";proto=https".parse().unwrap());
        assert!(!origins(lan, &f).iter().all(|ip| extension::is_local(*ip)));
        let mut t = HeaderMap::new();
        t.insert("x-forwarded-for", "100.80.1.2".parse().unwrap()); // Tailscale
        assert!(origins(lan, &t).iter().all(|ip| extension::is_local(*ip)));
    }

    #[test]
    fn after_signing_in_only_this_site() {
        assert_eq!(safe_next(Some("/settings?x=1")), "/settings?x=1");
        for n in ["//evil.example", "https://evil.example", "/\\evil", "/login?next=/"] { assert_eq!(safe_next(Some(n)), "/", "{n}"); }
        assert_eq!(safe_next(None), "/");
    }

    #[test]
    fn the_browser_language_picks_the_page_language() {
        let mut h = HeaderMap::new();
        h.insert(header::ACCEPT_LANGUAGE, "zh-TW,zh;q=0.9".parse().unwrap());
        assert_eq!(Lang::of(&h).code(), "zh-Hant");
        h.insert(header::ACCEPT_LANGUAGE, "zh-CN".parse().unwrap());
        assert_eq!(Lang::of(&h).code(), "zh-Hans");
        h.insert(header::ACCEPT_LANGUAGE, "fr-FR,ja;q=0.8".parse().unwrap());
        assert_eq!(Lang::of(&h).code(), "ja");
    }
}

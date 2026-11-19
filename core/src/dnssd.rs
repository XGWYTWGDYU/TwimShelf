//! The Apple backend: the system's Bonjour through the `dns_sd` C API (in libSystem), served by
//! mDNSResponder — what the native apps' `NetService` / `NWBrowser` use. An app's own mDNS
//! sockets would need Apple's multicast entitlement on iOS and compete with mDNSResponder for
//! port 5353 on macOS; through the daemon neither applies, and the system's Local Network
//! permission and `NSBonjourServices` work as for the native apps.
//!
//! Each operation has a reference with a socket; a thread per long-lived reference (the
//! registration, the browse) waits on it and lets the daemon call back. A device found on an
//! interface is resolved (host, port, TXT) and its IPv4 addresses looked up on that interface,
//! on a short-lived thread. A device seen on several interfaces is removed only when it is gone
//! from all of them.
use crate::discovery::{Backend, Found};
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

type DNSServiceRef = *mut c_void;
type DNSServiceErrorType = i32;
type DNSServiceFlags = u32;

const K_DNS_SERVICE_FLAGS_MORE_COMING: DNSServiceFlags = 0x1;
const K_DNS_SERVICE_FLAGS_ADD: DNSServiceFlags = 0x2;
const K_DNS_SERVICE_PROTOCOL_IPV4: u32 = 0x01;
/// The system refused (the Local Network permission is off for this app).
const K_DNS_SERVICE_ERR_POLICY_DENIED: DNSServiceErrorType = -65570;

/// The catalog key for a daemon error, and the code in the log for anything else.
fn error_key(what: &str, err: DNSServiceErrorType) -> String {
    eprintln!("tl-discovery: {what} failed: dns_sd error {err}");
    if err == K_DNS_SERVICE_ERR_POLICY_DENIED { "sync.err.noLocalNetwork".into() } else { "sync.err.paused".into() }
}

type RegisterReply = extern "C" fn(DNSServiceRef, DNSServiceFlags, DNSServiceErrorType, *const c_char, *const c_char, *const c_char, *mut c_void);
type BrowseReply = extern "C" fn(DNSServiceRef, DNSServiceFlags, u32, DNSServiceErrorType, *const c_char, *const c_char, *const c_char, *mut c_void);
type ResolveReply = extern "C" fn(DNSServiceRef, DNSServiceFlags, u32, DNSServiceErrorType, *const c_char, *const c_char, u16, u16, *const u8, *mut c_void);
type AddrInfoReply = extern "C" fn(DNSServiceRef, DNSServiceFlags, u32, DNSServiceErrorType, *const c_char, *const libc::sockaddr, u32, *mut c_void);

extern "C" {
    fn DNSServiceRegister(sd: *mut DNSServiceRef, flags: DNSServiceFlags, interface: u32, name: *const c_char, regtype: *const c_char,
        domain: *const c_char, host: *const c_char, port: u16, txt_len: u16, txt: *const c_void, reply: RegisterReply, ctx: *mut c_void) -> DNSServiceErrorType;
    fn DNSServiceBrowse(sd: *mut DNSServiceRef, flags: DNSServiceFlags, interface: u32, regtype: *const c_char, domain: *const c_char,
        reply: BrowseReply, ctx: *mut c_void) -> DNSServiceErrorType;
    fn DNSServiceResolve(sd: *mut DNSServiceRef, flags: DNSServiceFlags, interface: u32, name: *const c_char, regtype: *const c_char,
        domain: *const c_char, reply: ResolveReply, ctx: *mut c_void) -> DNSServiceErrorType;
    fn DNSServiceGetAddrInfo(sd: *mut DNSServiceRef, flags: DNSServiceFlags, interface: u32, protocol: u32, host: *const c_char,
        reply: AddrInfoReply, ctx: *mut c_void) -> DNSServiceErrorType;
    fn DNSServiceRefSockFD(sd: DNSServiceRef) -> i32;
    fn DNSServiceProcessResult(sd: DNSServiceRef) -> DNSServiceErrorType;
    fn DNSServiceRefDeallocate(sd: DNSServiceRef);
}

/// Waits on `sd` and lets the daemon call back until `done` says so, the deadline passes or the
/// connection fails. Returns false on failure.
fn pump(sd: DNSServiceRef, deadline: Option<Instant>, done: &dyn Fn() -> bool) -> bool {
    let fd = unsafe { DNSServiceRefSockFD(sd) };
    if fd < 0 { return false; }
    while !done() {
        if deadline.is_some_and(|d| Instant::now() >= d) { return true; }
        let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let n = unsafe { libc::poll(&mut p, 1, 250) };
        if n < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted { continue; }
            return false;
        }
        if n > 0 && unsafe { DNSServiceProcessResult(sd) } != 0 { return false; }
    }
    true
}

/// A reference handed to its pump thread (the daemon's callbacks run there only).
struct Owned(DNSServiceRef);
unsafe impl Send for Owned {}
impl Drop for Owned {
    fn drop(&mut self) { unsafe { DNSServiceRefDeallocate(self.0) }; }
}

fn callback(f: impl FnOnce()) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
}

fn c(s: &str) -> CString { CString::new(s.replace('\0', "")).unwrap_or_default() }
fn s(p: *const c_char) -> String { if p.is_null() { String::new() } else { unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned() } }

/// A TXT record: length-prefixed `key=value` strings.
pub(super) fn txt_record(txt: &[(&str, String)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (k, v) in txt {
        let mut e = format!("{k}={v}").into_bytes();
        e.truncate(255);
        out.push(e.len() as u8);
        out.extend_from_slice(&e);
    }
    out
}

pub(super) fn parse_txt(data: &[u8]) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut i = 0;
    while i < data.len() {
        let n = data[i] as usize;
        let Some(e) = data.get(i + 1..i + 1 + n) else { break };
        let e = String::from_utf8_lossy(e);
        match e.split_once('=') {
            Some((k, v)) => { out.insert(k.to_string(), v.to_string()); }
            None if !e.is_empty() => { out.insert(e.to_string(), String::new()); }
            None => {}
        }
        i += 1 + n;
    }
    out
}

pub(super) struct DnsSd {
    service_type: String,
    network_ok: Arc<AtomicBool>,
    /// Why the daemon refused (a catalog key), for the page to say.
    error: Arc<Mutex<Option<String>>>,
    /// Ends the current registration's / browse's thread (which then frees its reference).
    registration: Mutex<Option<Arc<AtomicBool>>>,
    browsing: Mutex<Option<Arc<AtomicBool>>>,
    resolves: SyncSender<ResolveJob>,
}

impl DnsSd {
    pub(super) fn new(service_type: &str) -> anyhow::Result<DnsSd> {
        let (resolves, pending) = mpsc::sync_channel::<ResolveJob>(64);
        let pending = Arc::new(Mutex::new(pending));
        for _ in 0..4 {
            let pending = pending.clone();
            std::thread::Builder::new().name("tl-discovery-resolve".into()).spawn(move || loop {
                let job = pending.lock().unwrap_or_else(|e| e.into_inner()).recv();
                let Ok(job) = job else { break; };
                callback(job);
            })?;
        }
        Ok(DnsSd {
            service_type: format!("{}.", service_type.trim_end_matches('.')),
            // the daemon reports a refusal (the permission, no network) when it happens: until
            // then the network is taken to work, so nothing warns while it confirms
            network_ok: Arc::new(AtomicBool::new(true)),
            error: Arc::new(Mutex::new(None)),
            registration: Mutex::new(None),
            browsing: Mutex::new(None),
            resolves,
        })
    }
}

struct RegisterCtx { ok: Arc<AtomicBool>, error: Arc<Mutex<Option<String>>> }

extern "C" fn register_reply(_: DNSServiceRef, _: DNSServiceFlags, err: DNSServiceErrorType, _: *const c_char, _: *const c_char, _: *const c_char, ctx: *mut c_void) {
    if ctx.is_null() { return; }
    callback(|| {
        let ctx = unsafe { &*(ctx as *const RegisterCtx) };
        ctx.ok.store(err == 0, Ordering::Relaxed);
        *ctx.error.lock().unwrap_or_else(|e| e.into_inner()) = if err == 0 { None } else { Some(error_key("register", err)) };
    });
}

struct BrowseCtx {
    sink: Sender<Found>,
    stop: Arc<AtomicBool>,
    seen: Arc<Mutex<HashMap<String, usize>>>,
    error: Arc<Mutex<Option<String>>>,
    resolves: SyncSender<ResolveJob>,
}

type ResolveJob = Box<dyn FnOnce() + Send>;
const MAX_SEEN_SERVICES: usize = 1024;

extern "C" fn browse_reply(_: DNSServiceRef, flags: DNSServiceFlags, interface: u32, err: DNSServiceErrorType, name: *const c_char,
    regtype: *const c_char, domain: *const c_char, ctx: *mut c_void) {
    if ctx.is_null() { return; }
    callback(|| {
        let ctx = unsafe { &*(ctx as *const BrowseCtx) };
        if err != 0 {
            *ctx.error.lock().unwrap_or_else(|e| e.into_inner()) = Some(error_key("browse", err));
            return;
        }
        let (name, regtype, domain) = (s(name), s(regtype), s(domain));
        let key = format!("{name}.{regtype}{domain}");
        let mut seen = ctx.seen.lock().unwrap_or_else(|e| e.into_inner());
        if flags & K_DNS_SERVICE_FLAGS_ADD != 0 {
            if seen.len() >= MAX_SEEN_SERVICES && !seen.contains_key(&key) { return; }
            let (sink, stop, current) = (ctx.sink.clone(), ctx.stop.clone(), ctx.seen.clone());
            let resolving_key = key.clone();
            let queued = ctx.resolves.try_send(Box::new(move || {
                if stop.load(Ordering::Relaxed) { return; }
                if let Some(found) = resolve(&name, &regtype, &domain, interface, resolving_key.clone(), &stop) {
                    let seen = current.lock().unwrap_or_else(|e| e.into_inner());
                    if !stop.load(Ordering::Relaxed) && seen.contains_key(&resolving_key) { let _ = sink.send(found); }
                }
            })).is_ok();
            if queued || seen.contains_key(&key) {
                let count = seen.entry(key).or_default();
                *count = count.saturating_add(1);
            }
        } else if let Some(n) = seen.get_mut(&key) {
            *n -= 1;
            if *n == 0 {
                seen.remove(&key);
                let _ = ctx.sink.send(Found::Removed(key));
            }
        }
    });
}

#[derive(Default)]
struct ResolveCtx { out: Mutex<Option<(String, u16, HashMap<String, String>)>> }

extern "C" fn resolve_reply(_: DNSServiceRef, _: DNSServiceFlags, _: u32, err: DNSServiceErrorType, _: *const c_char, host: *const c_char,
    port: u16, txt_len: u16, txt: *const u8, ctx: *mut c_void) {
    if ctx.is_null() { return; }
    callback(|| {
        if err != 0 { return; }
        let ctx = unsafe { &*(ctx as *const ResolveCtx) };
        let data = if txt.is_null() { &[][..] } else { unsafe { std::slice::from_raw_parts(txt, txt_len as usize) } };
        *ctx.out.lock().unwrap_or_else(|e| e.into_inner()) = Some((s(host), u16::from_be(port), parse_txt(data)));
    });
}

#[derive(Default)]
struct AddrCtx { addrs: Mutex<Vec<Ipv4Addr>>, done: AtomicBool }

extern "C" fn addr_reply(_: DNSServiceRef, flags: DNSServiceFlags, _: u32, err: DNSServiceErrorType, _: *const c_char, addr: *const libc::sockaddr,
    _: u32, ctx: *mut c_void) {
    if ctx.is_null() { return; }
    callback(|| {
        let ctx = unsafe { &*(ctx as *const AddrCtx) };
        if err == 0 && !addr.is_null() && flags & K_DNS_SERVICE_FLAGS_ADD != 0 && unsafe { (*addr).sa_family } as i32 == libc::AF_INET {
            let a = unsafe { &*(addr as *const libc::sockaddr_in) };
            ctx.addrs.lock().unwrap_or_else(|e| e.into_inner()).push(Ipv4Addr::from(u32::from_be(a.sin_addr.s_addr)));
        }
        if flags & K_DNS_SERVICE_FLAGS_MORE_COMING == 0 { ctx.done.store(true, Ordering::Relaxed); }
    });
}

/// Host, port and TXT of a service, then the host's IPv4 addresses on that interface.
fn resolve(name: &str, regtype: &str, domain: &str, interface: u32, key: String, stop: &AtomicBool) -> Option<Found> {
    let rctx = Box::new(ResolveCtx::default());
    let mut sd: DNSServiceRef = std::ptr::null_mut();
    let (n, t, d) = (c(name), c(regtype), c(domain));
    let err = unsafe { DNSServiceResolve(&mut sd, 0, interface, n.as_ptr(), t.as_ptr(), d.as_ptr(), resolve_reply, &*rctx as *const _ as *mut c_void) };
    if err != 0 { return None; }
    let owned = Owned(sd);
    pump(owned.0, Some(Instant::now() + Duration::from_secs(5)), &||
        stop.load(Ordering::Relaxed) || rctx.out.lock().unwrap_or_else(|e| e.into_inner()).is_some());
    drop(owned);
    if stop.load(Ordering::Relaxed) { return None; }
    let (host, port, txt) = rctx.out.lock().unwrap_or_else(|e| e.into_inner()).take()?;

    let actx = Box::new(AddrCtx::default());
    let mut sd: DNSServiceRef = std::ptr::null_mut();
    let h = c(&host);
    let err = unsafe { DNSServiceGetAddrInfo(&mut sd, 0, interface, K_DNS_SERVICE_PROTOCOL_IPV4, h.as_ptr(), addr_reply, &*actx as *const _ as *mut c_void) };
    if err == 0 {
        let owned = Owned(sd);
        pump(owned.0, Some(Instant::now() + Duration::from_secs(3)), &||
            stop.load(Ordering::Relaxed) || actx.done.load(Ordering::Relaxed));
    }
    let v4 = std::mem::take(&mut *actx.addrs.lock().unwrap_or_else(|e| e.into_inner()));
    Some(Found::Resolved { key, port, txt, v4 })
}

impl Backend for DnsSd {
    fn register(&self, instance: &str, _device: &str, port: u16, txt: &[(&str, String)]) -> anyhow::Result<()> {
        if let Some(old) = self.registration.lock().unwrap_or_else(|e| e.into_inner()).take() { old.store(true, Ordering::Relaxed); }
        let record = txt_record(txt);
        let ctx = Box::new(RegisterCtx { ok: self.network_ok.clone(), error: self.error.clone() });
        let mut sd: DNSServiceRef = std::ptr::null_mut();
        let (n, t) = (c(instance), c(&self.service_type));
        let err = unsafe {
            DNSServiceRegister(&mut sd, 0, 0, n.as_ptr(), t.as_ptr(), std::ptr::null(), std::ptr::null(), port.to_be(),
                record.len() as u16, record.as_ptr() as *const c_void, register_reply, &*ctx as *const _ as *mut c_void)
        };
        if err != 0 {
            self.network_ok.store(false, Ordering::Relaxed);
            let key = error_key("register", err);
            *self.error.lock().unwrap_or_else(|e| e.into_inner()) = Some(key.clone());
            anyhow::bail!(key);
        }
        let stop = Arc::new(AtomicBool::new(false));
        *self.registration.lock().unwrap_or_else(|e| e.into_inner()) = Some(stop.clone());
        let owned = Owned(sd);
        let ok = self.network_ok.clone();
        std::thread::Builder::new().name("tl-discovery-register".into()).spawn(move || {
            let owned = owned;
            if !pump(owned.0, None, &|| stop.load(Ordering::Relaxed)) { ok.store(false, Ordering::Relaxed); }
            drop(owned);
            drop(ctx);
        })?;
        Ok(())
    }

    fn browse(&self, sink: Sender<Found>) -> anyhow::Result<()> {
        if let Some(old) = self.browsing.lock().unwrap_or_else(|e| e.into_inner()).take() { old.store(true, Ordering::Relaxed); }
        let stop = Arc::new(AtomicBool::new(false));
        let ctx = Box::new(BrowseCtx { sink, stop: stop.clone(), seen: Arc::new(Mutex::new(HashMap::new())), error: self.error.clone(), resolves: self.resolves.clone() });
        let mut sd: DNSServiceRef = std::ptr::null_mut();
        let t = c(&self.service_type);
        let err = unsafe { DNSServiceBrowse(&mut sd, 0, 0, t.as_ptr(), std::ptr::null(), browse_reply, &*ctx as *const _ as *mut c_void) };
        if err != 0 {
            let key = error_key("browse", err);
            *self.error.lock().unwrap_or_else(|e| e.into_inner()) = Some(key.clone());
            anyhow::bail!(key);
        }
        *self.browsing.lock().unwrap_or_else(|e| e.into_inner()) = Some(stop.clone());
        let owned = Owned(sd);
        std::thread::Builder::new().name("tl-discovery".into()).spawn(move || {
            let owned = owned;
            pump(owned.0, None, &|| stop.load(Ordering::Relaxed));
            drop(owned);
            drop(ctx);
        })?;
        Ok(())
    }

    fn network_ok(&self) -> bool { self.network_ok.load(Ordering::Relaxed) }

    fn error(&self) -> Option<String> { self.error.lock().unwrap_or_else(|e| e.into_inner()).clone() }

    fn shutdown(&self) {
        self.network_ok.store(false, Ordering::Relaxed);
        if let Some(s) = self.registration.lock().unwrap_or_else(|e| e.into_inner()).take() { s.store(true, Ordering::Relaxed); }
        if let Some(s) = self.browsing.lock().unwrap_or_else(|e| e.into_inner()).take() { s.store(true, Ordering::Relaxed); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn txt_records_round_trip() {
        let rec = txt_record(&[("dev", "abc".into()), ("name", "Mac·mini".into()), ("acct", String::new())]);
        let m = parse_txt(&rec);
        assert_eq!(m["dev"], "abc");
        assert_eq!(m["name"], "Mac·mini");
        assert_eq!(m["acct"], "");
        assert!(parse_txt(&[5, b'a']).is_empty() || parse_txt(&[5, b'a']).len() <= 1);
    }
}

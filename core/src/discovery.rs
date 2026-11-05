//! Finding the account's other devices on the local network and deciding when to sync with
//! them — what the native apps' `SyncService` does with Bonjour, here once for every front end.
//!
//! * Advertises this device as `<type>.local.` (`_twlib._tcp`, the debug Mac build
//!   `_twlib-debug._tcp`) with the TXT fields the native apps use (`dev`, `name`, `acct`, `rev`),
//!   so native and Flutter devices find each other.
//! * Browses for the same type; every resolved service of another device is a peer, by device id.
//! * Every 20 s, and 3 s after a local change, syncs with the account's reachable peers. One side
//!   of each pair starts (the smaller device id), but either does when the pair has not synced
//!   for a minute (discovery can be one-sided); two sessions at once are refused by the node.
//! * An address whose last attempt failed is dropped and the device looked up again (an app that
//!   restarted listens on a new port).
//!
//! Sessions themselves (protocol, crypto, merging) are `sync::SyncNode`'s.
//!
//! mDNS itself is a backend: the system's Bonjour on Apple platforms (`dnssd.rs`, the daemon the
//! native apps use too), the `mdns-sd` responder elsewhere (`mdnssd.rs`).
use crate::sync::SyncNode;
use serde::Serialize;
use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};


/// What a backend reports: a service of the type resolved (again), or gone.
pub(crate) enum Found {
    Resolved { key: String, port: u16, txt: HashMap<String, String>, v4: Vec<Ipv4Addr> },
    Removed(String),
}

/// An mDNS implementation: advertise this device, browse for the others.
pub(crate) trait Backend: Send + Sync {
    /// Publishes (replacing the previous publication) `instance` on `port` with these TXT fields.
    fn register(&self, instance: &str, device: &str, port: u16, txt: &[(&str, String)]) -> anyhow::Result<()>;
    /// (Re)starts browsing; every service is resolved anew into `sink`.
    fn browse(&self, sink: Sender<Found>) -> anyhow::Result<()>;
    /// The network carries mDNS (a multicast join, or the system's daemon accepted the service).
    fn network_ok(&self) -> bool;
    /// Why the network does not carry it, as a catalog key (none: no specific reason known).
    fn error(&self) -> Option<String> { None }
    fn shutdown(&self);
}

fn backend(service_type: &str) -> anyhow::Result<Box<dyn Backend>> {
    #[cfg(target_vendor = "apple")]
    return Ok(Box::new(crate::dnssd::DnsSd::new(service_type)?));
    #[cfg(not(target_vendor = "apple"))]
    return Ok(Box::new(crate::mdnssd::MdnsSd::new(service_type)?));
}

/// A device of the network seen through discovery.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Peer {
    pub device: String,
    pub name: String,
    /// The sync account it belongs to (devices of other accounts are listed but never synced).
    pub account: Option<String>,
    /// What it is (`mac`, `iphone`, `ipad`, `android-phone`, `android-tablet`, `windows`,
    /// `linux`); none from an app that does not say.
    pub kind: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
    #[serde(skip)]
    fullname: String,
    #[serde(skip)]
    rev: String,
}

/// What the app shows: peers, and whether the network works at all.
#[derive(Clone, Debug, Serialize)]
pub struct DiscoveryStatus {
    pub running: bool,
    /// At least one non-loopback address successfully joined mDNS multicast.
    pub network_ok: bool,
    pub peers: Vec<Peer>,
    /// Why discovery could not start or stopped (no multicast on this network, …).
    pub error: Option<String>,
}

pub struct Discovery {
    node: Arc<SyncNode>,
    mdns: Box<dyn Backend>,
    sink: Mutex<Sender<Found>>,
    device_name: String,
    device_kind: String,
    peers: Mutex<HashMap<String, Peer>>,
    error: Mutex<Option<String>>,
    stop: AtomicBool,
    /// A local change asks for a sync this many ms after the epoch (0: none pending).
    change_at: AtomicU64,
    /// "立即同步": sync with everyone at the next tick, whichever side would normally start.
    force: AtomicBool,
    handled_failures: Mutex<Vec<String>>,
}

fn now_ms() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64) }

impl Discovery {
    /// Starts advertising and browsing; the node must already be started (its listener has a
    /// port). `service_type` without the domain, e.g. `_twlib._tcp`.
    pub fn start(node: Arc<SyncNode>, service_type: &str, device_name: &str) -> anyhow::Result<Arc<Discovery>> {
        Self::start_as(node, service_type, device_name, "")
    }

    /// As `start`, also saying what kind of device this is (see `Peer::kind`).
    pub fn start_as(node: Arc<SyncNode>, service_type: &str, device_name: &str, device_kind: &str) -> anyhow::Result<Arc<Discovery>> {
        let mdns = backend(service_type).map_err(|_| anyhow::anyhow!("sync.err.paused"))?;
        let (sink, found) = channel();
        let d = Arc::new(Discovery {
            node,
            mdns,
            sink: Mutex::new(sink),
            device_name: device_name.to_string(),
            device_kind: device_kind.to_string(),
            peers: Mutex::new(HashMap::new()),
            error: Mutex::new(None),
            stop: AtomicBool::new(false),
            change_at: AtomicU64::new(0),
            force: AtomicBool::new(false),
            handled_failures: Mutex::new(Vec::new()),
        });
        let me = d.clone();
        std::thread::Builder::new().name("tl-discovery-found".into()).spawn(move || {
            while !me.stop.load(Ordering::Relaxed) {
                match found.recv_timeout(Duration::from_millis(500)) {
                    Ok(Found::Resolved { key, port, txt, v4 }) => me.resolved(key, port, &txt, v4),
                    Ok(Found::Removed(key)) => me.removed(&key),
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(_) => {}
                }
            }
        }).map_err(|e| { d.stop(); e })?;
        // Stop spawned readers and the backend if initialization fails.
        if let Err(e) = d.advertise().and_then(|_| d.browse()) { d.stop(); return Err(e); }
        let me = d.clone();
        std::thread::Builder::new().name("tl-sync-schedule".into()).spawn(move || me.schedule()).map_err(|e| { d.stop(); e })?;
        Ok(d)
    }

    /// (Re)starts browsing: every device is resolved again.
    fn browse(self: &Arc<Self>) -> anyhow::Result<()> {
        let sink = self.sink.lock().unwrap().clone();
        self.mdns.browse(sink)
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        self.mdns.shutdown();
    }

    /// Publishes this device (again: a new `rev` tells the others to look its port up anew).
    fn advertise(&self) -> anyhow::Result<()> {
        let st = self.node.status();
        let port = st.port.ok_or_else(|| anyhow::anyhow!("sync listener not running"))?;
        let dev = st.device_id.clone();
        let short: String = dev.chars().take(4).collect();
        let instance = format!("{}·{}", self.device_name, short);
        let mut props: Vec<(&str, String)> = vec![("dev", dev.clone()), ("name", self.device_name.clone()), ("rev", format!("{:x}", rand::random::<u64>()))];
        if let Some(a) = &st.account_id { props.push(("acct", a.clone())); }
        if !self.device_kind.is_empty() { props.push(("kind", self.device_kind.clone())); }
        self.mdns.register(&instance, &dev, port, &props)
    }

    fn resolved(&self, key: String, port: u16, txt: &HashMap<String, String>, mut v4: Vec<Ipv4Addr>) {
        let Some(dev) = txt.get("dev").filter(|d| !d.is_empty()).cloned() else { return };
        if dev == self.node.status().device_id { return; }
        // an IPv4 address (link-local IPv6 needs a scope id the sync client does not keep): a
        // LAN address first, loopback last (another device's 127.0.0.1 would be this device —
        // it only works when both run on one machine, as in the tests)
        v4.sort_by_key(|a| (a.is_loopback(), a.is_link_local(), !a.is_private(), *a));
        v4.dedup();
        let Some(host) = v4.first().map(|a| a.to_string()) else { return };
        let peer = Peer {
            device: dev.clone(),
            name: txt.get("name").filter(|n| !n.is_empty()).cloned().unwrap_or_else(|| key.clone()),
            account: txt.get("acct").filter(|a| !a.is_empty()).cloned(),
            kind: txt.get("kind").filter(|k| !k.is_empty()).cloned(),
            host: Some(host),
            port: Some(port),
            fullname: key,
            rev: txt.get("rev").cloned().unwrap_or_default(),
        };
        let mut peers = self.peers.lock().unwrap();
        // a resolution over a worse interface (link-local, loopback) never replaces a LAN address
        if let Some(old) = peers.get(&dev) {
            let rank = |h: &Option<String>| h.as_deref().and_then(|h| h.parse::<Ipv4Addr>().ok()).map(|a| (a.is_loopback(), a.is_link_local(), !a.is_private()));
            if old.rev == peer.rev && old.port == peer.port && rank(&old.host) < rank(&peer.host) && old.host.is_some() { return; }
        }
        peers.insert(dev, peer);
    }

    fn removed(&self, key: &str) {
        for p in self.peers.lock().unwrap().values_mut() {
            if p.fullname == key { p.host = None; p.port = None; }
        }
    }

    /// A local change: sync in 3 s (more changes meanwhile push it back).
    pub fn changed(&self) { self.change_at.store(now_ms() + 3000, Ordering::Relaxed); }

    /// 立即同步: every device of the account, whichever side would normally start.
    pub fn sync_now(self: &Arc<Self>) {
        // look everyone up again: a restarted app has a new port
        if self.browse().is_err() { *self.error.lock().unwrap() = Some("sync.err.paused".into()); }
        self.force.store(true, Ordering::Relaxed);
    }

    /// The network changed (wake from sleep, back to the foreground): advertise and look up again.
    pub fn rediscover(self: &Arc<Self>) {
        for p in self.peers.lock().unwrap().values_mut() { p.host = None; p.port = None; }
        if self.advertise().is_err() { *self.error.lock().unwrap() = Some("sync.err.paused".into()); }
        self.sync_now();
    }

    pub fn status(&self) -> DiscoveryStatus {
        let mut peers: Vec<Peer> = self.peers.lock().unwrap().values().cloned().collect();
        peers.sort_by(|a, b| a.name.cmp(&b.name));
        let running = !self.stop.load(Ordering::Relaxed);
        let network_ok = running && self.mdns.network_ok();
        // the backend's own reason first (the system refused: the Local Network permission)
        DiscoveryStatus { running, network_ok, peers, error: if running && !network_ok {
            Some(self.mdns.error().unwrap_or_else(|| "sync.err.paused".into()))
        } else { self.error.lock().unwrap().clone() } }
    }

    fn schedule(self: Arc<Self>) {
        let mut last_round = Instant::now() - Duration::from_secs(20);
        let mut last_retry = Instant::now();
        while !self.stop.load(Ordering::Relaxed) {
            std::thread::sleep(Duration::from_millis(500));
            // the system's mDNS connection can go (iOS cuts a suspended app's): announce and look
            // again every 10 s until it works, rather than staying "paused"
            if !self.mdns.network_ok() && last_retry.elapsed() >= Duration::from_secs(10) {
                last_retry = Instant::now();
                if self.advertise().is_ok() { let _ = self.browse(); }
            }
            self.drop_failed();
            let change = self.change_at.load(Ordering::Relaxed);
            let due_change = change != 0 && now_ms() >= change;
            let forced = self.force.swap(false, Ordering::Relaxed);
            if forced || due_change || last_round.elapsed() >= Duration::from_secs(20) {
                if due_change { self.change_at.store(0, Ordering::Relaxed); }
                last_round = Instant::now();
                self.sync_all(forced);
            }
        }
    }

    /// One round: the account's reachable peers, by the rule of who starts.
    fn sync_all(&self, forced: bool) {
        let st = self.node.status();
        let Some(mine) = st.account_id.clone() else { return };
        let now = now_ms() / 1000;
        let targets: Vec<(String, u16)> = self.peers.lock().unwrap().values()
            .filter(|p| p.account.as_deref() == Some(mine.as_str()))
            .filter(|p| {
                let last = st.peers.iter().find(|x| x.device == p.device).map_or(0, |x| x.last_sync);
                forced || st.device_id < p.device || now.saturating_sub(last) > 60
            })
            .filter_map(|p| Some((p.host.clone()?, p.port?)))
            .collect();
        for (host, port) in targets {
            let node = self.node.clone();
            crate::download::runtime().spawn(async move { let _ = node.sync_with(&host, port).await; });
        }
    }

    /// An address whose last attempt failed may be stale: forget it so the device is resolved again.
    fn drop_failed(self: &Arc<Self>) {
        let st = self.node.status();
        let stale = new_failures(&mut self.handled_failures.lock().unwrap(), &st.failed);
        if stale.is_empty() { return; }
        let mut peers = self.peers.lock().unwrap();
        for p in peers.values_mut() {
            if let (Some(h), Some(port)) = (&p.host, p.port) {
                if stale.contains(&format!("{h}:{port}")) { p.host = None; p.port = None; }
            }
        }
        drop(peers);
        let _ = self.browse();
    }
}

/// The addresses whose failure has not been acted on yet. A failure that is gone (the address
/// worked again) is forgotten, so the same failure coming back later counts as new.
fn new_failures(handled: &mut Vec<String>, failed: &std::collections::BTreeMap<String, String>) -> Vec<String> {
    let current: Vec<String> = failed.iter().map(|(addr, err)| format!("{addr} {err}")).collect();
    handled.retain(|key| current.contains(key));
    let mut stale = Vec::new();
    for (key, addr) in current.into_iter().zip(failed.keys()) {
        if !handled.contains(&key) { handled.push(key); stale.push(addr.clone()); }
    }
    stale
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_failure_is_acted_on_once_until_the_address_has_worked_again() {
        let failed = std::collections::BTreeMap::from([("10.0.0.5:7000".to_string(), "timeout".to_string())]);
        let mut handled = Vec::new();
        assert_eq!(new_failures(&mut handled, &failed), ["10.0.0.5:7000"]);
        assert!(new_failures(&mut handled, &failed).is_empty(), "the same failure again: nothing new");
        assert!(new_failures(&mut handled, &Default::default()).is_empty());
        assert!(handled.is_empty(), "it worked: forgotten");
        assert_eq!(new_failures(&mut handled, &failed), ["10.0.0.5:7000"], "it failed again later");
    }

    #[test]
    fn status_reports_the_error_key() {
        let status = DiscoveryStatus { running: true, network_ok: false, peers: vec![], error: Some("sync.err.paused".into()) };
        let json = serde_json::to_value(status).unwrap();
        assert_eq!(json["network_ok"], false);
        assert_eq!(json["error"], "sync.err.paused");
    }

    #[test]
    fn a_lan_address_beats_loopback_and_link_local() {
        let mut v: Vec<std::net::Ipv4Addr> = ["127.0.0.1", "169.254.3.4", "8.8.8.8", "192.168.1.20", "10.0.0.5"].iter().map(|s| s.parse().unwrap()).collect();
        v.sort_by_key(|a| (a.is_loopback(), a.is_link_local(), !a.is_private(), *a));
        assert_eq!(v[0].to_string(), "10.0.0.5");
        assert_eq!(v[1].to_string(), "192.168.1.20");
        assert_eq!(v.last().unwrap().to_string(), "127.0.0.1");
    }
}

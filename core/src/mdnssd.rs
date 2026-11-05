//! The portable backend (Android, Windows, Linux): the `mdns-sd` responder, which joins the mDNS
//! multicast group itself. Apple platforms use the system's Bonjour instead (`dnssd.rs`): there an
//! app's own multicast sockets need a special entitlement (iOS) or compete with mDNSResponder.
use crate::discovery::{Backend, Found};
use mdns_sd::{DaemonEvent, IfKind, ServiceDaemon, ServiceEvent, ServiceInfo};
use std::collections::HashSet;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub(super) struct MdnsSd {
    daemon: ServiceDaemon,
    service_type: String,
    registered: Mutex<Option<String>>,
    network_ok: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
}

impl MdnsSd {
    pub(super) fn new(service_type: &str) -> anyhow::Result<MdnsSd> {
        let daemon = ServiceDaemon::new().map_err(|_| anyhow::anyhow!("sync.err.paused"))?;
        // Subscribe before re-enabling interfaces so the initial successful joins
        // are observed too. The daemon serializes these commands in FIFO order.
        daemon.disable_interface(IfKind::All).map_err(|e| { let _ = daemon.shutdown(); e })?;
        let events = daemon.monitor().map_err(|e| { let _ = daemon.shutdown(); e })?;
        daemon.enable_interface(IfKind::All).map_err(|e| { let _ = daemon.shutdown(); e })?;
        let network_ok = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let (ok, halt) = (network_ok.clone(), stop.clone());
        std::thread::Builder::new().name("tl-discovery-network".into()).spawn(move || {
            let mut network = NetworkState::default();
            while !halt.load(Ordering::Relaxed) {
                match events.recv_timeout(Duration::from_millis(500)) {
                    Ok(event) => { network.event(event); ok.store(network.ok(), Ordering::Relaxed); }
                    Err(_) if events.is_disconnected() => break,
                    Err(_) => {}
                }
            }
            ok.store(false, Ordering::Relaxed);
        })?;
        Ok(MdnsSd {
            daemon,
            service_type: format!("{}.local.", service_type.trim_end_matches('.')),
            registered: Mutex::new(None),
            network_ok,
            stop,
        })
    }
}

impl Backend for MdnsSd {
    fn register(&self, instance: &str, device: &str, port: u16, txt: &[(&str, String)]) -> anyhow::Result<()> {
        let host = format!("tl-{}.local.", device.chars().filter(|c| c.is_ascii_alphanumeric()).take(12).collect::<String>());
        let info = ServiceInfo::new(&self.service_type, instance, &host, "", port, txt)?.enable_addr_auto();
        if let Some(old) = self.registered.lock().unwrap().take() { let _ = self.daemon.unregister(&old); }
        let full = info.get_fullname().to_string();
        self.daemon.register(info)?;
        *self.registered.lock().unwrap() = Some(full);
        Ok(())
    }

    fn browse(&self, sink: Sender<Found>) -> anyhow::Result<()> {
        let _ = self.daemon.stop_browse(&self.service_type);
        let rx = self.daemon.browse(&self.service_type)?;
        let stop = self.stop.clone();
        std::thread::Builder::new().name("tl-discovery".into()).spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                let found = match rx.recv_timeout(Duration::from_millis(500)) {
                    Ok(ServiceEvent::ServiceResolved(info)) => Found::Resolved {
                        key: info.get_fullname().to_string(),
                        port: info.get_port(),
                        txt: info.get_properties().iter().map(|p| (p.key().to_string(), p.val_str().to_string())).collect(),
                        v4: info.get_addresses_v4().into_iter().collect(),
                    },
                    Ok(ServiceEvent::ServiceRemoved(_, fullname)) => Found::Removed(fullname),
                    Ok(ServiceEvent::SearchStopped(_)) => break,
                    Ok(_) => continue,
                    Err(_) if rx.is_disconnected() => break,
                    Err(_) => continue,
                };
                if sink.send(found).is_err() { break; }
            }
        })?;
        Ok(())
    }

    fn network_ok(&self) -> bool { self.network_ok.load(Ordering::Relaxed) }

    fn shutdown(&self) {
        self.stop.store(true, Ordering::Relaxed);
        self.network_ok.store(false, Ordering::Relaxed);
        if let Some(name) = self.registered.lock().unwrap().take() { let _ = self.daemon.unregister(&name); }
        let _ = self.daemon.stop_browse(&self.service_type);
        let _ = self.daemon.shutdown();
    }
}

// IpAdd is sent only after a socket has actually joined the multicast group;
// IpDel removes that address on link loss. An error without an address does not
// invalidate unrelated working interfaces.
#[derive(Default)]
pub(super) struct NetworkState { addresses: HashSet<IpAddr> }
impl NetworkState {
    pub(super) fn event(&mut self, event: DaemonEvent) {
        match event {
            DaemonEvent::IpAdd(ip) if !ip.is_loopback() => { self.addresses.insert(ip); }
            DaemonEvent::IpDel(ip) => { self.addresses.remove(&ip); }
            _ => {}
        }
    }
    pub(super) fn ok(&self) -> bool { !self.addresses.is_empty() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn multicast_health_tracks_joins_and_link_loss_without_needing_peers() {
        let mut state = NetworkState::default();
        assert!(!state.ok());
        state.event(DaemonEvent::IpAdd("127.0.0.1".parse().unwrap()));
        assert!(!state.ok());
        let a = "192.0.2.1".parse().unwrap();
        let b = "2001:db8::1".parse().unwrap();
        state.event(DaemonEvent::IpAdd(a));
        state.event(DaemonEvent::IpAdd(b));
        assert!(state.ok());
        state.event(DaemonEvent::IpDel(a));
        assert!(state.ok());
        state.event(DaemonEvent::IpDel(b));
        assert!(!state.ok());
    }
}

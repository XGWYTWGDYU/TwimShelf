//! Decentralized LAN sync. Every device is equal: each runs a listener, discovers peers via
//! Bonjour (done by the app), and periodically syncs pairwise with every visible peer of the same
//! account. Pairwise exchange of op-log suffixes (by version vector) makes all devices converge.
//!
//! Security: devices of one account share a 256-bit account key. A sync session starts with a
//! mutual HMAC challenge over fresh nonces, then derives per-direction ChaCha20-Poly1305 keys with
//! HKDF. A new device obtains the account key by entering a 6-digit code shown on a paired
//! device; the code is run through SPAKE2, so an eavesdropper cannot brute-force it offline and an
//! active attacker gets one guess per attempt (max 5 per code, 5-minute lifetime).
use crate::library::Library;
use crate::oplog::{blob_rel, LoggedOp, VersionVector};
use anyhow::{anyhow, bail, Context};
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use spake2::{Ed25519Group, Identity, Password, Spake2};
use std::collections::{BTreeMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Largest encrypted frame (after authentication). Ops are sent in batches of at most
/// OPS_BYTES, so a batch always fits; one op is never larger than a post (its fields are limited, see PostMeta::clamped).
const MAX_FRAME: usize = 16 << 20;
/// Largest op in the log, with room for the batch around it (see `Store::record`).
pub(crate) const MAX_OP_BYTES: usize = 15 << 20;
/// Largest frame before authentication: handshake messages are tiny, and a stranger on the
/// network must not make this device allocate megabytes per connection.
const MAX_HANDSHAKE_FRAME: usize = 64 << 10;
/// Batches of ops are cut at this many bytes as well as OPS_BATCH ops.
const OPS_BYTES: usize = 4 << 20;
/// Connections being handshaken at once (more are closed at once), and how long a handshake may take.
const MAX_INCOMING: usize = 32;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
const CHUNK: usize = 256 << 10;
const OPS_BATCH: usize = 2000;
const PAIR_TTL: Duration = Duration::from_secs(300);
const PAIR_ATTEMPTS: u8 = 5;

type HmacSha = Hmac<Sha256>;

#[derive(Clone)]
pub struct Account { pub key: [u8; 32], pub id: String }

impl Account {
    pub fn from_key(key: [u8; 32]) -> Account {
        let id = hex::encode(&Sha256::new().chain_update(b"tl-account-v1").chain_update(key).finalize()[..8]);
        Account { key, id }
    }
    pub fn generate() -> Account { Account::from_key(rand::random()) }
}

struct Pairing { code: String, expires: Instant, attempts: u8 }

#[derive(Debug, Clone, Serialize, Default)]
pub struct PeerInfo { pub device: String, pub name: String, pub last_sync: u64, pub last_error: Option<String>, pub addr: String,
    /// Peer clock minus ours, in ms, at the last session (None before the first one).
    pub clock_skew_ms: Option<i64>,
    /// The difference is large enough to matter (recycle-bin expiry and last-writer-wins use wall time).
    pub clock_warning: bool }

#[derive(Debug, Clone, Serialize, Default)]
pub struct JoinState { pub running: bool, pub account_key: Option<String>, pub error: Option<String> }

/// Live progress of media being received in the current sessions.
#[derive(Debug, Clone, Serialize, Default)]
pub struct Transfer {
    /// Files received / wanted in this round.
    pub received: u64,
    pub total: u64,
    /// Total size of this round (known once the sender's plan arrives; 0 before).
    pub total_bytes: u64,
    /// Bytes received in this round (including the file in flight).
    pub bytes: u64,
    /// Size and progress of the file currently arriving.
    pub current_size: u64,
    pub current_done: u64,
    /// Absolute path of the most recently stored media (for previews).
    pub last_path: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SyncStatus {
    pub account_id: Option<String>,
    pub device_id: String,
    pub device_name: String,
    pub port: Option<u16>,
    pub pairing_code: Option<String>,
    pub pairing_seconds_left: Option<u64>,
    pub peers: Vec<PeerInfo>,
    pub syncing: usize,
    pub changes: u64,
    pub join: JoinState,
    pub receiving: Option<Transfer>,
    /// Addresses ("host:port") whose last attempt failed before or during a session, with the
    /// reason: the app then looks the device up again (its port changes when it restarts) and
    /// shows the reason instead of staying silent.
    pub failed: BTreeMap<String, String>,
    /// Devices with a session running now (the schedulers do not start another one with them).
    #[serde(default)]
    pub in_session: Vec<String>,
}

pub struct SyncNode {
    lib: Arc<Library>,
    account_revision: tokio::sync::watch::Sender<u64>,
    account: Mutex<Option<Account>>,
    device_name: Mutex<String>,
    port: Mutex<Option<u16>>,
    pairing: Mutex<Option<Pairing>>,
    peers: Mutex<BTreeMap<String, PeerInfo>>,
    active: Mutex<HashSet<String>>,
    /// Peer devices with a session in progress (one session per peer at a time).
    peer_sessions: Mutex<HashSet<String>>,
    /// Files being fetched by a running session: a session with another device asks for the
    /// rest, so a new device filling up from two peers at once never receives a file twice.
    claimed: Mutex<HashSet<String>>,
    failed: Mutex<BTreeMap<String, String>>,
    transfer: Mutex<Option<Transfer>>,
    join: Mutex<JoinState>,
    changes: AtomicU64,
    shutdown: Mutex<Option<tokio::sync::watch::Sender<bool>>>,
}

const ALREADY_SYNCING: &str = "already syncing with this device";
fn is_busy(e: &anyhow::Error) -> bool { format!("{e:#}").contains(ALREADY_SYNCING) }

fn now_s() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()) }
fn now_ms() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64) }
fn hmac(key: &[u8], parts: &[&[u8]]) -> Vec<u8> {
    let mut m = <HmacSha as Mac>::new_from_slice(key).unwrap();
    for p in parts { m.update(p); }
    m.finalize().into_bytes().to_vec()
}
fn hmac_ok(key: &[u8], parts: &[&[u8]], tag: &[u8]) -> bool {
    let mut m = <HmacSha as Mac>::new_from_slice(key).unwrap();
    for p in parts { m.update(p); }
    m.verify_slice(tag).is_ok()
}

// ---------- framing ----------

/// Anything a session can run over: a TCP connection in the app, an in-memory pipe with
/// injected faults in the simulation tests.
pub trait Wire: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Wire for T {}

async fn write_frame<S: AsyncWrite + Unpin + ?Sized>(s: &mut S, b: &[u8]) -> anyhow::Result<()> {
    if b.len() > MAX_FRAME { bail!("frame too large"); }
    s.write_all(&(b.len() as u32).to_be_bytes()).await?;
    s.write_all(b).await?;
    Ok(())
}
async fn read_frame<S: AsyncRead + Unpin + ?Sized>(s: &mut S, max: usize) -> anyhow::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    s.read_exact(&mut len).await?;
    let n = u32::from_be_bytes(len) as usize;
    if n > max { bail!("frame too large"); }
    let mut b = vec![0u8; n];
    s.read_exact(&mut b).await?;
    Ok(b)
}
async fn send_json<T: Serialize>(s: &mut TcpStream, v: &T) -> anyhow::Result<()> { write_frame(s, &serde_json::to_vec(v)?).await }
async fn recv_json<T: for<'a> Deserialize<'a>>(s: &mut TcpStream) -> anyhow::Result<T> { Ok(serde_json::from_slice(&read_frame(s, MAX_HANDSHAKE_FRAME).await?)?) }

/// How long a model transfer may stay silent (no answer, no next chunk) before it is given up.
const MODEL_SILENCE: Duration = Duration::from_secs(60);

/// Waits for a peer's answer, for at most `MODEL_SILENCE`.
async fn silence_limited<T>(f: impl std::future::Future<Output = anyhow::Result<T>>) -> anyhow::Result<T> {
    tokio::time::timeout(MODEL_SILENCE, f).await.map_err(|_| anyhow!(tr!("sync.peerSilent")))?
}

/// A step of pulling a model from a peer: ends at once when the transfer is cancelled (not only
/// between chunks, as a peer that stops answering would otherwise hold the cancel back for as
/// long as it likes), and gives up after `MODEL_SILENCE`.
async fn model_wait<T>(f: impl std::future::Future<Output = anyhow::Result<T>>) -> anyhow::Result<T> {
    let cancelled = async { while !crate::models::external_cancelled() { tokio::time::sleep(Duration::from_millis(100)).await; } };
    tokio::select! {
        biased;
        _ = cancelled => bail!(tr!("common.cancelled")),
        r = silence_limited(f) => r,
    }
}

/// Encrypted, ordered channel. Nonce = 4 zero bytes || 64-bit counter; keys differ per direction.
struct Channel { s: Box<dyn Wire>, tx: ChaCha20Poly1305, rx: ChaCha20Poly1305, tx_n: u64, rx_n: u64,
    /// Library generation when the session began: writes stop if a wipe happened since.
    epoch: u64,
    revoked: tokio::sync::watch::Receiver<u64> }

impl Channel {
    fn check(&self) -> anyhow::Result<()> {
        if self.revoked.has_changed().unwrap_or(true) { bail!(tr!("sync.accountGone")); }
        Ok(())
    }
    fn nonce(n: u64) -> Nonce { let mut b = [0u8; 12]; b[4..].copy_from_slice(&n.to_be_bytes()); *Nonce::from_slice(&b) }
    async fn send_raw(&mut self, b: &[u8]) -> anyhow::Result<()> {
        self.check()?;
        let n = crate::rules::take_channel_nonce(&mut self.tx_n).ok_or_else(|| anyhow!("channel nonce exhausted"))?;
        let c = self.tx.encrypt(&Self::nonce(n), b).map_err(|_| anyhow!("encrypt"))?;
        tokio::select! {
            biased;
            _ = self.revoked.changed() => bail!(tr!("sync.accountGone")),
            r = write_frame(&mut self.s, &c) => r,
        }
    }
    async fn recv_raw(&mut self) -> anyhow::Result<Vec<u8>> {
        self.check()?;
        if self.rx_n == u64::MAX { bail!("channel nonce exhausted"); }
        let c = tokio::select! {
            biased;
            _ = self.revoked.changed() => bail!(tr!("sync.accountGone")),
            r = read_frame(&mut self.s, MAX_FRAME) => r?,
        };
        self.check()?;
        let p = self.rx.decrypt(&Self::nonce(self.rx_n), c.as_ref()).map_err(|_| anyhow!(tr!("sync.authFailed")))?;
        crate::rules::take_channel_nonce(&mut self.rx_n).ok_or_else(|| anyhow!("channel nonce exhausted"))?;
        Ok(p)
    }
    async fn send(&mut self, m: &Msg) -> anyhow::Result<()> { self.send_raw(&serde_json::to_vec(m)?).await }
    async fn recv(&mut self) -> anyhow::Result<Msg> { Ok(serde_json::from_slice(&self.recv_raw().await?)?) }
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "m", rename_all = "snake_case")]
enum Msg {
    Hello { device: String, name: String, vv: VersionVector, #[serde(default)] now_ms: u64 },
    Ops { ops: Vec<LoggedOp> },
    OpsEnd,
    Want { blobs: Vec<(String, String)> },
    /// Sent once before the blobs: how many of the requested files the sender has and their total size.
    Plan { files: u64, bytes: u64 },
    Blob { id: String, ext: String, size: u64 },
    NoBlob { id: String },
    BlobsEnd,
    Bye,
    /// "A session with your device is already running": the side that finds the duplicate says
    /// so instead of hanging up, and neither side takes it for a failure.
    Busy,
    // ---- on-demand model sharing (mode "models") ----
    ListModels,
    Models { list: Vec<crate::models::ModelInfo> },
    FetchModel { id: String },
    ModelFile { name: String, size: u64 },
    ModelEnd,
    ModelError { message: String },
}

#[derive(Serialize, Deserialize)]
struct Hello1 { v: u32, mode: String, account: Option<String>, device: String, nonce: Option<String>, spake: Option<String> }
#[derive(Serialize, Deserialize, Default)]
struct Hello2 { error: Option<String>, nonce: Option<String>, device: Option<String>, mac: Option<String>, spake: Option<String>, sealed: Option<String> }
#[derive(Serialize, Deserialize)]
struct Hello3 { mac: Option<String>, ack: Option<String> }

fn session_keys(account: &[u8; 32], ni: &[u8], nr: &[u8]) -> (ChaCha20Poly1305, ChaCha20Poly1305) {
    let salt = [ni, nr].concat();
    let hk = hkdf::Hkdf::<Sha256>::new(Some(&salt), account);
    let (mut a, mut b) = ([0u8; 32], [0u8; 32]);
    hk.expand(b"tl-sync-v1 i2r", &mut a).unwrap();
    hk.expand(b"tl-sync-v1 r2i", &mut b).unwrap();
    (ChaCha20Poly1305::new(Key::from_slice(&a)), ChaCha20Poly1305::new(Key::from_slice(&b)))
}

impl SyncNode {
    pub fn new(lib: Arc<Library>) -> Arc<SyncNode> {
        Arc::new(SyncNode {
            account_revision: tokio::sync::watch::channel(0).0,
            lib, account: Mutex::new(None), device_name: Mutex::new(tr!("sync.defaultName").into()), port: Mutex::new(None),
            pairing: Mutex::new(None), peers: Mutex::new(BTreeMap::new()), active: Mutex::new(HashSet::new()), peer_sessions: Mutex::new(HashSet::new()), claimed: Mutex::new(HashSet::new()), failed: Mutex::new(BTreeMap::new()), transfer: Mutex::new(None),
            join: Mutex::new(JoinState::default()), changes: AtomicU64::new(0), shutdown: Mutex::new(None),
        })
    }

    fn device_id(&self) -> String { self.lib.db().device_id().unwrap_or_default() }
    fn account(&self) -> Option<Account> { self.account.lock().unwrap().clone() }

    pub fn status(&self) -> SyncStatus {
        let (pairing_code, pairing_seconds_left) = {
            let pairing = self.pairing.lock().unwrap();
            let live = pairing.as_ref().filter(|p| p.expires > Instant::now() && p.attempts < PAIR_ATTEMPTS);
            (live.map(|p| p.code.clone()), live.map(|p| p.expires.saturating_duration_since(Instant::now()).as_secs()))
        };
        // (a guard taken inside the literal lives until its end: lock once, before it)
        let mut in_session: Vec<String> = self.peer_sessions.lock().unwrap().iter().cloned().collect();
        in_session.sort();
        SyncStatus {
            account_id: self.account().map(|a| a.id),
            device_id: self.device_id(),
            device_name: self.device_name.lock().unwrap().clone(),
            port: *self.port.lock().unwrap(),
            pairing_code,
            pairing_seconds_left,
            peers: self.peers.lock().unwrap().values().cloned().collect(),
            syncing: self.active.lock().unwrap().len().max(in_session.len()),
            receiving: self.transfer.lock().unwrap().clone(),
            changes: self.changes.load(Ordering::SeqCst),
            join: self.join.lock().unwrap().clone(),
            failed: self.failed.lock().unwrap().clone(),
            in_session,
        }
    }

    /// Starts listening (idempotent). `account` may be None for a device waiting to join.
    pub async fn start(self: &Arc<Self>, account: Option<Account>, name: String) -> anyhow::Result<u16> {
        {
            let mut current = self.account.lock().unwrap();
            if current.as_ref().map(|a| a.key) != account.as_ref().map(|a| a.key) {
                self.account_revision.send_modify(|r| *r = r.wrapping_add(1));
                *self.pairing.lock().unwrap() = None;
                *self.join.lock().unwrap() = JoinState::default();
            }
            *current = account;
        }
        *self.device_name.lock().unwrap() = name;
        if let Some(p) = *self.port.lock().unwrap() { return Ok(p); }
        let v4 = TcpListener::bind("0.0.0.0:0").await?;
        let port = v4.local_addr()?.port();
        let v6 = TcpListener::bind(format!("[::]:{port}")).await.ok();
        let (tx, rx) = tokio::sync::watch::channel(false);
        *self.shutdown.lock().unwrap() = Some(tx);
        *self.port.lock().unwrap() = Some(port);
        let slots = Arc::new(tokio::sync::Semaphore::new(MAX_INCOMING));
        for l in std::iter::once(v4).chain(v6) {
            let me = self.clone();
            let mut rx = rx.clone();
            let slots = slots.clone();
            tokio::spawn(async move {
                loop {
                    tokio::select! {
                        _ = rx.changed() => break,
                        r = l.accept() => if let Ok((s, addr)) = r {
                            // too many connections at once (a flood): close this one right away
                            let Ok(slot) = slots.clone().try_acquire_owned() else { drop(s); continue };
                            let me = me.clone();
                            tokio::spawn(async move {
                                let _slot = slot;
                                let _ = s.set_nodelay(true);
                                if let Err(e) = tokio::time::timeout(Duration::from_secs(3600), me.handle_incoming(s)).await.unwrap_or_else(|_| Err(anyhow!("timeout"))) {
                                    log::debug(&format!("incoming {addr}: {e:#}"));
                                }
                            });
                        } else {
                            // iOS may invalidate a listener during suspension. Do not busy-loop
                            // on a permanently failed socket; foreground recovery rebinds it.
                            break;
                        }
                    }
                }
            });
        }
        Ok(port)
    }

    /// A suspended iOS process may retain its advertised port after the OS invalidated
    /// the listening socket. Rebind on foreground without revoking authenticated sessions.
    pub async fn restart_listener(self: &Arc<Self>) -> anyhow::Result<u16> {
        if let Some(tx) = self.shutdown.lock().unwrap().take() { let _ = tx.send(true); }
        *self.port.lock().unwrap() = None;
        let account = self.account();
        let name = self.device_name.lock().unwrap().clone();
        self.start(account, name).await
    }

    pub fn stop(&self) {
        let _account = self.account.lock().unwrap();
        self.account_revision.send_modify(|r| *r = r.wrapping_add(1));
        if let Some(tx) = self.shutdown.lock().unwrap().take() { let _ = tx.send(true); }
        *self.port.lock().unwrap() = None;
    }

    /// Forgets the account and everything learned about peers. Used by "清除所有数据".
    pub fn reset(&self) {
        self.stop();
        *self.account.lock().unwrap() = None;
        *self.pairing.lock().unwrap() = None;
        self.peers.lock().unwrap().clear();
        *self.join.lock().unwrap() = JoinState::default();
    }

    /// Shows a fresh 6-digit pairing code on this (already paired) device.
    pub fn begin_pairing(&self) -> anyhow::Result<String> {
        let account = self.account.lock().unwrap();
        if account.is_none() { bail!(tr!("sync.noAccountYet")); }
        let code = format!("{:06}", rand::random::<u32>() % 1_000_000);
        *self.pairing.lock().unwrap() = Some(Pairing { code: code.clone(), expires: Instant::now() + PAIR_TTL, attempts: 0 });
        Ok(code)
    }
    pub fn cancel_pairing(&self) { *self.pairing.lock().unwrap() = None; }

    // ---------- incoming ----------

    /// Everything before authentication (or the pairing exchange) must finish within
    /// HANDSHAKE_TIMEOUT: a connection that sends nothing is closed instead of held for an hour.
    async fn handle_incoming(self: &Arc<Self>, mut s: TcpStream) -> anyhow::Result<()> {
        let hs = |e| anyhow!("handshake: {e}");
        let h: Hello1 = tokio::time::timeout(HANDSHAKE_TIMEOUT, recv_json(&mut s)).await.map_err(hs)??;
        if h.v != 1 { bail!("unsupported version"); }
        match h.mode.as_str() {
            "pair" => tokio::time::timeout(HANDSHAKE_TIMEOUT, self.host_pairing(s, h)).await.map_err(hs)?,
            "sync" => {
                let addr = s.peer_addr().map(|a| a.to_string()).unwrap_or_default();
                let ch = tokio::time::timeout(HANDSHAKE_TIMEOUT, self.accept_auth(s, h)).await.map_err(hs)??;
                self.run_session(ch, false, addr).await
            }
            "models" => {
                let ch = tokio::time::timeout(HANDSHAKE_TIMEOUT, self.accept_auth(s, h)).await.map_err(hs)??;
                self.serve_models(ch).await
            }
            _ => bail!("unknown mode"),
        }
    }

    /// Responder side of the mutual HMAC handshake; returns the encrypted channel.
    async fn accept_auth(&self, mut s: TcpStream, h: Hello1) -> anyhow::Result<Channel> {
        let revoked = self.account_revision.subscribe();
        let epoch = self.lib.epoch();
        let Some(acct) = self.account() else { send_json(&mut s, &Hello2 { error: Some("no_account".into()), ..Default::default() }).await?; bail!("no account") };
        if h.account.as_deref() != Some(&acct.id) { send_json(&mut s, &Hello2 { error: Some("account".into()), ..Default::default() }).await?; bail!("other account"); }
        let ni = hex::decode(h.nonce.unwrap_or_default())?;
        if ni.len() != 32 { bail!("bad nonce"); }
        let nr: [u8; 32] = rand::random();
        let me = self.device_id();
        send_json(&mut s, &Hello2 { nonce: Some(hex::encode(nr)), device: Some(me), mac: Some(hex::encode(hmac(&acct.key, &[b"R", &ni, &nr]))), ..Default::default() }).await?;
        let h3: Hello3 = recv_json(&mut s).await?;
        if !hmac_ok(&acct.key, &[b"I", &ni, &nr], &hex::decode(h3.mac.unwrap_or_default())?) { bail!("peer failed authentication"); }
        let (i2r, r2i) = session_keys(&acct.key, &ni, &nr);
        Ok(Channel { s: Box::new(s), tx: r2i, rx: i2r, tx_n: 0, rx_n: 0, epoch, revoked })
    }

    /// Initiator side of the handshake for `mode` ("sync" or "models").
    async fn connect_auth(&self, host: &str, port: u16, mode: &str) -> anyhow::Result<Channel> {
        let revoked = self.account_revision.subscribe();
        let epoch = self.lib.epoch();
        let acct = self.account().ok_or_else(|| anyhow!(tr!("sync.notJoined")))?;
        let mut s = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect((host, port))).await.map_err(|_| anyhow!(tr!("sync.timeout")))??;
        let _ = s.set_nodelay(true);
        let ni: [u8; 32] = rand::random();
        // A peer may accept the connection and then say nothing: its answer is waited for a
        // limited time only, and leaving the account (or "clear all data") ends the wait at once
        // (the channel's own checks only start once the handshake is done).
        let mut leaving = revoked.clone();
        let handshake = async {
            send_json(&mut s, &Hello1 { v: 1, mode: mode.into(), account: Some(acct.id.clone()), device: self.device_id(), nonce: Some(hex::encode(ni)), spake: None }).await?;
            let h2: Hello2 = recv_json(&mut s).await?;
            if let Some(e) = h2.error { bail!(tr!("sync.refused", e = e)); }
            let nr = hex::decode(h2.nonce.unwrap_or_default())?;
            if !hmac_ok(&acct.key, &[b"R", &ni, &nr], &hex::decode(h2.mac.unwrap_or_default())?) { bail!(tr!("sync.peerUnauthenticated")); }
            send_json(&mut s, &Hello3 { mac: Some(hex::encode(hmac(&acct.key, &[b"I", &ni, &nr]))), ack: None }).await?;
            Ok::<_, anyhow::Error>(nr)
        };
        let nr = tokio::select! {
            biased;
            _ = leaving.changed() => bail!(tr!("sync.accountGone")),
            r = tokio::time::timeout(HANDSHAKE_TIMEOUT, handshake) => r.map_err(|_| anyhow!(tr!("sync.handshakeTimeout")))??,
        };
        let (i2r, r2i) = session_keys(&acct.key, &ni, &nr);
        Ok(Channel { s: Box::new(s), tx: i2r, rx: r2i, tx_n: 0, rx_n: 0, epoch, revoked })
    }

    // ---------- on-demand model sharing ----------

    /// Answers one model request: a list, or the files of one model.
    async fn serve_models(&self, mut ch: Channel) -> anyhow::Result<()> {
        let dir = self.lib.models_dir();
        match ch.recv().await? {
            // MLX folders only: they run on Apple devices alone, and only those pull models
            Msg::ListModels => ch.send(&Msg::Models { list: crate::models::installed(&dir).into_iter().filter(|m| m.format == "mlx").collect() }).await,
            Msg::FetchModel { id } => {
                let Ok(id) = crate::models::checked_id(&id).map(str::to_string) else { return ch.send(&Msg::ModelError { message: tr!("models.badName").into() }).await };
                let mdir = dir.join(&id);
                if crate::models::validate_dir(&mdir).is_err() { return ch.send(&Msg::ModelError { message: tr!("sync.noSuchModel").into() }).await; }
                let mut names: Vec<String> = std::fs::read_dir(&mdir)?.filter_map(|e| e.ok()).filter(|e| e.path().is_file())
                    .map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| crate::models::is_wanted_file(n)).collect();
                names.sort();
                for n in names {
                    let mut f = tokio::fs::File::open(mdir.join(&n)).await?;
                    let size = f.metadata().await?.len();
                    ch.send(&Msg::ModelFile { name: n, size }).await?;
                    let mut buf = vec![0u8; CHUNK];
                    let mut left = size;
                    while left > 0 {
                        let k = f.read(&mut buf[..(CHUNK as u64).min(left) as usize]).await?;
                        if k == 0 { bail!("model file truncated"); }
                        ch.send_raw(&buf[..k]).await?;
                        left -= k as u64;
                    }
                }
                ch.send(&Msg::ModelEnd).await
            }
            _ => bail!("protocol: models"),
        }
    }

    /// Models installed on a peer (asks only; transfers nothing).
    pub async fn peer_models(&self, host: &str, port: u16) -> anyhow::Result<Vec<crate::models::ModelInfo>> {
        let mut ch = self.connect_auth(host, port, "models").await?;
        silence_limited(ch.send(&Msg::ListModels)).await?;
        match silence_limited(ch.recv()).await? { Msg::Models { list } => Ok(list), _ => bail!("protocol: models") }
    }

    /// Copies one model folder from a peer, validates it, then installs it. Progress is reported
    /// through the model-download status.
    pub async fn pull_model(&self, host: &str, port: u16, id: &str, label: &str, total: u64) -> anyhow::Result<()> {
        crate::models::begin_external(label, total)?;
        let r = self.pull_model_inner(host, port, id).await;
        crate::models::end_external(&r);
        r
    }

    async fn pull_model_inner(&self, host: &str, port: u16, id: &str) -> anyhow::Result<()> {
        let id = crate::models::checked_id(id)?.to_string();
        let dir = self.lib.models_dir();
        std::fs::create_dir_all(&dir)?;
        let staging = dir.join(crate::models::staging_name(&format!("pull-{id}")));
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging)?;
        let r: anyhow::Result<()> = async {
            let mut ch = model_wait(self.connect_auth(host, port, "models")).await?;
            model_wait(ch.send(&Msg::FetchModel { id: id.clone() })).await?;
            let mut done = 0u64;
            loop {
                match model_wait(ch.recv()).await? {
                    Msg::ModelFile { name, size } => {
                        if name.contains('/') || name.contains("..") || !crate::models::is_wanted_file(&name) { bail!(tr!("sync.badFileName", name = name)); }
                        let mut f = tokio::fs::File::create(staging.join(&name)).await?;
                        let mut left = size;
                        while left > 0 {
                            if crate::models::external_cancelled() { bail!(tr!("common.cancelled")); }
                            let c = model_wait(ch.recv_raw()).await?;
                            if c.is_empty() || c.len() as u64 > left { bail!("protocol: invalid model chunk"); }
                            f.write_all(&c).await?;
                            left -= c.len() as u64;
                            done += c.len() as u64;
                            crate::models::external_progress(done, &name);
                        }
                        f.sync_all().await?;
                    }
                    Msg::ModelEnd => break,
                    Msg::ModelError { message } => bail!(message),
                    _ => bail!("protocol: model"),
                }
            }
            let _account = self.account.lock().unwrap();
            ch.check()?;
            let _db = self.lib.db_at(ch.epoch)?;
            crate::models::validate_dir(&staging)?;
            let dst = dir.join(&id);
            crate::models::replace_dir(&staging, &dst)?;
            Ok(())
        }.await;
        if r.is_err() { let _ = std::fs::remove_dir_all(&staging); }
        r
    }

    async fn host_pairing(&self, mut s: TcpStream, h: Hello1) -> anyhow::Result<()> {
        let (code, acct) = {
            let account = self.account.lock().unwrap();
            let mut p = self.pairing.lock().unwrap();
            match (p.as_mut(), account.clone()) {
                (Some(p), Some(a)) if p.expires > Instant::now() && p.attempts < PAIR_ATTEMPTS => { p.attempts += 1; (p.code.clone(), a) }
                _ => (String::new(), Account::from_key([0; 32])),
            }
        };
        if code.is_empty() { send_json(&mut s, &Hello2 { error: Some("no_pairing".into()), ..Default::default() }).await?; bail!("not pairing"); }
        let (st, msg_b) = Spake2::<Ed25519Group>::start_b(&Password::new(code.as_bytes()), &Identity::new(b"tl-joiner"), &Identity::new(b"tl-host"));
        let k = st.finish(&hex::decode(h.spake.unwrap_or_default())?).map_err(|_| anyhow!("spake"))?;
        let aead = ChaCha20Poly1305::new(Key::from_slice(&k[..32]));
        let payload = serde_json::to_vec(&serde_json::json!({ "key": hex::encode(acct.key) }))?;
        let sealed = aead.encrypt(&Channel::nonce(0), payload.as_ref()).map_err(|_| anyhow!("seal"))?;
        send_json(&mut s, &Hello2 { spake: Some(hex::encode(msg_b)), sealed: Some(hex::encode(sealed)), device: Some(self.device_id()), ..Default::default() }).await?;
        let h3: Hello3 = recv_json(&mut s).await?;
        if !hmac_ok(&k, &[b"paired"], &hex::decode(h3.ack.unwrap_or_default())?) { bail!("wrong code"); }
        *self.pairing.lock().unwrap() = None;
        Ok(())
    }

    // ---------- outgoing ----------

    /// Joins an account by pairing with `host:port` using the code shown there.
    pub fn join(self: &Arc<Self>, host: String, port: u16, code: String) {
        *self.join.lock().unwrap() = JoinState { running: true, ..Default::default() };
        let me = self.clone();
        let revision = self.account_revision.subscribe();
        tokio::spawn(async move {
            let r = tokio::time::timeout(Duration::from_secs(20), me.do_join(&host, port, code.trim())).await.unwrap_or_else(|_| Err(anyhow!(tr!("sync.timeout"))));
            let mut account = me.account.lock().unwrap();
            if revision.has_changed().unwrap_or(true) { return; }
            let mut j = me.join.lock().unwrap();
            j.running = false;
            match r {
                Ok(acct) => {
                    if account.as_ref().map(|a| a.key) != Some(acct.key) {
                        me.account_revision.send_modify(|r| *r = r.wrapping_add(1));
                    }
                    j.account_key = Some(hex::encode(acct.key)); *account = Some(acct);
                }
                Err(e) => j.error = Some(format!("{e:#}")),
            }
        });
    }

    async fn do_join(&self, host: &str, port: u16, code: &str) -> anyhow::Result<Account> {
        if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) { bail!(tr!("sync.codeFormat")); }
        let mut s = TcpStream::connect((host, port)).await.context(tr!("sync.cannotConnect"))?;
        let (st, msg_a) = Spake2::<Ed25519Group>::start_a(&Password::new(code.as_bytes()), &Identity::new(b"tl-joiner"), &Identity::new(b"tl-host"));
        send_json(&mut s, &Hello1 { v: 1, mode: "pair".into(), account: None, device: self.device_id(), nonce: None, spake: Some(hex::encode(msg_a)) }).await?;
        let h2: Hello2 = recv_json(&mut s).await?;
        if let Some(e) = h2.error { bail!(if e == "no_pairing" { tr!("sync.codeNotShown").to_string() } else { e }); }
        let k = st.finish(&hex::decode(h2.spake.unwrap_or_default())?).map_err(|_| anyhow!(tr!("sync.pairFailed")))?;
        let aead = ChaCha20Poly1305::new(Key::from_slice(&k[..32]));
        let opened = aead.decrypt(&Channel::nonce(0), hex::decode(h2.sealed.unwrap_or_default())?.as_ref()).map_err(|_| anyhow!(tr!("sync.codeWrong")))?;
        let v: serde_json::Value = serde_json::from_slice(&opened)?;
        let key: [u8; 32] = hex::decode(v["key"].as_str().unwrap_or_default())?.try_into().map_err(|_| anyhow!("bad key"))?;
        send_json(&mut s, &Hello3 { mac: None, ack: Some(hex::encode(hmac(&k, &[b"paired"]))) }).await?;
        Ok(Account::from_key(key))
    }

    /// One sync session over any wire, with fixed keys (the handshake is tested separately): the
    /// deterministic simulation tests run sessions between libraries over in-memory pipes with
    /// injected faults. Not used by the app.
    #[doc(hidden)]
    pub async fn simulated_session<W: Wire + 'static>(self: &Arc<Self>, wire: W, initiator: bool) -> anyhow::Result<()> {
        let (i2r, r2i) = session_keys(&[7u8; 32], &[1u8; 32], &[2u8; 32]);
        let (tx, rx) = if initiator { (i2r, r2i) } else { (r2i, i2r) };
        let ch = Channel { s: Box::new(wire), tx, rx, tx_n: 0, rx_n: 0, epoch: self.lib.epoch(), revoked: self.account_revision.subscribe() };
        self.run_session(ch, initiator, "simulated".into()).await
    }

    /// Syncs with one peer; concurrent requests for the same address are coalesced.
    pub async fn sync_with(self: &Arc<Self>, host: &str, port: u16) -> anyhow::Result<()> {
        let acct = self.account().ok_or_else(|| anyhow!(tr!("sync.notJoined")))?;
        let key = format!("{host}:{port}");
        if !self.active.lock().unwrap().insert(key.clone()) { return Ok(()); }
        // removed on every exit, panics included (a stuck entry would silently block this address)
        struct Active<'a>(&'a Mutex<HashSet<String>>, String);
        impl Drop for Active<'_> { fn drop(&mut self) { if let Ok(mut a) = self.0.lock() { a.remove(&self.1); } } }
        let _active = Active(&self.active, key.clone());
        let _ = &acct;
        let r = tokio::time::timeout(Duration::from_secs(3600), async {
            let ch = self.connect_auth(host, port, "sync").await?;
            self.run_session(ch, true, key.clone()).await
        }).await.unwrap_or_else(|_| Err(anyhow!(tr!("sync.syncTimeout"))));
        let mut failed = self.failed.lock().unwrap();
        match &r {
            Ok(()) => { failed.remove(&key); }
            // the other device started the same session first: not a failure
            Err(e) if is_busy(e) => {}
            Err(e) => { failed.insert(key.clone(), crate::diagnostics::scrub(&format!("{e:#}"))); }
        }
        drop(failed);
        r
    }

    // ---------- session ----------

    async fn run_session(&self, mut ch: Channel, initiator: bool, addr: String) -> anyhow::Result<()> {
        // a wipe during the session stops it at its next write (see `Library::db_at`)
        ch.check()?;
        let my_vv = {
            let _account = self.account.lock().unwrap();
            ch.check()?;
            let db = self.lib.db_at(ch.epoch)?;
            let applied = db.retry_pending_ops(|id, ext| self.lib.dir.join(blob_rel(id, ext)).exists())?;
            if applied > 0 { self.changes.fetch_add(1, Ordering::SeqCst); }
            // files gone from this device are asked for again below, like files never received.
            // Looking at every file holds the library and takes long on a slow disk: every ten
            // minutes at most, however many devices connect every 20 seconds.
            let due = {
                static LAST: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);
                let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
                let every = std::time::Duration::from_secs(if cfg!(test) { 0 } else { 600 });
                let due = last.map_or(true, |t| t.elapsed() >= every);
                if due { *last = Some(std::time::Instant::now()); }
                due
            };
            let missing = if due { db.note_missing_files(|p| self.lib.dir.join(p).exists())? } else { 0 };
            if missing > 0 { self.lib.diag("files_missing_refetch", serde_json::json!({ "files": missing })); self.changes.fetch_add(1, Ordering::SeqCst); }
            db.version_vector()?
        };
        let me = self.device_id();
        let name = self.device_name.lock().unwrap().clone();
        ch.send(&Msg::Hello { device: me.clone(), name, vv: my_vv, now_ms: now_ms() }).await?;
        let Msg::Hello { device: peer, name: peer_name, vv: their_vv, now_ms: their_now } = ch.recv().await? else { bail!("protocol: hello") };
        let my_now = now_ms();
        if peer == me { bail!("connected to self"); }
        // One session per peer: a second concurrent session would fetch the same files twice.
        // Both sides check, and the side that finds a duplicate tells the other (two devices may
        // start a session with each other at the same moment; then both end, without an error,
        // and the next round runs one).
        if !self.peer_sessions.lock().unwrap().insert(peer.clone()) {
            let _ = ch.send(&Msg::Busy).await;
            bail!(ALREADY_SYNCING);
        }
        struct Release<'a>(&'a Mutex<HashSet<String>>, String);
        impl Drop for Release<'_> { fn drop(&mut self) { self.0.lock().unwrap().remove(&self.1); } }
        let _release = Release(&self.peer_sessions, peer.clone());
        let mut changed = false;
        let result: anyhow::Result<()> = async {
            if initiator {
                self.send_ops(&mut ch, &their_vv).await?;
                changed |= self.recv_ops(&mut ch).await?;
                changed |= self.request_blobs(&mut ch).await?;
                self.serve_blobs(&mut ch).await?;
                // Wait until the responder has stored everything before reporting success.
                match ch.recv().await? { Msg::Bye => {} Msg::Busy => bail!(ALREADY_SYNCING), _ => bail!("protocol: bye") }
            } else {
                changed |= self.recv_ops(&mut ch).await?;
                self.send_ops(&mut ch, &their_vv).await?;
                self.serve_blobs(&mut ch).await?;
                changed |= self.request_blobs(&mut ch).await?;
                ch.send(&Msg::Bye).await?;
            }
            Ok(())
        }.await;
        if changed { self.changes.fetch_add(1, Ordering::SeqCst); }
        // the other device was already in a session with this one: nothing went wrong
        let busy = matches!(&result, Err(e) if is_busy(e));
        let mut peers = self.peers.lock().unwrap();
        let p = peers.entry(peer.clone()).or_default();
        p.device = peer; p.name = peer_name; p.addr = addr;
        if their_now != 0 {
            p.clock_skew_ms = i64::try_from(their_now as i128 - my_now as i128).ok();
            p.clock_warning = crate::rules::skew_warning(my_now, their_now);
        }
        match &result { Ok(_) => { p.last_sync = now_s(); p.last_error = None; } Err(_) if busy => {} Err(e) => p.last_error = Some(format!("{e:#}")) }
        drop(peers);
        if let (Err(e), false) = (&result, busy) { self.lib.diag("sync_error", serde_json::json!({ "error": crate::diagnostics::scrub(&format!("{e:#}")) })); }
        result
    }

    async fn send_ops(&self, ch: &mut Channel, their_vv: &VersionVector) -> anyhow::Result<()> {
        let mut vv = their_vv.clone();
        let upper = self.lib.db().version_vector()?;
        loop {
            let ops = self.lib.db().ops_since_until(&vv, &upper, OPS_BATCH)?;
            if ops.is_empty() { break; }
            for o in &ops { let e = vv.entry(o.device.clone()).or_insert(0); *e = crate::rules::vv_advance(*e, o.seq); }
            // cut by size too, in order (each device's ops stay in sequence across batches)
            let mut batch: Vec<LoggedOp> = vec![];
            let mut bytes = 0;
            for o in ops {
                let n = serde_json::to_vec(&o)?.len();
                if !batch.is_empty() && bytes + n > OPS_BYTES { ch.send(&Msg::Ops { ops: std::mem::take(&mut batch) }).await?; bytes = 0; }
                bytes += n;
                batch.push(o);
            }
            if !batch.is_empty() { ch.send(&Msg::Ops { ops: batch }).await?; }
        }
        ch.send(&Msg::OpsEnd).await
    }

    async fn recv_ops(&self, ch: &mut Channel) -> anyhow::Result<bool> {
        let mut changed = false;
        let dir = self.lib.dir.clone();
        loop {
            match ch.recv().await? {
                Msg::Ops { ops } => {
                    let r = {
                        let _account = self.account.lock().unwrap();
                        ch.check()?;
                        self.lib.db_at(ch.epoch)?.apply_remote_counted(&ops, |id, ext| dir.join(blob_rel(id, ext)).exists())?
                    };
                    let n = r.applied;
                    // Each batch is already committed, even if the next read disconnects.
                    if n > 0 { self.changes.fetch_add(1, Ordering::SeqCst); }
                    // A disconnect before OpsEnd must not strand already-committed deletions.
                    self.lib.settle()?;
                    if r.refused + r.invalid > 0 {
                        self.lib.diag("sync_ops_refused", serde_json::json!({ "out_of_sequence_or_bad_device": r.refused, "invalid_media": r.invalid }));
                    }
                    // Counts per kind of change received (numbers only).
                    let mut kinds: BTreeMap<String, usize> = BTreeMap::new();
                    for o in &ops {
                        let k = match &o.op {
                            crate::oplog::Op::Post { .. } => "post".to_string(), crate::oplog::Op::Media { .. } => "media".into(),
                            crate::oplog::Op::Tag { .. } => "tag".into(), crate::oplog::Op::TagSrc { .. } => "tag_source".into(),
                            crate::oplog::Op::AiDone { .. } => "ai_done".into(),
                            crate::oplog::Op::Trash { state, .. } => format!("bin_state_{state}"),
                            crate::oplog::Op::Alias { .. } => "rename".to_string(),
                            crate::oplog::Op::Folder { .. } => "folder".to_string(),
                            crate::oplog::Op::FolderMedia { .. } => "folder_member".to_string(),
                            crate::oplog::Op::Recent { .. } => "recently_added".to_string(),
                            crate::oplog::Op::Setting { .. } => "setting".to_string(),
                            crate::oplog::Op::Album { .. } => "album".to_string(),
                            crate::oplog::Op::Unknown(_) => "from_newer_app_version".to_string(),
                        };
                        *kinds.entry(k).or_default() += 1;
                    }
                    self.lib.diag("sync_ops_received", serde_json::json!({ "received": ops.len(), "new": n, "by_kind": kinds }));
                    changed |= n > 0;
                }
                Msg::Busy => bail!(ALREADY_SYNCING),
                Msg::OpsEnd => {
                    // Remove files of media deleted elsewhere (state check and removal are atomic).
                    if changed { self.lib.settle()?; }
                    return Ok(changed);
                }
                _ => bail!("protocol: ops"),
            }
        }
    }

    async fn request_blobs(&self, ch: &mut Channel) -> anyhow::Result<bool> {
        // skip files another session is already fetching, and claim these until this ends
        let wanted = {
            let mut claimed = self.claimed.lock().unwrap();
            let all = self.lib.db().wanted_blobs(5000 + claimed.len() as i64)?;
            let mine: Vec<(String, String)> = all.into_iter().filter(|(id, _)| !claimed.contains(id)).take(5000).collect();
            claimed.extend(mine.iter().map(|(id, _)| id.clone()));
            mine
        };
        struct Claims<'a>(&'a Mutex<HashSet<String>>, Vec<String>);
        impl Drop for Claims<'_> { fn drop(&mut self) { if let Ok(mut c) = self.0.lock() { for id in &self.1 { c.remove(id); } } } }
        let _claims = Claims(&self.claimed, wanted.iter().map(|(id, _)| id.clone()).collect());
        let total = wanted.len() as u64;
        let asked: HashSet<String> = wanted.iter().map(|(id, _)| id.clone()).collect();
        ch.send(&Msg::Want { blobs: wanted }).await?;
        let mut got = false;
        if total > 0 {
            // another session receiving at the same time: one progress for both
            let mut t = self.transfer.lock().unwrap();
            match t.as_mut() { Some(t) => t.total += total, None => *t = Some(Transfer { total, ..Default::default() }) }
        }
        let mut since_notice = 0u32;
        let mut last_notice = Instant::now();
        let result = self.receive_blobs(ch, &asked, &mut got, &mut since_notice, &mut last_notice).await;
        drop(_claims);
        if self.claimed.lock().unwrap().is_empty() { *self.transfer.lock().unwrap() = None; }
        if got { self.changes.fetch_add(1, Ordering::SeqCst); }
        result.map(|_| got)
    }

    async fn receive_blobs(&self, ch: &mut Channel, asked: &HashSet<String>, got: &mut bool, since_notice: &mut u32, last_notice: &mut Instant) -> anyhow::Result<()> {
        loop {
            match ch.recv().await? {
                Msg::Blob { id, ext, size } => {
                    // only files this device asked for, with a well-formed name
                    if !asked.contains(&id) || !crate::rules::valid_blob_id(id.as_bytes()) || !crate::rules::valid_ext(ext.as_bytes()) { bail!("protocol: unrequested file"); }
                    let tmp = self.lib.tmp_path();
                    let _cleanup = crate::library::TempFile(tmp.clone());
                    let mut f = tokio::fs::File::create(&tmp).await?;
                    let mut h = Sha256::new();
                    let mut head: Vec<u8> = Vec::with_capacity(16);
                    let mut left = size;
                    if let Some(t) = self.transfer.lock().unwrap().as_mut() { t.current_size = size; t.current_done = 0; }
                    while left > 0 {
                        let c = ch.recv_raw().await?;
                        if c.is_empty() || c.len() as u64 > left { bail!("protocol: invalid blob chunk"); }
                        if head.len() < 16 { head.extend_from_slice(&c[..c.len().min(16 - head.len())]); }
                        h.update(&c);
                        f.write_all(&c).await?;
                        left -= c.len() as u64;
                        if let Some(t) = self.transfer.lock().unwrap().as_mut() { t.current_done += c.len() as u64; t.bytes += c.len() as u64; }
                    }
                    f.sync_all().await?;
                    drop(f);
                    if hex::encode(h.finalize()) != id {
                        // The peer's copy is damaged: skip just this file (another peer may have it).
                        let _ = tokio::fs::remove_file(&tmp).await;
                        if let Some(t) = self.transfer.lock().unwrap().as_mut() { t.total = t.total.saturating_sub(1); }
                        self.lib.diag("sync_peer_file_rejected", serde_json::json!({ "reason": "hash_mismatch", "bytes": size }));
                        continue;
                    }
                    // the same content check as downloads and imports
                    let photo = self.lib.db().wanted_is_photo(&id)?.unwrap_or(true);
                    let sn = crate::rules::sniff(&head);
                    if !crate::rules::sniff_ok(sn, photo) {
                        let _ = tokio::fs::remove_file(&tmp).await;
                        if let Some(t) = self.transfer.lock().unwrap().as_mut() { t.total = t.total.saturating_sub(1); }
                        self.lib.diag("sync_peer_file_rejected", serde_json::json!({ "reason": "not_media", "bytes": size }));
                        self.lib.db_at(ch.epoch)?.give_up_blob(&id)?;
                        continue;
                    }
                    let epoch = ch.epoch;
                    if self.lib.epoch() != epoch { let _ = tokio::fs::remove_file(&tmp).await; bail!(tr!("library.wiped")); }
                    let stored_path;
                    {
                        let _account = self.account.lock().unwrap();
                        ch.check()?;
                        let db = self.lib.db_at(epoch)?;
                        if db.trash_reg(&id)?.state == crate::rules::PURGED { continue; }
                        // The sender may keep this content under another extension. Store it
                        // under our requested path so existing rows and pending rows stay valid.
                        let expected = db.wanted_extension(&id)?;
                        let Some(expected) = expected else { continue };
                        stored_path = self.lib.commit_tmp_locked(&db, &tmp, &id, &expected)?;
                        db.blob_arrived(&id)?;
                    }
                    *got = true;
                    if let Some(t) = self.transfer.lock().unwrap().as_mut() {
                        t.received += 1;
                        t.last_path = Some(self.lib.dir.join(stored_path).to_string_lossy().into_owned());
                    }
                    // Let the UI refresh as media arrive, not only when the whole round ends.
                    *since_notice += 1;
                    if *since_notice >= 5 || last_notice.elapsed() > Duration::from_secs(2) {
                        *since_notice = 0;
                        *last_notice = Instant::now();
                        self.changes.fetch_add(1, Ordering::SeqCst);
                    }
                }
                Msg::Plan { files, bytes } => {
                    // the files this peer has of the ones asked (another session's share stays counted)
                    if let Some(t) = self.transfer.lock().unwrap().as_mut() { t.total = t.total.saturating_sub(asked.len() as u64) + files; t.total_bytes += bytes; }
                }
                Msg::NoBlob { .. } => { if let Some(t) = self.transfer.lock().unwrap().as_mut() { t.total = t.total.saturating_sub(1); } }
                Msg::BlobsEnd => return Ok(()),
                Msg::Busy => bail!(ALREADY_SYNCING),
                _ => bail!("protocol: blobs"),
            }
        }
    }

    fn served_blob_path(&self, id: &str, ext: &str) -> std::path::PathBuf {
        let db = self.lib.db();
        if let Ok(Some((_, _, _, path))) = db.media_row(id) {
            if crate::rules::is_blob_path(path.as_bytes()) { return self.lib.dir.join(path); }
        }
        self.lib.dir.join(blob_rel(id, ext))
    }

    async fn serve_blobs(&self, ch: &mut Channel) -> anyhow::Result<()> {
        let blobs = match ch.recv().await? { Msg::Want { blobs } => blobs, Msg::Busy => bail!(ALREADY_SYNCING), _ => bail!("protocol: want") };
        let valid = |id: &str, ext: &str| crate::rules::valid_blob_id(id.as_bytes()) && crate::rules::valid_ext(ext.as_bytes());
        let (mut files, mut bytes) = (0u64, 0u64);
        for (id, ext) in &blobs {
            if !valid(id, ext) { continue; }
            if self.lib.db().bad_reason(id).ok().flatten().map_or(false, |r| r == "missing" || r == "hash") { continue; }
            if let Ok(m) = tokio::fs::metadata(self.served_blob_path(id, ext)).await { files += 1; bytes += m.len(); }
        }
        ch.send(&Msg::Plan { files, bytes }).await?;
        for (id, ext) in blobs {
            if !valid(&id, &ext) { continue; }
            let path = self.served_blob_path(&id, &ext);
            // Never serve a file known to be damaged (the receiver would reject it anyway).
            let damaged = self.lib.db().bad_reason(&id).ok().flatten().map_or(false, |r| r == "missing" || r == "hash");
            let opened = if damaged { None } else { tokio::fs::File::open(&path).await.ok() };
            let Some(mut f) = opened else { ch.send(&Msg::NoBlob { id }).await?; continue };
            let size = f.metadata().await?.len();
            ch.send(&Msg::Blob { id, ext, size }).await?;
            let mut buf = vec![0u8; CHUNK];
            let mut left = size;
            while left > 0 {
                let n = f.read(&mut buf[..(CHUNK as u64).min(left) as usize]).await?;
                if n == 0 { bail!("blob truncated"); }
                ch.send_raw(&buf[..n]).await?;
                left -= n as u64;
            }
        }
        ch.send(&Msg::BlobsEnd).await
    }
}

#[cfg(test)]
mod pairing_tests {
    use super::*;

    fn node(name: &str) -> Arc<SyncNode> {
        let d = std::env::temp_dir().join(format!("tl-pair-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        SyncNode::new(Arc::new(Library::open(&d).unwrap()))
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn foreground_listener_rebind_preserves_account_and_active_channels() {
        let (host, client) = (node("rebind-host"), node("rebind-client"));
        let acct = Account::generate();
        let old = host.start(Some(acct.clone()), "Phone".into()).await.unwrap();
        client.start(Some(acct.clone()), "Mac".into()).await.unwrap();
        let channel = client.connect_auth("127.0.0.1", old, "sync").await.unwrap();
        let revision = *host.account_revision.borrow();
        let new = host.restart_listener().await.unwrap();
        assert_ne!(old, new);
        assert_eq!(*host.account_revision.borrow(), revision, "listener recovery must not revoke active transfers");
        assert_eq!(host.status().account_id.as_deref(), Some(acct.id.as_str()));
        channel.check().unwrap();
        assert!(client.peer_models("127.0.0.1", new).await.unwrap().is_empty());
        drop(channel);
        client.sync_with("127.0.0.1", new).await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if TcpStream::connect(("127.0.0.1", old)).await.is_err() { break; }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await.unwrap();
        host.stop(); client.stop();
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn attempts_are_limited_and_codes_expire() {
        let (host, joiner) = (node("h"), node("j"));
        let port = host.start(Some(Account::generate()), "H".into()).await.unwrap();
        joiner.start(None, "J".into()).await.unwrap();
        let code = host.begin_pairing().unwrap();
        let wrong = if code == "000000" { "111111" } else { "000000" };
        for _ in 0..PAIR_ATTEMPTS { assert!(joiner.do_join("127.0.0.1", port, wrong).await.is_err()); }
        // After 5 wrong attempts even the right code is refused.
        assert!(joiner.do_join("127.0.0.1", port, &code).await.is_err());
        assert!(host.status().pairing_code.is_none(), "code no longer shown");
        // A fresh code works; an expired one does not.
        let code2 = host.begin_pairing().unwrap();
        host.pairing.lock().unwrap().as_mut().unwrap().expires = Instant::now() - Duration::from_secs(1);
        assert!(joiner.do_join("127.0.0.1", port, &code2).await.is_err());
        let code3 = host.begin_pairing().unwrap();
        assert!(joiner.do_join("127.0.0.1", port, &code3).await.is_ok());
        // Malformed codes are rejected before connecting.
        assert!(joiner.do_join("127.0.0.1", port, "12a456").await.is_err());
        assert!(joiner.do_join("127.0.0.1", port, "12345").await.is_err());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn only_one_session_per_peer_at_a_time() {
        let (a, b) = (node("sa"), node("sb"));
        let acct = Account::generate();
        let pa = a.start(Some(acct.clone()), "A".into()).await.unwrap();
        b.start(Some(acct), "B".into()).await.unwrap();
        // Two concurrent sessions from B to A via different addresses (so the address de-dup does not apply).
        let (b1, b2) = (b.clone(), b.clone());
        let (r1, r2) = tokio::join!(b1.sync_with("127.0.0.1", pa), b2.sync_with("localhost", pa));
        assert!(r1.is_ok() || r2.is_ok());
        // The initiator has finished, but the responder task may still be draining
        // its final frame. Check eventual cleanup instead of assuming scheduler order.
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if a.peer_sessions.lock().unwrap().is_empty() && b.peer_sessions.lock().unwrap().is_empty() { break; }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        }).await.expect("session locks must be released");
        assert!(b.sync_with("127.0.0.1", pa).await.is_ok(), "next session runs normally");
    }

    /// Two devices starting a session with each other at the same moment (or one during the
    /// other's long first sync) must not show each other as failed: the duplicate is refused
    /// with Busy, which neither side records as an error.
    #[tokio::test(flavor = "multi_thread")]
    async fn crossing_sessions_are_not_failures() {
        let (a, b) = (node("xa"), node("xb"));
        let acct = Account::generate();
        let pa = a.start(Some(acct.clone()), "A".into()).await.unwrap();
        let pb = b.start(Some(acct), "B".into()).await.unwrap();
        let src = a.lib.dir.join("src");
        for i in 0..40 {
            let d = src.join(format!("p{i}"));
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("1.jpg"), crate::testutil::jpg(format!("x{i}").as_bytes())).unwrap();
        }
        a.lib.import_legacy_dir(&src).unwrap();
        for i in 0..20 {
            let (a2, b2) = (a.clone(), b.clone());
            let r = tokio::time::timeout(Duration::from_secs(20), async { tokio::join!(a2.sync_with("127.0.0.1", pb), b2.sync_with("127.0.0.1", pa)) }).await;
            assert!(r.is_ok(), "round {i} must end");
        }
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let busy = !a.peer_sessions.lock().unwrap().is_empty() || !b.peer_sessions.lock().unwrap().is_empty();
                if !busy { break; }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await.unwrap();
        for n in [&a, &b] {
            let st = n.status();
            assert!(st.failed.is_empty(), "no failed address: {:?}", st.failed);
            assert!(st.peers.iter().all(|p| p.last_error.is_none()), "no peer error: {:?}", st.peers);
            assert!(st.in_session.is_empty());
        }
        assert_eq!(b.lib.db().wanted_blobs(1000).unwrap().len(), 0, "everything arrived");
    }

    /// A new device filling up from two peers at once asks each for different files.
    #[tokio::test(flavor = "multi_thread")]
    async fn two_sessions_never_fetch_the_same_file() {
        let (a, b, c) = (node("ta"), node("tb"), node("tc"));
        let acct = Account::generate();
        let pa = a.start(Some(acct.clone()), "A".into()).await.unwrap();
        let pb = b.start(Some(acct.clone()), "B".into()).await.unwrap();
        c.start(Some(acct), "C".into()).await.unwrap();
        let src = a.lib.dir.join("src");
        for i in 0..60 {
            let d = src.join(format!("p{i}"));
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("1.jpg"), crate::testutil::jpg(format!("y{i}").as_bytes())).unwrap();
        }
        a.lib.import_legacy_dir(&src).unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        let (c1, c2) = (c.clone(), c.clone());
        let (r1, r2) = tokio::join!(c1.sync_with("127.0.0.1", pa), c2.sync_with("127.0.0.1", pb));
        r1.unwrap(); r2.unwrap();
        for _ in 0..3 { c.sync_with("127.0.0.1", pa).await.unwrap(); }
        assert_eq!(c.lib.db().wanted_blobs(1000).unwrap().len(), 0);
        assert!(c.claimed.lock().unwrap().is_empty() && c.transfer.lock().unwrap().is_none());
    }

    /// Throughput of the sync protocol alone over loopback (run with --ignored --nocapture).
    #[tokio::test(flavor = "multi_thread")]
    #[ignore]
    async fn blob_throughput() {
        let la = { let d = std::env::temp_dir().join(format!("tl-tp-a-{}", std::process::id())); let _ = std::fs::remove_dir_all(&d); Arc::new(Library::open(&d).unwrap()) };
        let lb = { let d = std::env::temp_dir().join(format!("tl-tp-b-{}", std::process::id())); let _ = std::fs::remove_dir_all(&d); Arc::new(Library::open(&d).unwrap()) };
        let src = la.dir.join("src");
        for i in 0..20 {
            let d = src.join(format!("p{i}"));
            std::fs::create_dir_all(&d).unwrap();
            let mut v = vec![0u8; 16 << 20];
            v[..8].copy_from_slice(&(i as u64).to_le_bytes());
            v[4..8].copy_from_slice(b"ftyp");
            std::fs::write(d.join("1.mp4"), v).unwrap();
        }
        la.import_legacy_dir(&src).unwrap();
        let (a, b) = (SyncNode::new(la), SyncNode::new(lb.clone()));
        let acct = Account::generate();
        let pa = a.start(Some(acct.clone()), "A".into()).await.unwrap();
        b.start(Some(acct), "B".into()).await.unwrap();
        let t = Instant::now();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        let secs = t.elapsed().as_secs_f64();
        let n: i64 = lb.db().conn().query_row("SELECT count(*) FROM media", [], |r| r.get(0)).unwrap();
        println!("THROUGHPUT {n} files, 320 MB in {secs:.2}s = {:.0} MB/s", 320.0 / secs);
    }

    /// Imports (with overlapping posts/files and conflicting text) run on both devices *while*
    /// sync sessions run between them; afterwards both libraries are identical.
    #[tokio::test(flavor = "multi_thread")]
    async fn concurrent_imports_and_sync_converge() {
        let (a, b) = (node("ca"), node("cb"));
        let acct = Account::generate();
        let pa = a.start(Some(acct.clone()), "A".into()).await.unwrap();
        b.start(Some(acct), "B".into()).await.unwrap();
        // Overlapping trees: same post ids with different text, the same image in different posts.
        let make = |lib: &Library, tag: &str, n: usize| {
            let root = lib.dir.join(format!("src-{tag}"));
            for i in 0..n {
                let d = root.join(format!("帖子{i}"));
                std::fs::create_dir_all(&d).unwrap();
                std::fs::write(d.join("1.jpg"), crate::testutil::jpg(format!("shared-{}", i % 7).as_bytes())).unwrap();      // shared across posts and devices
                std::fs::write(d.join("2.jpg"), crate::testutil::jpg(format!("{tag}-{i}").as_bytes())).unwrap();             // device-specific
                std::fs::write(d.join(crate::legacy::SIDECAR_NAME), format!("推文 ID: {}\n【推文完整正文】\n{tag} 版本 {i}", 1000 + i)).unwrap();
            }
            root
        };
        let (ra, rb) = (make(&a.lib, "A", 30), make(&b.lib, "B", 30));
        let (la, lb) = (a.lib.clone(), b.lib.clone());
        let ia = tokio::task::spawn_blocking(move || {
            for i in 0..30 { let one = ra.join(format!("帖子{i}")); let tmp = ra.join(format!("one{i}")); std::fs::create_dir_all(&tmp).unwrap(); std::fs::rename(&one, tmp.join("x")).unwrap(); la.import_legacy_dir(&tmp).unwrap(); }
        });
        let ib = tokio::task::spawn_blocking(move || {
            for i in 0..30 { let one = rb.join(format!("帖子{i}")); let tmp = rb.join(format!("one{i}")); std::fs::create_dir_all(&tmp).unwrap(); std::fs::rename(&one, tmp.join("x")).unwrap(); lb.import_legacy_dir(&tmp).unwrap(); }
        });
        let syncer = { let b = b.clone(); tokio::spawn(async move { for _ in 0..15 { let _ = b.sync_with("127.0.0.1", pa).await; tokio::time::sleep(Duration::from_millis(20)).await; } }) };
        ia.await.unwrap(); ib.await.unwrap(); syncer.await.unwrap();
        for _ in 0..3 { b.sync_with("127.0.0.1", pa).await.unwrap(); }
        let snapshot = |l: &Library| -> Vec<String> {
            let db = l.db();
            let mut v = vec![];
            let mut st = db.conn().prepare("SELECT id, coalesce(text,'') FROM post ORDER BY 1").unwrap();
            for r in st.query_map([], |r| Ok(format!("P {} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?))).unwrap() { v.push(r.unwrap()); }
            let mut st = db.conn().prepare("SELECT id, post_id, ordinal FROM media ORDER BY 1").unwrap();
            for r in st.query_map([], |r| Ok(format!("M {} {} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))).unwrap() { v.push(r.unwrap()); }
            assert_eq!(db.wanted_blobs(1000).unwrap().len(), 0, "every blob arrived");
            v
        };
        let (sa, sb) = (snapshot(&a.lib), snapshot(&b.lib));
        assert_eq!(sa.iter().filter(|l| l.starts_with("P ")).count(), 30);
        assert_eq!(sa.iter().filter(|l| l.starts_with("M ")).count(), 7 + 60, "shared files stored once, device files kept");
        assert_eq!(sa, sb, "both devices converge");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn models_are_listed_and_pulled_on_demand() {
        let (a, b) = (node("ma"), node("mb"));
        // a fake standard model on A
        let mdir = a.lib.models_dir().join("org--tiny");
        std::fs::create_dir_all(&mdir).unwrap();
        std::fs::write(mdir.join("config.json"), br#"{"model_type":"qwen3_vl","vision_config":{}}"#).unwrap();
        let hdr = br#"{"w":{"dtype":"F32","shape":[2],"data_offsets":[0,8]}}"#;
        let mut w = (hdr.len() as u64).to_le_bytes().to_vec(); w.extend_from_slice(hdr); w.extend_from_slice(&[0u8; 8]);
        std::fs::write(mdir.join("model.safetensors"), w).unwrap();
        let acct = Account::generate();
        let pa = a.start(Some(acct.clone()), "A".into()).await.unwrap();
        b.start(Some(acct), "B".into()).await.unwrap();
        assert!(crate::models::installed(&b.lib.models_dir()).is_empty(), "nothing is pushed automatically");
        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert!(crate::models::installed(&b.lib.models_dir()).is_empty(), "library sync does not move models");
        let list = b.peer_models("127.0.0.1", pa).await.unwrap();
        assert_eq!(list.len(), 1);
        b.pull_model("127.0.0.1", pa, &list[0].id, "tiny", list[0].bytes).await.unwrap();
        let got = crate::models::installed(&b.lib.models_dir());
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, "org--tiny");
        assert!(b.pull_model("127.0.0.1", pa, "../etc", "x", 0).await.is_err(), "path traversal refused");
        // a stranger cannot list models
        let s = node("ms");
        s.start(Some(Account::generate()), "S".into()).await.unwrap();
        assert!(s.peer_models("127.0.0.1", pa).await.is_err());
    }

    fn put(l: &Library, folder: &str, files: &[(&str, &[u8])]) -> crate::library::ImportReport {
        let root = l.dir.join(format!("in-{}", rand::random::<u32>()));
        let d = root.join(folder);
        std::fs::create_dir_all(&d).unwrap();
        for (n, b) in files { std::fs::write(d.join(n), crate::testutil::jpg(b)).unwrap(); }
        let r = l.import_legacy_dir(&root).unwrap();
        std::fs::remove_dir_all(&root).unwrap();
        r
    }
    fn sha(b: &[u8]) -> String { hex::encode(Sha256::digest(crate::testutil::jpg(b))) }
    fn visible(l: &Library) -> Vec<String> {
        let mut v: Vec<String> = l.db().feed_filtered(&[], &[], crate::model::SearchScope::Both, Default::default(), &Default::default()).unwrap().into_iter().map(|i| i.media_id).collect();
        v.sort(); v
    }
    fn file(l: &Library, id: &str) -> std::path::PathBuf { l.dir.join(blob_rel(id, "jpg")) }
    async fn pair() -> (Arc<SyncNode>, Arc<SyncNode>, u16) {
        let (a, b) = (node(&format!("bin{}", rand::random::<u32>())), node(&format!("bin{}", rand::random::<u32>())));
        let acct = Account::generate();
        let pa = a.start(Some(acct.clone()), "A".into()).await.unwrap();
        b.start(Some(acct), "B".into()).await.unwrap();
        (a, b, pa)
    }

    /// Leaving the account and keeping the library, changing things on both sides meanwhile, then
    /// joining again: nothing is lost, each side gets what the other did, and a repeat of the same
    /// file on both sides stays one media.
    #[tokio::test(flavor = "multi_thread")]
    async fn leaving_keeping_the_library_and_joining_again_loses_nothing() {
        use crate::rules::TrashAction::*;
        let (a, b) = (node(&format!("re{}", rand::random::<u32>())), node(&format!("re{}", rand::random::<u32>())));
        let acct = Account::generate();
        let pa = a.start(Some(acct.clone()), "A".into()).await.unwrap();
        b.start(Some(acct.clone()), "B".into()).await.unwrap();
        put(&a.lib, "共有", &[("1.jpg", b"shared"), ("2.jpg", b"binned-on-a"), ("3.jpg", b"tagged-on-b")]);
        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert_eq!(visible(&b.lib).len(), 3);

        // B leaves, keeping everything
        b.stop();
        b.start(None, "B".into()).await.unwrap();
        assert_eq!(visible(&b.lib).len(), 3, "leaving removes nothing");
        // apart: both add, one bins, one tags, and both add the same new file
        put(&a.lib, "只在A", &[("a.jpg", b"only-a"), ("same.jpg", b"both")]);
        put(&b.lib, "只在B", &[("b.jpg", b"only-b"), ("same.jpg", b"both")]);
        a.lib.trash_apply(&[sha(b"binned-on-a")], Trash).unwrap();
        b.lib.tag(&sha(b"tagged-on-b"), "猫", crate::model::Origin(1)).unwrap();

        // B joins again (the same account key)
        b.stop();
        b.start(Some(acct), "B".into()).await.unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        let (va, vb) = (visible(&a.lib), visible(&b.lib));
        assert_eq!(va, vb, "the same library on both");
        for id in [sha(b"shared"), sha(b"tagged-on-b"), sha(b"only-a"), sha(b"only-b"), sha(b"both")] {
            assert!(va.contains(&id), "{id} is there");
            assert!(file(&a.lib, &id).exists() && file(&b.lib, &id).exists(), "{id} has its file on both");
        }
        assert_eq!(va.len(), 5);
        assert_eq!(a.lib.trash_list().unwrap().len(), 1, "the bin came along, and the file is kept");
        assert!(file(&b.lib, &sha(b"binned-on-a")).exists());
        let tags = |l: &Library| l.db().feed_filtered(&[], &[], crate::model::SearchScope::Both, Default::default(), &Default::default()).unwrap()
            .into_iter().find(|i| i.media_id == sha(b"tagged-on-b")).unwrap().tags.len();
        assert_eq!((tags(&a.lib), tags(&b.lib)), (1, 1));
    }

    /// Joining another account with a library of its own merges the two: nobody loses media.
    #[tokio::test(flavor = "multi_thread")]
    async fn joining_another_account_merges_the_libraries() {
        let (a, b) = (node(&format!("mj{}", rand::random::<u32>())), node(&format!("mj{}", rand::random::<u32>())));
        let (one, two) = (Account::generate(), Account::generate());
        let pa = a.start(Some(one), "A".into()).await.unwrap();
        b.start(Some(two.clone()), "B".into()).await.unwrap();
        put(&a.lib, "A的", &[("a.jpg", b"from-a")]);
        put(&b.lib, "B的", &[("b.jpg", b"from-b")]);
        assert!(b.sync_with("127.0.0.1", pa).await.is_err() || visible(&b.lib).len() == 1, "another account's device gives nothing");
        a.stop();
        let pa = a.start(Some(two), "A".into()).await.unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert_eq!(visible(&a.lib), visible(&b.lib));
        assert_eq!(visible(&a.lib).len(), 2);
    }

    /// 从相册导入 travels with the media, and only what a share brought in has it.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_album_mark_syncs() {
        let (a, b, pa) = pair().await;
        put(&a.lib, "帖子", &[("1.jpg", b"from-a-post")]);
        let share = a.lib.dir.join("share");
        std::fs::create_dir_all(&share).unwrap();
        std::fs::write(share.join("p.jpg"), crate::testutil::jpg(b"from-album")).unwrap();
        crate::import::import_loose_dir(&a.lib, &share, None, true).unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        let filter = crate::library::FeedFilter { album_only: true, ..Default::default() };
        for l in [&a.lib, &b.lib] {
            let v = l.db().feed_filtered(&[], &[], crate::model::SearchScope::Both, Default::default(), &filter).unwrap();
            assert_eq!(v.len(), 1);
            assert_eq!(v[0].media_id, sha(b"from-album"));
            assert!(v[0].album);
            assert_eq!(visible(l).len(), 2);
        }
    }

    /// A file deleted by hand on one device (not through the app) comes back from another device
    /// at the next sync, and the other device keeps its own: missing is not a deletion.
    #[tokio::test(flavor = "multi_thread")]
    async fn files_lost_on_one_device_come_back_from_another() {
        let (a, b, pa) = pair().await;
        put(&a.lib, "帖子", &[("1.jpg", b"one"), ("2.jpg", b"two")]);
        b.sync_with("127.0.0.1", pa).await.unwrap();
        let x = sha(b"one");
        assert!(file(&b.lib, &x).exists());
        // B loses a file outside the app
        std::fs::remove_file(file(&b.lib, &x)).unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert!(file(&b.lib, &x).exists(), "fetched again from A");
        assert!(file(&a.lib, &x).exists(), "A keeps its file");
        assert_eq!(b.lib.db().bad_reason(&x).unwrap(), None);
        assert_eq!(visible(&a.lib).len(), 2);
        assert_eq!(visible(&b.lib).len(), 2);
    }

    /// Binning, permanent deletion and explicit re-download all travel between devices, and a
    /// permanent deletion removes the file everywhere without it ever being requested again.
    #[tokio::test(flavor = "multi_thread")]
    async fn recycle_bin_syncs_and_deletion_removes_files_everywhere() {
        use crate::rules::TrashAction::*;
        let (a, b, pa) = pair().await;
        put(&a.lib, "帖子", &[("1.jpg", b"one"), ("2.jpg", b"two")]);
        b.sync_with("127.0.0.1", pa).await.unwrap();
        let x = sha(b"one");
        assert_eq!(visible(&b.lib).len(), 2);
        // B moves X to the bin: A hides it but keeps the file (it can be restored).
        assert_eq!(b.lib.trash_apply(&[x.clone()], Trash).unwrap(), 1);
        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert_eq!(visible(&a.lib), vec![sha(b"two")]);
        assert_eq!(a.lib.trash_list().unwrap().len(), 1);
        assert!(file(&a.lib, &x).exists());
        // A deletes it permanently: the file disappears on both devices and is never wanted again.
        a.lib.trash_apply(&[x.clone()], Purge).unwrap();
        assert!(!file(&a.lib, &x).exists());
        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert!(!file(&b.lib, &x).exists(), "deletion removed the peer's file");
        for l in [&a.lib, &b.lib] {
            assert!(l.db().wanted_blobs(100).unwrap().is_empty());
            assert_eq!(l.db().stats().unwrap().trashed, 0);
            assert!(l.trash_list().unwrap().is_empty());
        }
        // A batch import of the same file does not bring it back (and leaves no file behind)...
        let r = put(&b.lib, "帖子", &[("1.jpg", b"one")]);
        assert_eq!((r.media, r.deleted), (0, 1));
        assert!(!file(&b.lib, &x).exists() && visible(&b.lib) == vec![sha(b"two")]);
        // ...an explicit re-download does, on every device (A fetches the file again from B).
        let (id, rel) = b.lib.put_reader(&mut &crate::testutil::jpg(b"one")[..], &crate::model::MediaKind::Photo, "jpg").unwrap();
        assert!(b.lib.db().add_media(&id, "legacy:帖子", 0, &crate::model::MediaKind::Photo, &rel, true).unwrap());
        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert_eq!(visible(&a.lib).len(), 2);
        assert_eq!(a.lib.check_file(&x, &blob_rel(&x, "jpg")), None, "re-fetched file is intact");
    }

    /// Restoring on one device while another empties the bin: the restore wins on both, and the
    /// device that had already deleted the file gets a verified copy back.
    #[tokio::test(flavor = "multi_thread")]
    async fn restore_beats_concurrent_permanent_deletion() {
        use crate::rules::TrashAction::*;
        for restore_on_initiator in [false, true] {
            let (a, b, pa) = pair().await;
            put(&a.lib, "帖子", &[("1.jpg", b"keep me")]);
            let x = sha(b"keep me");
            b.sync_with("127.0.0.1", pa).await.unwrap();
            a.lib.trash_apply(&[x.clone()], Trash).unwrap();
            b.sync_with("127.0.0.1", pa).await.unwrap();
            // offline: one empties the bin, the other restores
            let (purger, restorer) = if restore_on_initiator { (&a, &b) } else { (&b, &a) };
            assert_eq!(purger.lib.empty_trash().unwrap(), 1);
            assert!(!file(&purger.lib, &x).exists());
            assert_eq!(restorer.lib.trash_apply(&[x.clone()], Restore).unwrap(), 1);
            b.sync_with("127.0.0.1", pa).await.unwrap();
            b.sync_with("127.0.0.1", pa).await.unwrap(); // the file travels in the second round
            for l in [&a.lib, &b.lib] {
                assert_eq!(visible(l), vec![x.clone()], "restore won");
                assert_eq!(l.check_file(&x, &blob_rel(&x, "jpg")), None);
            }
        }
    }

    /// A damaged local file is found by verification and replaced by a peer's verified copy; a
    /// peer's damaged copy is never served and never breaks the session.
    #[tokio::test(flavor = "multi_thread")]
    async fn damaged_files_are_detected_and_replaced_from_peers() {
        let (a, b, pa) = pair().await;
        put(&a.lib, "帖子", &[("1.jpg", b"photo x"), ("2.jpg", b"photo y")]);
        b.sync_with("127.0.0.1", pa).await.unwrap();
        let (x, y) = (sha(b"photo x"), sha(b"photo y"));
        std::fs::write(file(&a.lib, &x), b"bit rot").unwrap();   // A's X is damaged
        std::fs::remove_file(file(&b.lib, &y)).unwrap();          // B's Y is missing
        for l in [&a.lib, &b.lib] {
            crate::verify::start(l.clone()).unwrap();
            while crate::verify::status().running { tokio::time::sleep(Duration::from_millis(10)).await; }
            assert_eq!(crate::verify::status().bad, 1);
            assert_eq!(l.db().stats().unwrap().bad, 1);
        }
        let flagged = a.lib.db().feed_filtered(&[], &[], crate::model::SearchScope::Both, Default::default(), &crate::library::FeedFilter { bad_only: true, ..Default::default() }).unwrap();
        assert_eq!((flagged.len(), flagged[0].bad.as_deref()), (1, Some("hash")));
        b.sync_with("127.0.0.1", pa).await.unwrap();
        for l in [&a.lib, &b.lib] {
            assert_eq!(l.check_file(&x, &blob_rel(&x, "jpg")), None);
            assert_eq!(l.check_file(&y, &blob_rel(&y, "jpg")), None);
            assert_eq!(l.db().stats().unwrap().bad, 0, "repaired copies cleared the damage records");
        }
        // Peers report each other's clocks; same machine, so no warning.
        let p = a.status().peers.into_iter().next().unwrap();
        assert!(p.clock_skew_ms.unwrap().abs() < 5000 && !p.clock_warning);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn device_without_account_refuses_sync() {
        let (a, b) = (node("na"), node("nb"));
        let pa = a.start(None, "A".into()).await.unwrap();
        b.start(Some(Account::generate()), "B".into()).await.unwrap();
        assert!(b.sync_with("127.0.0.1", pa).await.is_err());
    }
}

mod log {
    pub fn debug(_m: &str) { #[cfg(debug_assertions)] eprintln!("[sync] {_m}"); }
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn channel_nonce_exhaustion_rejects_send_and_receive() {
        use super::*;
        let (a, b) = tokio::io::duplex(1024);
        let (tx, rx) = session_keys(&[7; 32], &[1; 32], &[2; 32]);
        let (_revision, revoked) = tokio::sync::watch::channel(0);
        let mut sender = Channel { s: Box::new(a), tx: tx.clone(), rx: rx.clone(),
            tx_n: u64::MAX - 1, rx_n: 0, epoch: 0, revoked: revoked.clone() };
        let mut receiver = Channel { s: Box::new(b), tx: rx, rx: tx,
            tx_n: 0, rx_n: u64::MAX - 1, epoch: 0, revoked };
        sender.send_raw(b"last permitted nonce").await.unwrap();
        assert_eq!(receiver.recv_raw().await.unwrap(), b"last permitted nonce");
        for _ in 0..2 {
            assert!(sender.send_raw(b"must not wrap").await.unwrap_err().to_string().contains("nonce exhausted"));
            // Reject before waiting for a frame, even while the peer is still connected.
            let err = tokio::time::timeout(Duration::from_secs(1), receiver.recv_raw()).await.unwrap().unwrap_err();
            assert!(err.to_string().contains("nonce exhausted"));
            assert_eq!((sender.tx_n, receiver.rx_n), (u64::MAX, u64::MAX));
        }
    }
    use super::*;
    use crate::model::{Origin, SearchScope};
    use crate::library::FeedRequest;

    fn lib(name: &str) -> Arc<Library> {
        let d = std::env::temp_dir().join(format!("tl-sync-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        Arc::new(Library::open(&d).unwrap())
    }
    fn seed(l: &Library, folder: &str, bytes: &[u8]) {
        let src = l.dir.join("src").join(folder);
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("1.jpg"), crate::testutil::jpg(bytes)).unwrap();
        l.import_legacy_dir(&l.dir.join("src")).unwrap();
        std::fs::remove_dir_all(l.dir.join("src")).unwrap();
    }
    fn feed(l: &Library, terms: &[&str]) -> Vec<crate::library::FeedItem> {
        l.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: terms.iter().map(|s| s.to_string()).collect(), scope: SearchScope::Both, seed: Some(0), fuzzy: false, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn pair_then_three_devices_converge() {
        let (la, lb, lc) = (lib("a"), lib("b"), lib("c"));
        seed(&la, "来自A", b"photo-a");
        seed(&lb, "来自B", b"photo-b");
        let a_media = feed(&la, &[])[0].media_id.clone();
        la.tag(&a_media, "白墙", Origin::AI).unwrap();

        let (a, b, c) = (SyncNode::new(la.clone()), SyncNode::new(lb.clone()), SyncNode::new(lc.clone()));
        let pa = a.start(Some(Account::generate()), "A".into()).await.unwrap();
        let pb = b.start(None, "B".into()).await.unwrap();
        c.start(None, "C".into()).await.unwrap();

        // Wrong code fails, right code pairs B with A.
        let code = a.begin_pairing().unwrap();
        let wrong = if code == "000000" { "111111" } else { "000000" };
        assert!(b.do_join("127.0.0.1", pa, wrong).await.is_err());
        let acct = b.do_join("127.0.0.1", pa, &code).await.unwrap();
        assert_eq!(acct.id, a.account().unwrap().id);
        *b.account.lock().unwrap() = Some(acct.clone());
        // The code is single-use.
        assert!(c.do_join("127.0.0.1", pa, &code).await.is_err());

        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert_eq!(feed(&la, &[]).len(), 2);
        assert_eq!(feed(&lb, &[]).len(), 2);
        assert_eq!(feed(&lb, &["白墙"]).len(), 1, "tag synced");

        // C joins via B (any paired device can admit new ones) and syncs only with B.
        let code_b = b.begin_pairing().unwrap();
        let acct_c = c.do_join("127.0.0.1", pb, &code_b).await.unwrap();
        *c.account.lock().unwrap() = Some(acct_c);
        c.sync_with("127.0.0.1", pb).await.unwrap();
        assert_eq!(feed(&lc, &[]).len(), 2, "A's media reaches C through B");
        assert_eq!(feed(&lc, &["白墙"]).len(), 1);

        // Endorse on C, remove on A concurrently-ish; after gossip all agree.
        lc.tag(&a_media, "白墙", Origin::USER).unwrap();
        c.sync_with("127.0.0.1", pb).await.unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        let origin = |l: &Library| feed(l, &["白墙"]).first().map(|i| i.tags[0].origin).unwrap_or(0);
        assert_eq!((origin(&la), origin(&lb), origin(&lc)), (3, 3, 3));

        // AI provenance and analysed-by records travel too.
        la.apply_ai_tags(&a_media, "qwen-2b", &["天空".into()], false).unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        c.sync_with("127.0.0.1", pb).await.unwrap();
        let sky = feed(&lc, &["天空"]);
        assert_eq!(sky.len(), 1);
        assert_eq!(sky[0].tags.iter().find(|t| t.label == "天空").unwrap().models, vec!["qwen-2b".to_string()]);
        assert!(lc.db().media_needing_ai(10).unwrap().iter().all(|m| m.media_id != a_media), "C does not re-analyse A's media");
        // Re-tag with replace on C drops the unendorsed AI tag everywhere but keeps the endorsed one.
        lc.apply_ai_tags(&a_media, "qwen-8b", &["海".into()], true).unwrap();
        c.sync_with("127.0.0.1", pb).await.unwrap();
        b.sync_with("127.0.0.1", pa).await.unwrap();
        assert!(feed(&la, &["天空"]).is_empty(), "removal synced to A");
        assert_eq!(feed(&la, &["白墙"]).len(), 1, "endorsed tag kept");
        assert_eq!(feed(&la, &["海"]).len(), 1);

        // An unpaired device with a different account is rejected.
        let stranger = SyncNode::new(lib("d"));
        stranger.start(Some(Account::generate()), "D".into()).await.unwrap();
        assert!(stranger.sync_with("127.0.0.1", pa).await.is_err());
        assert_eq!(feed(&la, &[]).len(), 2);
    }
}

#[cfg(test)]
mod chatgpt_fault_tests {
 use super::*;
 #[tokio::test(flavor="multi_thread")]
 async fn regression_partial_ops_no_change_notification() {
  let dir=std::env::temp_dir().join(format!("tl-audit-notify-{}",std::process::id()));
  let lib=Arc::new(Library::open(dir).unwrap());let node=SyncNode::new(lib.clone());
  let (a,b)=tokio::io::duplex(1<<20);
  let (i2r,r2i)=session_keys(&[7;32],&[1;32],&[2;32]);
  let mut peer=Channel{s:Box::new(a),tx:i2r,rx:r2i,tx_n:0,rx_n:0,epoch:0,revoked:node.account_revision.subscribe()};
  let n=node.clone();let task=tokio::spawn(async move {n.simulated_session(b,false).await});
  peer.send(&Msg::Hello{device:"peer".into(),name:"peer".into(),vv:Default::default(),now_ms:now_ms()}).await.unwrap();
  let _=peer.recv().await.unwrap();
  peer.send(&Msg::Ops{ops:vec![LoggedOp{device:"peer".into(),seq:1,op:crate::oplog::Op::Setting{key:"x".into(),value:Some("new".into()),hlc:now_ms()<<16}}]}).await.unwrap();
  drop(peer);assert!(task.await.unwrap().is_err());
  assert_eq!(lib.db().setting("x").unwrap(),Some("new".into()));
  assert!(node.status().changes > 0,"committed partial sync must notify observers");
 }
 #[tokio::test]
 async fn regression_interrupted_blob_keeps_partial_file() {
  let dir=std::env::temp_dir().join(format!("tl-audit-partial-{}",std::process::id()));
  let lib=Arc::new(Library::open(&dir).unwrap());let node=SyncNode::new(lib);
  let (a,b)=tokio::io::duplex(1<<20);
  let (i2r,r2i)=session_keys(&[7;32],&[1;32],&[2;32]);
  let mut peer=Channel{s:Box::new(a),tx:i2r.clone(),rx:r2i.clone(),tx_n:0,rx_n:0,epoch:0,revoked:node.account_revision.subscribe()};
  let mut ch=Channel{s:Box::new(b),tx:r2i,rx:i2r,tx_n:0,rx_n:0,epoch:0,revoked:node.account_revision.subscribe()};
  let id="a".repeat(64);
  peer.send(&Msg::Blob{id:id.clone(),ext:"jpg".into(),size:1024}).await.unwrap();
  peer.send_raw(&[1;16]).await.unwrap();drop(peer);
  let asked=HashSet::from([id]);let mut got=false;let mut count=0;let mut notice=Instant::now();
  assert!(node.receive_blobs(&mut ch,&asked,&mut got,&mut count,&mut notice).await.is_err());
  let files:Vec<_>=std::fs::read_dir(dir.join("tmp")).unwrap().collect();
  assert_eq!(files.len(),0,"interrupted file must be cleaned up");
 }

 #[tokio::test]
 async fn account_switch_revokes_waiting_channel_and_blocks_writes() {
  let dir = std::env::temp_dir().join(format!("tl-revoke-{}", rand::random::<u64>()));
  let lib = Arc::new(Library::open(&dir).unwrap());
  let node = SyncNode::new(lib.clone());
  // Mark a listener as already running so start exercises account replacement
  // without binding a socket; transport is the real encrypted Channel over duplex.
  *node.port.lock().unwrap() = Some(1);
  node.start(Some(Account::generate()), "test".into()).await.unwrap();
  let (a,b) = tokio::io::duplex(1 << 20);
  let (i2r,r2i) = session_keys(&[7;32], &[1;32], &[2;32]);
  let mut ch = Channel { s: Box::new(b), tx:r2i, rx:i2r, tx_n:0, rx_n:0,
      epoch:lib.epoch(), revoked:node.account_revision.subscribe() };
  let n = node.clone();
  let task = tokio::spawn(async move { n.recv_ops(&mut ch).await });
  tokio::task::yield_now().await;
  node.start(None, "test".into()).await.unwrap();
  assert!(tokio::time::timeout(Duration::from_secs(2), task).await.unwrap().unwrap().is_err());
  assert!(lib.db().version_vector().unwrap().is_empty());
  drop(a); drop(node); drop(lib);
  std::fs::remove_dir_all(dir).unwrap();
 }

}

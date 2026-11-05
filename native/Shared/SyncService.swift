import Foundation
import Network
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// App side of LAN sync: Bonjour advertising/discovery and scheduling. The Rust core owns the
/// listener, the protocol, crypto and data merging.
final class SyncService: NSObject, NetServiceDelegate {
    static let shared = SyncService()
    static let changed = Notification.Name("SyncServiceChanged")
    #if DEBUG && os(macOS)
    /// The Mac debug build is a separate app with its own library: it never shows up as (or
    /// pairs with) the user's devices.
    static let serviceType = "_twlib-debug._tcp"
    #else
    static let serviceType = "_twlib._tcp"
    #endif
    /// A one-line warning the main screen should show once (local network denied, clock skew).
    static let warning = Notification.Name("SyncServiceWarning")

    /// The system refused local-network access (iOS / macOS privacy setting): sync cannot work.
    private(set) var localNetworkDenied = false
    private var warnedSkew = Set<String>()
    private var warnedDenied = false

    struct Peer: Hashable {
        let serviceName: String
        let name: String
        let account: String?
        let device: String
        /// What it is (mac, iphone, ipad, android-phone, android-tablet, windows, linux), as the
        /// device announced it; nil from an app that does not say.
        var kind: String? = nil
        var host: String?
        var port: UInt16?

        /// The symbol and the plain name of its type (product names, not translated).
        var typeSymbol: String {
            switch kind {
            case "mac": "laptopcomputer"
            case "iphone", "android-phone": "iphone"
            case "ipad", "android-tablet": "ipad"
            case "windows", "linux": "desktopcomputer"
            default: "laptopcomputer.and.iphone"
            }
        }
        var typeName: String? {
            switch kind {
            case "mac": "macOS"
            case "iphone": "iPhone"
            case "ipad": "iPad"
            case "android-phone", "android-tablet": "Android"
            case "windows": "Windows"
            case "linux": "Linux"
            default: nil
            }
        }
    }

    /// What this device announces itself as.
    static var deviceKind: String {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
        return "mac"
        #endif
    }

    struct Status: Decodable, Equatable {
        struct PeerInfo: Decodable, Equatable { let device: String; let name: String; let lastSync: UInt64; let lastError: String?; let addr: String
            /// Peer clock minus ours (ms) at the last session, and whether that is enough to matter.
            var clockSkewMs: Int64? = nil; var clockWarning: Bool? = false
            var skewText: String? {
                guard clockWarning == true, let ms = clockSkewMs else { return nil }
                let m = Double(abs(ms)) / 60_000
                let amount = m >= 120 ? String(format: L("time.hoursValue"), m / 60) : String(format: L("time.minutesValue"), m)
                return L("sync.clock.skew", ms > 0 ? L("sync.clock.ahead", amount) : L("sync.clock.behind", amount))
            }
        }
        struct Join: Decodable, Equatable { let running: Bool; let accountKey: String?; let error: String? }
        struct Transfer: Decodable, Equatable { let received: UInt64; let total: UInt64; let totalBytes: UInt64; let bytes: UInt64; let currentSize: UInt64; let currentDone: UInt64; let lastPath: String? }
        let accountId: String?
        let deviceId: String
        let deviceName: String
        let port: UInt16?
        let pairingCode: String?
        let pairingSecondsLeft: UInt64?
        let peers: [PeerInfo]
        let syncing: Int
        let changes: UInt64
        let join: Join
        let receiving: Transfer?
        /// "host:port" → reason, for addresses whose last attempt failed.
        var failed: [String: String]? = nil
    }

    private(set) var peers: [String: Peer] = [:]     // by device id
    private(set) var status: Status?
    private var browser: NWBrowser?
    private var service: NetService?
    private var resolvers: [String: NWConnection] = [:]
    private var resolveDeadlines: [String: DispatchWorkItem] = [:]
    private var resolveRetries: [String: DispatchWorkItem] = [:]
    private var resolveErrors: [String: String] = [:]
    private var needsListenerRestart = false
    private var timer: Timer?
    private var pollTimer: Timer?
    private var lastChanges: UInt64 = 0
    private var pendingLocalSync: DispatchWorkItem?
    private let queue = DispatchQueue(label: "sync.bonjour")
    /// The result of the last "立即同步", shown under the button (nil = nothing to say).
    private(set) var note: String?
    private var noteStarted: Date?
    /// Devices to sync with as soon as their address is known (a manual sync looks every device up again).
    private var syncWhenResolved = Set<String>()
    /// Failures already acted on, so one failure triggers one new lookup.
    private var handledFailures = Set<String>()
    private var lifecycleObservers: [NSObjectProtocol] = []

    var accountKey: String? { Keychain.get("sync.key") }
    var hasAccount: Bool { accountKey != nil }

    var summary: String {
        if localNetworkDenied { return L("sync.state.denied") }
        guard hasAccount else { return L("sync.state.off") }
        let online = reachablePeers.count
        return online == 0 ? L("sync.state.on") : L("mac.sync.online", online)
    }

    var stateText: String {
        guard hasAccount else { return L("sync.state.notJoined") }
        if localNetworkDenied { return L("sync.state.denied") }
        guard let s = status else { return L("sync.state.reading") }
        if s.syncing > 0 { return L("mac.sync.syncing") }
        if !(s.failed ?? [:]).isEmpty || s.peers.contains(where: { $0.lastError != nil }) { return L("sync.state.failed") }
        let last = s.peers.map(\.lastSync).max() ?? 0
        if last > 0 { return L("sync.state.lastOK") + Date(timeIntervalSince1970: Double(last)).formatted(date: .omitted, time: .shortened) }
        return L("sync.state.waiting")
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : (ProcessInfo.processInfo.isiOSAppOnMac ? "Mac (iPad App)" : UIDevice.current.name)
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    // MARK: Lifecycle

    /// Starts listening, advertising and browsing. Safe to call repeatedly.
    func start() {
        let r = Core.syncStart(accountKey: accountKey ?? "", deviceName: Self.deviceName)
        guard case .success(let port) = r else { return }
        refreshStatus()
        advertise(port: port)
        browse()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.syncAll() }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshStatus() }
        NotificationCenter.default.removeObserver(self, name: .libraryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(localChange), name: .libraryChanged, object: nil)
        #if canImport(UIKit)
        // iOS withdraws a suspended app's Bonjour advertisement and may leave the browser with
        // stale results: advertise and browse again (and look every device up again) on return.
        if lifecycleObservers.isEmpty {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.needsListenerRestart = true
            })
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let restart = self.needsListenerRestart
                self.needsListenerRestart = false
                self.rediscover(restartListener: restart)
            })
        }
        #else
        // after sleep the network may have changed and other devices restarted
        if lifecycleObservers.isEmpty {
            lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.rediscover(restartListener: true)
            })
        }
        #endif
        syncAll()
    }

    /// Advertises and browses again and forgets resolved addresses (they change when the other
    /// app restarts); the browser then reports every device again and each is looked up anew.
    func rediscover(restartListener: Bool = false) {
        guard hasAccount || status != nil else { start(); return }
        if restartListener {
            service?.stop()
            switch Core.syncRestartListener() {
            case .success: refreshStatus()
            case .failure(let error):
                setNote(L("sync.err.listen") + error.localizedDescription)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.hasAccount else { return }
                    self.rediscover(restartListener: true)
                }
                return
            }
        }
        guard let port = status?.port else { start(); return }
        cancelResolvers()
        for k in peers.keys { peers[k]?.host = nil; peers[k]?.port = nil }
        advertise(port: port)
        browse()
        post()
    }

    private func cancelResolvers() {
        resolveDeadlines.values.forEach { $0.cancel() }; resolveDeadlines.removeAll()
        resolveRetries.values.forEach { $0.cancel() }; resolveRetries.removeAll()
        resolvers.values.forEach { $0.stateUpdateHandler = nil; $0.cancel() }; resolvers.removeAll()
        resolveErrors.removeAll()
    }

    func stopNetworking() {
        timer?.invalidate(); pollTimer?.invalidate()
        browser?.cancel(); browser = nil
        service?.stop(); service = nil
        cancelResolvers()
        peers.removeAll(); endpoints.removeAll(); advertisementRevisions.removeAll(); syncWhenResolved.removeAll(); noteStarted = nil
    }

    /// Called by "清除所有数据": forget the account locally; nothing is sent to other devices.
    func resetForWipe() {
        DispatchQueue.main.async {
            self.stopNetworking()
            if !Keychain.set("sync.key", nil) { self.setNote(L("sync.err.keychainRemoveRetry")) }
            self.status = nil
            self.post()
        }
    }

    // MARK: Account

    func createAccount() {
        guard case .success(let key) = Core.syncNewAccount() else { return }
        guard Keychain.set("sync.key", key) else { setNote(L("sync.err.keychainSave")); return }
        stopNetworking()
        start()
    }

    func leaveAccount() {
        guard Keychain.set("sync.key", nil) else { setNote(L("sync.err.keychainRemove")); return }
        stopNetworking()
        start()
    }

    func beginPairing() -> String? { try? Core.syncPairBegin() }

    var discoveredAccountPeers: [Peer] {
        guard let acct = status?.accountId else { return [] }
        return peers.values.filter { $0.account == acct }.sorted { $0.name < $1.name }
    }

    func connectionDetail(_ peer: Peer) -> String? {
        if let error = resolveErrors[peer.device] { return L("sync.err.connect") + error }
        return peer.host == nil ? L("sync.found.confirming") : nil
    }

    /// Online peers of this account with a resolved address.
    var reachablePeers: [Peer] {
        guard let acct = status?.accountId else { return [] }
        return peers.values.filter { $0.account == acct && $0.host != nil && $0.port != nil }.sorted { $0.name < $1.name }
    }

    /// Models on other devices that this device does not have yet (asked on demand, never pushed).
    struct RemoteModel: Hashable { let peer: Peer; let info: Core.ModelInfo }
    func remoteModels(completion: @escaping (Result<[RemoteModel], Error>) -> Void) {
        let account = status?.accountId
        let have = Set(ModelStore.shared.installed.map(\.id))
        if discoveredAccountPeers.isEmpty { rediscover() }
        for p in discoveredAccountPeers where p.host == nil {
            if let endpoint = endpoints[p.device] { resolve(endpoint, device: p.device) }
        }
        Task { @MainActor in
            // Discovery is not yet reachability. Give pending resolution a bounded chance.
            let deadline = Date().addingTimeInterval(10)
            while self.reachablePeers.isEmpty, Date() < deadline, self.status?.accountId == account {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let account, self.status?.accountId == account else {
                completion(.failure(CoreError(message: L("sync.err.accountChanged")))); return
            }
            let targets = self.reachablePeers
            guard !targets.isEmpty else {
                let message = self.discoveredAccountPeers.isEmpty ? L("sync.err.noPeers") : L("sync.err.unreachable")
                completion(.failure(CoreError(message: message))); return
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[RemoteModel], Error> in
                var out: [RemoteModel] = []
                var failures: [String] = []
                var succeeded = false
                for p in targets {
                    guard let h = p.host, let port = p.port else { continue }
                    do {
                        let list = try Core.syncPeerModels(host: h, port: port)
                        succeeded = true
                        out += list.filter { model in !have.contains(model.id) && !out.contains(where: { $0.info.id == model.id }) }.map { RemoteModel(peer: p, info: $0) }
                    } catch { failures.append(L("format.labelValue", p.name, error.localizedDescription)) }
                }
                return succeeded ? .success(out) : .failure(CoreError(message: failures.joined(separator: L("list.semicolon"))))
            }.value
            guard self.status?.accountId == account else { completion(.failure(CoreError(message: L("sync.err.accountChanged")))); return }
            completion(result)
        }
    }

    func pull(_ m: RemoteModel) throws {
        guard let h = m.peer.host, let port = m.peer.port else { throw CoreError(message: L("sync.err.peerOffline")) }
        try Core.syncPullModel(host: h, port: port, id: m.info.id, label: L("sync.model.from", ModelStore.shared.displayName(m.info.id), m.peer.name), total: m.info.bytes)
    }
    func cancelPairing() { Core.syncPairCancel() }

    func join(peer: Peer, code: String) throws {
        guard let host = peer.host, let port = peer.port else { throw CoreError(message: L("sync.err.unresolved")) }
        try Core.syncJoin(host: host, port: port, code: code)
        refreshStatus()   // pick up join.running = true right away so callers don't see stale state
    }

    /// Called while a join is running; stores the key once pairing succeeded.
    func adoptJoinResultIfAny() -> Bool {
        guard let key = status?.join.accountKey, accountKey != key else { return false }
        guard Keychain.set("sync.key", key) else {
            stopNetworking()
            start()
            setNote(L("sync.err.keychainSave"))
            return false
        }
        stopNetworking()
        start()
        return true
    }

    // MARK: Syncing

    /// Automatic sync. Normally one side of each pair starts (the smaller device id): a session
    /// moves data both ways. But discovery can be one-sided (one device sees the other but not
    /// back), so the other side also starts when the pair has not synced for a minute. Two
    /// sessions at once are harmless: the core refuses the second for the same device.
    func syncAll() {
        guard hasAccount, let mine = status?.accountId, let me = status?.deviceId else { return }
        let now = UInt64(Date().timeIntervalSince1970)
        for p in peers.values where p.account == mine {
            if p.host == nil, let endpoint = endpoints[p.device] { resolve(endpoint, device: p.device) }
            let last = status?.peers.first { $0.device == p.device }?.lastSync ?? 0
            guard me < p.device || now &- last > 60 else { continue }
            if let h = p.host, let port = p.port { Core.syncWith(host: h, port: port) }
        }
    }

    /// "立即同步": looks every device of the account up again (a restarted app has a new port)
    /// and syncs with each as soon as it is found, whichever side would normally start. Says
    /// what happened in `note`.
    func syncNow() {
        guard hasAccount, let mine = status?.accountId else { setNote(L("sync.err.noAccount")); return }
        let targets = peers.values.filter { $0.account == mine }
        if localNetworkDenied { setNote(L("sync.err.noLocalNetwork")); return }
        guard !targets.isEmpty else {
            setNote(L("sync.err.noneOnline"))
            rediscover()
            return
        }
        cancelResolvers()
        syncWhenResolved.removeAll()
        noteStarted = Date()
        setNote(L("sync.connecting") + targets.map(\.name).joined(separator: L("list.separator")) + "…")
        for p in targets {
            syncWhenResolved.insert(p.device)
            peers[p.device]?.host = nil; peers[p.device]?.port = nil
            if let ep = endpoints[p.device] { resolve(ep, device: p.device) }
        }
    }

    private func setNote(_ t: String?) { note = t; post() }

    /// Bonjour endpoints by device (to look a device up again without waiting for the browser).
    private var endpoints: [String: NWEndpoint] = [:]
    private var advertisementRevisions: [String: String] = [:]

    /// After a manual sync: report success or the reason once the sessions have ended.
    private func updateNote(_ s: Status) {
        guard let started = noteStarted else { return }
        if Date().timeIntervalSince(started) > 20, s.syncing == 0 {
            for device in syncWhenResolved {
                cancelResolver(device)
                resolveErrors[device] = L("sync.err.timeoutForeground")
            }
            syncWhenResolved.removeAll()
        }
        guard s.syncing == 0, syncWhenResolved.isEmpty else { return }
        let since = UInt64(started.timeIntervalSince1970)
        let mine = peers.values.filter { $0.account == s.accountId }
        let ok = mine.filter { p in (s.peers.first { $0.device == p.device }?.lastSync ?? 0) >= since }
        let errors = mine.compactMap { p -> String? in
            if let error = resolveErrors[p.device] { return L("format.labelValue", p.name, error) }
            guard let h = p.host, let port = p.port, let e = s.failed?["\(h):\(port)"] else { return nil }
            return L("format.labelValue", p.name, e)
        }
        if !ok.isEmpty && errors.isEmpty { noteStarted = nil; setNote(L("sync.done") + ok.map(\.name).joined(separator: L("list.separator"))) }
        else if !errors.isEmpty { noteStarted = nil; setNote(L("sync.failedPrefix") + errors.joined(separator: L("list.semicolon"))) }
        else if Date().timeIntervalSince(started) > 15 { noteStarted = nil; setNote(L("sync.err.noConnection")) }
    }

    @objc private func localChange() {
        pendingLocalSync?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.syncAll() }
        pendingLocalSync = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    func refreshStatus() {
        guard let s = Core.syncStatus() else { return }
        let grew = s.changes > lastChanges
        lastChanges = s.changes
        guard s != status else { updateNote(s); return }   // only notify on real changes
        status = s
        post()
        // a failed address may be stale (the other app restarted on a new port): look it up again
        // a failure that is gone (the address worked again) counts as new if it comes back
        handledFailures.formIntersection((s.failed ?? [:]).map { $0.key + $0.value })
        for (addr, err) in s.failed ?? [:] where !handledFailures.contains(addr + err) {
            handledFailures.insert(addr + err)
            AppLog.warn("sync", L("sync.failed", err))
            for p in peers.values where p.host.map({ "\($0):\(p.port ?? 0)" }) == addr {
                peers[p.device]?.host = nil; peers[p.device]?.port = nil
                if let ep = endpoints[p.device] { resolve(ep, device: p.device) }
            }
        }
        updateNote(s)
        for p in s.peers where p.clockWarning == true && !warnedSkew.contains(p.device) {
            warnedSkew.insert(p.device)
            let text = L("sync.clock.warning", p.name, p.skewText ?? L("sync.clock.mismatch"))
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.warning, object: nil, userInfo: ["text": text]) }
        }
        #if canImport(UIKit)
        // iOS pauses networking when the screen locks; keep it awake while a sync is running.
        UIApplication.shared.isIdleTimerDisabled = s.syncing > 0
        #endif
        if grew {
            // Remote data arrived: refresh UI without echoing a sync storm back.
            NotificationCenter.default.removeObserver(self, name: .libraryChanged, object: nil)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(localChange), name: .libraryChanged, object: nil)
        }
    }

    private func post() { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) } }

    // MARK: Bonjour

    private func advertise(port: UInt16) {
        service?.stop()
        let dev = status?.deviceId ?? UUID().uuidString
        let svc = NetService(domain: "local.", type: Self.serviceType + ".", name: "\(Self.deviceName)·\(dev.prefix(4))", port: Int32(port))
        var txt: [String: Data] = ["dev": Data(dev.utf8), "name": Data(Self.deviceName.utf8), "kind": Data(Self.deviceKind.utf8), "rev": Data(UUID().uuidString.utf8)]
        if let a = status?.accountId { txt["acct"] = Data(a.utf8) }
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.delegate = self
        svc.publish()
        service = svc
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        AppLog.warn("sync", L("sync.err.publish", errorDict))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.service === sender, let port = self.status?.port else { return }
            self.advertise(port: port)
        }
    }

    private func browse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            DispatchQueue.main.async {
                guard let self, let b, self.browser === b else { return }
                self.apply(results)
            }
        }
        b.stateUpdateHandler = { [weak self, weak b] state in
            // Denied local-network permission shows up as a DNS "policy denied" (-65570) error.
            var denied = false
            if case .waiting(let e) = state, case .dns(let code) = e, code == -65570 { denied = true }
            if case .failed(let e) = state, case .dns(let code) = e, code == -65570 { denied = true }
            if case .failed(let e) = state { AppLog.warn("sync", L("sync.err.browse", e)) }
            DispatchQueue.main.async {
                guard let self, let b, self.browser === b else { return }
                if case .failed = state, !denied {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak b] in
                        guard let self, let b, self.browser === b else { return }
                        self.rediscover()
                    }
                }
                if case .ready = state { denied = false }
                guard denied != self.localNetworkDenied else { return }
                self.localNetworkDenied = denied
                self.post()
                if denied && !self.warnedDenied {
                    self.warnedDenied = true
                    NotificationCenter.default.post(name: Self.warning, object: nil, userInfo: ["text": L("sync.err.paused"), "settings": true])
                }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        let me = status?.deviceId
        var seen = Set<String>()
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata,
                  let dev = txt["dev"], dev != me else { continue }
            seen.insert(dev)
            let old = peers[dev]
            // a re-published service (the other app restarted) may have a new port: look it up again
            let same = old?.serviceName == name && endpoints[dev] == r.endpoint && advertisementRevisions[dev] == txt["rev"]
            let peer = Peer(serviceName: name, name: txt["name"] ?? name, account: txt["acct"], device: dev, kind: txt["kind"],
                            host: same ? old?.host : nil, port: same ? old?.port : nil)
            if !same { cancelResolver(dev) }
            peers[dev] = peer
            endpoints[dev] = r.endpoint
            advertisementRevisions[dev] = txt["rev"]
            if peer.host == nil { resolve(r.endpoint, device: dev) }
        }
        for k in Array(peers.keys) where !seen.contains(k) { cancelResolver(k); peers.removeValue(forKey: k); endpoints.removeValue(forKey: k); advertisementRevisions.removeValue(forKey: k); syncWhenResolved.remove(k) }
        post()
    }

    private func cancelResolver(_ device: String) {
        resolveDeadlines.removeValue(forKey: device)?.cancel()
        resolveRetries.removeValue(forKey: device)?.cancel()
        if let c = resolvers.removeValue(forKey: device) { c.stateUpdateHandler = nil; c.cancel() }
    }

    /// Probe reachability with a bounded lifetime. All callbacks check connection identity:
    /// an old connection must never overwrite a new Bonjour result for the same device.
    private func resolve(_ endpoint: NWEndpoint, device: String, attempt: Int = 0) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard resolvers[device] == nil, resolveRetries[device] == nil else { return }
        let params = NWParameters.tcp
        if attempt == 0, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolvers[device] = c
        resolveErrors[device] = nil
        let timeout = DispatchWorkItem { [weak self, weak c] in
            guard let self, let c, self.resolvers[device] === c else { return }
            self.resolveFailed(device, endpoint: endpoint, attempt: attempt, message: L("sync.err.timeout"))
        }
        resolveDeadlines[device] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: timeout)
        c.stateUpdateHandler = { [weak self, weak c] state in
            DispatchQueue.main.async {
                guard let self, let c, self.resolvers[device] === c else { return }
                switch state {
                case .ready:
                    guard case let .hostPort(host, port) = c.currentPath?.remoteEndpoint, var peer = self.peers[device] else {
                        self.resolveFailed(device, endpoint: endpoint, attempt: attempt, message: L("sync.err.address")); return
                    }
                    var h = "\(host)"
                    // IPv6 link-local addresses require the interface scope; IPv4 does not.
                    if !h.contains(":"), let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    self.cancelResolver(device)
                    self.resolveErrors[device] = nil
                    peer.host = h; peer.port = port.rawValue; self.peers[device] = peer
                    self.post()
                    if self.syncWhenResolved.remove(device) != nil { Core.syncWith(host: h, port: port.rawValue) }
                    else { self.syncAll() }
                case .failed(let error):
                    self.resolveFailed(device, endpoint: endpoint, attempt: attempt, message: error.localizedDescription)
                case .cancelled:
                    self.resolveFailed(device, endpoint: endpoint, attempt: attempt, message: L("sync.err.cancelled"))
                default: break   // .waiting/.preparing are bounded by the deadline above
                }
            }
        }
        c.start(queue: queue)
    }

    private func resolveFailed(_ device: String, endpoint: NWEndpoint, attempt: Int, message: String) {
        cancelResolver(device)
        peers[device]?.host = nil; peers[device]?.port = nil
        resolveErrors[device] = message
        if attempt == 0, endpoints[device] == endpoint {
            let retry = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.resolveRetries[device] = nil
                guard self.endpoints[device] == endpoint else { return }
                self.resolve(endpoint, device: device, attempt: 1)
            }
            resolveRetries[device] = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
        } else {
            syncWhenResolved.remove(device)
            AppLog.warn("sync", L("sync.err.connectPeer") + message)
            if let status { updateNote(status) }
        }
        post()
    }

}

extension Core {
    static func syncNewAccount() -> Result<String, Error> { Result { try decodeOk(tl_sync_new_account(), as: String.self) } }
    static func syncStart(accountKey: String, deviceName: String) -> Result<UInt16, Error> { Result { try decodeOk(tl_sync_start(accountKey, deviceName), as: UInt16.self) } }
    static func syncRestartListener() -> Result<UInt16, Error> { Result { try decodeOk(tl_sync_restart_listener(), as: UInt16.self) } }
    static func syncStatus() -> SyncService.Status? { try? decodeOk(tl_sync_status(), as: SyncService.Status.self) }
    static func syncPairBegin() throws -> String { try decodeOk(tl_sync_pair_begin(), as: String.self) }
    static func syncPairCancel() { tl_sync_pair_cancel() }
    static func syncJoin(host: String, port: UInt16, code: String) throws { _ = try decodeOk(tl_sync_join(host, port, code), as: Optional<Int>.self) }
    static func syncPeerModels(host: String, port: UInt16) throws -> [Core.ModelInfo] { try decodeOk(tl_sync_peer_models(host, port), as: [Core.ModelInfo].self) }
    static func syncPullModel(host: String, port: UInt16, id: String, label: String, total: UInt64) throws {
        _ = try decodeOk(tl_sync_pull_model(host, port, id, label, total), as: Optional<Int>.self)
    }
    static func syncWith(host: String, port: UInt16) { _ = try? decodeOk(tl_sync_with(host, port), as: Optional<Int>.self) }
}

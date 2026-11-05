import UIKit

/// Six digit tiles with a draining countdown bar. Updated in place (no list reloads), so the
/// one-second countdown never makes the screen stutter.
final class PairingCodeView: UIView {
    private let digits = UILabel()
    private let caption = UILabel()
    private(set) var code: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        digits.font = .monospacedDigitSystemFont(ofSize: 40, weight: .light)
        digits.textAlignment = .center
        digits.adjustsFontSizeToFitWidth = true
        caption.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        let st = UIStackView(arrangedSubviews: [digits, caption])
        st.axis = .vertical
        st.spacing = 6
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([st.topAnchor.constraint(equalTo: topAnchor, constant: 12), st.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
                                     st.leadingAnchor.constraint(equalTo: leadingAnchor), st.trailingAnchor.constraint(equalTo: trailingAnchor)])
        accessibilityIdentifier = "pairingCode"
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(code: String, secondsLeft: UInt64) {
        if code != self.code {
            self.code = code
            accessibilityLabel = code
            digits.attributedText = NSAttributedString(string: code, attributes: [.kern: 8])
        }
        caption.text = String(format: L("sync.code.expires"), Int(secondsLeft) / 60, Int(secondsLeft) % 60)
        accessibilityValue = caption.text
    }
}

/// LAN sync: create an account, admit devices with a 6-digit code, or join one.
final class SyncViewController: FormViewController {
    private var observers: [NSObjectProtocol] = []
    private let codeView = PairingCodeView()
    private let stats = StatsCardView()
    private var joining = false
    private var countdown: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("common.lanSync")
        navigationItem.largeTitleDisplayMode = .never
        observers = [SyncService.changed, ActivityCenter.changed].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        }
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateCode() }
        build()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver); countdown?.invalidate() }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if SyncService.shared.status?.pairingCode != nil { SyncService.shared.cancelPairing() }
    }

    private func tick() {
        let svc = SyncService.shared
        if joining, let j = svc.status?.join, !j.running {
            joining = false
            if svc.adoptJoinResultIfAny() {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                alert(L("sync.joined"), L("sync.joined.message"))
            } else if let e = j.error {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                alert(L("sync.joinFailed"), e)
            }
        }
        build()
    }

    /// Countdown: touches only the code view.
    private func updateCode() {
        guard let st = SyncService.shared.status, let code = st.pairingCode else { return }
        let left = max(0, Int(st.pairingSecondsLeft ?? 0) - Int(Date().timeIntervalSince(lastStatusAt)))
        codeView.update(code: code, secondsLeft: UInt64(left))
    }
    private var lastStatusAt = Date()

    private func ago(_ t: UInt64) -> String {
        guard t > 0 else { return L("time.never") }
        let s = Int(Date().timeIntervalSince1970) - Int(t)
        return s < 60 ? L("time.justNow") : s < 3600 ? L("time.minutesAgo", s / 60) : s < 86400 ? L("time.hoursAgo", s / 3600) : L("time.daysAgo", s / 86400)
    }

    private func build() {
        let svc = SyncService.shared
        let st = svc.status
        lastStatusAt = Date()
        stats.update(ActivityCenter.shared.stats)
        var s: [Section] = []
        if svc.localNetworkDenied {
            s.append(Section(id: "denied", header: L("sync.noLocalNetwork"), footer: L("sync.noLocalNetwork.ios"), rows: [
                .button(L("sync.openSettings"), icon: .init("gear", .systemRed), id: "b:settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) },
            ]))
        }

        if let n = ActivityCenter.shared.stats?.newerOps, n > 0 {
            s.append(Section(id: "newer", header: L("sync.updateDevice"), footer: LibraryStats.newerOpsText, rows: [
                .value(L("sync.pendingRecords"), L("common.items", n), icon: .init("arrow.up.circle.fill", .systemOrange), id: "newerOps")]))
        }
        if svc.hasAccount, let acct = st?.accountId {
            s.append(Section(id: "me", header: L("sync.thisDevice"), rows: [
                .custom("stats", stats),
                .value(L("sync.device"), st?.deviceName, icon: .init("laptopcomputer.and.iphone", .systemBlue)),
                .value(L("sync.account"), String(acct.prefix(8)).uppercased(), icon: .init("person.badge.key.fill", .systemIndigo)),
                .value(L("sync.status"), (st?.syncing ?? 0) > 0 ? L("sync.syncingEllipsis") : L("sync.idle"), icon: .init("arrow.triangle.2.circlepath", .systemTeal), id: "status"),
                .button(L("sync.now"), icon: .init("arrow.clockwise", .systemGreen)) { svc.syncNow() },
            ] + (svc.note.map { [.value($0, nil, icon: .init("info.circle", .systemGray), id: "syncNote")] } ?? [])))
            if let code = st?.pairingCode {
                codeView.update(code: code, secondsLeft: st?.pairingSecondsLeft ?? 0)
                s.append(Section(id: "pair", header: L("sync.addDevice"), footer: L("sync.addDevice.footer"), rows: [
                    .custom("code", codeView),
                    .button(L("common.cancel"), icon: .init("xmark", .systemRed), destructive: true) { svc.cancelPairing() },
                ]))
            } else {
                s.append(Section(id: "pair", header: L("sync.addDevice"), rows: [
                    .button(L("sync.showCodeEllipsis"), icon: .init("plus.viewfinder", .systemBlue)) { _ = svc.beginPairing(); svc.refreshStatus() }]))
            }
            let mine = svc.peers.values.filter { $0.account == acct }.sorted { $0.name < $1.name }
            let known = st?.peers ?? []
            var rows: [Row] = mine.map { p in
                let info = known.first { $0.device == p.device }
                var detail = svc.connectionDetail(p) ?? (L("sync.onlinePrefix") + (info.map { $0.lastError == nil ? L("sync.syncedAt") + self.ago($0.lastSync) : L("sync.errored") } ?? L("sync.waiting")))
                if let t = p.typeName { detail = t + " · " + detail }
                if let skew = info?.skewText { detail += " · ⚠︎ " + skew }
                return .value(p.name, detail, icon: .init(info?.skewText == nil ? "checkmark.icloud.fill" : "clock.badge.exclamationmark.fill", info?.skewText == nil ? .systemGreen : .systemOrange), id: "peer-\(p.device)")
            }
            for k in known where !mine.contains(where: { $0.device == k.device }) {
                rows.append(.value(k.name, L("sync.offlineLast") + ago(k.lastSync), icon: .init("icloud.slash.fill", .systemGray), id: "peer-\(k.device)"))
            }
            if rows.isEmpty { rows = [.value(L("sync.noOthers"), nil, icon: .init("wifi", .systemGray))] }
            s.append(Section(id: "peers", header: L("sync.devices"), footer: L("sync.devices.footer"), rows: rows))
            s.append(Section(id: "leave", footer: L("sync.leave.footer"), rows: [
                .button(L("sync.leave"), icon: .init("rectangle.portrait.and.arrow.right", .systemRed), destructive: true) { [weak self] in self?.confirmLeave() }]))
        } else {
            s.append(Section(id: "create", header: L("sync.first"), footer: L("sync.first.footer"), rows: [
                .button(L("sync.create"), icon: .init("person.crop.circle.badge.plus", .systemBlue)) { svc.createAccount() }]))
            let joinable = svc.peers.values.filter { $0.account != nil }.sorted { $0.name < $1.name }
            var rows: [Row] = joinable.map { p in
                .navigation(p.name, detail: p.host == nil ? L("sync.resolving") : L("sync.join"), icon: .init(p.typeSymbol, .systemIndigo, mascot: Mascot.name(forDevice: p.typeSymbol)), id: "join-\(p.device)") { [weak self] in self?.promptCode(p) }
            }
            if joining { rows.insert(.value(L("sync.pairing"), nil, icon: .init("hourglass", .systemOrange), id: "joining"), at: 0) }
            if rows.isEmpty { rows = [.value(L("sync.searching"), nil, icon: .init("dot.radiowaves.left.and.right", .systemTeal))] }
            s.append(Section(id: "join", header: L("sync.joinExisting"), footer: L("sync.joinExisting.footer"), rows: rows))
        }
        sections = s
        reloadForm()
    }

    private func promptCode(_ p: SyncService.Peer) {
        let a = UIAlertController(title: L("sync.joinOf", p.name), message: L("sync.enterCode"), preferredStyle: .alert)
        a.addTextField { $0.keyboardType = .numberPad; $0.placeholder = "000000"; $0.textContentType = .oneTimeCode; $0.accessibilityIdentifier = "codeField" }
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("sync.join"), style: .default) { [weak self] _ in
            do { try SyncService.shared.join(peer: p, code: a.textFields?.first?.text ?? ""); self?.joining = true; self?.build() }
            catch { self?.alert(L("sync.cannotJoin"), error.localizedDescription) }
        })
        present(a, animated: true)
    }

    private func confirmLeave() {
        let a = UIAlertController(title: L("sync.leave.title"), message: L("sync.leave.message"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("sync.leave.keep"), style: .default) { _ in SyncService.shared.leaveAccount() })
        // the same as 清除所有数据 in 设置, with its confirmation: it leaves the account too
        a.addAction(UIAlertAction(title: L("sync.leave.deleteAll"), style: .destructive) { [weak self] _ in
            (self?.navigationController?.viewControllers.first { $0 is SettingsViewController } as? SettingsViewController)?.confirmWipe()
        })
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        present(a, animated: true)
    }
}

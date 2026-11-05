import AppKit
import SwiftUI

@MainActor
final class SyncModel: ObservableObject {
    @Published var joining = false

    /// A pairing that ended: adopt the account, or say why not.
    func tick(_ window: NSWindow?) {
        let svc = SyncService.shared
        guard joining, let j = svc.status?.join, !j.running else { return }
        joining = false
        if svc.adoptJoinResultIfAny() { macAlert(window, L("sync.joined"), L("sync.joined.mac")) }
        else if let e = j.error { macAlert(window, L("sync.joinFailed"), e) }
    }

    func join(_ p: SyncService.Peer, _ window: NSWindow?) {
        macPrompt(window, title: L("sync.joinOf", p.name), message: L("sync.enterCode"), placeholder: "000000") { [weak self] code in
            do { try SyncService.shared.join(peer: p, code: code); self?.joining = true }
            catch { macAlert(window, L("sync.cannotJoin"), error.localizedDescription) }
        }
    }
}

struct SyncPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @StateObject private var m = SyncModel()

    var body: some View {
        let _ = live.count
        let svc = SyncService.shared
        let st = svc.status
        SettingsCanvas {
            if svc.localNetworkDenied {
                Card(tint: .red, spacing: 12) {
                    CardRow(symbol: "wifi.exclamationmark", color: .red, title: L("sync.noLocalNetwork"),
                            detail: L("sync.noLocalNetwork.mac")) {
                        Button(L("sync.openSystemSettings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!) }
                    }
                }
            }
            if let n = ActivityCenter.shared.stats?.newerOps, n > 0 {
                Card(tint: .orange, spacing: 8) {
                    CardRow(symbol: "arrow.up.circle.fill", color: .orange, title: L("sync.updateMac", n), detail: LibraryStats.newerOpsText) { EmptyView() }
                }
            }
            if svc.hasAccount, let acct = st?.accountId {
                account(svc, st, acct)
            } else {
                noAccount(svc)
            }
        }
        .onAppear { live.onTick = { [weak m] in m?.tick(env.window) }; live.start(every: 1) }
        .onDisappear { live.stop() }
    }

    // MARK: With an account

    @ViewBuilder private func account(_ svc: SyncService, _ st: SyncService.Status?, _ acct: String) -> some View {
        let syncing = (st?.syncing ?? 0) > 0
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    if syncing { PulseRing(color: .green) }
                    IconTile(symbol: "laptopcomputer", color: .green, size: 52, mascot: "laptop")
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text(st?.deviceName ?? L("sync.thisMac")).font(.system(size: 20, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Pill(text: L("sync.accountId", acct.prefix(8).uppercased()), color: .secondary, symbol: "person.crop.circle")
                        if syncing { Pill(text: L("mac.sync.syncing"), color: .blue, symbol: "arrow.triangle.2.circlepath") }
                        else { Pill(text: L("sync.idle"), color: .green, symbol: "checkmark") }
                    }
                }
                Spacer(minLength: 8)
                Button { svc.syncNow() } label: { Label(L("sync.now"), systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            StatsStrip(stats: ActivityCenter.shared.stats)
            if let n = svc.note { Banner(text: n, symbol: "info.circle.fill", color: .blue) }
            Text(L("sync.devices.footer.mac"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(LinearGradient(colors: [Color.green.opacity(0.18), Color.teal.opacity(0.08), Color.blue.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: Color.green.opacity(0.12), radius: 16, y: 6)
        }

        devices(svc, st, acct)
        addDevice(svc, st)

        Card(tint: .red, spacing: 10) {
            CardRow(symbol: "rectangle.portrait.and.arrow.right", color: .red, title: L("sync.leave"), detail: L("sync.leave.footer.mac")) {
                Button(L("sync.leaveEllipsis"), role: .destructive) {
                    macChoose(env.window, title: L("sync.leave.title"), message: L("sync.leave.message"), options: [L("sync.leave.keep"), L("sync.leave.deleteAll")]) { choice in
                        if choice == 0 { svc.leaveAccount() } else { MacWipeFlow.start(env.window) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func devices(_ svc: SyncService, _ st: SyncService.Status?, _ acct: String) -> some View {
        let mine = svc.peers.values.filter { $0.account == acct }.sorted { $0.name < $1.name }
        let known = st?.peers ?? []
        let offline = known.filter { k in !mine.contains(where: { $0.device == k.device }) }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("sync.devices"), note: mine.isEmpty && known.isEmpty ? nil : L("sync.devices.counts", svc.reachablePeers.count, mine.count, offline.count))
            if mine.isEmpty && known.isEmpty {
                Card { Text(L("sync.noOthers.mac")).foregroundStyle(.secondary) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(mine, id: \.device) { p in
                        let info = known.first { $0.device == p.device }
                        deviceCard(name: p.name, symbol: p.typeSymbol, online: p.host != nil,
                                   detail: [p.typeName, svc.connectionDetail(p) ?? info.map { $0.lastError == nil ? L("sync.syncedAgo", ago($0.lastSync)) : L("sync.error", $0.lastError!) } ?? L("sync.justFound")].compactMap { $0 }.joined(separator: " · "),
                                   warning: info?.skewText, failed: info?.lastError != nil, discovered: true)
                    }
                    ForEach(offline, id: \.device) { k in
                        deviceCard(name: k.name, online: false, detail: L("sync.lastSynced", ago(k.lastSync)), warning: k.skewText, failed: false)
                    }
                }
            }
        }
    }

    private func deviceCard(name: String, symbol: String = "laptopcomputer.and.iphone", online: Bool, detail: String, warning: String?, failed: Bool, discovered: Bool = false) -> some View {
        Card(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, color: online ? .green : .gray, size: 40, mascot: Mascot.name(forDevice: symbol))
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(online ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                        Text(online ? L("sync.online") : (discovered ? L("sync.found") : L("sync.offline"))).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(detail).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning { Banner(text: warning, symbol: "clock.badge.exclamationmark", color: .orange) }
        }
        .opacity(online ? 1 : 0.8)
    }

    /// The pairing: a code that stays valid for a few minutes.
    @ViewBuilder private func addDevice(_ svc: SyncService, _ st: SyncService.Status?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("sync.addDevice"))
            if let code = st?.pairingCode {
                Card(tint: .blue, spacing: 16) {
                    PairingCodeView(code: code, secondsLeft: Int(st?.pairingSecondsLeft ?? 0))
                    HStack {
                        Text(L("sync.addDevice.mac")).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("common.cancel"), role: .destructive) { svc.cancelPairing() }
                    }
                }
            } else {
                Card {
                    CardRow(symbol: "plus.viewfinder", color: .blue, title: L("sync.showCode"), detail: L("sync.showCode.detail")) {
                        Button(L("sync.showCodeEllipsis")) { _ = svc.beginPairing(); svc.refreshStatus() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: Without an account

    @ViewBuilder private func noAccount(_ svc: SyncService) -> some View {
        let joinable = svc.peers.values.filter { $0.account != nil }.sorted { $0.name < $1.name }
        Card(tint: .green, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "person.crop.circle.badge.plus", color: .green, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("sync.first")).font(.system(size: 16, weight: .semibold))
                    Text(L("sync.first.footer")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { svc.createAccount() } label: { Label(L("sync.create"), systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("sync.joinExisting"), note: L("sync.joinExisting.footer"))
            Card(spacing: 12) {
                if m.joining { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("sync.pairing")).foregroundStyle(.secondary) } }
                if joinable.isEmpty {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L("sync.searching")).foregroundStyle(.secondary) }
                }
                ForEach(Array(joinable.enumerated()), id: \.element.device) { i, p in
                    if i > 0 { RowDivider() }
                    CardRow(symbol: p.typeSymbol, color: .indigo, mascot: Mascot.name(forDevice: p.typeSymbol), title: p.name, detail: L("sync.accountDevices")) {
                        Button(p.host == nil ? L("sync.resolving") : L("sync.joinEllipsis")) { m.join(p, env.window) }.disabled(p.host == nil)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func ago(_ t: UInt64) -> String {
        guard t > 0 else { return L("time.never") }
        let s = Int(Date().timeIntervalSince1970) - Int(t)
        return s < 60 ? L("time.justNow") : s < 3600 ? L("time.minutesAgo", s / 60) : L("time.hoursAgo", s / 3600)
    }
}

/// A ring that breathes outward (something is happening).
struct PulseRing: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().strokeBorder(color.opacity(on ? 0 : 0.5), lineWidth: 3)
            .scaleEffect(on ? 1.35 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// Six digits in boxes, with a draining countdown (the service reports the seconds left every second or so).
struct PairingCodeView: View {
    let code: String
    let secondsLeft: Int
    @State private var base = 0
    @State private var baseAt = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, base - Int(ctx.date.timeIntervalSince(baseAt)))
            VStack(spacing: 6) {
                Text(code).font(.system(size: 40, weight: .light)).monospacedDigit().tracking(8).textSelection(.enabled)
                Text(String(format: L("sync.code.expires"), left / 60, left % 60)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { base = secondsLeft; baseAt = Date() }
        .onChange(of: secondsLeft) { _, v in base = v; baseAt = Date() }
        .onChange(of: code) { _, _ in base = secondsLeft; baseAt = Date() }
    }
}

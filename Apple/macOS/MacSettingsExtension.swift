import AppKit
import SwiftUI

/// The browser extension's receiver on this Mac (the core answers it, see core/src/extension.rs):
/// listening while the app is open, with the user's download settings (route, concurrency,
/// interval), so a link from the browser downloads as one pasted here would.
@MainActor
final class ExtensionReceiver {
    static let shared = ExtensionReceiver()
    static let openSettingsRequested = Notification.Name("twimshelf.ext.openSettings")
    static let managedChanged = Notification.Name("twimshelf.ext.managedChanged")
    private static let lastCheckKey = "ext.update.lastCheck"
    private static let skippedKey = "ext.update.skipped"

    private(set) var port: Int?
    private(set) var problem: String?
    private var observer: NSObjectProtocol?
    private var openPoll: Timer?

    static var managedDirectory: URL {
        Core.libraryDirectory.appendingPathComponent("extension", isDirectory: true)
    }

    func start() {
        apply()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        openPoll?.invalidate()
        openPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if Core.extensionTakeOpenSettings() {
                MainActor.assumeIsolated {
                    NotificationCenter.default.post(name: Self.openSettingsRequested, object: nil)
                }
            }
        }
    }

    private func apply() {
        let d = UserDefaults.standard
        let routes = DownloadRoute.allCases
        let route = routes[min(max(d.integer(forKey: "dl.route"), 0), routes.count - 1)].rawValue
        do {
            port = try Core.extensionServe(name: SyncService.deviceName, platform: "macos", route: route,
                                           concurrency: d.object(forKey: "dl.concurrency") as? Int ?? 3,
                                           intervalMs: d.object(forKey: "dl.interval") as? Int ?? 500,
                                           folder: nil, listen: true, desktop: true, managedDir: Self.managedDirectory.path)
            problem = nil
        } catch {
            problem = error.localizedDescription
            AppLog.warn("extension", error.localizedDescription)
        }
    }

    /// Daily automatic update check for the app-hosted extension (only when the app manages a copy
    /// in its own data directory; external installs are never checked or modified).
    static func checkUpdateOnLaunch(window: NSWindow?) {
        guard let status = try? Core.extensionManagedStatus(), status.installed else { return }
        let ud = UserDefaults.standard
        if Date().timeIntervalSince1970 - ud.double(forKey: lastCheckKey) < 86_400 { return }
        let repo = UpdateCheck.repo ?? ""
        DispatchQueue.global(qos: .utility).async {
            let r = Result { try Core.extensionManagedCheck(repo: repo) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard case .success(let info) = r else { return }
                    ud.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                    guard info.installed, info.hasUpdate, ud.string(forKey: skippedKey) != info.latest else { return }
                    macChoose(window, title: L("ext.managed.prompt.title", info.latest),
                              message: L("ext.managed.prompt.message", info.current ?? ""),
                              options: [L("ext.managed.updateNow"), L("update.later"), L("update.skip")]) { i in
                        if i == 2 { ud.set(info.latest, forKey: skippedKey); return }
                        guard i == 0 else { return }
                        installManaged(window: window, updating: true)
                    }
                }
            }
        }
    }

    /// Downloads or updates the app-hosted extension in-place (Chrome does not need to quit).
    static func installManaged(window: NSWindow?, updating: Bool, done: (@MainActor (Result<Core.ExtensionManagedStatus, Error>) -> Void)? = nil) {
        let repo = UpdateCheck.repo ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Core.extensionManagedInstall(repo: repo) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch r {
                    case .success(let st):
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                        UserDefaults.standard.removeObject(forKey: skippedKey)
                        NotificationCenter.default.post(name: Self.managedChanged, object: nil)
                        if updating {
                            macAlert(window, L("ext.managed.updated.title", st.version ?? ""), L("ext.managed.updated.message"))
                        } else {
                            macAlert(window, L("ext.managed.downloaded.title"), L("ext.managed.downloaded.message", st.dir))
                        }
                    case .failure(let e):
                        AppLog.warn("extension", "managed install: \(e.localizedDescription)")
                        macAlert(window, L("ext.managed.downloadFailed", e.localizedDescription))
                    }
                    done?(r)
                }
            }
        }
    }

    /// The tile's detail: how many browsers are bound.
    static var summary: String {
        let n = (try? Core.extensionState().clients.count) ?? 0
        return n == 0 ? L("ext.state.none") : L("ext.state.count", "\(n)")
    }
}

struct ExtensionPageView: View {
    var autoCheckUpdate = false
    @EnvironmentObject private var env: PaneEnv
    @State private var state: Core.ExtensionState?
    @State private var managed: Core.ExtensionManagedStatus?
    @State private var updateCheck: Core.ExtensionUpdateCheck?
    @State private var busyText: String?
    @State private var error: String?
    @State private var before: Set<String> = []
    @State private var copied = false
    @State private var pathCopied = false
    @State private var didAutoCheck = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsCanvas {
            Text(L("ext.intro")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            managedSection
            if let p = state?.pairing { codeCard(p) } else {
                Card(spacing: 12) {
                    CardRow(symbol: "link.badge.plus", color: .blue, title: L("ext.bind"), detail: nil) {
                        Button(L("ext.bind").replacingOccurrences(of: "…", with: "")) { bind() }
                            .disabled(ExtensionReceiver.shared.port == nil)
                            .accessibilityIdentifier("extBind")
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("ext.clients"), note: footer)
                Card(spacing: 12) {
                    let clients = state?.clients ?? []
                    if clients.isEmpty { Text(L("ext.state.none")).foregroundStyle(.secondary) }
                    ForEach(Array(clients.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { RowDivider(inset: 42) }
                        CardRow(symbol: "puzzlepiece.extension.fill", color: .indigo, title: c.name,
                                detail: L("ext.client.detail", Self.date(c.added), Self.date(c.seen))) {
                            HStack(spacing: 8) {
                                if managed?.installed == true {
                                    if let u = updateCheck, u.hasUpdate {
                                        Button(L("ext.managed.update", u.latest)) { runInstall(updating: true) }
                                            .disabled(busyText != nil)
                                    } else {
                                        Button(L("ext.managed.checkUpdate")) { runCheck(silentIfCurrent: false) }
                                            .disabled(busyText != nil)
                                    }
                                }
                                Button(L("ext.remove.confirm")) { remove(c) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            load()
            if autoCheckUpdate, !didAutoCheck, managed?.installed == true {
                didAutoCheck = true
                runCheck(silentIfCurrent: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ExtensionReceiver.managedChanged)) { _ in loadManaged() }
        .onReceive(timer) { _ in if state?.pairing != nil { load() } }
        .onDisappear { if state?.pairing != nil { Core.extensionPairCancel() } }
    }

    private var managedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("ext.managed.title"))
            Card(spacing: 12) {
                if let m = managed, m.installed {
                    CardRow(symbol: "arrow.down.circle.fill", color: .blue,
                            title: L("ext.managed.version", m.version ?? ""),
                            detail: updateCheck?.hasUpdate == true ? L("ext.managed.updateReady", updateCheck!.latest) : nil) {
                        HStack(spacing: 8) {
                            if let busyText {
                                ProgressView().controlSize(.small)
                                Text(busyText).font(.caption).foregroundStyle(.secondary)
                            } else if let u = updateCheck, u.hasUpdate {
                                Button(L("ext.managed.update", u.latest)) { runInstall(updating: true) }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button(L("ext.managed.checkUpdate")) { runCheck(silentIfCurrent: false) }
                            }
                        }
                    }
                    Text(m.dir)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                    HStack(spacing: 8) {
                        Button(L("ext.managed.openFolder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.dir)])
                        }
                        Button(pathCopied ? L("ext.managed.pathCopied") : L("ext.managed.copyPath")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(m.dir, forType: .string)
                            pathCopied = true
                        }
                        Spacer()
                    }
                    Text(L("ext.managed.installGuide"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    CardRow(symbol: "arrow.down.circle", color: .blue, title: L("ext.managed.download"),
                            detail: L("ext.managed.notInstalled")) {
                        if let busyText {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(busyText).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Button(L("ext.managed.download")) { runInstall(updating: false) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var footer: String {
        if let p = ExtensionReceiver.shared.port { return L("ext.footer.desktop", "\(p)") }
        return L("ext.unavailable", ExtensionReceiver.shared.problem ?? "")
    }

    private func codeCard(_ p: Core.ExtensionPairing) -> some View {
        Card(tint: .blue, spacing: 12) {
            Text(L("ext.code.title")).font(.headline)
            Text("\(p.code.prefix(3)) \(p.code.suffix(3))")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(4).frame(maxWidth: .infinity).textSelection(.enabled)
                .accessibilityIdentifier("extCode")
            Text(L("ext.code.howto")).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(p.link).font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            HStack {
                Text(L("ext.code.expires")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? L("ext.code.copied") : L("ext.code.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.link, forType: .string)
                    copied = true
                }
            }
        }
    }

    private func loadManaged() {
        managed = try? Core.extensionManagedStatus()
    }

    private func load() {
        loadManaged()
        do {
            let s = try Core.extensionState()
            if state?.pairing != nil, s.pairing == nil, let added = s.clients.first(where: { !before.contains($0.id) }) {
                macAlert(env.window, L("ext.code.done", added.name))
            }
            state = s
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func runCheck(silentIfCurrent: Bool) {
        guard busyText == nil else { return }
        busyText = L("ext.managed.checking")
        error = nil
        let repo = UpdateCheck.repo ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Core.extensionManagedCheck(repo: repo) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busyText = nil
                    switch r {
                    case .success(let info):
                        updateCheck = info
                        loadManaged()
                        if info.hasUpdate {
                            macChoose(env.window, title: L("ext.managed.prompt.title", info.latest),
                                      message: L("ext.managed.prompt.message", info.current ?? ""),
                                      options: [L("ext.managed.updateNow"), L("update.later")]) { i in
                                if i == 0 { runInstall(updating: true) }
                            }
                        } else if !silentIfCurrent {
                            macAlert(env.window, L("ext.managed.upToDate", info.current ?? info.latest))
                        }
                    case .failure(let e):
                        error = L("ext.managed.checkFailed", e.localizedDescription)
                    }
                }
            }
        }
    }

    private func runInstall(updating: Bool) {
        guard busyText == nil else { return }
        busyText = updating ? L("ext.managed.updating") : L("ext.managed.downloading")
        error = nil
        ExtensionReceiver.installManaged(window: env.window, updating: updating) { r in
            busyText = nil
            if case .success(let st) = r {
                managed = st
                updateCheck = nil
                pathCopied = false
            }
        }
    }

    private func bind() {
        before = Set(state?.clients.map(\.id) ?? [])
        copied = false
        do { _ = try Core.extensionPairBegin(); load() } catch { self.error = error.localizedDescription }
    }

    private func remove(_ c: Core.ExtensionClient) {
        let a = NSAlert()
        a.messageText = L("ext.remove.title", c.name)
        a.informativeText = L("ext.remove.message")
        a.addButton(withTitle: L("ext.remove.confirm"))
        a.addButton(withTitle: L("common.cancel"))
        let go = { (r: NSApplication.ModalResponse) in
            guard r == .alertFirstButtonReturn else { return }
            do { try Core.extensionRemove(c.id) } catch { self.error = error.localizedDescription }
            load()
        }
        if let w = env.window { a.beginSheetModal(for: w, completionHandler: go) } else { go(a.runModal()) }
    }

    private static func date(_ seconds: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

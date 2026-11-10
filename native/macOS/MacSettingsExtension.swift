import AppKit
import SwiftUI

/// The browser extension's receiver on this Mac (the core answers it, see core/src/extension.rs):
/// listening while the app is open, with the user's download settings (route, concurrency,
/// interval), so a link from the browser downloads as one pasted here would.
@MainActor
final class ExtensionReceiver {
    static let shared = ExtensionReceiver()
    private(set) var port: Int?
    private(set) var problem: String?
    private var observer: NSObjectProtocol?

    func start() {
        apply()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
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
                                           folder: nil, listen: true)
            problem = nil
        } catch {
            problem = error.localizedDescription
            AppLog.warn("extension", error.localizedDescription)
        }
    }

    /// The tile's detail: how many browsers are bound.
    static var summary: String {
        let n = (try? Core.extensionState().clients.count) ?? 0
        return n == 0 ? L("ext.state.none") : L("ext.state.count", "\(n)")
    }
}

struct ExtensionPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @State private var state: Core.ExtensionState?
    @State private var error: String?
    @State private var before: Set<String> = []
    @State private var copied = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsCanvas {
            Text(L("ext.intro")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                            Button(L("ext.remove.confirm")) { remove(c) }
                        }
                    }
                }
            }
        }
        .onAppear { load() }
        .onReceive(timer) { _ in if state?.pairing != nil { load() } }
        .onDisappear { if state?.pairing != nil { Core.extensionPairCancel() } }
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

    private func load() {
        do {
            let s = try Core.extensionState()
            if state?.pairing != nil, s.pairing == nil, let added = s.clients.first(where: { !before.contains($0.id) }) {
                macAlert(env.window, L("ext.code.done", added.name))
            }
            state = s
            error = nil
        } catch { self.error = error.localizedDescription }
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

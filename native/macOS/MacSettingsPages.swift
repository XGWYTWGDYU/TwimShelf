import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings pages, in SwiftUI: cards, tiles and rings on a soft page (`MacSettingsKit`).
/// Each is pushed on the settings panel by `PaneEnv.open`; the panel's header is the main
/// window's toolbar.
enum MacSettingsPages {
    static func root() -> SettingsHost { SettingsHost { SettingsRootView() } }
    static func download() -> SettingsHost { SettingsHost { DownloadPageView() } }
    static func transfer() -> SettingsHost { SettingsHost { TransferPageView() } }
    static func models() -> SettingsHost { SettingsHost { ModelsPageView() } }
    static func modelHub() -> SettingsHost { SettingsHost { ModelHubPageView() } }
    static func modelHubRepo(_ repo: String) -> SettingsHost { SettingsHost { ModelHubRepoPageView(repo: repo) } }
    static func sync() -> SettingsHost { SettingsHost { SyncPageView() } }
    static func problems() -> SettingsHost { SettingsHost { ProblemsPageView() } }
    static func about() -> SettingsHost { SettingsHost { AboutPageView() } }
    static func storage() -> SettingsHost { SettingsHost { StoragePageView() } }
}

// MARK: - Root

/// The front page: the library's numbers, tiles for the places, then preferences and care.
struct SettingsRootView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    private let tiles = [GridItem(.adaptive(minimum: 230), spacing: 14, alignment: .top)]

    var body: some View {
        let _ = live.count
        let stats = ActivityCenter.shared.stats
        let counts = AutoTagger.shared.counts
        let svc = SyncService.shared
        let online = svc.reachablePeers.count
        let downloading = ActivityCenter.shared.activities.first { $0.kind == .download }
        SettingsCanvas {
            hero(stats, svc)
            ActivityCard()

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("mac.manage"))
                LazyVGrid(columns: tiles, spacing: 14) {
                    NavTile(title: L("common.downloadPosts"), detail: downloading.map { "\($0.title) · \($0.detail)" } ?? L("mac.download.detail"), symbol: "arrow.down", color: .blue, mascot: downloading != nil ? "bag" : nil,
                            progress: downloading?.progress, id: "nav-download") { env.open(L("common.downloadPosts"), MacSettingsPages.download()) }
                    NavTile(title: L("common.importAndBackup"), detail: L("settings.import.detail"), symbol: "shippingbox.fill", color: .brown, id: "nav-transfer") { env.open(L("common.importAndBackup"), MacSettingsPages.transfer()) }
                    NavTile(title: L("common.tags"), detail: L("mac.tags.detail", stats?.tags ?? 0), symbol: "tag.fill", color: .indigo, id: "nav-tags") { env.open(L("common.tags"), MacTagsPage()) }
                    NavTile(title: L("common.aiModels"), detail: (ModelStore.shared.activeTaggerId.map { ModelStore.shared.displayName($0) } ?? L("mac.models.none")) + (counts.total > 0 ? L("mac.models.analysed", counts.done, counts.total) : ""),
                            symbol: "sparkles", color: .purple, mascot: AutoTagger.shared.running ? "camera" : nil, progress: counts.total > 0 ? Double(counts.done) / Double(counts.total) : nil, id: "nav-models") { env.open(L("common.aiModels"), MacSettingsPages.models()) }
                    NavTile(title: L("mac.sync"), detail: svc.hasAccount ? (online > 0 ? L("mac.sync.online", online) : L("mac.sync.noneOnline")) : L("mac.sync.noAccount"), symbol: "arrow.triangle.2.circlepath", color: .green,
                            badge: (svc.status?.syncing ?? 0) > 0 ? L("mac.sync.syncing") : nil, badgeColor: .blue, id: "nav-sync") { env.open(L("mac.sync"), MacSettingsPages.sync()) }
                }
            }

            preferences(stats)
            privacyCard
            mascotCard
            // GitHub builds only
            if UpdateCheck.repo != nil {
                Card(spacing: 12) {
                    CardRow(symbol: "arrow.down.app.fill", color: .blue, title: L("update.check"), detail: L("update.footer")) {
                        Button(L("update.check")) { UpdateCheck.run(manual: true) { r in MacUpdate.show(r, window: env.window, manual: true) } }
                    }
                }
            }
            // how many cards a row of 浏览 holds (the window's shape picks the level)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("cards.section"))
                Card(spacing: 14) {
                CardRow(symbol: "rectangle.portrait.split.2x1", color: .teal, title: L("cards.portrait")) {
                    Picker("", selection: Binding(get: { LibraryPrefs.cardDensityPortrait }, set: { LibraryPrefs.cardDensityPortrait = $0 })) {
                        ForEach(0..<3, id: \.self) { Text(LibraryPrefs.densityNames[$0]).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                RowDivider(inset: 42)
                CardRow(symbol: "rectangle.split.3x1", color: .teal, title: L("cards.landscape")) {
                    Picker("", selection: Binding(get: { LibraryPrefs.cardDensityLandscape }, set: { LibraryPrefs.cardDensityLandscape = $0 })) {
                        ForEach(0..<3, id: \.self) { Text(LibraryPrefs.densityNames[$0]).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                }
            }
            // last: what the app takes on this Mac, the app itself, and clearing everything
            Card(spacing: 12) {
                CardRow(symbol: "internaldrive.fill", color: .gray, title: L("storage.title"), detail: L("storage.footer")) {
                    Button(L("common.view")) { env.open(L("storage.title"), MacSettingsPages.storage()) }.accessibilityIdentifier("nav-storage")
                }
                RowDivider(inset: 42)
                CardRow(symbol: "info.circle.fill", color: .gray, title: L("settings.about")) {
                    Button(L("common.view")) { env.open(L("settings.about"), MacSettingsPages.about()) }.accessibilityIdentifier("settingsAbout")
                }
            }
            danger
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    // MARK: Blocks

    private func hero(_ stats: LibraryStats?, _ svc: SyncService) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("common.library")).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(L("mac.stats.footer")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Pill(text: svc.stateText, color: (svc.status?.syncing ?? 0) > 0 ? .blue : .secondary, symbol: "arrow.triangle.2.circlepath")
            }
            StatsStrip(stats: stats)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(LinearGradient(colors: [Color.accentColor.opacity(0.20), Color.purple.opacity(0.10), Color.pink.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: Color.accentColor.opacity(0.12), radius: 16, y: 6)
        }
    }

    private func preferences(_ stats: LibraryStats?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("mac.prefs"))
            Card(spacing: 14) {
                groupLabel(L("settings.section.browse"))
                if LibraryPrefs.aboutExtras, (stats?.bad ?? 0) > 0 || LibraryPrefs.badOnly {
                    ToggleRow(symbol: "exclamationmark.triangle.fill", color: .red, title: L("mac.badOnly"), detail: L("mac.badCount", stats?.bad ?? 0),
                              isOn: Binding(get: { LibraryPrefs.badOnly }, set: { LibraryPrefs.badOnly = $0 }))
                    RowDivider(inset: 42)
                }
                ToggleRow(symbol: "headphones", color: .pink, title: L("settings.headphonesOnly"), detail: L("mac.headphones.detail"),
                          isOn: Binding(get: { AudioPolicy.headphonesOnly }, set: { AudioPolicy.headphonesOnly = $0 }))
                RowDivider(inset: 42)
                ToggleRow(symbol: "hand.raised.slash.fill", color: .indigo, title: L("settings.noGestures"),
                          detail: L("mac.noGestures.detail"),
                          isOn: Binding(get: { LibraryPrefs.playerGesturesOff }, set: { LibraryPrefs.playerGesturesOff = $0 }))

                Divider().padding(.vertical, 2)
                groupLabel(L("common.search"))
                ToggleRow(symbol: "sparkle.magnifyingglass", color: .purple, title: L("settings.fuzzy"),
                          detail: LibraryPrefs.semanticSearchAvailable ? L("mac.fuzzy.detail") : LibraryPrefs.semanticSearchNeedsModel,
                          isOn: Binding(get: { LibraryPrefs.fuzzySearch }, set: { LibraryPrefs.fuzzySearch = $0; NotificationCenter.default.post(name: .libraryChanged, object: nil) }),
                          disabled: !LibraryPrefs.semanticSearchAvailable)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("mac.search.footer"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    FlowLayout(spacing: 6) {
                        ForEach(SearchKeyword.all, id: \.key) { kw in Pill(text: kw.info.word, color: .accentColor, symbol: kw.info.symbol) }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("applock.section"))
            Card(spacing: 14) { AppLockRow() }
        }
    }

    private var mascotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("mascot.title"))
            Card(spacing: 14) {
                ToggleRow(symbol: "pawprint.fill", color: .orange, mascot: "settings", alwaysMascot: true, title: L("mascot.toggle"), detail: L("mascot.footer"),
                          isOn: Binding(get: { Mascot.isOn }, set: { Mascot.isOn = $0 }))
                RowDivider(inset: 42)
                CardRow(symbol: "doc.text", color: .gray, title: L("mascot.licenses")) {
                    Button(L("common.view")) {
                        let a = NSAlert()
                        a.messageText = L("mascot.licenses")
                        a.informativeText = Mascot.license
                        a.runModal()
                    }
                }
            }
        }
    }

    private var danger: some View {
        Card(tint: .red, spacing: 12) {
            CardRow(symbol: "trash.fill", color: .red, title: L("mac.wipe.title"),
                    detail: L("mac.wipe.detail")) {
                Button(L("mac.eraseEllipsis"), role: .destructive) { MacWipeFlow.start(env.window) }.accessibilityIdentifier("wipeAll")
            }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}


// MARK: - Download

@MainActor
final class DownloadModel: ObservableObject {
    static let shared = DownloadModel()
    static let routes: [(title: String, detail: String, symbol: String, color: Color)] = [
        (L("common.auto"), L("mac.method.auto"), "wand.and.stars", .blue),
        (L("settings.method.fx"), L("mac.method.fx"), "globe", .teal),
        (L("settings.method.cookie"), L("mac.method.cookie"), "key.fill", .orange),
    ]
    @Published var route = UserDefaults.standard.integer(forKey: "dl.route") { didSet { UserDefaults.standard.set(route, forKey: "dl.route") } }
    @Published var folder = ""      // "" = none; single links and batches
    @Published var links = ""
    @Published var concurrency = UserDefaults.standard.object(forKey: "dl.concurrency") as? Int ?? 3 { didSet { UserDefaults.standard.set(concurrency, forKey: "dl.concurrency") } }
    @Published var interval = UserDefaults.standard.object(forKey: "dl.interval") as? Int ?? 500 { didSet { UserDefaults.standard.set(interval, forKey: "dl.interval") } }
    @Published var batch: [String] = []
    @Published var batchName: String?
    @Published var authToken = Keychain.get("auth_token") ?? ""
    @Published var ct0 = Keychain.get("ct0") ?? ""

    var routeValue: DownloadRoute { DownloadRoute.allCases[min(max(route, 0), DownloadRoute.allCases.count - 1)] }
    var folderValue: String? { folder.isEmpty ? nil : folder }

    /// The links typed so far: how many are recognised and how many are not.
    var parsed: (good: Int, bad: Int) {
        let urls = links.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let good = urls.filter { Core.fxAPIURL(for: $0) != nil }.count
        return (good, urls.count - good)
    }

    func download(_ window: NSWindow?) {
        let urls = links.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !urls.isEmpty else { return macAlert(window, L("settings.links.empty")) }
        let bad = urls.filter { Core.fxAPIURL(for: $0) == nil }
        guard bad.isEmpty else { return macAlert(window, L("settings.links.unrecognized"), bad.prefix(3).joined(separator: "\n")) }
        do { try Core.startDownload(DownloadRequest(urls: urls, concurrency: concurrency, intervalMs: UInt64(interval), route: routeValue, revive: true, folder: folderValue)); links = "" }
        catch { macAlert(window, L("common.couldNotStartDownload"), error.localizedDescription) }
    }

    func startBatch(_ window: NSWindow?) {
        do {
            try Core.startDownload(DownloadRequest(urls: batch, concurrency: concurrency, intervalMs: UInt64(interval), route: routeValue, folder: folderValue, markRecent: true))
            batch = []; batchName = nil
        } catch { macAlert(window, L("common.couldNotStartDownload"), error.localizedDescription) }
    }

    func chooseBatch(_ window: NSWindow?) { macOpenPanel([.json]) { [weak self] u in self?.loadBatch(u, window) } }

    func loadBatch(_ u: URL, _ window: NSWindow?) {
        do { batch = try Core.bookmarkURLs(in: u); batchName = u.lastPathComponent }
        catch { macAlert(window, L("settings.json.unreadable"), error.localizedDescription) }
    }

    func newFolder(_ window: NSWindow?) {
        macPrompt(window, title: L("common.newFolder"), placeholder: L("common.folderName")) { [weak self] n in
            let n = n.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            _ = try? Core.createFolder(n)
            self?.folder = n
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
    }

    func saveCookies(_ window: NSWindow?) {
        let ok1 = Keychain.set("auth_token", authToken.trimmingCharacters(in: .whitespacesAndNewlines))
        let ok2 = Keychain.set("ct0", ct0.trimmingCharacters(in: .whitespacesAndNewlines))
        Session.applyStoredCookies()
        macAlert(window, ok1 && ok2 ? L("settings.cookie.saved") : L("settings.cookie.notSaved"), ok1 && ok2 ? "" : L("settings.cookie.keychainRefused"))
    }
}

struct DownloadPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @StateObject private var m = DownloadModel.shared
    @State private var dropTargeted = false

    var body: some View {
        let _ = live.count
        let status = Core.downloadStatus()
        let folders = Core.folders().map(\.name)
        let parsed = m.parsed
        SettingsCanvas {
            if status?.running == true, let a = ActivityCenter.shared.activities.first(where: { $0.kind == .download }) {
                Card(tint: .accentColor, spacing: 14) {
                    ActivityRow(activity: a)
                    HStack { Spacer()
                        Button(L("mac.pause")) { do { try Core.stopDownload(pause: true) } catch { macAlert(env.window, L("settings.pauseFailed"), error.localizedDescription) } }
                        Button(L("settings.cancelDownload"), role: .destructive) { do { try Core.stopDownload(pause: false) } catch { macAlert(env.window, L("common.couldNotCancel"), error.localizedDescription) } }
                    }
                }
            }

            if let d = status, !d.running, d.total > 0 { Text(d.outcomeText + L("mac.download.progress", d.done, d.failed)).foregroundStyle(.secondary) }
            if let d = status, !d.running, d.paused > 0 {
                HStack {
                    Text(L("mac.download.paused", d.paused))
                    Button(L("settings.resume")) { do { try Core.resumeDownload() } catch { macAlert(env.window, L("settings.resumeFailed"), error.localizedDescription) } }
                    Button(L("settings.cancelJobs"), role: .destructive) { do { try Core.stopDownload(pause: false) } catch { macAlert(env.window, L("common.couldNotCancel"), error.localizedDescription) } }
                }
            }
            Text(L("settings.paused.footer")).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("settings.method"), note: L("mac.method.footer"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(Array(DownloadModel.routes.enumerated()), id: \.offset) { i, r in
                        OptionCard(title: r.title, detail: r.detail, symbol: r.symbol, color: r.color, selected: m.route == i) { m.route = i }
                    }
                }
                Card(spacing: 10) {
                    Label(L("mac.saveToFolder"), systemImage: "folder").font(.system(size: 13, weight: .medium))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ChipButton(title: L("mac.noFolder"), selected: m.folder.isEmpty) { m.folder = "" }
                            ForEach(folders, id: \.self) { f in ChipButton(title: f, symbol: "folder", selected: m.folder == f) { m.folder = f } }
                            ChipButton(title: L("common.newFolderEllipsis"), symbol: "plus", dashed: true) { m.newFolder(env.window) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("common.downloadPosts"), note: L("mac.links.footer"))
                Card(spacing: 12) {
                    PlaceholderEditor(text: $m.links, placeholder: L("mac.links.placeholder"), minHeight: 120)
                        .accessibilityLabel(L("mac.links.label"))
                    HStack(spacing: 8) {
                        if parsed.good > 0 { Pill(text: L("mac.links.good", parsed.good), color: .green, symbol: "checkmark") }
                        if parsed.bad > 0 { Pill(text: L("mac.links.bad", parsed.bad), color: .orange, symbol: "exclamationmark.triangle.fill") }
                        Spacer()
                        Button { m.download(env.window) } label: { Label(L("common.download"), systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(parsed.good == 0)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("settings.batch"), note: L("mac.batch.footer"))
                Card(spacing: 16) {
                    dropZone
                    VStack(spacing: 12) {
                        sliderRow(L("mac.batch.concurrency"), L("mac.batch.concurrency.detail"), value: Double(m.concurrency), display: "\(m.concurrency)") {
                            Slider(value: Binding(get: { Double(m.concurrency) }, set: { m.concurrency = Int($0.rounded()) }), in: 1...16, step: 1)
                        }
                        sliderRow(L("settings.batch.interval"), L("mac.batch.interval.detail"), value: Double(m.interval), display: String(format: L("settings.batch.seconds"), Double(m.interval) / 1000)) {
                            Slider(value: Binding(get: { Double(m.interval) }, set: { m.interval = Int($0.rounded()) }), in: 0...10000, step: 250)
                        }
                    }
                    HStack { Spacer(); Button { m.startBatch(env.window) } label: { Label(L("settings.batch.start"), systemImage: "square.and.arrow.down.on.square.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.batch.isEmpty) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("mac.cookie"), note: L("mac.cookie.footer"),
                               trailing: AnyView(Pill(text: (!m.authToken.isEmpty && !m.ct0.isEmpty) ? L("mac.set") : L("mac.notSet"), color: (!m.authToken.isEmpty && !m.ct0.isEmpty) ? .green : .secondary,
                                                      symbol: (!m.authToken.isEmpty && !m.ct0.isEmpty) ? "lock.fill" : "lock.open")))
                Card(spacing: 12) {
                    secretField("auth_token", $m.authToken)
                    secretField("ct0", $m.ct0)
                    HStack(spacing: 8) {
                        Spacer()
                        Button(L("settings.cookie.check")) {
                            // a network request of up to ~30 s: never on the main thread
                            let w = env.window
                            macRun(w, { Core.checkCookies() }) { r in macAlert(w, r.title, r.detail) }
                        }
                        Button(L("settings.cookie.save")) { m.saveCookies(env.window) }.buttonStyle(.borderedProminent)
                    }
                }
            }

            if let status, !status.errors.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(L("mac.failures", status.errors.count))
                    Card(tint: .orange, spacing: 10) {
                        ForEach(Array(status.errors.suffix(8).reversed().enumerated()), id: \.offset) { _, e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.first ?? "").font(.caption.weight(.semibold))
                                Text(e.last ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { live.start(every: 1) }
        .onDisappear { live.stop() }
    }

    // MARK: Pieces

    /// The place to drop (or choose) a bookmarks JSON.
    private var dropZone: some View {
        Button { m.chooseBatch(env.window) } label: {
            HStack(spacing: 14) {
                IconTile(symbol: m.batchName == nil ? "tray.and.arrow.down.fill" : "doc.text.fill", color: m.batchName == nil ? .indigo : .green, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.batchName ?? L("mac.batch.drop")).font(.system(size: 14, weight: .semibold))
                    Text(m.batchName == nil ? L("mac.batch.drop.detail") : L("mac.batch.loaded", m.batch.count)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if m.batchName != nil { Pill(text: L("mac.batch.count", m.batch.count), color: .green, symbol: "checkmark") }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            let window = env.window
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { m.loadBatch(url, window) }
            }
            return true
        }
    }

    private func sliderRow<S: View>(_ title: String, _ note: String, value: Double, display: String, @ViewBuilder slider: () -> S) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)
            slider()
            Text(display).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }

    private func secretField(_ name: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 13, weight: .medium, design: .monospaced)).frame(width: 90, alignment: .leading)
            SecureField(name, text: text, prompt: Text(L("mac.notSet"))).labelsHidden().textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Import and backup

struct TransferPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()

    var body: some View {
        let _ = live.count
        let reports = Array(Core.importReports().prefix(8))
        let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = L("date.monthDayTime"); return f }()
        SettingsCanvas {
            ActivityCard(kinds: [.importing])

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("common.import"), note: L("mac.import.footer"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14, alignment: .top)], spacing: 14) {
                    NavTile(title: L("mac.import.legacy"), detail: L("mac.import.legacy.detail"), symbol: "archivebox.fill", color: .brown) {
                        importFile([.zip]) { try Core.importLegacyZip($0, folder: $1) }
                    }
                    NavTile(title: L("mac.import.loose"), detail: L("mac.import.loose.detail"), symbol: "square.dashed", color: .indigo) {
                        importFile([.zip]) { try Core.importLooseZip($0, folder: $1) }
                    }
                    NavTile(title: L("mac.import.pack"), detail: L("mac.import.pack.detail"), symbol: "shippingbox.fill", color: .blue) {
                        importFile([.tlpack, .zip]) { try Core.importPack($0, folder: $1) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("common.backup"))
                Card(tint: .purple, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        IconTile(symbol: "externaldrive.fill.badge.timemachine", color: .purple, size: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("mac.backup.title")).font(.system(size: 15, weight: .semibold))
                            Text(L("mac.backup.detail"))
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button { backup() } label: { Label(L("mac.backup.button"), systemImage: "arrow.down.doc.fill") }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Text(L("mac.backup.footer"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !reports.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(L("common.importRecords"), note: L("mac.importHistory.footer"),
                                   trailing: AnyView(Button(L("mac.deleteAll")) { let all = Core.importReports(); deleteReports(all.map(\.file), what: L("mac.importHistory.all", all.count)) }.buttonStyle(.borderless).foregroundStyle(.red)))
                    Card(spacing: 12) {
                        ForEach(Array(reports.enumerated()), id: \.element.file) { i, r in
                            if i > 0 { RowDivider() }
                            HStack(spacing: 12) {
                                IconTile(symbol: r.issues == 0 ? "checkmark" : "exclamationmark", color: r.issues == 0 ? .green : .orange, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: r.source).lastPathComponent).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(df.string(from: r.date)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Pill(text: r.issues == 0 ? L("mac.importHistory.ok") : L("mac.importHistory.issues", r.issues), color: r.issues == 0 ? .green : .orange)
                                Button(L("mac.viewEllipsis")) { MacImportReportWindowController.show(reportFile: r.file) }
                                Button(L("common.delete")) { deleteReports([r.file], what: L("mac.importHistory.this")) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    private func importFile(_ types: [UTType], _ work: @escaping (URL, String?) throws -> ImportReport) {
        let window = env.window
        macOpenPanel(types) { url in
            DispatchQueue.main.async {
                macChooseFolder(window, title: L("common.importToFolder"), suggested: url.deletingPathExtension().lastPathComponent) { folder in
                    macRun(window, { try work(url, folder) }) { r in
                        NotificationCenter.default.post(name: .libraryChanged, object: nil)
                        macShowImportResult(window, r)
                        live.poke()
                    }
                }
            }
        }
    }

    /// Deletes import records; a share's leftover problem files go with them (they are the app's
    /// own copies). Files you imported from elsewhere on this Mac are never touched.
    private func deleteReports(_ files: [String], what: String) {
        guard !files.isEmpty else { return }
        let window = env.window
        macChoose(window, title: L("mac.importHistory.deleteTitle", what), message: L("mac.importHistory.deleteMessage"), options: [L("common.delete")]) { _ in
            do {
                let r = try Core.deleteImportReports(files, owned: ShareInbox.ownedRoots)
                live.poke()
                macAlert(window, L("mac.importHistory.deleted", r.reports), r.sources > 0 ? L("mac.importHistory.freed", r.sources, ActivityCenter.bytes(r.bytes)) : nil)
            } catch { macAlert(window, L("mac.deleteFailed"), error.localizedDescription) }
        }
    }

    private func backup() {
        let window = env.window
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        macSavePanel(L("mac.backup.fileName", f.string(from: Date()))) { url in
            macRunProgress(window, title: L("settings.backup.running"), progress: {
                guard let p = Core.exportStatus(), p.total > 0 else { return nil }
                return L("settings.backup.progress", p.done, p.total, ActivityCenter.bytes(p.bytes))
            }, cancel: { Core.cancelExport() }, { try Core.exportBackup(to: url) }) { r in
                var t = L("mac.backup.result", r.posts, r.media, r.trashed ?? 0, ActivityCenter.bytes(r.bytes))
                let skipped = r.skipped ?? []
                if !skipped.isEmpty {
                    t += L("settings.backup.skipped", skipped.count)
                    for s in skipped.prefix(15) { t += L("export.skip.line", s.postId.hasPrefix("loose:") ? L("card.loose") : L("common.post", s.postId), s.mediaId.prefix(10), s.reason) }
                    if skipped.count > 15 { t += L("export.skip.more", skipped.count - 15) }
                }
                macAlert(window, skipped.isEmpty ? L("settings.backup.done") : L("settings.backup.doneIncomplete"), t)
            }
        }
    }
}

// MARK: - Problems and rename rules

struct ProblemsPageView: View {
    @StateObject private var live = LiveTick()
    var body: some View {
        let _ = live.count
        let list = AppLog.recentProblems()
        let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = L("date.monthDayTimeSeconds"); return f }()
        SettingsCanvas {
            if list.isEmpty {
                emptyState(symbol: "checkmark.seal.fill", color: .green, title: L("mac.problems.none"), detail: L("mac.problems.footer"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(L("mac.problems.recent", list.count), note: Diagnostics.contents)
                    Card(padding: 4, spacing: 0) {
                        ForEach(Array(list.prefix(200).enumerated()), id: \.offset) { i, e in
                            if i > 0 { RowDivider() }
                            HStack(alignment: .top, spacing: 12) {
                                Capsule().fill(e.level == .error ? Color.red : Color.orange).frame(width: 4)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Pill(text: e.cat, color: e.level == .error ? .red : .orange)
                                        Text(df.string(from: e.date)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(e.msg).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }
}

/// 应用锁: both ways ask first, whoever turns it off has to be able to pass it.
private struct AppLockRow: View {
    @State private var on = AppLock.enabled
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToggleRow(symbol: "lock.fill", color: .blue, title: L("applock.toggle", AppLock.methodName), detail: L("applock.footer"),
                      isOn: Binding(get: { on }, set: { ask($0) }), disabled: !AppLock.available && !on)
                .accessibilityIdentifier("appLockToggle")
            if let problem { Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func ask(_ wanted: Bool) {
        problem = nil
        AppLock.authenticate { outcome in
            switch outcome {
            case .passed: AppLock.enabled = wanted
            case .unavailable: AppLock.enabled = false
            case .stayed(let reason): problem = reason
            }
            on = AppLock.enabled
        }
    }
}

/// 存储空间: the shared page, in the settings' canvas.
struct StoragePageView: View {
    @EnvironmentObject private var env: PaneEnv
    var body: some View {
        SettingsCanvas { StorageUsageView(showsTitle: false) { env.open(L("common.aiModels"), MacSettingsPages.models()) } }
    }
}

/// A page with nothing to show: a big symbol and a sentence.
func emptyState(symbol: String, color: Color, title: String, detail: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(color.gradient)
        Text(title).font(.system(size: 17, weight: .semibold))
        Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 70)
}

struct QuickDownloadView: View {
    @ObservedObject var model = DownloadModel.shared
    var openSettings: () -> Void
    var download: () -> Void

    var body: some View {
        QuickDownloadCard(links: $model.links, width: 380, openSettings: openSettings, download: download)
    }
}

/// 关于: the app's icon, name and version. Ten clicks on the icon bring out what is only for looking
/// into a problem (checking the media, the problem log, exporting the diagnostics) until ten more
/// put it away.
struct AboutPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @State private var clicks = 0
    @State private var extras = LibraryPrefs.aboutExtras

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return L("about.version", info["CFBundleShortVersionString"] as? String ?? "") + " · " + L("about.build", info["CFBundleVersion"] as? String ?? "")
    }

    var body: some View {
        let _ = live.count
        SettingsCanvas {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        clicks += 1
                        guard clicks == 10 else { return }
                        clicks = 0
                        extras.toggle()
                        LibraryPrefs.aboutExtras = extras
                    }
                    .accessibilityIdentifier("aboutIcon")
                    .padding(.bottom, 12)
                Text(L10n.appName).font(.system(size: 26, weight: .bold))
                Text(L("about.tagline")).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(version).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .accessibilityIdentifier("aboutVersion")
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            if extras {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(L("settings.section.maintenance"), note: L("settings.maintenance.footer"))
                    Card(spacing: 14) {
                        CardRow(symbol: "checkmark.shield.fill", color: .green, mascot: Core.integritySummary().map { $0.last != nil && $0.bad == 0 && $0.unchecked == 0 } == true ? "shield" : nil, title: L("mac.integrity")) {
                            HStack(spacing: 10) {
                                Pill(text: Core.integritySummary()?.text ?? L("settings.checkUnreadable"), color: (ActivityCenter.shared.stats?.bad ?? 0) > 0 ? .red : .secondary)
                                if Core.verifyStatus()?.running == true {
                                    Button(L("settings.stopCheck")) { Core.cancelVerify() }
                                } else {
                                    Button(L("settings.check")) {
                                        do { try Core.startVerify() } catch { macAlert(env.window, L("settings.checkFailed"), error.localizedDescription) }
                                    }
                                }
                            }
                        }
                        RowDivider(inset: 42)
                        CardRow(symbol: "exclamationmark.triangle.fill", color: .orange, title: L("common.problemLog")) {
                            Button(L("common.view")) { env.open(L("common.problemLog"), MacSettingsPages.problems()) }
                        }
                        RowDivider(inset: 42)
                        CardRow(symbol: "stethoscope", color: .teal, title: L("mac.diagnostics")) {
                            Button(L("mac.exportEllipsis")) { macExportDiagnostics(env.window) }
                        }
                    }
                }
            }
        }
        .onAppear { live.start() }
    }
}

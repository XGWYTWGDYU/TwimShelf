import UIKit
import UniformTypeIdentifiers

/// Library management: totals, live progress, download (single + batch, shared route),
/// compatibility import, export, AI, sync, account, wipe.
final class SettingsViewController: FormViewController, UIDocumentPickerDelegate {
    var onLibraryChanged: (() -> Void)?

    private let stats = StatsCardView()
    private let linksView = PlaceholderTextView(placeholder: L("settings.links.placeholder"))
    private let authField = UITextField()
    private let ct0Field = UITextField()
    private var activityCards: [Activity.Kind: ActivityCardView] = [:]
    private var batchURLs: [String] = []
    private var batchFileName: String?
    private var concurrency = Double(UserDefaults.standard.object(forKey: "dl.concurrency") as? Int ?? 3)
    private var intervalMs = Double(UserDefaults.standard.object(forKey: "dl.interval") as? Int ?? 500)
    private var pickerKind: PickerKind = .bookmarks
    /// Folder downloads go into (nil = none). Applies to single links and batches, and to the
    /// feed's quick download card, so it outlives this page.
    private static var downloadFolder: String?
    private var downloadFolder: String? {
        get { Self.downloadFolder }
        set { Self.downloadFolder = newValue }
    }
    /// The download page's own progress card (a view can be on one page only).
    private var downloadCard: ActivityCardView?
    private var observers: [NSObjectProtocol] = []

    private enum PickerKind { case bookmarks, legacyZip, looseZip, pack, backupFolder }

    /// Download route (index into `DownloadRoute.allCases`), shared by links and batches.
    private var routeIndex: Int {
        get { min(max(UserDefaults.standard.integer(forKey: "dl.route"), 0), DownloadRoute.allCases.count - 1) }
        set { UserDefaults.standard.set(newValue, forKey: "dl.route") }
    }
    private var route: DownloadRoute { DownloadRoute.allCases[routeIndex] }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("place.settings")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        linksView.accessibilityIdentifier = "linksView"
        for (f, p) in [(authField, "auth_token"), (ct0Field, "ct0")] {
            f.placeholder = p; f.isSecureTextEntry = true; f.autocapitalizationType = .none; f.autocorrectionType = .no; f.clearButtonMode = .whileEditing
            f.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            f.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        }
        authField.text = Keychain.get("auth_token")
        ct0Field.text = Keychain.get("ct0")
        let nc = NotificationCenter.default
        observers = [ActivityCenter.changed, ModelStore.changed, SyncService.changed, LibraryPrefs.changed].map {
            nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.build() }
        }
        ActivityCenter.shared.refreshStats()
        build()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func card(_ a: Activity) -> ActivityCardView {
        let c = activityCards[a.kind] ?? ActivityCardView()
        activityCards[a.kind] = c
        c.update(a)
        return c
    }

    /// Top level, grouped as in Settings: library totals and live work first, then content,
    /// viewing, intelligence and sync, account, maintenance, and the destructive reset
    /// last. Forms with fields (download, import, Cookie) live one level down.
    /// How many cards a row of 浏览 holds, for each orientation (a large screen only: empty, a
    /// form shows nothing of it).
    private func cardsSection() -> Section {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return Section(id: "cards", rows: []) }
        return Section(id: "cards", header: L("cards.section"), footer: L("cards.footer"), rows: [
                .menu(L("cards.portrait"), value: LibraryPrefs.densityNames[LibraryPrefs.cardDensityPortrait], icon: .init("rectangle.portrait.split.2x1", .systemTeal), id: "m:densityP") {
                    UIMenu(children: LibraryPrefs.densityNames.enumerated().map { i, n in
                        UIAction(title: n, state: i == LibraryPrefs.cardDensityPortrait ? .on : .off) { [weak self] _ in LibraryPrefs.cardDensityPortrait = i; self?.build() } })
                },
                .menu(L("cards.landscape"), value: LibraryPrefs.densityNames[LibraryPrefs.cardDensityLandscape], icon: .init("rectangle.split.3x1", .systemTeal), id: "m:densityL") {
                    UIMenu(children: LibraryPrefs.densityNames.enumerated().map { i, n in
                        UIAction(title: n, state: i == LibraryPrefs.cardDensityLandscape ? .on : .off) { [weak self] _ in LibraryPrefs.cardDensityLandscape = i; self?.build() } })
                },
        ])
    }

    private func mascotSection() -> Section {
        let toggle = Row.toggle(L("mascot.toggle"), Mascot.isOn, icon: Icon("pawprint.fill", .systemOrange, mascot: "settings", alwaysMascot: true), id: "t:mascot") { [weak self] on in
            Mascot.isOn = on
            self?.build()
        }
        let license = Row.button(L("mascot.licenses"), icon: Icon("doc.text", .systemGray), id: "b:mascotLicense") { [weak self] in
            self?.alert(L("mascot.licenses"), Mascot.license)
        }
        return Section(id: "mascot", header: L("mascot.title"), footer: L("mascot.footer"), rows: [toggle, license])
    }

    private func build() {
        stats.update(ActivityCenter.shared.stats)
        let acts = ActivityCenter.shared.activities
        var s: [Section] = [
            Section(id: "stats", header: L("common.library"), footer: L("settings.stats.footer"), rows: [.custom("stats", stats)]),
        ]
        if !acts.isEmpty {
            var rows: [Row] = acts.map { .banner("act-\($0.kind.rawValue)", card($0)) }
            if Core.downloadStatus()?.running == true {
                rows.append(.button(L("settings.cancelDownload"), icon: .init("xmark", .systemRed), destructive: true) { [weak self] in do { try Core.stopDownload(pause: false) } catch { self?.alert(L("common.couldNotCancel"), error.localizedDescription) } })
            }
            s.append(Section(id: "activity", header: L("settings.jobStatus"), rows: rows))
        }
        if let d = Core.downloadStatus(), !d.running, !d.errors.isEmpty {
            s.append(Section(id: "lastdl", rows: [.navigation(L("settings.lastFailed", d.failed), detail: L("common.view"), icon: .init("exclamationmark.triangle.fill", .systemOrange)) { [weak self] in self?.showErrors(d.errors) }]))
        }
        let bad = ActivityCenter.shared.stats?.bad ?? 0
        let downloadIcon = Icon("arrow.down.circle.fill", .systemBlue, mascot: Core.downloadStatus()?.running == true ? "bag" : nil)
        let aiIcon = Icon("sparkles", .systemPurple, mascot: AutoTagger.shared.running ? "camera" : nil)
        s += [
            Section(id: "content", header: L("settings.section.content"), rows: [
                .navigation(L("common.downloadPosts"), detail: Core.downloadStatus()?.running == true ? L("settings.downloading") : L("settings.download.detail"), icon: downloadIcon, id: "n:download") { [weak self] in
                    self?.openSub(L("common.downloadPosts")) { self?.downloadSections() ?? [] } },
                .navigation(L("common.importAndBackup"), detail: L("settings.import.detail"), icon: .init("shippingbox.fill", .systemBrown), id: "n:transfer") { [weak self] in
                    self?.openSub(L("common.importAndBackup")) { self?.transferSections() ?? [] } },
                .navigation(L("common.tags"), detail: L("common.count", ActivityCenter.shared.stats?.tags ?? 0), icon: .init("tag.fill", .systemBlue), id: "n:tags") { [weak self] in
                    self?.navigationController?.pushViewController(TagListViewController(style: .insetGrouped), animated: true) },
            ]),
            Section(id: "view", header: L("settings.section.browse"), footer: L("settings.browse.footer"), rows: [
            ] + (LibraryPrefs.aboutExtras && (bad > 0 || LibraryPrefs.badOnly) ? [
                .toggle(L("settings.badOnly", bad), LibraryPrefs.badOnly, icon: .init("exclamationmark.triangle.fill", .systemRed), id: "t:bad") { on in LibraryPrefs.badOnly = on },
            ] : []) + [
                .toggle(L("settings.headphonesOnly"), AudioPolicy.headphonesOnly, icon: .init("headphones", .systemPink), id: "t:headphones") { on in AudioPolicy.headphonesOnly = on },
            ] + [
                .toggle(L("settings.noGestures"), LibraryPrefs.playerGesturesOff, icon: .init("hand.raised.slash.fill", .systemIndigo), id: "t:playerGestures") { on in LibraryPrefs.playerGesturesOff = on },
                .toggle(L("settings.autoLandscape"), LibraryPrefs.autoLandscape, icon: .init("rectangle.landscape.rotate", .systemOrange), id: "t:landscape") { on in LibraryPrefs.autoLandscape = on },
            ]),
            cardsSection(),
            Section(id: "privacy", header: L("applock.section"), footer: L("applock.footer"), rows: [
                .toggle(L("applock.toggle", AppLock.methodName), AppLock.enabled, enabled: AppLock.available || AppLock.enabled, icon: .init("lock.fill", .systemBlue), id: "t:appLock") { [weak self] on in
                    // both ways ask first: whoever turns it off has to be able to pass it
                    AppLock.authenticate { outcome in
                        switch outcome {
                        case .passed: AppLock.enabled = on
                        case .unavailable: AppLock.enabled = false
                        case .stayed(let reason): if let reason { self?.alert(L("applock.failed"), reason) }
                        }
                        self?.build()
                    }
                },
            ]),
            Section(id: "search", header: L("common.search"), footer: L("settings.search.footer") + (LibraryPrefs.semanticSearchAvailable ? "" : "\n" + LibraryPrefs.semanticSearchNeedsModel), rows: [
                .toggle(L("settings.fuzzy"), LibraryPrefs.fuzzySearch, enabled: LibraryPrefs.semanticSearchAvailable, icon: .init("sparkle.magnifyingglass", .systemPurple), id: "t:fuzzy") { on in LibraryPrefs.fuzzySearch = on },
            ]),
            Section(id: "smart", header: L("settings.section.smart"), rows: [
                .navigation(L("common.aiModels"), detail: ModelStore.shared.activeTaggerId.map { ModelStore.shared.displayName($0) } ?? L("common.notInstalled"), icon: aiIcon) { [weak self] in
                    self?.navigationController?.pushViewController(ModelsViewController(), animated: true) },
                .navigation(L("common.lanSync"), detail: SyncService.shared.summary, icon: .init("arrow.triangle.2.circlepath", .systemTeal)) { [weak self] in
                    self?.navigationController?.pushViewController(SyncViewController(), animated: true) },
            ]),
            mascotSection(),
        ]
        // GitHub builds only
        if UpdateCheck.repo != nil {
            s.append(Section(id: "update", footer: L("update.footer"), rows: [
                .button(L("update.check"), icon: .init("arrow.down.app.fill", .systemBlue), id: "b:update") { [weak self] in
                    UpdateCheck.run(manual: true) { r in UpdatePrompt.show(r, on: self, manual: true) } },
            ]))
        }
        s += [
            // last: what the app takes on this device, the app itself, and clearing everything
            Section(id: "storage", rows: [
                .navigation(L("storage.title"), icon: .init("internaldrive.fill", .systemGray), id: "n:storage") { [weak self] in
                    self?.navigationController?.pushViewController(StorageViewController(), animated: true) },
                .navigation(L("settings.about"), icon: .init("info.circle.fill", .systemGray), id: "n:about") { [weak self] in
                    guard let self else { return }
                    self.navigationController?.pushViewController(AboutViewController(settings: self), animated: true)
                },
            ]),
            Section(id: "wipe", footer: L("settings.wipe.footer"), rows: [
                .button(L("settings.wipe.button"), icon: .init("trash.fill", .systemRed), destructive: true) { [weak self] in self?.confirmWipe() },
            ]),
        ]
        sections = s
        reloadForm()
        subpage?.rebuild()
    }

    // MARK: Subpages (their fields and state stay here, so nothing is lost going back and forth)

    private weak var subpage: SettingsSubpage?

    /// [links]: what the quick download card held, carried over to this page's field.
    func openDownloads(links: String = "") {
        linksView.text = links
        openSub(L("common.downloadPosts")) { [weak self] in self?.downloadSections() ?? [] }
        // The search-bar shortcut opens this page directly; allow closing the whole sheet.
        subpage?.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.navigationController?.dismiss(animated: true)
        })
    }

    private func openSub(_ title: String, _ make: @escaping () -> [Section]) {
        let vc = SettingsSubpage(title: title, make: make)
        subpage = vc
        navigationController?.pushViewController(vc, animated: true)
    }

    /// Pickers, alerts and sheets started from a subpage are shown on top of it.
    override func present(_ vc: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        if viewIfLoaded?.window == nil, let top = navigationController?.topViewController, top !== self {
            top.present(vc, animated: animated, completion: completion)
        } else {
            super.present(vc, animated: animated, completion: completion)
        }
    }

    /// The download page: progress first while a download runs, then the way and the folder (for
    /// the links and the batch alike), the links and the button (kept above the keyboard), batch
    /// import, and the account Cookie that locked-account posts need.
    private func downloadSections() -> [Section] {
        var s: [Section] = []
        if let a = ActivityCenter.shared.activities.first(where: { $0.kind == .download }) {
            let c = downloadCard ?? ActivityCardView()
            downloadCard = c
            c.update(a)
            var rows: [Row] = [.custom("dl-progress", c)]
            if Core.downloadStatus()?.running == true {
                rows.append(.button(L("settings.pause"), icon: .init("pause", .systemOrange), id: "b:dlpause") { [weak self] in do { try Core.stopDownload(pause: true) } catch { self?.alert(L("settings.pauseFailed"), error.localizedDescription) } })
                rows.append(.button(L("settings.cancelDownload"), icon: .init("xmark", .systemRed), destructive: true, id: "b:dlcancel") { [weak self] in do { try Core.stopDownload(pause: false) } catch { self?.alert(L("common.couldNotCancel"), error.localizedDescription) } })
            }
            s.append(Section(id: "dlprogress", header: Core.downloadStatus()?.outcomeText ?? L("settings.downloadStatus"), rows: rows))
        } else if let d = Core.downloadStatus(), d.total > 0 {
            var rows: [Row] = [.value(d.outcomeText, L("settings.doneSkipped", d.done, d.skipped) + (d.failed > 0 ? L("settings.failedSuffix", d.failed) : ""), icon: .init("checkmark.circle", .systemGreen), id: "v:lastdl")]
            if !d.errors.isEmpty { rows.append(.navigation(L("settings.viewFailed"), detail: L("common.items", d.errors.count), icon: .init("exclamationmark.triangle.fill", .systemOrange)) { [weak self] in self?.showErrors(d.errors) }) }
            s.append(Section(id: "dlprogress", header: L("settings.lastDownload"), rows: rows))
        }
        if let d = Core.downloadStatus(), !d.running, d.paused > 0 {
            s.append(Section(id: "dlpaused", header: L("settings.paused", d.paused), footer: L("settings.paused.footer"), rows: [
                .button(L("settings.resume"), icon: .init("play.fill", .systemBlue), id: "b:dlresume") { [weak self] in do { try Core.resumeDownload() } catch { self?.alert(L("settings.resumeFailed"), error.localizedDescription) } },
                .button(L("settings.cancelJobs"), icon: .init("xmark", .systemRed), destructive: true, id: "b:dlcancelpaused") { [weak self] in do { try Core.stopDownload(pause: false) } catch { self?.alert(L("common.couldNotCancel"), error.localizedDescription) } },
            ]))
        }
        // the way and the folder come first and apart: they hold for the links below and for the
        // batch import after them (inside the links' section they looked like theirs alone)
        s.append(Section(id: "dlsettings", header: L("settings.section.method"), footer: L("settings.method.footer"), rows: [
            .menu(L("settings.method"), value: Self.routeNames[routeIndex], icon: .init("point.3.connected.trianglepath.dotted", .systemIndigo), id: "m:route") { [weak self] in self?.routeMenu() ?? UIMenu() },
            .menu(L("settings.intoFolder"), value: downloadFolder ?? L("common.notIntoFolder"), icon: .init("folder.fill", .systemTeal), id: "m:folder") { [weak self] in self?.folderMenu() ?? UIMenu() },
        ]))
        s.append(Section(id: "links", header: L("common.downloadPosts"), footer: L("settings.links.footer"), rows: [
            .custom("links", linksView),
            .button(L("common.download"), icon: .init("arrow.down.circle.fill", .systemBlue), id: "b:download") { [weak self] in self?.downloadLinks() },
        ]))
        s.append(Section(id: "batch", header: L("settings.batch"), footer: L("settings.batch.footer"), rows: [
            .button(batchFileName.map { L("settings.batch.loaded", $0) } ?? L("settings.batch.pick"), icon: .init("doc.badge.plus", .systemIndigo), id: "b:pick") { [weak self] in self?.pick(.bookmarks) },
            .value(L("settings.batch.posts"), batchURLs.isEmpty ? "—" : "\(batchURLs.count)", icon: .init("number", .systemGray)),
            .stepper(L("settings.batch.concurrency"), value: concurrency, range: 1...16, step: 1, icon: .init("arrow.triangle.branch", .systemTeal), format: { "\(Int($0))" }) { [weak self] v in
                self?.concurrency = v; UserDefaults.standard.set(Int(v), forKey: "dl.concurrency") },
            .stepper(L("settings.batch.interval"), value: intervalMs, range: 0...10_000, step: 250, icon: .init("timer", .systemOrange), format: { String(format: L("settings.batch.seconds"), $0 / 1000) }) { [weak self] v in
                self?.intervalMs = v; UserDefaults.standard.set(Int(v), forKey: "dl.interval") },
            .button(L("settings.batch.start"), icon: .init("square.and.arrow.down.on.square", .systemGreen), enabled: !batchURLs.isEmpty) { [weak self] in self?.startBatch() },
        ]))
        return s + cookieSections()
    }

    private func transferSections() -> [Section] {
        [
            Section(id: "legacy", header: L("common.import"), footer: L("settings.import.footer"), rows: [
                .button(L("settings.import.legacy"), icon: .init("archivebox.fill", .systemBrown)) { [weak self] in self?.pick(.legacyZip) },
                .button(L("settings.import.loose"), icon: .init("square.dashed", .systemIndigo)) { [weak self] in self?.pick(.looseZip) },
                .button(L("settings.import.pack"), icon: .init("shippingbox.fill", .systemBlue)) { [weak self] in self?.pick(.pack) },
                .navigation(L("common.importRecords"), detail: nil, icon: .init("list.bullet.rectangle", .systemGray)) { [weak self] in
                    self?.navigationController?.pushViewController(ImportHistoryViewController(), animated: true) },
            ]),
            Section(id: "export", header: L("common.backup"), footer: L("settings.backup.footer"), rows: [
                .button(L("settings.backup.button"), icon: .init("externaldrive.fill.badge.timemachine", .systemPurple), id: "b:backup") { [weak self] in self?.pick(.backupFolder) },
            ]),
        ]
    }

    private func cookieSections() -> [Section] {
        [
            Section(id: "cookie", header: L("settings.cookie.header"), footer: L("settings.cookie.footer"), rows: [
                .custom("auth", authField),
                .custom("ct0", ct0Field),
                .button(L("settings.cookie.save"), icon: .init("key.fill", .systemYellow)) { [weak self] in self?.saveCookies() },
                .button(L("settings.cookie.check"), icon: .init("checkmark.shield", .systemGreen), id: "b:checkCookie") { [weak self] in
                    // a network request of up to ~30 s: never on the main thread
                    self?.runBusy(L("settings.cookie.checking"), { Core.checkCookies() }) { r in
                        let a = UIAlertController(title: r.title, message: r.detail, preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                        self?.present(a, animated: true)
                    }
                },
            ]),
        ]
    }

    func exportDiagnostics() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        let out = dir.appendingPathComponent(L("settings.diagnostics.fileName", f.string(from: Date())))
        runBusy(L("settings.diagnostics.collecting"), { try Diagnostics.export(to: out) }) { [weak self] _ in
            guard let self else { return }
            let share = UIActivityViewController(activityItems: [out], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = self.view
            share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY - 80, width: 1, height: 1)
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
            self.present(share, animated: true)
        }
    }


    private static let routeNames = [L("common.auto"), L("settings.method.fx"), L("settings.method.cookie")]

    private func routeMenu() -> UIMenu {
        UIMenu(children: DownloadRoute.allCases.enumerated().map { i, _ in
            UIAction(title: Self.routeNames[i], state: i == routeIndex ? .on : .off) { [weak self] _ in
                self?.routeIndex = i; self?.build() }
        })
    }

    private func folderMenu() -> UIMenu {
        var acts: [UIMenuElement] = [UIAction(title: L("common.notIntoFolder"), state: downloadFolder == nil ? .on : .off) { [weak self] _ in self?.downloadFolder = nil; self?.build() }]
        let folders = Core.folders()
        if !folders.isEmpty {
            acts.append(UIMenu(options: .displayInline, children: folders.map { f in
                UIAction(title: f.name, image: UIImage(systemName: "folder"), state: downloadFolder == f.name ? .on : .off) { [weak self] _ in self?.downloadFolder = f.name; self?.build() } }))
        }
        acts.append(UIMenu(options: .displayInline, children: [UIAction(title: L("common.newFolderEllipsis"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            let a = UIAlertController(title: L("common.newFolder"), message: nil, preferredStyle: .alert)
            a.addTextField { $0.placeholder = L("common.folderName") }
            a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
            a.addAction(UIAlertAction(title: L("common.create"), style: .default) { _ in
                let n = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { _ = try? Core.createFolder(n); self?.downloadFolder = n; self?.build() }
            })
            self?.present(a, animated: true)
        }]))
        return UIMenu(children: acts)
    }

    // MARK: Actions

    /// Starts the links of [text] (one per line) with the download page's settings. Returns why
    /// it could not, for an alert; nil when it started.
    static func startLinks(_ text: String) -> (title: String, message: String?)? {
        let urls = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !urls.isEmpty else { return (L("settings.links.empty"), nil) }
        let bad = urls.filter { Core.fxAPIURL(for: $0) == nil }
        guard bad.isEmpty else { return (L("settings.links.unrecognized"), bad.prefix(3).joined(separator: "\n")) }
        let defaults = UserDefaults.standard
        let concurrency = defaults.object(forKey: "dl.concurrency") as? Int ?? 3
        let interval = defaults.object(forKey: "dl.interval") as? Int ?? 500
        let route = DownloadRoute.allCases[min(max(defaults.integer(forKey: "dl.route"), 0), DownloadRoute.allCases.count - 1)]
        do {
            // Links you paste are explicit: posts you deleted earlier come back.
            try Core.startDownload(DownloadRequest(urls: urls, concurrency: concurrency, intervalMs: UInt64(interval), route: route, revive: true, folder: downloadFolder))
        } catch { return (L("common.couldNotStartDownload"), error.localizedDescription) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ActivityCenter.shared.refreshNow()   // the progress shows right away
        return nil
    }

    private func downloadLinks() {
        if let failure = Self.startLinks(linksView.text) { return alert(failure.title, failure.message) }
        linksView.text = ""
        view.endEditing(true)
        build()
    }

    private func startBatch() {
        do {
            let n = try Core.startDownload(DownloadRequest(urls: batchURLs, concurrency: Int(concurrency), intervalMs: UInt64(intervalMs), route: route, folder: downloadFolder, markRecent: true))
            batchURLs = []; batchFileName = nil
            ActivityCenter.shared.refreshNow()
            build()
            if n == 0 { alert(L("settings.links.nothing")) } else { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        } catch { alert(L("common.couldNotStartDownload"), error.localizedDescription) }
    }

    private func saveCookies() {
        let ok1 = Keychain.set("auth_token", (authField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let ok2 = Keychain.set("ct0", (ct0Field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        Session.applyStoredCookies()
        view.endEditing(true)
        guard ok1 && ok2 else { return alert(L("settings.cookie.notSaved"), L("settings.cookie.keychainRefused")) }
        alert((authField.text ?? "").isEmpty || (ct0Field.text ?? "").isEmpty ? L("settings.cookie.cleared") : L("settings.cookie.saved"))
    }

    private func showErrors(_ errors: [[String]]) {
        let vc = FormViewController()
        vc.title = L("settings.failures")
        vc.loadViewIfNeeded()
        vc.sections = [.init(id: "e", rows: errors.reversed().enumerated().map { i, e in
            let l = UILabel()
            l.numberOfLines = 0
            l.font = .preferredFont(forTextStyle: .footnote)
            l.text = "\(e.first ?? "")\n\(e.last ?? "")"
            return .custom("e\(i)", l)
        })]
        vc.reloadForm(animated: false)
        navigationController?.pushViewController(vc, animated: true)
    }

    func confirmWipe() {
        let a = UIAlertController(title: L("settings.wipe.title"), message: L("settings.wipe.message"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        for (title, models) in [(L("settings.wipe.keepModels"), false), (L("settings.wipe.withModels"), true)] {
            a.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
                let b = UIAlertController(title: L("common.confirmAgain"), message: L("settings.wipe.typeToConfirm", L("settings.wipe.word")) + (models ? L("settings.wipe.modelsToo") : ""), preferredStyle: .alert)
                b.addTextField()
                b.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
                b.addAction(UIAlertAction(title: L("settings.wipe.confirm"), style: .destructive) { _ in
                    guard b.textFields?.first?.text == L("settings.wipe.word") else { return }
                    self?.performWipe(includeModels: models)
                })
                self?.present(b, animated: true)
            })
        }
        present(a, animated: true)
    }

    private func performWipe(includeModels: Bool) {
        AutoTagger.shared.stop()
        runBusy(L("settings.wipe.erasing"), {
            try Core.wipe(includeModels: includeModels)
            ShareInbox.wipe()
            AppLog.wipe()
            Keychain.wipeAll()
            Core.setCookies(authToken: "", ct0: "")
            let d = UserDefaults.standard
            d.dictionaryRepresentation().keys.filter { includeModels || !Core.aiPreferenceKeys.contains($0) }.forEach { d.removeObject(forKey: $0) }
        }) { [weak self] in
            if includeModels { ModelStore.shared.wipe() } else { ModelStore.shared.reload() }
            SyncService.shared.resetForWipe()
            self?.authField.text = ""; self?.ct0Field.text = ""
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            ActivityCenter.shared.refreshStats()
            self?.build()
            self?.alert(L("settings.wipe.done"), L("settings.wipe.doneMessage"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ModelStore.shared.configure(); SyncService.shared.start() }
        }
    }

    // MARK: Document picking

    private func pick(_ kind: PickerKind) {
        pickerKind = kind
        let types: [UTType] = switch kind {
        case .bookmarks: [.json]
        case .legacyZip, .looseZip: [.zip]
        case .pack: [.tlpack, .zip]
        case .backupFolder: [.folder]
        }
        // a folder is opened in place (the backup is written straight into it); files are copied
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: kind != .backupFolder)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        switch pickerKind {
        case .bookmarks:
            do { batchURLs = try Core.bookmarkURLs(in: url); batchFileName = url.lastPathComponent; build() }
            catch { alert(L("settings.json.unreadable"), error.localizedDescription) }
            // the links are read: the picker's copy is not needed any more
            if Self.isInsideTemporary(url) { try? FileManager.default.removeItem(at: url) }
        case .legacyZip:
            chooseTargetFolder(title: L("common.importToFolder"), suggested: url.deletingPathExtension().lastPathComponent) { [weak self] folder in self?.importZip(url, folder: folder) }
        case .looseZip:
            chooseTargetFolder(title: L("common.importToFolder"), suggested: url.deletingPathExtension().lastPathComponent) { [weak self] folder in
                self?.runBusy(L("common.importing"), { try Core.importLooseZip(url, folder: folder) }) { r in
                    self?.releasePickedCopy(url, r)
                    self?.showImportResult(r)
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                }
            }
        case .pack:
            chooseTargetFolder(title: L("common.importToFolder"), suggested: url.deletingPathExtension().lastPathComponent) { [weak self] folder in self?.importPack(url, folder: folder) }
        case .backupFolder:
            backup(into: url)
        }
    }

    /// Files picked in Files arrive as the app's own copy (it can be gigabytes). When nothing in
    /// it needs attention, nobody will ever export problem files from it: delete it now.
    /// Otherwise it stays until the import record is deleted.
    /// Whether a picked file is the system's copy in our temporary folder (compared by path
    /// components: "/tmp2/x" is not inside "/tmp").
    static func isInsideTemporary(_ url: URL) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let p = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return p.count > tmp.count && Array(p.prefix(tmp.count)) == tmp
    }

    private func releasePickedCopy(_ url: URL, _ r: ImportReport) {
        guard r.skipped.isEmpty, Self.isInsideTemporary(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes the whole-library backup straight into the chosen folder, with live progress.
    private func backup(into folder: URL) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let out = folder.appendingPathComponent(L("settings.backup.fileName", f.string(from: Date()))).appendingPathExtension("tlpack")
        let access = folder.startAccessingSecurityScopedResource()
        runBusy(L("settings.backup.running"), progress: {
            guard let p = Core.exportStatus(), p.total > 0 else { return nil }
            return L("settings.backup.progress", p.done, p.total, ActivityCenter.bytes(p.bytes))
        }, cancel: { Core.cancelExport() }, {
            // released on success and on failure (runBusy shows failures itself)
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            return try Core.exportBackup(to: out)
        }) { [weak self] r in self?.showBackupResult(r, file: out) }
    }

    private func showBackupResult(_ r: ExportReport, file: URL) {
        var t = L("settings.backup.result", r.posts, r.media, r.trashed ?? 0, ActivityCenter.bytes(r.bytes), file.lastPathComponent)
        let skipped = r.skipped ?? []
        if !skipped.isEmpty {
            t += L("settings.backup.skipped", skipped.count)
            for s in skipped.prefix(15) { t += L("export.skip.line", s.postId.hasPrefix("loose:") ? L("card.loose") : L("common.post", s.postId), s.mediaId.prefix(10), s.reason) }
            if skipped.count > 15 { t += L("export.skip.more", skipped.count - 15) }
        }
        alert(skipped.isEmpty ? L("settings.backup.done") : L("settings.backup.doneIncomplete"), t)
    }

    private func importZip(_ url: URL, folder: String?) {
            runBusy(L("common.importing"), { try Core.importLegacyZip(url, folder: folder) }) { [weak self] r in
                self?.releasePickedCopy(url, r)
                self?.showImportResult(r)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
            }
    }

    private func importPack(_ url: URL, folder: String?) {
            runBusy(L("common.importing"), { try Core.importPack(url, folder: folder) }) { [weak self] r in
                self?.releasePickedCopy(url, r)
                self?.showImportResult(r, extra: L("settings.import.restoredExtras"))
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
            }
    }
}

/// One level below the library page: its sections come from the library page, which owns the
/// fields and state, and rebuilds this page whenever it rebuilds itself.
final class SettingsSubpage: FormViewController {
    private let make: () -> [Section]
    init(title: String, make: @escaping () -> [Section]) {
        self.make = make
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        rebuild()
    }

    func rebuild() {
        guard isViewLoaded else { return }
        sections = make()
        reloadForm()
    }
}

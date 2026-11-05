import AppKit

/// A collection shown beside the sidebar (a folder, 图片, 视频, 最近添加, the recycle bin, …), as on iOS
/// (`MediaGridViewController`): the zoomable grid (`MacMediaGridView`) and nothing else — the
/// title, the zoom, 选择 and the selection's actions live in the window's toolbar, which asks
/// this page for them (`subtitle`, `canZoom…`, the actions below) and refreshes on
/// `onStateChanged`.
final class MacMediaGridPage: NSView, MacMediaGridDelegate {
    var onOpenMedia: ((FeedItem, [FeedItem]) -> Void)?
    var onShowInBrowse: ((FeedFilter, String) -> Void)?
    /// Shows the post of a media in 浏览 (not offered in the recycle bin).
    var onRevealPost: ((FeedItem) -> Void)?
    /// The selection, the counts or the zoom changed (the toolbar and the subtitle follow).
    var onStateChanged: (() -> Void)?
    let filter: FeedFilter
    let folder: String?
    let title: String
    /// The recycle bin: the same grid over the binned media, with 还原 and 永久删除 for actions.
    let bin: Bool
    private var trashedAt: [String: Date] = [:]
    private var entries: [[FeedItem]] = []
    private var items: [FeedItem] = []
    let grid = MacMediaGridView()
    private let emptyLabel = NSTextField(labelWithString: L("grid.empty"))
    private let toast = MacToast()
    private let reloadWork = LatestWork()
    private var generation = 0
    private var countsLine = ""
    private var grouped: Bool { UserDefaults.standard.object(forKey: "grouped") as? Bool ?? true }

    init(title: String, filter: FeedFilter, folder: String? = nil, bin: Bool = false) {
        self.title = title
        self.filter = filter
        self.folder = folder
        self.bin = bin
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityIdentifier("mediaGridPage")
        grid.delegate = self
        if bin { emptyLabel.stringValue = L("grid.trashEmpty") }
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        emptyLabel.isHidden = true
        for v in [grid, emptyLabel, toast] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            // the grid runs under the toolbar (it keeps its first row below it)
            grid.topAnchor.constraint(equalTo: topAnchor), grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor), grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: grid.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: grid.centerYAnchor),
            toast.centerXAnchor.constraint(equalTo: centerXAnchor), toast.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
        grid.initialLevel = UserDefaults.standard.object(forKey: "mac.grid.level") as? Int ?? 1
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .libraryChanged, object: nil)
        reload()
        // media past the retention period leave the bin (as the bin's own page used to do on opening)
        if bin {
            DispatchQueue.global(qos: .userInitiated).async { if Core.expireTrash() > 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryChanged, object: nil) } } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        generation += 1
        let gen = generation
        let req = FeedRequest(filter: filter)
        let bin = self.bin
        reloadWork.submit { [weak self] isCurrent in
            guard let self, isCurrent() else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> ([FeedItem], [String: Date]) in
                var dates: [String: Date] = [:]
                let items: [FeedItem]
                if bin {
                    let t = Core.trashList()
                    for i in t { dates[i.mediaId] = i.trashedAt }
                    items = t.map(\.asFeedItem)
                } else {
                    items = (try? Core.feed(req)) ?? []
                }
                return (items, dates)
            }.value
            guard isCurrent(), gen == self.generation else { return }
            self.items = result.0
            self.trashedAt = result.1
            self.rebuild()
        }
    }

    private func rebuild() {
        if grouped {
            var order: [String] = []
            var byPost: [String: [FeedItem]] = [:]
            for it in items {
                if byPost[it.postId] == nil { order.append(it.postId) }
                byPost[it.postId, default: []].append(it)
            }
            entries = order.map { byPost[$0]!.sorted { $0.ordinal < $1.ordinal } }
        } else {
            entries = items.map { [$0] }
        }
        emptyLabel.isHidden = !entries.isEmpty
        let videos = items.filter { $0.kind == .video }.count
        let photos = items.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append(L("grid.photos", photos)) }
        if videos > 0 { parts.append(L("grid.videos", videos)) }
        countsLine = parts.joined(separator: L("list.separator"))
        grid.setTiles(entries.compactMap { e in e.first.map { ZoomGridTile(item: $0, count: e.count) } }, footer: countsLine)
        onStateChanged?()
    }

    /// The window's subtitle: what is in it, or what is selected.
    var subtitle: String {
        guard grid.selecting else { return countsLine }
        let n = selectedMedia.count
        return n == 0 ? L("grid.selectItems") : L("grid.selected", n)
    }

    // MARK: Grid

    func mediaGrid(_ g: MacMediaGridView, didOpen i: Int) {
        guard i < entries.count, let first = entries[i].first else { return }
        // ← → goes through every media of the grid, starting here
        onOpenMedia?(first, grouped ? entries.flatMap { $0 } : items)
    }

    func mediaGrid(_ g: MacMediaGridView, didSettleAt level: Int) {
        UserDefaults.standard.set(level, forKey: "mac.grid.level")
        onStateChanged?()
    }

    func mediaGridSelectionChanged(_ g: MacMediaGridView) { updateSelectionUI() }

    #if DEBUG
    var debugFirstItem: FeedItem? { entries.first?.first }
    #endif

    func mediaGrid(_ g: MacMediaGridView, menuFor i: Int) -> NSMenu? {
        guard i < entries.count else { return nil }
        let entry = entries[i]
        let m = NSMenu()
        if grid.selecting, let id = entry.first?.mediaId {
            let on = grid.selected.contains(id)
            m.addItem(ClosureMenuItem(on ? L("common.deselect") : L("common.select")) { [weak self] in
                guard let self else { return }
                if on { self.grid.selected.remove(id) } else { self.grid.selected.insert(id) }
                self.updateSelectionUI()
            })
            return m
        }
        let ids = entry.map(\.mediaId)
        if bin, let left = daysLeft(entry) {
            m.addItem(NSMenuItem(title: left, action: nil, keyEquivalent: ""))      // no action: shown greyed
            m.addItem(.separator())
        }
        m.addItem(ClosureMenuItem(L("common.select")) { [weak self] in
            self?.setSelecting(true)
            if let id = entry.first?.mediaId { self?.grid.selected = [id] }
            self?.updateSelectionUI()
        })
        if bin {
            let n = ids.count > 1 ? L("grid.countSuffix", ids.count) : ""
            m.addItem(ClosureMenuItem(L("common.restore") + n) { [weak self] in self?.restore(ids) })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("common.deletePermanently") + n + "…") { [weak self] in self?.confirmPurge(ids) })
            return m
        }
        // the post in 浏览, found among the cards (or the media itself, for a loose one)
        if let first = entry.first, onRevealPost != nil {
            m.addItem(ClosureMenuItem(first.isLoose ? L("grid.revealMedia") : L("grid.revealPost")) { [weak self] in self?.onRevealPost?(first) })
        }
        if let folder {
            m.addItem(ClosureMenuItem(L("common.removeFromFolder")) {
                _ = try? Core.removeFromFolder(folder, media: ids)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
            })
        }
        m.addItem(.separator())
        if entry.count == 1 {
            m.addItem(ClosureMenuItem(L("grid.trashMedia")) { [weak self] in
                guard let receipt = try? Core.action(.trash, media: ids), receipt.count > 0 else { return }
                self?.afterTrash(receipt)
            })
        }
        // "the whole post" goes by post id, so media this grid does not show go to the bin too
        if let first = entry.first, !first.isLoose {
            let post = first.postId
            m.addItem(ClosureMenuItem(L("grid.trashPost")) { [weak self] in
                guard let receipt = try? Core.action(.trash, posts: [post]), receipt.count > 0 else { return }
                self?.afterTrash(receipt)
            })
        }
        return m
    }

    private func afterTrash(_ receipt: Core.ActionReceipt) {
        let n = receipt.count
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        toast.show(L("trash.moved", n), action: L("common.undo")) { [weak self] in
            do { self?.toast.show(try Core.undo(receipt)) } catch { self?.toast.show(error.localizedDescription) }
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
    }

    // MARK: Recycle bin

    /// How long the media of an entry stay (the first of them to go counts).
    private func daysLeft(_ entry: [FeedItem]) -> String? {
        let keep = Core.trashKeepDays
        guard let first = entry.compactMap({ trashedAt[$0.mediaId] }).min() else { return nil }
        if keep == 0 { return L("trash.keepForever") }
        let d = Double(keep) - Date().timeIntervalSince(first) / 86_400
        return d < 1 ? L("trash.deletingSoon") : L("trash.daysLeft", Int(d.rounded(.up)))
    }

    private func binChanged() {
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        ActivityCenter.shared.refreshStats()
    }

    private func restore(_ ids: [String]? = nil) {
        guard let snapshot = try? Core.binSnapshot(media: ids), let receipt = try? Core.action(.restore, snapshot: snapshot), receipt.count > 0 else { return }
        let n = receipt.count
        setSelecting(false)
        binChanged()
        toast.show(L("trash.restored", n), action: L("common.undo")) { [weak self] in
            do { self?.toast.show(try Core.undo(receipt)) } catch { self?.toast.show(error.localizedDescription) }
            self?.binChanged()
        }
    }

    func restoreSelected() { restore(selectedMedia.map(\.mediaId)) }
    func purgeSelected() { confirmPurge(selectedMedia.map(\.mediaId)) }

    private func confirmPurge(_ ids: [String]) { confirmBinDeletion(media: ids) }
    private func confirmEmpty() { confirmBinDeletion(media: nil) }
    private func confirmBinDeletion(media: [String]?) {
        do {
            let snapshot = try Core.binSnapshot(media: media)
            guard snapshot.count > 0 else { return }
            macChoose(window, title: media == nil ? L("trash.emptyTitle") : L("trash.purgeTitle"), message: L("trash.purgeMessage", snapshot.description), options: [L("common.deletePermanently")]) { [weak self] _ in
                macRun(self?.window, { try Core.action(.purge, snapshot: snapshot) }) { result in
                    self?.setSelecting(false); self?.binChanged()
                    self?.toast.show(L("trash.purged", result.count) + (result.count < snapshot.count ? L("trash.purged.skipped") : ""))
                }
            }
        } catch { macAlert(window, L("trash.unreadableShort"), error.localizedDescription) }
    }

    /// 自动永久删除 (retention), 全部还原 and 清空回收站 in the toolbar's More menu.
    private func binMenu() -> NSMenu {
        let m = NSMenu()
        let keep = Core.trashKeepDays
        let retention = NSMenu()
        for c in LibraryPrefs.keepChoices {
            let it = ClosureMenuItem(c.days == 0 ? L("trash.neverShort") : c.title) { [weak self] in
                Core.trashKeepDays = c.days
                DispatchQueue.global().async { Core.expireTrash(); DispatchQueue.main.async { self?.binChanged() } }
            }
            it.state = c.days == keep ? .on : .off
            retention.addItem(it)
        }
        let r = NSMenuItem(title: L("trash.autoDeleteMac", LibraryPrefs.keepTitle(keep)), action: nil, keyEquivalent: "")
        r.submenu = retention
        m.addItem(r)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("trash.restoreAll")) { [weak self] in
            guard let self else { return }
            self.restore()
        })
        m.addItem(ClosureMenuItem(L("trash.emptyEllipsis")) { [weak self] in self?.confirmEmpty() })
        return m
    }

    // MARK: Selection

    private var selectedMedia: [FeedItem] {
        entries.filter { grid.selected.contains($0.first?.mediaId ?? "") }.flatMap { $0 }
    }

    var selecting: Bool { grid.selecting }
    var selectedURLs: [URL] { selectedMedia.map(\.fileURL).filter { FileManager.default.fileExists(atPath: $0.path) } }
    var hasSelection: Bool { !selectedMedia.isEmpty }
    var allSelected: Bool { !entries.isEmpty && grid.selected.count == entries.count }
    var canZoomIn: Bool { grid.level < grid.levelCount - 1 }
    var canZoomOut: Bool { grid.level > 0 }
    func zoomIn() { grid.step(-1) }
    func zoomOut() { grid.step(1) }
    func toggleAll() { grid.selectAll(!allSelected) }

    func setSelecting(_ on: Bool) {
        guard grid.selecting != on else { return }
        grid.selecting = on
        onStateChanged?()
    }

    private func updateSelectionUI() { onStateChanged?() }

    func shareSelected(from b: NSView) {
        let urls = selectedMedia.map(\.fileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    /// The folders the selection can go into (the toolbar's 加入文件夹 menu).
    func addToFolderMenu() -> NSMenu {
        let ids = selectedMedia.map(\.mediaId)
        let m = NSMenu()
        for f in Core.folders() where f.name != folder { m.addItem(ClosureMenuItem(f.name) { [weak self] in self?.add(ids, to: f.name) }) }
        if !m.items.isEmpty { m.addItem(.separator()) }
        m.addItem(ClosureMenuItem(L("common.newFolderEllipsis")) { [weak self] in
            macPrompt(self?.window, title: L("common.newFolder"), placeholder: L("common.folderName")) { n in
                let n = n.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { self?.add(ids, to: n) }
            }
        })
        return m
    }

    private func add(_ ids: [String], to name: String) {
        do {
            let n = try Core.addToFolder(name, media: ids)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            setSelecting(false)
            toast.show(n == 0 ? L("folder.allAlready", name) : L("folder.added", n, name))
        } catch { macAlert(window, L("common.couldNotAddToFolder"), error.localizedDescription) }
    }

    func removeSelectedFromFolder() {
        guard let folder else { return }
        let ids = selectedMedia.map(\.mediaId)
        guard let receipt = try? Core.action(.folderRemove, media: ids, folder: folder) else { return }
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        setSelecting(false)
        toast.show(L("folder.removed", receipt.count, folder), action: L("common.undo")) { [weak self] in
            do { self?.toast.show(try Core.undo(receipt)) } catch { self?.toast.show(error.localizedDescription) }
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
    }

    func trashSelected() {
        let ids = selectedMedia.map(\.mediaId)
        guard !ids.isEmpty else { return }
        macChoose(window, title: L("grid.trashConfirm.title"), message: L("grid.trashConfirm", ids.count), options: [L("grid.moveToTrash")]) { [weak self] _ in
            guard let receipt = try? Core.action(.trash, media: ids), receipt.count > 0 else { return }
            self?.setSelecting(false)
            self?.afterTrash(receipt)
        }
    }

    // MARK: Menu

    /// The toolbar's More menu: 浏览 view of this collection and, for a folder, its export
    /// and deletion. (放大 / 缩小 have their own toolbar buttons and View menu items.)
    /// The folder shown here was renamed (the window goes to it under its new name).
    var onFolderRenamed: ((String) -> Void)?

    func moreMenu() -> NSMenu {
        if bin { return binMenu() }
        let m = NSMenu()
        m.addItem(ClosureMenuItem(L("grid.revealMedia")) { [weak self] in
            guard let self else { return }
            self.onShowInBrowse?(self.filter, self.title)
        })
        if let folder {
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("folder.exportZip")) { [weak self] in self?.exportZip(folder) })
            m.addItem(ClosureMenuItem(L("folder.renameEllipsis")) { [weak self] in MacFolderActions.rename(folder, in: self?.window) { self?.onFolderRenamed?($0) } })
            m.addItem(ClosureMenuItem(L("folder.deleteEllipsis")) { [weak self] in MacFolderActions.delete(folder, in: self?.window) })
        }
        return m
    }

    private func exportZip(_ name: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "_") + ".zip"
        p.beginSheetModal(for: window ?? NSWindow()) { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            macRun(self?.window, { try Core.exportMedia(Core.mediaIds(inFolder: name), options: ExportOptions(tags: false, folders: false, mediaOnly: true), to: url) }) { r in
                let more = r.skippedText
                macAlert(self?.window, more.isEmpty ? L("export.done") : L("export.doneIncomplete"), L("export.summaryMedia", r.media, ActivityCenter.bytes(r.bytes)) + (more.isEmpty ? "" : "\n\n" + more))
            }
        }
    }
}

/// A page's title and subtitle on a capsule of glass, for the toolbar of a grid page: the photos
/// scroll under the toolbar, and the glass keeps the text legible over any of them.
final class MacGlassTitle: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    /// As wide as the longer line plus the capsule's padding (at most 320).
    private lazy var width = widthAnchor.constraint(equalToConstant: 60)

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.translatesAutoresizingMaskIntoConstraints = false
        // centred in the pill, whatever the glass does with its content view
        let box = NSView()
        box.addSubview(text)
        NSLayoutConstraint.activate([text.centerYAnchor.constraint(equalTo: box.centerYAnchor), text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
                                     text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14)])
        let glass: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 18
            g.contentView = box
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 18
            box.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(box)
            NSLayoutConstraint.activate([box.topAnchor.constraint(equalTo: v.topAnchor), box.bottomAnchor.constraint(equalTo: v.bottomAnchor),
                                         box.leadingAnchor.constraint(equalTo: v.leadingAnchor), box.trailingAnchor.constraint(equalTo: v.trailingAnchor)])
            glass = v
        }
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        width.priority = .required
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 36),
            width,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Appears or goes at once, without any animation (nothing of the glass lingers on a page that has none).
    func setShown(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            isHidden = !on
            width.constant = on ? width.constant : 0
            CATransaction.commit()
        }
        if on { refreshWidth() }
    }

    private func refreshWidth() {
        let w = max(title.intrinsicContentSize.width, subtitle.isHidden ? 0 : subtitle.intrinsicContentSize.width)
        width.constant = min(320, ceil(w) + 30)
    }

    func set(title t: String, subtitle s: String) {
        title.stringValue = t
        subtitle.stringValue = s
        subtitle.isHidden = s.isEmpty
        if !isHidden { refreshWidth() }
        setAccessibilityLabel(s.isEmpty ? t : L("format.commaJoin", t, s))
        invalidateIntrinsicContentSize()
    }
}

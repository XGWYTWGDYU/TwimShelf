import AppKit

/// What the main window shows, chosen in the sidebar (shared with the iPad's sidebar).
typealias MacPlace = LibraryPlace

/// The window's content: a sidebar and the content beside it, and above both the media viewer
/// when one is open (it takes the whole window).
final class MacRootViewController: NSViewController {
    let split = NSSplitViewController()
    let sidebar = MacSidebarViewController()
    let content: MacContentController

    init(feed: MacFeedViewController) {
        content = MacContentController(feed: feed)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 820))
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 190
        side.maximumThickness = 320
        side.canCollapse = true
        // the content gives way when the window resizes or its page changes, not the sidebar
        side.holdingPriority = .init(rawValue: 260)
        // collapses by itself when the window gets narrow, as Mail does
        side.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let main = NSSplitViewItem(viewController: content)
        main.minimumThickness = 480
        main.canCollapse = false        // only the sidebar folds away
        split.addSplitViewItem(side)
        split.addSplitViewItem(main)
        split.splitView.autosaveName = "MainSplit.v2"
        addChild(split)
        split.view.frame = view.bounds
        split.view.autoresizingMask = [.width, .height]
        view.addSubview(split.view)
        view.addSubview(MascotPetView(frame: view.bounds))
        main.isCollapsed = false
        sidebar.onSelect = { [weak self] p in self?.content.show(p) }
        content.onOpenPlace = { [weak self] p in self?.sidebar.select(p) }
    }

    /// Goes somewhere: the sidebar selects it, the content follows.
    func go(_ p: MacPlace) { sidebar.select(p) }

    /// The sidebar folds away by itself when the window gets narrow and comes back when it is
    /// wide again (as in Mail), unless it was hidden by hand.
    private var autoCollapsed = false
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let side = split.splitViewItems.first, view.window?.inLiveResize == true || !side.isCollapsed || autoCollapsed else { return }
        let w = view.bounds.width
        if w < 900, !side.isCollapsed {
            autoCollapsed = true
            side.animator().isCollapsed = true
        } else if w > 1000, side.isCollapsed, autoCollapsed {
            autoCollapsed = false
            side.animator().isCollapsed = false
        }
    }
}

// MARK: - Sidebar

/// A source list: 资料库 (浏览, 最近添加), 媒体类型, 文件夹 (all of them, then each), 其他. Counts
/// in secondary text; a folder's menu deletes it; ⇧⌘N / the 文件夹 header's menu makes one.
final class MacSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((MacPlace) -> Void)?
    private let outline = NSOutlineView()

    private final class Section { let title: String; var rows: [Row]; init(_ t: String, _ r: [Row]) { title = t; rows = r } }
    private final class Row { let place: MacPlace; let count: Int?; init(_ p: MacPlace, _ c: Int?) { place = p; count = c } }
    private var sections: [Section] = []
    private var current: MacPlace = .browse
    private var lastKey = ""

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let col = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setAccessibilityIdentifier("sidebar")
        scroll.documentView = outline
        view = scroll
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .libraryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ActivityCenter.statsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: LibraryPrefs.changed, object: nil)
    }

    private let reloadWork = LatestWork()
    @objc func reload() {
        reloadWork.submit { [weak self] isCurrent in
            let o = await Task.detached(priority: .userInitiated) { Core.folderOverview() }.value
            guard isCurrent() else { return }
            self?.build(o)
        }
    }

    private func build(_ o: FolderOverview?) {
        let stats = ActivityCenter.shared.stats
        let key = "\(String(describing: o))|\(stats?.bad ?? 0)|\(stats?.trashed ?? 0)|\(LibraryPrefs.aboutExtras)"
        guard key != lastKey else { return }
        lastKey = key
        var other: [Row] = [Row(.loose, nil), Row(.album, nil), Row(.unreviewed, nil), Row(.reviewed, nil)]
        if LibraryPrefs.aboutExtras { other.append(Row(.bad, (stats?.bad ?? 0) > 0 ? stats?.bad : nil)) }
        other.append(Row(.trash, (stats?.trashed ?? 0) > 0 ? stats?.trashed : nil))
        sections = [
            Section(L("sidebar.library"), [Row(.browse, nil)]),
            Section(L("sidebar.mediaTypes"), [Row(.photos, o?.photos), Row(.videos, o?.videos)]),
            Section(L("place.folders"), [Row(.allFolders, nil)] + (o?.folders ?? []).map { Row(.folder($0.name), $0.count) }),
            Section(L("sidebar.other"), other),
            Section(L("sidebar.app"), [Row(.settings, nil)]),
        ]
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
        // a deleted folder that was open: back to the folders
        if case .folder(let n) = current, o?.folders.contains(where: { $0.name == n }) == false { select(.allFolders); return }
        selectRow(current)
    }

    /// Selects a place (and shows it).
    func select(_ p: MacPlace) {
        current = p
        if !selectRow(p) { reload() }
        onSelect?(p)
    }

    @discardableResult
    private func selectRow(_ p: MacPlace) -> Bool {
        for s in sections { for r in s.rows where r.place == p {
            let i = outline.row(forItem: r)
            if i >= 0 { if outline.selectedRow != i { outline.selectRowIndexes([i], byExtendingSelection: false) }; return true }
        } }
        return false
    }

    // MARK: Outline

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        return (item as? Section)?.rows.count ?? 0
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        return (item as! Section).rows[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Section }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Row }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let s = item as? Section {
            let v = o.makeView(withIdentifier: .init("header"), owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = .init("header")
                let t = NSTextField(labelWithString: "")
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2), t.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                return c
            }()
            v.textField?.stringValue = s.title
            return v
        }
        guard let r = item as? Row else { return nil }
        let v = o.makeView(withIdentifier: .init("row"), owner: self) as? SidebarCell ?? SidebarCell()
        v.identifier = .init("row")
        v.set(title: r.place.title, symbol: r.place.symbol, mascot: Mascot.name(for: r.place), count: r.count, tint: r.place == .bad ? .systemRed : nil)
        v.setAccessibilityIdentifier("side-" + r.place.id)
        return v
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard let r = outline.item(atRow: outline.selectedRow) as? Row, r.place != current else { return }
        current = r.place
        onSelect?(r.place)
    }

    /// A row's menu: a folder can be deleted; the 文件夹 rows offer a new one.
    private func menuFor(row i: Int) -> NSMenu {
        let m = NSMenu()
        let item = i >= 0 ? outline.item(atRow: i) : nil
        if let r = item as? Row, case .folder(let n) = r.place {
            m.addItem(ClosureMenuItem(L("folder.renameShort")) { [weak self] in
                MacFolderActions.rename(n, in: self?.view.window) { new in if self?.current == .folder(n) { self?.select(.folder(new)) } }
            })
            m.addItem(ClosureMenuItem(L("folder.deleteNamed", n)) { [weak self] in MacFolderActions.delete(n, in: self?.view.window) })
        }
        if item == nil || (item as? Row)?.place == .allFolders || (item as? Row)?.place.folderName != nil || (item as? Section)?.title == L("place.folders") {
            if !m.items.isEmpty { m.addItem(.separator()) }
            m.addItem(ClosureMenuItem(L("common.newFolderEllipsis")) { [weak self] in MacFolderActions.create(in: self?.view.window) })
        }
        return m
    }
}

extension MacSidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for it in menuFor(row: outline.clickedRow).items { it.menu?.removeItem(it); menu.addItem(it) }
    }
}

/// A sidebar row: symbol, title, and a count on the trailing side.
private final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.alignment = .right
        for v in [icon, title, count] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, symbol: String, mascot: String? = nil, count c: Int?, tint: NSColor?) {
        title.stringValue = t
        if let mascot, Mascot.isOn {
            icon.image = Mascot.icon(mascot, side: 20)
        } else {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        icon.contentTintColor = tint     // nil: the accent colour, as sidebar icons should be
        count.stringValue = c.map { "\($0)" } ?? ""
        count.isHidden = c == nil
        setAccessibilityLabel(c.map { L("format.commaJoin", t, $0) } ?? t)
    }
}

// MARK: - Content

/// The content beside the sidebar: 浏览, or a grid of a collection, all folders, or the
/// recycle bin. 浏览 stays loaded underneath (its position and filters survive).
final class MacContentController: NSViewController {
    let feed: MacFeedViewController
    private(set) var place: MacPlace = .browse
    private(set) var page: MacMediaGridPage?
    private var overview: MacFoldersOverview?
    /// 整理 is kept between visits: coming back shows the same post at once (no rebuild, no flash).
    /// The settings panel, shown here when 设置 is chosen (it lives on in the settings controller).
    var settingsPanel: MacSettingsPanel?
    private var cover: NSView?
    /// The place, the selection or the counts changed: the window updates its title and toolbar.
    var onChange: (() -> Void)?
    var onOpenPlace: ((MacPlace) -> Void)?

    init(feed: MacFeedViewController) {
        self.feed = feed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        addChild(feed)
        feed.view.frame = view.bounds
        feed.view.autoresizingMask = [.width, .height]
        view.addSubview(feed.view)
    }

    func show(_ p: MacPlace) {
        let same = p == place && (page != nil || overview != nil || p == .browse || (p == .settings && cover != nil))
        place = p
        guard !same else { onChange?(); return }
        page?.setSelecting(false)
        cover?.removeFromSuperview()
        cover = nil
        page = nil
        overview = nil
        if let sp = settingsPanel, sp.parent === self { sp.didHide(); sp.removeFromParent() }
        let v: NSView?
        if p.filter != nil || p == .trash {
            // the recycle bin is the same grid, over the binned media
            let g = MacMediaGridPage(title: p.title, filter: p.filter ?? FeedFilter(), folder: p.folderName, bin: p == .trash)
            g.onOpenMedia = { [weak self] it, list in self?.feed.openMedia(it, in: list) }
            g.onShowInBrowse = { [weak self] f, _ in
                self?.feed.showFromFolders(f, title: p.title)
                self?.onOpenPlace?(.browse)
            }
            g.onStateChanged = { [weak self] in self?.onChange?() }
            g.onFolderRenamed = { [weak self] new in self?.onOpenPlace?(.folder(new)) }
            if p != .trash {
                g.onRevealPost = { [weak self] it in
                    self?.onOpenPlace?(.browse)
                    self?.feed.reveal(it)
                }
            }
            page = g
            v = g
        } else if p == .allFolders {
            let o = MacFoldersOverview()
            o.onOpen = { [weak self] name in self?.onOpenPlace?(.folder(name)) }
            overview = o
            v = o
        } else if p == .settings, let sp = settingsPanel {
            sp.embedded = true
            sp.onStackChanged = { [weak self] in self?.onChange?() }
            addChild(sp)
            // The form owns its margins. Keep the scroll view at the detail area's
            // edges so wide windows are usable and the scroller stays at the edge.
            let surface = MacOpaqueView(color: .windowBackgroundColor)
            sp.view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(sp.view)
            NSLayoutConstraint.activate([
                sp.view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                sp.view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                sp.view.topAnchor.constraint(equalTo: surface.safeAreaLayoutGuide.topAnchor),
                sp.view.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            ])
            v = surface
            sp.willShow()
        } else {
            v = nil
        }
        if let v {
            v.frame = view.bounds
            v.autoresizingMask = [.width, .height]
            view.addSubview(v)
            cover = v
        }
        feed.setCovered(v != nil)
        if let g = page { view.window?.makeFirstResponder(g.grid) }
        onChange?()
    }

    /// The title and subtitle of the window for what is shown.
    var titles: (String, String) {
        switch place {
        case .browse: return (L("place.browse"), ActivityCenter.shared.statsLine)
        case .allFolders: return (L("place.folders"), overview?.subtitle ?? "")
        case .settings: return (settingsPanel?.currentTitle ?? L("place.settings"), "")
        default: return (place.title, page?.subtitle ?? "")
        }
    }
}

// MARK: - Folders

/// Creating and deleting folders, from the sidebar, the overview and the menu bar.
enum MacFolderActions {
    static func create(in window: NSWindow?, then: ((String) -> Void)? = nil) {
        macPrompt(window, title: L("common.newFolder"), placeholder: L("common.name")) { name in
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            do { try Core.createFolder(n); NotificationCenter.default.post(name: .libraryChanged, object: nil); then?(n) }
            catch { macAlert(window, L("common.couldNotCreate"), error.localizedDescription) }
        }
    }

    /// Renames a folder; a name that is already taken merges the two (asked first). `then`
    /// gets the new name (the page showing the folder follows it).
    static func rename(_ name: String, in window: NSWindow?, then: ((String) -> Void)? = nil) {
        macPrompt(window, title: L("folder.rename.title"), placeholder: L("common.name"), initial: name) { input in
            let new = input.trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new != name else { return }
            let apply = {
                do { try Core.renameFolder(name, to: new); then?(new); NotificationCenter.default.post(name: .libraryChanged, object: nil) }
                catch { macAlert(window, L("common.couldNotRename"), error.localizedDescription) }
            }
            if Core.folders().contains(where: { $0.name == new }) {
                DispatchQueue.main.async {
                    macChoose(window, title: L("folder.merge.title", new), message: L("folder.merge.message", new, name, name), options: [L("folder.merge")]) { _ in apply() }
                }
            } else { apply() }
        }
    }

    static func delete(_ name: String, in window: NSWindow?) {
        macChoose(window, title: L("folder.delete.title", name), message: L("folder.delete.message"), options: [L("folder.delete.confirm")]) { _ in
            try? Core.deleteFolder(name)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
    }
}

/// All folders as cover tiles, like the albums in Photos: as many columns as the width allows
/// (tiles 170–240 pt), each a square cover with the name and count beneath. The content scrolls
/// under the toolbar.
final class MacFoldersOverview: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onOpen: ((String) -> Void)?
    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private let flow = NSCollectionViewFlowLayout()
    private let emptyLabel = NSTextField(labelWithString: L("folders.empty.mac"))
    private var folders: [FolderOverview.Folder] = []
    private(set) var subtitle = ""
    private static let margin: CGFloat = 20, gap: CGFloat = 16, minTile: CGFloat = 170, caption: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityIdentifier("foldersOverview")
        flow.minimumInteritemSpacing = Self.gap
        flow.minimumLineSpacing = Self.gap + 6
        flow.sectionInset = NSEdgeInsets(top: 12, left: Self.margin, bottom: 24, right: Self.margin)
        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(FolderCoverItem.self, forItemWithIdentifier: FolderCoverItem.id)
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = true     // starts below the toolbar, scrolls under it
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -80)])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .libraryChanged, object: nil)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let o = Core.folderOverview()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.folders = o?.folders ?? []
                self.subtitle = self.folders.isEmpty ? "" : L("folders.count", self.folders.count)
                self.emptyLabel.isHidden = !self.folders.isEmpty
                self.collection.reloadData()
            }
        }
    }

    override func layout() {
        super.layout()
        // tiles as wide as the columns that fit, so rows always fill the width
        let w = max(bounds.width - 2 * Self.margin, Self.minTile)
        let cols = max(1, Int((w + Self.gap) / (Self.minTile + Self.gap)))
        let side = floor((w - Self.gap * CGFloat(cols - 1)) / CGFloat(cols))
        let size = NSSize(width: side, height: side + Self.caption)
        if flow.itemSize != size { flow.itemSize = size; flow.invalidateLayout() }
    }

    func numberOfSections(in c: NSCollectionView) -> Int { 1 }
    func collectionView(_ c: NSCollectionView, numberOfItemsInSection s: Int) -> Int { folders.count }
    func collectionView(_ c: NSCollectionView, itemForRepresentedObjectAt i: IndexPath) -> NSCollectionViewItem {
        let item = c.makeItem(withIdentifier: FolderCoverItem.id, for: i) as! FolderCoverItem
        let f = folders[i.item]
        item.set(f)
        item.onMenu = { [weak self] in
            let m = NSMenu()
            m.addItem(ClosureMenuItem(L("common.open")) { self?.onOpen?(f.name) })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("folder.renameShort")) { MacFolderActions.rename(f.name, in: self?.window) })
            m.addItem(ClosureMenuItem(L("folder.deleteEllipsis")) { MacFolderActions.delete(f.name, in: self?.window) })
            return m
        }
        return item
    }
    func collectionView(_ c: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) {
        guard let i = paths.first?.item, i < folders.count else { return }
        c.deselectAll(nil)
        onOpen?(folders[i].name)
    }
}

/// One folder: its cover (rounded, filled), the name and the count beneath.
private final class FolderCoverItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("folderCover")
    private let cover = NSView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var path: String?
    var onMenu: (() -> NSMenu)?

    override func loadView() {
        let v = CoverItemView()
        v.item = self
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 8
        cover.layer?.cornerCurve = .continuous
        cover.layer?.masksToBounds = true
        cover.layer?.contentsGravity = .resizeAspectFill
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        for s in [cover, name, detail] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: v.topAnchor), cover.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: v.trailingAnchor), cover.heightAnchor.constraint(equalTo: cover.widthAnchor),
            name.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 6), name.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1), detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
        ])
        view = v
    }

    func set(_ f: FolderOverview.Folder) {
        name.stringValue = f.name
        detail.stringValue = L("search.row.mediaCount", f.count) + (f.videos > 0 ? L("folders.videosSuffix", f.videos) : "")
        view.setAccessibilityLabel(f.name)
        view.setAccessibilityIdentifier("folder-\(f.name)")
        cover.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        cover.layer?.contents = nil
        path = f.coverPath
        guard let p = f.coverPath else { return }
        _ = MacMediaLoader.shared.load(path: p, isVideo: f.coverVideo, maxPixel: 480) { [weak self] img in
            guard let self, self.path == p else { return }
            self.cover.layer?.contents = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }
}

private final class CoverItemView: NSView {
    weak var item: FolderCoverItem?
    override var isFlipped: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { item?.onMenu?() }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
}

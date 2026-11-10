import UIKit

/// The app's root. Which layout shows is decided by the window, never by the device model: an
/// iPhone, a foldable iPhone folded or open, an iPad in Split View, Slide Over or a Stage Manager
/// window are all just windows of some size, and the size can change at any moment.
///  * Compact (narrow, or short): the system's tab bar with 浏览, 文件夹 and 设置.
///  * Regular in both directions (a full iPad, a wide window, an open foldable): the Mac's
///    layout — the places of the library in a sidebar, which the user can fold into the floating
///    tab bar at the top and back (iPadOS's sidebar-adaptable tab bar), the content beside it.
/// 浏览 is one object that moves between the two, so its search, filters and scroll
/// position survive every change.
final class AdaptiveRootViewController: UIViewController {
    let feed = FeedViewController()
    private var child: UIViewController?
    private var wide: Bool?
    /// Both layouts are kept once made: switching back shows the same one (its place, its stacks).
    private var tablet: TabletRootController?
    private var bar: TabletRootController?
    private var current: TabletRootController? { wide == true ? tablet : bar }
    private var drops: DropImport?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        drops = DropImport(host: self)
        #if DEBUG
        // the page as it looks for what is dropped, in a test without anything to drag from
        if let dir = ProcessInfo.processInfo.environment["TL_TEST_DROP"] {
            let urls = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.drops?.offer(urls.compactMap { url in
                    let p = NSItemProvider(contentsOf: url)
                    p?.suggestedName = url.lastPathComponent
                    return p
                })
            }
        }
        #endif
        update()
        // swapped once the new traits have reached every controller (a tab bar controller added while
        // they are still on their way would see the old width and fold its sidebar the wrong way)
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (self: Self, _) in
            DispatchQueue.main.async { self.update() }
        }
    }

    /// The sidebar layout needs room both ways: an iPhone turned sideways is wide but short.
    private var wantsWide: Bool { traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular }

    private func update() {
        let w = wantsWide
        guard w != wide else { return }
        wide = w
        // whatever was presented over the old layout belongs to it
        let presented = presentedViewController
        let next: TabletRootController
        if w {
            next = tablet ?? TabletRootController(feed: feed, barOnly: false)
            tablet = next
        } else {
            next = bar ?? TabletRootController(feed: feed, barOnly: true)
            bar = next
        }
        feed.onShowBrowse = { [weak next] in next?.select(.browse) }
        child?.willMove(toParent: nil)
        child?.view.removeFromSuperview()
        child?.removeFromParent()
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        child = next
        if presented != nil { setNeedsStatusBarAppearanceUpdate() }
    }

    override var childForStatusBarHidden: UIViewController? { child }
    override var childForHomeIndicatorAutoHidden: UIViewController? { child }

    #if DEBUG
    /// TL_SIZE_TOUR: the sidebar shown, then the window made narrow and wide again (as Split View
    /// or a foldable would), so both layouts and the switch between them can be pictured.
    /// TL_WINDOW_TOUR: the window at each size in turn, 8 s each (`W×H` to TL_WINDOW_TOUR, a file:
    /// the size in force, to picture from outside). Where the system does not let a window be
    /// sized, the window is simply made that small, with the size class that width would have.
    func debugWindowTour(_ scene: UIWindowScene, sizes: [CGSize], log: String) {
        func step(_ i: Int) {
            guard i < sizes.count else { return }
            let size = sizes[i]
            scene.sizeRestrictions?.minimumSize = size
            scene.sizeRestrictions?.maximumSize = size
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let real = abs(scene.coordinateSpace.bounds.width - size.width) < 2
                if !real, let w = self.view.window {
                    w.frame = CGRect(origin: .zero, size: size)
                    self.traitOverrides.horizontalSizeClass = size.width < 680 ? .compact : .regular
                }
                let line = "\(i) \(Int(size.width))x\(Int(size.height)) real=\(real) wide=\(self.wide == true) view=\(Int(self.view.bounds.width))x\(Int(self.view.bounds.height))\n"
                try? line.write(toFile: log, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { step(i + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { step(0) }
    }

    func debugSizeTour(_ scene: UIWindowScene) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.tablet?.sidebar.isHidden = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.traitOverrides.horizontalSizeClass = .compact }
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { self.traitOverrides.horizontalSizeClass = .regular }
    }
    #endif

    /// Goes to 浏览 (a grid's "在浏览中查看"), in either layout.
    func showBrowse() { current?.select(.browse) }
}

/// Holds 浏览 in a layout; adopting it takes it out of the previous one.
final class FeedHost: UIViewController {
    let feed: FeedViewController
    init(feed: FeedViewController) { self.feed = feed; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        adopt()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        adopt()
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    func adopt() {
        guard feed.parent !== self else { return }
        if feed.parent != nil {
            feed.willMove(toParent: nil)
            feed.view.removeFromSuperview()
            feed.removeFromParent()
        }
        addChild(feed)
        feed.view.frame = view.bounds
        feed.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(feed.view)
        feed.didMove(toParent: self)
    }

    override var prefersStatusBarHidden: Bool { feed.prefersStatusBarHidden }
}

/// The wide layout: every place of the library (`LibraryPlace`, as in the Mac's sidebar) as a
/// tab. iPadOS shows them in a sidebar the user can turn into the floating tab bar at the top
/// (浏览, 整理, 文件夹 and 设置 are there; the media kinds and the special collections stay in the
/// sidebar). The folders are listed one by one and follow the library.
final class TabletRootController: UITabBarController, UITabBarControllerDelegate, UITabBarController.Sidebar.Delegate {
    private let feed: FeedViewController
    private let folderGroup: UITabGroup
    private let otherGroup: UITabGroup
    private var folderNames: [String] = []
    private var observers: [NSObjectProtocol] = []

    /// The tabs show as a bar or a rail, never with a sidebar: a narrow window, or a phone (a
    /// foldable opened up).
    private let railOnly: Bool
    private var lastBrowseTap: Date?

    init(feed: FeedViewController, barOnly: Bool) {
        self.feed = feed
        railOnly = barOnly || UIDevice.current.userInterfaceIdiom == .phone
        folderGroup = Self.group(L("place.folders"), "folder", "group.folders", children: [])
        otherGroup = Self.group(L("sidebar.other"), "ellipsis.circle", "group.other", children: [])
        super.init(nibName: nil, bundle: nil)
        mode = .tabSidebar
        delegate = self
        sidebar.delegate = self
        sidebar.preferredLayout = .tile
        let browse = tab(.browse) { [feed] in UINavigationController(rootViewController: FeedHost(feed: feed)) }
        browse.preferredPlacement = .fixed
        let media = Self.group(L("sidebar.mediaTypes"), "photo.on.rectangle", "group.media", children: [grid(.photos), grid(.videos)])
        media.preferredPlacement = .sidebarOnly
        folderGroup.children = [overviewTab()]
        folderGroup.defaultChildIdentifier = LibraryPlace.allFolders.id
        otherGroup.children = otherPlaces()
        otherGroup.defaultChildIdentifier = LibraryPlace.loose.id
        otherGroup.preferredPlacement = .sidebarOnly
        let settings = tab(.settings) {
            let m = SettingsViewController()
            m.onLibraryChanged = { [weak feed] in feed?.reload(keepPosition: true) }
            return NavContainer(root: m)
        }
        if railOnly {
            // the tabs are a bar or a rail with no sidebar beside it, and every tab there is a
            // button. Three: the media kinds and the other collections are on the folders page.
            let folders = UITab(title: L("place.folders"), image: UIImage(systemName: "folder"), identifier: LibraryPlace.allFolders.id) { [weak self] _ in
                let v = FoldersViewController()
                v.onShowInBrowse = { [weak self] f in self?.showInBrowse(f) }
                v.onRevealPost = { [weak self] it in self?.reveal(it) }
                let c = NavContainer(root: v)
                c.nav.navigationBar.prefersLargeTitles = true
                return c
            }
            tabs = [browse, folders, settings]
        } else {
            // 浏览, 文件夹, 设置 in the bar (the media kinds and the others are sidebar sections,
            // listed in the sidebar in this order too)
            tabs = [browse, media, folderGroup, otherGroup, settings]
        }
        Self.lock(tabs)
        reloadFolders()
        observers.append(NotificationCenter.default.addObserver(forName: Mascot.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMascotIcons() }
        })
        updateMascotIcons()
        observers.append(NotificationCenter.default.addObserver(forName: LibraryPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOtherPlaces() }
        })
        observers += [Notification.Name.libraryChanged, ActivityCenter.statsChanged].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reloadFolders() } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var changingSidebar = false
    private var changingSize = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSearch()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        changingSize = true
        feed.hideSearchDuringTransition(true)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.changingSize = false
            UIView.performWithoutAnimation {
                self.layoutSearch()
                self.view.layoutIfNeeded()
                self.feed.view.layoutIfNeeded()
            }
            self.feed.hideSearchDuringTransition(self.changingSidebar)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        layoutSearch()
        #if DEBUG
        if let state = ProcessInfo.processInfo.environment["TL_SEARCH_LAYOUT_STATE"] {
            let orientation: UIInterfaceOrientationMask = state.hasPrefix("portrait") ? .portrait : .landscapeLeft
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.sidebar.isHidden = !state.hasSuffix("sidebar")
                if state.hasSuffix("focus") { self.feed.debugFocusSearch() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    print("LAYOUT_READY", state, self.view.bounds.size, self.sidebar.isHidden)
                }
            }
        }
        #endif
    }

    private func layoutSearch() {
        guard !changingSidebar, !changingSize, view.window != nil, feed.isViewLoaded, feed.view.window != nil else { return }
        guard selectedTab?.identifier == LibraryPlace.browse.id else {
            feed.additionalSafeAreaInsets.left = 0
            feed.restoreSearchToContent()
            return
        }
        // In a narrow portrait window UIKit can present even a tiled sidebar as an overlay.
        // Keep the browse controls in the uncovered area in that case as well.
        let inheritedLeft = max(0, feed.view.safeAreaInsets.left - feed.additionalSafeAreaInsets.left)
        let coveredLeft = sidebarFrame.map { view.convert($0, to: feed.view).maxX } ?? 0
        let leftInset = max(0, coveredLeft - inheritedLeft)
        if abs(feed.additionalSafeAreaInsets.left - leftInset) > 0.5 {
            feed.additionalSafeAreaInsets.left = leftInset
        }
        // the floating tab bar's row has room at its end (a wide landscape window without the
        // sidebar): the search folds into a magnifier there while nothing is searched
        let width = view.safeAreaLayoutGuide.layoutFrame.width
        if sidebar.isHidden, view.bounds.width > view.bounds.height,
           traitCollection.horizontalSizeClass == .regular, width >= 960, let host = feed.parent as? FeedHost {
            feed.setSearchFoldable(in: host.navigationItem)
        } else {
            feed.restoreSearchToContent()
        }
    }

    private var sidebarFrame: CGRect? {
        guard !sidebar.isHidden else { return nil }
        let page = selectedViewController?.viewIfLoaded
        func panel(in node: UIView) -> CGRect? {
            guard !node.isHidden, node.alpha > 0.01 else { return nil }
            if let page, page === node || page.isDescendant(of: node) { return nil }
            let rect = node.convert(node.bounds, to: view)
            if node is UIVisualEffectView, rect.minX < 1, rect.width >= 200,
               rect.width < view.bounds.width * 0.6, rect.height > view.bounds.height * 0.7 { return rect }
            for child in node.subviews {
                if let frame = panel(in: child) { return frame }
            }
            return nil
        }
        for child in view.subviews {
            if let frame = panel(in: child) { return frame }
        }
        return nil
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          sidebarVisibilityWillChange sidebar: UITabBarController.Sidebar,
                          animator: any UITabBarController.Sidebar.Animating) {
        changingSidebar = true
        feed.hideSearchDuringTransition(true)
        animator.addCompletion { [weak self] in
            guard let self else { return }
            self.changingSidebar = false
            UIView.performWithoutAnimation {
                self.layoutSearch()
                self.view.layoutIfNeeded()
                self.feed.view.layoutIfNeeded()
            }
            self.feed.hideSearchDuringTransition(self.changingSize)
        }
    }

    /// Nothing in the sidebar or the tab bar can be hidden, added or moved: every tab keeps a
    /// fixed place (the tab bar ones fixed, the rest sidebar only), which leaves the sidebar no
    /// 编辑 button. Children would otherwise be optional tabs the user could add to the bar.
    private static func lock(_ tabs: [UITab]) {
        for t in tabs {
            t.allowsHiding = false
            if t.preferredPlacement != .sidebarOnly { t.preferredPlacement = .fixed }
            if let g = t as? UITabGroup {
                g.allowsReordering = false
                for c in g.children { c.allowsHiding = false; c.preferredPlacement = .sidebarOnly }
            }
        }
    }

    /// The places' icons, or the mascot mode's.
    private func updateMascotIcons() {
        func visit(_ t: UITab) {
            let places: [LibraryPlace] = [.browse, .photos, .videos, .allFolders, .settings]
            if let p = places.first(where: { $0.id == t.identifier }) { t.image = icon(p) }
            if let g = t as? UITabGroup { g.children.forEach(visit) }
        }
        tabs.forEach(visit)
        folderGroup.image = Mascot.isOn ? Mascot.icon("folder", side: 28) : UIImage(systemName: "folder")
    }

    private func icon(_ p: LibraryPlace) -> UIImage? {
        if Mascot.isOn, let name = Mascot.name(for: p) { return Mascot.icon(name, side: 28) }
        return UIImage(systemName: p == .allFolders && railOnly ? "folder" : p.symbol)
    }

    /// 浏览 tapped twice in a row reshuffles it.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab.identifier == LibraryPlace.browse.id else { lastBrowseTap = nil; return true }
        let now = Date()
        if selectedTab === tab, let last = lastBrowseTap, now.timeIntervalSince(last) < 0.4 {
            lastBrowseTap = nil
            feed.reshuffle()
        } else {
            lastBrowseTap = now
        }
        return true
    }

    func select(_ p: LibraryPlace) {
        if let t = tab(forIdentifier: p.id) { selectedTab = t }
    }

    /// A group of places (a sidebar section): the chosen place's page is shown in the group's
    /// navigation stack, on top of the group's own page, a list of its places. The sidebar is the
    /// way between places: they have no 返回 to that list (`grid`, `overviewTab`), only what opens
    /// inside one does. (Handing UIKit the stack itself as that page made it push the stack into
    /// itself when the width changed.)
    private static func group(_ title: String, _ symbol: String, _ id: String, children: [UITab]) -> UITabGroup {
        let nav = UINavigationController()
        nav.navigationBar.prefersLargeTitles = true
        let g = UITabGroup(title: title, image: UIImage(systemName: symbol), identifier: id, children: children) { tab in GroupPlacesViewController(group: tab as? UITabGroup) }
        g.managingNavigationController = nav
        g.defaultChildIdentifier = children.first?.identifier
        return g
    }

    private func tab(_ p: LibraryPlace, _ make: @escaping () -> UIViewController) -> UITab {
        UITab(title: p.title, image: icon(p), identifier: p.id) { _ in make() }
    }

    /// A grid of a place: its "在浏览中查看" and "在浏览中查看帖子" go to 浏览.
    private func grid(_ p: LibraryPlace) -> UITab {
        tab(p) { [weak self] in
            let g = MediaGridViewController(title: p.title, filter: p.filter ?? FeedFilter(), folder: p.folderName, bin: p == .trash)
            g.onShowInBrowse = { [weak self] f in self?.showInBrowse(f) }
            if p != .trash { g.onRevealPost = { [weak self] it in self?.reveal(it) } }
            g.isTopLevel = true
            return g
        }
    }

    /// 损坏或丢失 is there while the maintenance rows of 关于 are out.
    private func otherPlaces() -> [UITab] {
        [grid(.loose), grid(.album), grid(.unreviewed), grid(.reviewed)] + (LibraryPrefs.aboutExtras ? [grid(.bad)] : []) + [grid(.trash)]
    }

    private func updateOtherPlaces() {
        guard !railOnly, (otherGroup.children.contains { $0.identifier == LibraryPlace.bad.id }) != LibraryPrefs.aboutExtras else { return }
        otherGroup.children = otherPlaces()
        Self.lock([otherGroup])
    }

    private func overviewTab() -> UITab {
        tab(.allFolders) { [weak self] in
            let v = FoldersViewController()
            // the sidebar lists the media kinds and the other collections itself
            v.foldersOnly = true
            v.navigationItem.hidesBackButton = true
            v.onShowInBrowse = { [weak self] f in self?.showInBrowse(f) }
            v.onRevealPost = { [weak self] it in self?.reveal(it) }
            return v
        }
    }

    private func showInBrowse(_ f: FeedFilter) {
        select(.browse)
        feed.showInBrowse(f)
    }

    private func reveal(_ item: FeedItem) {
        select(.browse)
        feed.reveal(item)
    }

    /// The folders in the sidebar follow the library (new, renamed, deleted ones).
    private func reloadFolders() {
        guard !railOnly else { return }   // the rail has no folder list (the folders page has)
        Task { [weak self] in
            let names = await Task.detached { Core.folders().map(\.name) }.value
            guard let self, names != self.folderNames else { return }
            self.folderNames = names
            let selected = self.selectedTab?.identifier
            self.folderGroup.children = [self.overviewTab()] + names.map { self.grid(.folder($0)) }
            Self.lock([self.folderGroup])
            // a deleted folder that was open: back to all folders
            if let s = selected, s.hasPrefix("folder:"), self.tab(forIdentifier: s) == nil { self.select(.allFolders) }
        }
    }
}

/// The page of a sidebar group: its places, as the sidebar lists them; choosing one selects
/// it as a tab (the sidebar follows, and the place opens in the group's stack).
final class GroupPlacesViewController: UITableViewController {
    private weak var group: UITabGroup?
    init(group: UITabGroup?) {
        self.group = group
        super.init(style: .insetGrouped)
        title = group?.title
    }
    required init?(coder: NSCoder) { fatalError() }

    private var places: [UITab] { group?.children ?? [] }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "place")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()      // the folders change with the library
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { places.count }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = tableView.dequeueReusableCell(withIdentifier: "place", for: ip)
        let t = places[ip.row]
        var cfg = c.defaultContentConfiguration()
        cfg.text = t.title
        cfg.image = t.image
        c.contentConfiguration = cfg
        c.accessoryType = .disclosureIndicator
        c.accessibilityIdentifier = "place-" + t.identifier
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        tabBarController?.selectedTab = places[ip.row]
    }
}

/// A tab's own navigation stack, held as a child: the tab bar controller nests a tab's root in
/// its own navigation stack when its sidebar collapses, and a navigation controller may not be
/// pushed onto another one.
final class NavContainer: UIViewController {
    let nav: UINavigationController
    init(root: UIViewController) {
        nav = UINavigationController(rootViewController: root)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(nav)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(nav.view)
        nav.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // the stack around this one (if any) shows no bar of its own
        navigationController?.setNavigationBarHidden(true, animated: false)
    }
}

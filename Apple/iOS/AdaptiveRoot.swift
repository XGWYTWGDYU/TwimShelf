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
        let previous = current
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
        feed.onOpenDownloads = { [weak next] links in next?.openDownloads(links: links) }
        // The search goes with the layout: into the search tab's page, or back into 浏览.
        if next.searchFeed != nil {
            let keys = feed.takeSearch()
            next.attachSearch(to: feed)
            if !keys.isEmpty { next.showSearch(keys: keys) }
        } else {
            next.attachSearch(to: feed)
            if let page = previous?.searchFeed, previous?.isShowingSearch == true {
                let keys = page.takeSearch()
                if !keys.isEmpty { feed.setSearch(keys: keys); next.select(.browse) }
            }
        }
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
        // a search on the search tab first: it should follow into 浏览 (narrow) and back (wide)
        if ProcessInfo.processInfo.environment["TL_SIZE_TOUR"] == "search" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.tablet?.showSearch(keys: [TokenQuery.termKey("seed")]) }
        }
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
    /// The search tab's page (the wide layout only; elsewhere 浏览 searches in place).
    let searchFeed: FeedViewController?
    private var searchTab: UISearchTab?
    private let folderGroup: UITabGroup
    private let otherGroup: UITabGroup
    private weak var settingsController: SettingsViewController?
    private var folderNames: [String] = []
    private var observers: [NSObjectProtocol] = []

    /// The tabs show as a bar or a rail, never with a sidebar: a narrow window, or a phone (a
    /// foldable opened up).
    private let railOnly: Bool
    private var lastBrowseTap: Date?
    private var tabPulses: [ObjectIdentifier: MascotPulse] = [:]
    private var tabIcons: [ObjectIdentifier: UIImage] = [:]
    private var sidebarOverlays: [ObjectIdentifier: SidebarMascotOverlay] = [:]

    private final class SidebarMascotOverlay {
        weak var iconView: UIImageView?
        weak var mascotView: UIImageView?
        var hideWork: DispatchWorkItem?
        func cancel() {
            hideWork?.cancel()
            hideWork = nil
            mascotView?.layer.removeAllAnimations()
            mascotView?.removeFromSuperview()
            iconView?.layer.removeAllAnimations()
            iconView?.alpha = 1
        }
    }

    init(feed: FeedViewController, barOnly: Bool) {
        self.feed = feed
        railOnly = barOnly || UIDevice.current.userInterfaceIdiom == .phone
        searchFeed = railOnly ? nil : FeedViewController(role: .search)
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
        let settings = tab(.settings) { [weak self] in
            let m = SettingsViewController()
            m.onLibraryChanged = { [weak feed] in feed?.reload(keepPosition: true) }
            self?.settingsController = m
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
            // the search is a tab of its own: at the trailing end of the tab bar, at the top of
            // the sidebar (UISearchTab's own places), its page a second feed
            // (held in a NavContainer, as 设置: the tab bar controller wraps a tab's root in a
            // navigation stack of its own when the sidebar folds, and stacks may not nest)
            let search = UISearchTab { [searchFeed] _ in NavContainer(root: FeedHost(feed: searchFeed!)) }
            if #available(iOS 26.0, *) { search.automaticallyActivatesSearch = false }
            searchTab = search
            tabs = [browse, media, folderGroup, otherGroup, settings, search]
        }
        Self.lock(tabs)
        reloadFolders()
        observers.append(NotificationCenter.default.addObserver(forName: Mascot.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreTabIcons() }
        })
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
    #if DEBUG
    private var stressStarted = false
    private var stressLink: CADisplayLink?
    private var stressPhase = "init"
    private var stressSettled = false
    private var stressAnomalies: [String] = []
    private var stressFrames = 0
    private var stressOpenedPhotos = 0
    private var stressOpenedVideos = 0
    private var stressCheckImmediately = false

    @objc private func stressTick() {
        stressFrames += 1
        guard stressSettled || stressCheckImmediately, !changingSize, !changingSidebar else { return }
        let s = feed.debugChromeSnapshot()
        guard !s.modalOpen else { return }
        // 浏览's two buttons on the tab bar's row, at its right margin, in both orientations
        // (never drifted to the top-left, never hidden by a viewer coming and going)
        let r = s.browseActionsInWindow
        if s.browseActionsHidden || s.browseActionsAlpha < 0.9 {
            stressAnomalies.append("[\(stressPhase) f\(stressFrames)] browseActions hidden=\(s.browseActionsHidden) alpha=\(s.browseActionsAlpha)")
        } else if abs(r.maxX - s.actionsRightInWindow) > 6 || abs(r.minY - (s.safeAreaInWindow.minY + s.actionsTop)) > 6 {
            stressAnomalies.append("[\(stressPhase) f\(stressFrames)] browseActions DRIFT rect=\(NSCoder.string(for: r)) right=\(s.actionsRightInWindow) top=\(s.safeAreaInWindow.minY + s.actionsTop) win=\(NSCoder.string(for: s.windowSize))")
        }
        if s.contentInsetTop < 0 || s.contentInsetTop > 260 {
            stressAnomalies.append("[\(stressPhase) f\(stressFrames)] bad contentInsetTop=\(s.contentInsetTop)")
        }
    }

    private func runStressTest(outputPath: String) {
        let link = CADisplayLink(target: self, selector: #selector(stressTick))
        link.add(to: .main, forMode: .common)
        stressLink = link

        var steps: [(String, Double, () -> Void)] = []
        func rotate(_ mask: UIInterfaceOrientationMask) {
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
        // 1. Portrait baseline + photo open/close (check EVERY frame immediately on dismiss!)
        steps.append(("portrait-init", 0.8, { self.stressSettled = false; self.stressCheckImmediately = false; rotate(.portrait) }))
        steps.append(("portrait-baseline", 0.5, { self.stressSettled = true }))
        steps.append(("portrait-open-photo", 0.8, {
            self.stressSettled = false; self.stressCheckImmediately = false
            if self.feed.debugOpenMedia(video: false) { self.stressOpenedPhotos += 1 }
        }))
        steps.append(("portrait-close-photo", 1.0, {
            self.stressCheckImmediately = true
            self.feed.presentedViewController?.dismiss(animated: true)
        }))
        // 2. Portrait video open/close (check EVERY frame immediately on dismiss!)
        steps.append(("portrait-open-video", 0.8, {
            self.stressSettled = false; self.stressCheckImmediately = false
            if self.feed.debugOpenMedia(video: true) { self.stressOpenedVideos += 1 }
        }))
        steps.append(("portrait-close-video", 1.0, {
            self.stressCheckImmediately = true
            self.feed.presentedViewController?.dismiss(animated: true)
        }))
        // 3. Landscape photo open/close (the reported drift-to-top-left bug — check EVERY frame immediately!)
        steps.append(("landscape-rotate", 1.0, { self.stressSettled = false; self.stressCheckImmediately = false; rotate(.landscapeLeft) }))
        steps.append(("landscape-check", 0.5, { self.stressSettled = true }))
        steps.append(("landscape-open-photo", 0.8, {
            self.stressSettled = false; self.stressCheckImmediately = false
            if self.feed.debugOpenMedia(video: false) { self.stressOpenedPhotos += 1 }
        }))
        steps.append(("landscape-close-photo", 1.0, {
            self.stressCheckImmediately = true
            self.feed.presentedViewController?.dismiss(animated: true)
        }))
        // 4. Landscape video open/close
        steps.append(("landscape-open-video", 0.8, {
            self.stressSettled = false; self.stressCheckImmediately = false
            if self.feed.debugOpenMedia(video: true) { self.stressOpenedVideos += 1 }
        }))
        steps.append(("landscape-close-video", 1.0, {
            self.stressCheckImmediately = true
            self.feed.presentedViewController?.dismiss(animated: true)
        }))
        // 5. Landscape sidebar rapid toggle x4
        for i in 0..<4 {
            steps.append(("landscape-sidebar-\(i)", 0.65, {
                self.stressSettled = false; self.stressCheckImmediately = true
                self.sidebar.isHidden.toggle()
            }))
        }
        // 6. Simultaneous rotate + sidebar toggle
        for i in 0..<3 {
            steps.append(("simul-to-portrait-\(i)", 1.0, {
                self.stressSettled = false; self.stressCheckImmediately = false
                self.sidebar.isHidden.toggle()
                rotate(.portrait)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { self.stressSettled = true }
            }))
            steps.append(("simul-to-landscape-\(i)", 1.0, {
                self.stressSettled = false; self.stressCheckImmediately = false
                self.sidebar.isHidden.toggle()
                rotate(.landscapeLeft)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { self.stressSettled = true }
            }))
        }
        // 7. Rotate WHILE media viewer is open (landscape -> portrait -> close, portrait -> landscape -> close)
        steps.append(("modal-rot-open-1", 0.7, {
            self.stressSettled = false; self.stressCheckImmediately = false
            if self.feed.debugOpenMedia(video: false) { self.stressOpenedPhotos += 1 }
        }))
        steps.append(("modal-rot-to-portrait", 0.8, { rotate(.portrait) }))
        steps.append(("modal-rot-close-1", 1.0, {
            self.feed.presentedViewController?.dismiss(animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.stressSettled = true }
        }))
        steps.append(("modal-rot-open-2", 0.7, {
            self.stressSettled = false; self.stressCheckImmediately = false
            if self.feed.debugOpenMedia(video: false) { self.stressOpenedPhotos += 1 }
        }))
        steps.append(("modal-rot-to-landscape", 0.8, { rotate(.landscapeLeft) }))
        steps.append(("modal-rot-close-2", 1.0, {
            self.feed.presentedViewController?.dismiss(animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.stressSettled = true }
        }))

        func run(_ idx: Int) {
            guard idx < steps.count else {
                self.stressLink?.invalidate()
                self.stressLink = nil
                let s = self.feed.debugChromeSnapshot()
                let summary = "STRESS_DONE frames=\(self.stressFrames) photos=\(self.stressOpenedPhotos) videos=\(self.stressOpenedVideos) cells=\(s.visibleCellCount) anomalies=\(self.stressAnomalies.count)\n" + self.stressAnomalies.prefix(50).joined(separator: "\n") + "\n"
                try? summary.write(toFile: outputPath, atomically: true, encoding: .utf8)
                print(summary)
                return
            }
            let (name, wait, action) = steps[idx]
            self.stressPhase = name
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { run(idx + 1) }
        }
        run(0)
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSearch()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        changingSize = true
        let landscapeAfter = size.width > size.height
        let wasLandscape = view.bounds.width > view.bounds.height
        let switchesChrome = !railOnly && (landscapeAfter != wasLandscape) && !sidebar.isHidden
        if switchesChrome { feed.hideActionsDuringTransition(true) }
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.layoutSearch(targetSize: size)
            self.view.layoutIfNeeded()
            self.feed.view.layoutIfNeeded()
        }) { [weak self] _ in
            guard let self else { return }
            self.changingSize = false
            // If rotation ended in portrait while a landscape sidebar animation was in flight,
            // clear the sidebar transition guard so portrait chrome lays out immediately.
            if self.view.bounds.width <= self.view.bounds.height && self.changingSidebar {
                self.changingSidebar = false
                self.feed.setSidebarTransitioning(false)
            }
            UIView.performWithoutAnimation {
                self.layoutSearch()
                self.view.layoutIfNeeded()
                self.feed.view.layoutIfNeeded()
            }
            if switchesChrome { self.feed.hideActionsDuringTransition(self.changingSize) }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        layoutSearch()
        #if DEBUG
        if let out = ProcessInfo.processInfo.environment["TL_IPAD_STRESS_TEST"], !stressStarted {
            stressStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runStressTest(outputPath: out)
            }
        }
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

    private func layoutSearch(targetSize: CGSize? = nil) {
        guard !changingSidebar, (targetSize != nil || !changingSize), view.window != nil else { return }
        let size = targetSize ?? view.bounds.size
        let isLandscape = size.width > size.height
        if isShowingSearch, let page = searchFeed, page.isViewLoaded, page.view.window != nil {
            let inset = isLandscape ? coveredLeftInset(of: page) : 0
            if abs(page.additionalSafeAreaInsets.left - inset) > 0.5 { page.additionalSafeAreaInsets.left = inset }
        }
        guard feed.isViewLoaded, feed.view.window != nil else { return }
        guard selectedTab?.identifier == LibraryPlace.browse.id else {
            feed.hostActions(in: nil)
            feed.additionalSafeAreaInsets.left = 0
            return
        }
        if railOnly {
            // a bar or a rail: 浏览 keeps its title, buttons and magnifier in its own row
            feed.hostActions(in: nil)
            if abs(feed.additionalSafeAreaInsets.left) > 0.5 { feed.additionalSafeAreaInsets.left = 0 }
            return
        }
        // the two buttons on the tab bar's row, as big as the bar, in both orientations
        if let m = tabBarMetrics() { feed.setActionMetrics(m) }
        feed.hostActions(in: view)
        // (in portrait the sidebar is a passing overlay: nothing moves for it)
        let leftInset = isLandscape ? coveredLeftInset(of: feed) : 0
        if abs(feed.additionalSafeAreaInsets.left - leftInset) > 0.5 { feed.additionalSafeAreaInsets.left = leftInset }
    }

    /// The system's floating tab bar as it is on screen (iPadOS 18+; private views, read only):
    /// its glass platter and one of its items. Nil while it is hidden (the sidebar shown): the
    /// last measure stays in force.
    private func tabBarMetrics() -> FeedViewController.ActionMetrics? {
        func find(_ v: UIView, _ name: String) -> UIView? {
            if NSStringFromClass(type(of: v)) == name { return v }
            for c in v.subviews { if let f = find(c, name) { return f } }
            return nil
        }
        guard let bar = find(view, "_UIFloatingTabBar"), !bar.isHidden, bar.alpha > 0.01, bar.window != nil,
              let platter = (bar.subviews.first { $0 is UIVisualEffectView && !$0.isHidden && $0.bounds.height > 0 }),
              // the search tab's item (pinned at the end): each button is that size
              let item = find(platter, "_UIFloatingTabBarPinnedItemsView").flatMap({ find($0, "_UIFloatingTabBarItemView") }) ?? find(platter, "_UIFloatingTabBarItemView")
        else { return nil }
        let frame = platter.convert(platter.bounds, to: view)
        guard frame.height > 0, frame.minY >= 0 else { return nil }
        return .init(top: frame.minY - view.safeAreaInsets.top, height: frame.height, item: item.bounds.size)
    }

    /// How much of a page the sidebar covers beyond its own safe area (iPadOS 26 lays the
    /// pages out under the floating sidebar).
    private func coveredLeftInset(of page: UIViewController) -> CGFloat {
        let inheritedLeft = max(0, page.view.safeAreaInsets.left - page.additionalSafeAreaInsets.left)
        let coveredLeft = sidebarFrame.map { view.convert($0, to: page.view).maxX } ?? 0
        return max(0, coveredLeft - inheritedLeft)
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
        if sidebar.isHidden {
            sidebarOverlays.values.forEach { $0.cancel() }
            sidebarOverlays.removeAll()
        }
        // In portrait on iPad the sidebar is a temporary overlay; buttons and card layout stay unchanged.
        guard !railOnly, view.bounds.width > view.bounds.height else { return }
        changingSidebar = true
        feed.setSidebarTransitioning(true)
        if sidebar.isHidden {
            // Prepare the full-width layout and shift contentOffset + visible cells in lockstep
            // BEFORE the animation starts so scrolled-down feeds never drift vertically or dequeue
            // intermediate cards across thousands of points during the sidebar collapse.
            feed.prepareSidebarTransition(leftInset: 0)
            if let page = searchFeed, page.isViewLoaded {
                page.prepareSidebarTransition(leftInset: 0)
            }
            animator.addAnimations { [weak self] in
                guard let self else { return }
                self.feed.animateSidebarTransition()
                if let page = self.searchFeed, page.isViewLoaded {
                    page.animateSidebarTransition()
                }
            }
        }
        animator.addCompletion { [weak self] in
            guard let self else { return }
            self.changingSidebar = false
            UIView.performWithoutAnimation {
                self.layoutSearch()
                self.view.layoutIfNeeded()
                self.feed.setSidebarTransitioning(false)
                self.feed.relayoutPreservingAnchor()
                if let page = self.searchFeed, page.isViewLoaded, page.view.window != nil {
                    page.relayoutPreservingAnchor()
                }
            }
        }
    }

    /// Nothing in the sidebar or the tab bar can be hidden, added or moved: every tab keeps a
    /// fixed place (the tab bar ones fixed, the rest sidebar only), which leaves the sidebar no
    /// 编辑 button. Children would otherwise be optional tabs the user could add to the bar.
    private static func lock(_ tabs: [UITab]) {
        for t in tabs {
            t.allowsHiding = false
            if t is UISearchTab { continue }    // pinned at the end, where the system puts it
            if t.preferredPlacement != .sidebarOnly { t.preferredPlacement = .fixed }
            if let g = t as? UITabGroup {
                g.allowsReordering = false
                for c in g.children { c.allowsHiding = false; c.preferredPlacement = .sidebarOnly }
            }
        }
    }

    private func restoreTabIcons() {
        func visit(_ t: UITab) {
            if let icon = tabIcons[ObjectIdentifier(t)] { t.image = icon }
            if let g = t as? UITabGroup { g.children.forEach(visit) }
        }
        tabs.forEach(visit)
        tabPulses.values.forEach { $0.cancel() }
        tabPulses.removeAll()
        tabIcons.removeAll()
        sidebarOverlays.values.forEach { $0.cancel() }
        sidebarOverlays.removeAll()
    }

    private func icon(_ p: LibraryPlace) -> UIImage? {
        return UIImage(systemName: p == .allFolders && railOnly ? "folder" : p.symbol)
    }

    /// Finds the icon `UIImageView` of `tab`'s visible cell in the iPad sidebar so we can animate
    /// Clawd directly on screen without mutating `tab.image` (which causes `UITabBarController.Sidebar`
    /// to drop bitmap frames and mis-size rasterized SF Symbols).
    private func sidebarIconView(for tab: UITab) -> UIImageView? {
        guard !railOnly, !sidebar.isHidden else { return nil }
        let page = selectedViewController?.viewIfLoaded
        func collectCollectionViews(in node: UIView, into out: inout [UICollectionView]) {
            guard !node.isHidden, node.alpha > 0.01 else { return }
            if let page, page === node || page.isDescendant(of: node) { return }
            if let cv = node as? UICollectionView {
                out.append(cv)
                return
            }
            for child in node.subviews { collectCollectionViews(in: child, into: &out) }
        }
        func labels(in v: UIView) -> [UILabel] {
            var out: [UILabel] = []
            if let l = v as? UILabel { out.append(l) }
            for s in v.subviews { out += labels(in: s) }
            return out
        }
        func imageViews(in v: UIView) -> [UIImageView] {
            var out: [UIImageView] = []
            if let iv = v as? UIImageView, !iv.isHidden, iv.image != nil { out.append(iv) }
            for s in v.subviews { out += imageViews(in: s) }
            return out
        }
        var lists: [UICollectionView] = []
        for child in view.subviews { collectCollectionViews(in: child, into: &lists) }
        var candidates: [UICollectionViewCell] = []
        for cv in lists {
            for cell in cv.visibleCells where !cell.isHidden && cell.alpha > 0.01 {
                if labels(in: cell.contentView).contains(where: { $0.text == tab.title }) {
                    candidates.append(cell)
                }
            }
        }
        guard !candidates.isEmpty else { return nil }
        let cell = (tab === selectedTab ? candidates.first(where: \.isSelected) : nil) ?? candidates.first!
        let ivs = imageViews(in: cell.contentView).filter { $0.bounds.width >= 10 && $0.bounds.height >= 10 }
        // Pick the leading icon image view (smallest minX in cell coordinates), not a trailing chevron.
        return ivs.min { a, b in
            a.convert(a.bounds, to: cell).minX < b.convert(b.bounds, to: cell).minX
        }
    }

    private func pulse(_ tab: UITab) {
        guard Mascot.isOn else { return }
        let places: [LibraryPlace] = [.browse, .photos, .videos, .allFolders, .settings]
        let name = tab.identifier.hasPrefix("folder:") || tab === folderGroup
            ? "folder" : places.first { $0.id == tab.identifier }.flatMap { Mascot.name(for: $0) }
        guard let name else { return }
        let key = ObjectIdentifier(tab)
        // Cancel any previous overlay before searching so we always find the cell's own icon view.
        sidebarOverlays.removeValue(forKey: key)?.cancel()

        // iPad sidebar: animate a real UIImageView overlay right over the cell's icon.
        if let iconView = sidebarIconView(for: tab), let host = iconView.superview {
            tabPulses[key]?.cancel()
            tabPulses[key] = nil
            if let normal = tabIcons.removeValue(forKey: key) { tab.image = normal }

            let side = max(24, max(iconView.bounds.width, iconView.bounds.height))
            let mascotView = UIImageView(image: Mascot.icon(name, side: side))
            mascotView.contentMode = .scaleAspectFit
            mascotView.isUserInteractionEnabled = false
            let center = iconView.center
            mascotView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            mascotView.center = center
            mascotView.alpha = 0
            mascotView.transform = CGAffineTransform(scaleX: 0.35, y: 0.35)
            host.addSubview(mascotView)

            let overlay = SidebarMascotOverlay()
            overlay.iconView = iconView
            overlay.mascotView = mascotView
            sidebarOverlays[key] = overlay

            UIView.animate(withDuration: 0.08, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                iconView.alpha = 0
            }
            UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0.8,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                mascotView.alpha = 1
                mascotView.transform = .identity
            }

            let hide = DispatchWorkItem { [weak self, weak overlay] in
                guard let overlay, let mascotView = overlay.mascotView else {
                    overlay?.iconView?.alpha = 1
                    self?.sidebarOverlays[key] = nil
                    return
                }
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn, .allowUserInteraction, .beginFromCurrentState]) {
                    mascotView.alpha = 0
                    mascotView.transform = CGAffineTransform(scaleX: 0.35, y: 0.35)
                } completion: { _ in
                    mascotView.removeFromSuperview()
                }
                UIView.animate(withDuration: 0.18, delay: 0.06, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                    overlay.iconView?.alpha = 1
                } completion: { _ in
                    if self?.sidebarOverlays[key] === overlay { self?.sidebarOverlays[key] = nil }
                }
            }
            overlay.hideWork = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + Mascot.pulseDuration, execute: hide)
            return
        }

        // Tab bar / floating bar fallback: frame-based pulse on tab.image.
        guard let normal = tabIcons[key] ?? tab.image else { return }
        tabPulses[key]?.cancel()
        tabIcons[key] = normal
        tabPulses[key] = MascotPulse(name, side: 28, normal: normal, show: { [weak tab] in tab?.image = $0 }, finished: { [weak self] in
            self?.tabIcons[key] = nil
            self?.tabPulses[key] = nil
        })
    }

    /// 浏览 tapped twice in a row reshuffles it.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.pulse(tab)
        }
        if selectedTab !== tab { UISelectionFeedbackGenerator().selectionChanged() }
        guard tab.identifier == LibraryPlace.browse.id else { lastBrowseTap = nil; return true }
        let now = Date()
        if selectedTab === tab, let last = lastBrowseTap, now.timeIntervalSince(last) < 0.4 {
            lastBrowseTap = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            feed.reshuffle()
        } else {
            lastBrowseTap = now
        }
        return true
    }

    func select(_ p: LibraryPlace) {
        if let t = tab(forIdentifier: p.id) { selectedTab = t }
    }

    func openDownloads(links: String) {
        select(.settings)
        DispatchQueue.main.async { [weak self] in
            guard let s = self?.settingsController else { return }
            s.loadViewIfNeeded()
            s.openDownloads(links: links)
        }
    }

    var isShowingSearch: Bool { searchTab != nil && selectedTab === searchTab }

    /// 浏览 in this layout: with a search tab it has no search of its own and sends its
    /// searches (a tag tapped, "在浏览中查看") to that tab.
    func attachSearch(to feed: FeedViewController) {
        guard let page = searchFeed else {
            feed.searchElsewhere = false
            feed.searchHandoff = nil
            return
        }
        feed.searchElsewhere = true
        feed.searchHandoff = { [weak self, weak page] run in
            guard let self, let page else { return }
            self.showSearchTab()
            page.loadViewIfNeeded()
            run(page)
        }
    }

    /// The search tab with these capsules.
    func showSearch(keys: [String]) {
        guard let page = searchFeed else { return }
        showSearchTab()
        page.setSearch(keys: keys)
    }

    private func showSearchTab() {
        guard let searchTab, selectedTab !== searchTab else { return }
        selectedTab = searchTab
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelectTab tab: UITab, previousTab: UITab?) {
        if tab === searchTab { searchFeed?.activateSearch() }
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
        [grid(.loose), grid(.album), grid(.favorites), grid(.unreviewed), grid(.reviewed)] + (LibraryPrefs.aboutExtras ? [grid(.bad)] : []) + [grid(.trash)]
    }

    private func updateOtherPlaces() {
        guard !railOnly, (otherGroup.children.contains { $0.identifier == LibraryPlace.bad.id }) != LibraryPrefs.aboutExtras else { return }
        let existing = Dictionary(uniqueKeysWithValues: otherGroup.children.map { ($0.identifier, $0) })
        let wanted: [LibraryPlace] = [.loose, .album, .favorites, .unreviewed, .reviewed] + (LibraryPrefs.aboutExtras ? [.bad] : []) + [.trash]
        otherGroup.children = wanted.map { existing[$0.id] ?? grid($0) }
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
            let existing = Dictionary(uniqueKeysWithValues: self.folderGroup.children.map { ($0.identifier, $0) })
            self.folderGroup.children = [existing[LibraryPlace.allFolders.id] ?? self.overviewTab()]
                + names.map { name in existing[LibraryPlace.folder(name).id] ?? self.grid(.folder(name)) }
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

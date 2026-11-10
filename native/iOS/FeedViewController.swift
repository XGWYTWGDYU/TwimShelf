import UIKit
import SwiftUI
import AVFoundation

/// Main screen: random feed, shown once to its end, with tag search chips on top and view toggles at the bottom.
final class FeedViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDataSourcePrefetching, UICollectionViewDelegate, UITextFieldDelegate, FeedCellDelegate, UIPopoverPresentationControllerDelegate {
    /// Settings asks the feed to show one folder (object: the name, or nil for everything).
    static let showFolderNote = Notification.Name("ShowFolder")
    /// object = a tag label: show only media with that tag.
    static let showLabelNote = Notification.Name("ShowLabel")
    // State
    private var allItems: [FeedItem] = []
    private var entries: [[FeedItem]] = []
    /// The search of the field's capsules (words, conditions, minus-words).
    private var query = TokenQuery() { didSet { collectionView?.visibleCells.forEach { ($0 as? FeedCell)?.highlight = query.marks } } }
    private var terms: [String] { query.terms }
    /// Settings → 搜索 → 语义模糊搜索.
    private var fuzzy: Bool { LibraryPrefs.fuzzySearch }
    private var grouped = UserDefaults.standard.object(forKey: "grouped") as? Bool ?? true
    /// Random order from the system RNG; ranks survive reloads until the next reshuffle.
    private var order = FeedOrder()
    /// "Only this author" / "only this tag" filters set from the long-press menus.
    private var filter = FeedFilter()
    private var pendingInline: DispatchWorkItem?

    // Views
    private var collectionView: UICollectionView!
    private let searchChrome = UIView()
    /// iPad, landscape, with the floating tab bar: while nothing is searched, the search bar is
    /// folded into a magnifier (and a ⋯ menu for its buttons) at the end of the tab bar's row, so
    /// the cards start right under the tab bar; the bar comes back while searching. Here: the
    /// navigation item of 浏览's page while that row has room (nil elsewhere), and whether it is
    /// folded now.
    private weak var foldItem: UINavigationItem?
    private var searchFolded = false
    /// The bar is fading out on its way back to the magnifier.
    private var folding = false
    /// The magnifier was tapped: the bar stays open until this search ends.
    private var unfolded = false
    private var chipsTop: NSLayoutConstraint!
    private let header = FollowedView()
    /// The filter chips (仅 #标签, 文件夹…) float on their own under the search bar, not inside it.
    private let chipBar = UIView()
    private let searchField = UISearchTextField()
    private let downloadButton = RoundSearchButton(symbol: "arrow.down", label: L("common.downloadPosts"), identifier: "quickDownload")
    /// 按添加时间排序: with the quick download button, at the same times.
    private let sortButton = RoundSearchButton(symbol: "clock", label: L("feed.sortByAdded"), identifier: "sortByAdded")
    /// The round × beside the search bar (not inside it): ends the search.
    private let exitButton = UIButton(type: .system)
    /// Exports what the search shows; beside the ×, shown while a search or filter is in effect.
    private let exportButton = UIButton(type: .system)
    private var exitShown = false, exportShown = false
    private var headerBesideExport: NSLayoutConstraint!
    private var exportBesideExit: NSLayoutConstraint!
    private var exportAtEdge: NSLayoutConstraint!
    private var headerTrailing: NSLayoutConstraint!
    private var headerBesideExit: NSLayoutConstraint!
    private let searchRow = UIStackView()
    /// The list under the field while searching (suggestions, or filters and scopes).
    private let suggestions = SearchSuggestionsView()
    private var searching = false
    /// Tags for the suggestions, read once per search.
    private var tagCache: [TagCount] = []
    private var folderCache: [(name: String, count: Int)] = []
    private let chipScroll = UIScrollView()
    private let chipStack = UIStackView()
    /// The L("place.folders") tab: its own navigation stack (folder → media), under the home's bar.
    private let emptyLabel = UILabel()
    private let activityPanel = ActivityPanel()
    private let toast = ToastView()

    // Inline autoplay: one shared muted player for the most visible video.
    private let inlinePlayer = AVPlayer()
    private weak var inlineHost: MediaPageView?
    private var loopObserver: NSObjectProtocol?
    /// The inline video's layer shows only once its first frame is ready (the still frame under
    /// it shows until then; an empty video layer is black).
    private var readyObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(forName: QuickDownloadRequest.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.view.window != nil { self?.answerQuickDownloadRequest() } }
        }
        view.backgroundColor = .feedBackground
        inlinePlayer.isMuted = true
        inlinePlayer.automaticallyWaitsToMinimizeStalling = false
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? AVPlayerItem) === self.inlinePlayer.currentItem else { return }
            self.inlinePlayer.seek(to: .zero); self.inlinePlayer.play()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged(_:)), name: .libraryChanged, object: nil)
        // in the background the video layer is dropped; back in front, playback is picked up again
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detachInline() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateInlinePlayback() }
        }
        NotificationCenter.default.addObserver(forName: Self.showLabelNote, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let l = n.object as? String else { return }
                self.onShowBrowse?()
                self.clearTerms()
                self.filter.labels = [l]
                self.renderChips(); self.reload()
            }
        }
        NotificationCenter.default.addObserver(forName: Self.showFolderNote, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.onShowBrowse?(); self?.showFolder(n.object as? String) }
        }
        NotificationCenter.default.addObserver(forName: SyncService.warning, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let text = n.userInfo?["text"] as? String else { return }
                if n.userInfo?["settings"] as? Bool == true {
                    self.toast.show(text, action: L("feed.goToSettings")) { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                } else { self.toast.show(text) }
            }
        }
        NotificationCenter.default.addObserver(forName: LibraryPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderChips(); self?.reload(); if self?.searching == true { self?.rebuildSuggestions() } }
        }
        buildCollection()
        // a new text size: every card's text is measured again
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.masonry.invalidateHeights() }
        buildHeader()
        activityPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityPanel)
        NSLayoutConstraint.activate([
            activityPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            activityPanel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            activityPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            { let c = activityPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14); c.priority = .defaultHigh; return c }(),
            activityPanel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
        ])
        NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.searching == true { self?.updateSuggestionFooter() } }
        }
        if CrashWatch.shared.lastRunAbnormal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.toast.show(L("feed.lastRunAbnormal"), action: L("feed.exportDiagnostics")) { [weak self] in
                    // a sheet of its own: 设置 may be in any state on its tab
                    guard let self else { return }
                    let m = SettingsViewController()
                    let nav = UINavigationController(rootViewController: m)
                    nav.modalPresentationStyle = .formSheet
                    m.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
                    self.present(nav, animated: true) { m.exportDiagnostics() }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: ShareInbox.failed, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let t = n.object as? String { self?.toast.show(t) } }
        }
        NotificationCenter.default.addObserver(forName: ShareInbox.imported, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let reports = n.object as? [ImportReport] else { return }
                self.toast.show(ShareInbox.summary(reports), action: L("common.importRecords")) { [weak self] in
                    guard let self else { return }
                    // in the sidebar layout 浏览 has no navigation stack of its own
                    if let nav = self.navigationController { nav.pushViewController(ImportHistoryViewController(), animated: true) }
                    else { self.present(UINavigationController(rootViewController: ImportHistoryViewController()), animated: true) } }
            }
        }
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            toast.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32),
        ])
        reload()
    }

    /// The safe area that also keeps clear of a window's corners (iPadOS 26+): the window
    /// controls at the top-leading corner and the rounded, resizable bottom corners of a windowed
    /// scene. The floating bars are laid out in it so nothing sits under them.
    private lazy var cornerGuide: UILayoutGuide = {
        if #available(iOS 26.0, *) { return view.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal)) }
        return view.safeAreaLayoutGuide
    }()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateInlinePlayback()
        answerQuickDownloadRequest()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restoreSearchToContent()
        detachInline()   // (not just paused: a paused video layer can go black)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSearchChrome()
        // the settings panel opens over the cards: the grid starts under the bar (and its chips)
        // (folded, the bar is out of sight: the cards start under the chips, or the tab bar)
        let last: UIView? = !chipScroll.isHidden ? chipScroll : searchFolded ? nil : searchRow
        // folded: the navigation bar that holds the magnifier adds its own height to the safe area,
        // though it shares the tab bar's row: start under that row, not under the safe area
        let top = last.map { max(0, $0.convert($0.bounds, to: view).maxY + 12 - view.safeAreaInsets.top) }
            ?? ((foldedRowBottom ?? view.safeAreaInsets.top) + 12 - view.safeAreaInsets.top)
        suggestions.topInset = max(view.safeAreaInsets.top, header.convert(header.bounds, to: view).maxY) + 8
        let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
        let below = max(view.bounds.maxY - keyboardTop, view.safeAreaInsets.bottom)
        if suggestions.table.contentInset.bottom != below {
            suggestions.table.contentInset.bottom = below
            suggestions.table.verticalScrollIndicatorInsets.bottom = below
        }
        let insets = UIEdgeInsets(top: top + 8, left: 0, bottom: 12, right: 0)
        if collectionView.contentInset != insets { collectionView.contentInset = insets; collectionView.verticalScrollIndicatorInsets = insets }
        // resting at the top: stay at the top of the new space (the bar folded or came back)
        let topOffset = -collectionView.adjustedContentInset.top
        if restingAtTop, !collectionView.isTracking, !collectionView.isDecelerating, abs(collectionView.contentOffset.y - topOffset) > 0.5 {
            collectionView.contentOffset.y = topOffset
        }
    }

    /// Back to the bar above the cards (another tab, a portrait or narrow window, the sidebar).
    func restoreSearchToContent() { setSearchFoldable(in: nil) }

    /// The row beside the floating tab bar has room (`item`: 浏览's navigation item) or not (nil).
    func setSearchFoldable(in item: UINavigationItem?) {
        guard isViewLoaded else { return }
        if foldItem !== item {
            foldItem?.rightBarButtonItems = nil
            foldItem = item
            if item == nil { unfolded = false }
        }
        syncSearchFold(animated: false)
    }

    private lazy var foldSearchItem: UIBarButtonItem = {
        let b = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.unfoldSearch() })
        b.accessibilityLabel = L("search.placeholder")
        b.accessibilityIdentifier = "searchButton"
        return b
    }()
    private lazy var foldMoreItem: UIBarButtonItem = {
        let b = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: nil)
        b.accessibilityLabel = L("sidebar.other")
        b.accessibilityIdentifier = "browseMore"
        return b
    }()

    /// The magnifier: the bar opens above the cards, ready to type.
    private func unfoldSearch() {
        unfolded = true
        syncSearchFold(animated: true)
        searchField.becomeFirstResponder()
    }

    /// Folds or unfolds as the state asks: folded while the row has room and nothing is searched,
    /// typed or filtered (a search in effect keeps its bar, so its capsules stay in sight).
    private func syncSearchFold(animated: Bool) {
        let idle = !searching && !searchField.isFirstResponder && searchField.tokens.isEmpty && (searchField.text ?? "").isEmpty && currentFilter.isEmpty
        let folded = foldItem != nil && !unfolded && idle
        let nav = (parent as? FeedHost)?.navigationController
        // Folding back to the magnifier (the search closed): the bar fades where it is, together
        // with the list, and only then gives its place back. Moving it while the navigation bar
        // returns would replay the opening animation backwards.
        if folded, !searchFolded, animated {
            guard !folding else { return }
            folding = true
            searchChrome.isUserInteractionEnabled = false
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.searchChrome.alpha = 0
            } completion: { _ in
                self.folding = false
                self.syncSearchFold(animated: false)
                // (searched again meanwhile: it stays open)
                if !self.searchFolded { self.searchChrome.alpha = 1; self.searchChrome.isUserInteractionEnabled = true }
            }
            return
        }
        guard !folding else { return }
        if folded {
            foldMoreItem.menu = UIMenu(children: browseActions())
            if foldItem?.rightBarButtonItems?.count != 2 { foldItem?.rightBarButtonItems = [foldSearchItem, foldMoreItem] }
            nav?.setNavigationBarHidden(false, animated: false)
        } else if foldItem != nil || searchFolded {
            foldItem?.rightBarButtonItems = nil
            nav?.setNavigationBarHidden(true, animated: false)
        }
        guard folded != searchFolded else { return }
        searchFolded = folded
        searchChrome.isUserInteractionEnabled = !folded
        searchChrome.accessibilityElementsHidden = folded
        let change = {
            self.searchChrome.alpha = folded ? 0 : 1
            self.layoutSearchChrome()
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        } else { UIView.performWithoutAnimation(change) }
    }

    func hideSearchDuringTransition(_ hidden: Bool) {
        // Fade, keeping the layout footprint: removing the view makes UIKit jump between layouts
        // before the sidebar's animation has finished. (A folded bar stays out of sight.)
        searchChrome.isUserInteractionEnabled = !hidden && !searchFolded
        searchChrome.accessibilityElementsHidden = hidden || searchFolded
        UIView.animate(withDuration: hidden ? 0.12 : 0.2,
                       delay: hidden ? 0 : 0.03,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
            self.searchChrome.alpha = hidden || self.searchFolded ? 0 : 1
        }
    }

    /// 下载帖子, 按添加时间, 按帖子 (and export / exit while a search is in effect): the folded
    /// bar's ⋯ menu.
    private func browseActions() -> [UIMenuElement] {
        [
            UIAction(title: L("common.downloadPosts"), image: UIImage(systemName: "arrow.down")) { [weak self] _ in self?.showQuickDownload() },
            UIAction(title: L("feed.sortByAdded"), image: UIImage(systemName: "clock"), state: LibraryPrefs.feedByAdded ? .on : .off) { [weak self] _ in self?.setByAdded(!LibraryPrefs.feedByAdded) },
            UIAction(title: groupToggle.accessibilityLabel ?? L("common.posts"), image: UIImage(systemName: "square.stack"), state: grouped ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.groupToggle.isOn.toggle()
                self.groupChanged()
            },
        ]
    }

    private func updateSearchActions() {
        let hasTokens = !searchField.tokens.isEmpty || !(searchField.text ?? "").isEmpty
        let hidden = searching || hasTokens || !currentFilter.isEmpty
        downloadButton.isHidden = hidden
        sortButton.isHidden = hidden
        groupToggle.isHidden = hidden
        if searchFolded { foldMoreItem.menu = UIMenu(children: browseActions()) }
    }

    #if DEBUG
    func debugFocusSearch() { if searchFolded { unfoldSearch() } else { searchField.becomeFirstResponder() } }
    func debugClearSearch() { clearSearch() }
    var debugSearchFolded: Bool { searchFolded }
    #endif

    private func layoutSearchChrome() {
        let safe = cornerGuide.layoutFrame
        searchChrome.frame = CGRect(x: safe.minX + 10, y: view.safeAreaInsets.top + 6,
                                    width: max(0, safe.width - 20), height: 56)
        // folded: the chips (and the cards) start right under the tab bar
        chipsTop?.constant = (searchFolded ? foldedRowBottom ?? view.safeAreaInsets.top : searchChrome.frame.maxY) + 8
    }

    /// Folded: the bottom of the row the tab bar and the magnifier share.
    private var foldedRowBottom: CGFloat? {
        guard searchFolded, let bar = (parent as? FeedHost)?.navigationController?.navigationBar, !bar.isHidden, bar.window != nil else { return nil }
        return bar.convert(bar.bounds, to: view).maxY
    }

    // MARK: Layout

    /// Card heights by entry (measuring post text is the costly part of laying out the grid).
    private let cardHeights = CardHeightCache()
    private let sizesWatcher = MediaSizesWatcher()
    private var cardPages = CardPages()
    private let masonry = FeedMasonryLayout()

    private func buildCollection() {
        let layout = masonry
        layout.height = { [weak self] i, w in
            guard let self, i < self.entries.count else { return w * 1.25 }
            let e = self.entries[i]
            let traits = self.traitCollection
            self.cardHeights.prepare(width: w, sizeKey: traits.preferredContentSizeCategory.rawValue)
            let key = self.entryKey(e)
            let caption = self.cardHeights.height(key + "#\(e.first?.cardContentKey ?? 0)") { CardLayout(item: e.first, width: w, traits: traits).captionHeight }
            return caption + cardMediaHeight(e, width: w, position: CGFloat(self.cardPages.page(of: key, count: e.count)))
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(FeedCell.self, forCellWithReuseIdentifier: FeedCell.reuseID)
        collectionView.register(FeedEndView.self, forSupplementaryViewOfKind: FeedEndView.kind, withReuseIdentifier: FeedEndView.kind)
        collectionView.prefetchDataSource = self
        updateShuffleControl()
        view.addSubview(collectionView)

        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            // the middle of the screen: the safe area's top moves as the tab bar, the sidebar and
            // the folded search take turns, and the text would jump with it
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: 0.8),
        ])
    }

    private func glass(_ host: UIView, corner: CGFloat) {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect() } else { effect = UIBlurEffect(style: .systemChromeMaterial) }
        let v = UIVisualEffectView(effect: effect)
        v.layer.cornerRadius = corner
        v.layer.cornerCurve = .continuous
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        host.insertSubview(v, at: 0)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
    }

    private func buildHeader() {
        glass(header, corner: 26)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchChrome)
        searchChrome.addSubview(header)

        searchField.returnKeyType = .search
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.delegate = self
        searchField.accessibilityIdentifier = "search"
        searchField.allowsDeletingTokens = true
        // one box only: the glass bar is the field's frame (the field's own rounded background
        // inside it looked like a second box)
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)

        var xc: UIButton.Configuration
        if #available(iOS 26.0, *) { xc = .glass() } else { xc = .gray() }
        xc.image = UIImage(systemName: "xmark")
        xc.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .medium)
        xc.cornerStyle = .capsule
        xc.baseForegroundColor = .label
        exitButton.configuration = xc
        exitButton.accessibilityIdentifier = "searchExit"
        exitButton.accessibilityLabel = L("search.exit")
        exitButton.addAction(UIAction { [weak self] _ in self?.clearSearch() }, for: .touchUpInside)
        exitButton.isHidden = true
        exitButton.alpha = 0
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        searchChrome.addSubview(exitButton)

        var ec: UIButton.Configuration
        if #available(iOS 26.0, *) { ec = .glass() } else { ec = .gray() }
        ec.image = UIImage(systemName: "square.and.arrow.up")
        ec.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .medium)
        ec.cornerStyle = .capsule
        ec.baseForegroundColor = .label
        exportButton.configuration = ec
        exportButton.accessibilityIdentifier = "searchExport"
        exportButton.accessibilityLabel = L("search.export")
        exportButton.addAction(UIAction { [weak self] _ in self?.showExport() }, for: .touchUpInside)
        exportButton.isHidden = true
        exportButton.alpha = 0
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        searchChrome.addSubview(exportButton)

        chipStack.axis = .horizontal
        chipStack.spacing = 8
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.addSubview(chipStack)
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.isHidden = true

        searchRow.addArrangedSubview(searchField)
        downloadButton.addAction(UIAction { [weak self] _ in self?.showQuickDownload() }, for: .touchUpInside)
        sortButton.addAction(UIAction { [weak self] _ in self?.setByAdded(!LibraryPrefs.feedByAdded) }, for: .touchUpInside)
        updateSortButton()
        groupToggle.isOn = grouped
        groupToggle.addAction(UIAction { [weak self] _ in self?.groupChanged() }, for: .touchUpInside)
        searchRow.addArrangedSubview(sortButton)
        searchRow.addArrangedSubview(groupToggle)
        searchRow.addArrangedSubview(downloadButton)
        searchRow.spacing = 6
        searchRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [searchRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipScroll)
        view.addSubview(chipBar)
        header.follower = chipBar
        chipsTop = chipBar.topAnchor.constraint(equalTo: view.topAnchor)

        headerTrailing = header.trailingAnchor.constraint(equalTo: searchChrome.trailingAnchor)
        headerBesideExit = header.trailingAnchor.constraint(equalTo: exitButton.leadingAnchor, constant: -8)
        headerBesideExport = header.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -8)
        exportBesideExit = exportButton.trailingAnchor.constraint(equalTo: exitButton.leadingAnchor, constant: -8)
        exportAtEdge = exportButton.trailingAnchor.constraint(equalTo: searchChrome.trailingAnchor)
        exportAtEdge.isActive = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: searchChrome.topAnchor),
            header.leadingAnchor.constraint(equalTo: searchChrome.leadingAnchor),
            headerTrailing,
            exitButton.trailingAnchor.constraint(equalTo: searchChrome.trailingAnchor),
            exitButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            exitButton.widthAnchor.constraint(equalToConstant: 52), exitButton.heightAnchor.constraint(equalToConstant: 52),
            exportButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            exportButton.widthAnchor.constraint(equalToConstant: 52), exportButton.heightAnchor.constraint(equalToConstant: 52),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 40),
            chipsTop,
            chipBar.leadingAnchor.constraint(equalTo: cornerGuide.leadingAnchor, constant: 12),
            chipBar.trailingAnchor.constraint(equalTo: cornerGuide.trailingAnchor, constant: -10),
            chipScroll.topAnchor.constraint(equalTo: chipBar.topAnchor), chipScroll.bottomAnchor.constraint(equalTo: chipBar.bottomAnchor),
            chipScroll.leadingAnchor.constraint(equalTo: chipBar.leadingAnchor), chipScroll.trailingAnchor.constraint(equalTo: chipBar.trailingAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: 32),
            chipStack.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
            chipStack.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
        ])

        // the list under the field while searching: it covers 浏览 (the field floats
        // above it) and ends at the keyboard
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        suggestions.isHidden = true
        suggestions.alpha = 0
        view.addSubview(suggestions)
        NSLayoutConstraint.activate([
            suggestions.topAnchor.constraint(equalTo: view.topAnchor),
            suggestions.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestions.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // the list goes on behind the keyboard (its rounded corners and the space beside
            // them show the list, not 浏览); its rows end above the keyboard
            suggestions.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        // an invisible view on the keyboard's top edge: the keyboard moving lays the view out
        // again, which updates where the list's rows end
        let probe = UIView()
        probe.isUserInteractionEnabled = false
        probe.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(probe)
        NSLayoutConstraint.activate([probe.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
                                     probe.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                     probe.widthAnchor.constraint(equalToConstant: 1), probe.heightAnchor.constraint(equalToConstant: 1)])
        if searchChrome.superview === view { view.bringSubviewToFront(searchChrome) }
        view.bringSubviewToFront(chipBar)
        searchChrome.bringSubviewToFront(exitButton)
        searchChrome.bringSubviewToFront(exportButton)
        updatePlaceholder()
    }

    /// A rail or sidebar came over the side, or the window turned: the cards fit the new room.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        masonry.invalidateLayout()
    }

    private let groupToggle = RoundSearchButton(symbol: "square.stack.3d.up", label: L("feed.groupByPost"), identifier: "groupToggle", onValue: L("feed.groupOn"), offValue: L("feed.groupOff"))
    /// Another place brings 浏览 to the front (a tag chosen on the tags page…).
    var onShowBrowse: (() -> Void)?

    /// Pulled down at the top: a new random order. Not while sorted by date, where there is
    /// nothing to shuffle.
    private func updateShuffleControl() {
        if LibraryPrefs.feedByAdded {
            collectionView.refreshControl = nil
        } else if collectionView.refreshControl == nil {
            let c = UIRefreshControl()
            c.accessibilityLabel = L("feed.reshuffle")
            c.accessibilityIdentifier = "pullToShuffle"
            c.addTarget(self, action: #selector(pulledToShuffle), for: .valueChanged)
            collectionView.refreshControl = c
        }
    }

    @objc private func pulledToShuffle() {
        reshuffle()
        collectionView.refreshControl?.endRefreshing()
    }

    /// A media to show in 浏览 once the next result is on screen (`reveal`).
    private var pendingReveal: FeedItem?

    /// "在浏览中查看帖子" from a grid: back to 浏览 with the card of that media's post on screen,
    /// turned to that media, and briefly marked. When the search or a filter hides it, they are
    /// cleared first (the browse order stays as it was).
    func reveal(_ item: FeedItem) {
        onShowBrowse?()
        if allItems.contains(where: { $0.mediaId == item.mediaId }) { return scrollTo(item) }
        pendingReveal = item
        searchField.tokens = []
        searchField.text = nil
        query = TokenQuery()
        filter = FeedFilter()
        if LibraryPrefs.badOnly && item.bad == nil { LibraryPrefs.badOnly = false }
        renderChips()
        updateExitButton()
        reload()
    }

    /// Puts the card of `item` in the middle of the screen, on its page, and marks it.
    private func scrollTo(_ item: FeedItem) {
        guard let i = entries.firstIndex(where: { $0.contains { $0.mediaId == item.mediaId } }), sectionCount > 0 else {
            toast.show(L("feed.reveal.notFound"))
            return
        }
        let ip = IndexPath(item: i, section: 0)
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: ip, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        DispatchQueue.main.async {
            guard let cell = self.collectionView.cellForItem(at: ip) as? FeedCell else { return }
            if let page = cell.items.firstIndex(where: { $0.mediaId == item.mediaId }) { cell.show(page: page) }
            cell.flash()
            self.updateInlinePlayback()
        }
    }

    /// "在浏览中查看" from the folders: back to 浏览 with that filter.
    func showInBrowse(_ f: FeedFilter) {
        onShowBrowse?()
        clearTerms()
        filter = f
        renderChips()
        reload()
    }

    // MARK: Data

    private var reloadGeneration = 0
    /// The generation of the result on screen (an export waits for the latest search).
    private var shownGeneration = -1

    private let reloadWork = LatestWork()

    func reload(keepPosition: Bool = false) {
        // every change of the search comes here: the bar folds or stays with what is searched
        if isViewLoaded { syncSearchFold(animated: true) }
        reloadGeneration += 1
        let gen = reloadGeneration
        let fields = query.searchFields
        var req = FeedRequest(terms: terms, scope: query.scope, newestFirst: LibraryPrefs.feedByAdded, fuzzy: fuzzy, fields: fields, filter: currentFilter, wholePosts: grouped)
        // a search that asks for something and its opposite finds nothing, without asking the core
        let contradictory = query.isContradictory
        let needsVectors = !contradictory && fuzzy && (fields.tags || fields.text || !fields.author) && !terms.isEmpty && ModelStore.shared.activeEmbedderId != nil && AIEngine.isSupported
        reloadWork.submit { [weak self] isCurrent in
            guard let self, isCurrent() else { return }
            if needsVectors, let q = await AIEngine.shared.queryVectors(req.terms) {
                req.termVectors = q.vectors
                req.embedModel = q.model
            }
            guard isCurrent() else { return }
            let items = contradictory ? [] : await Task.detached(priority: .userInitiated) { () -> [FeedItem] in
                do { return try Core.feed(req) } catch { AppLog.error("feed", "\(error)"); return [] }
            }.value
            guard gen == self.reloadGeneration else { return }
            self.shownGeneration = gen
            self.apply(items, keepPosition: keepPosition)
            #if DEBUG
            self.debugCheckCards()
            #endif
            self.sizesWatcher.watch(items) { [weak self] in self?.reload(keepPosition: true) }
            self.updateExitButton()
            if let r = self.pendingReveal {
                self.pendingReveal = nil
                DispatchQueue.main.async { self.scrollTo(r) }
            }
        }
    }

    /// Long-press filters plus the settings filters (unreviewed only, damaged only).
    private var currentFilter: FeedFilter {
        var f = filter
        if LibraryPrefs.badOnly { f.badOnly = true }
        // conditions from the search field's capsules
        return query.filter(over: f)
    }

    /// Where you were in the unfiltered feed before searching or filtering: restored when the
    /// search is closed (the order is stable, so the same position shows the same media).
    private var savedBrowse: CGPoint?
    private var lastUnfiltered = true
    private var isUnfiltered: Bool { terms.isEmpty && currentFilter.isEmpty && !query.isContradictory }

    private func apply(_ items: [FeedItem], keepPosition: Bool) {
        let nowUnfiltered = isUnfiltered
        // kept from the top of the cards: the space above them may differ when it comes back
        // (the iPad's search bar folds away once the search is closed)
        if lastUnfiltered && !nowUnfiltered { savedBrowse = CGPoint(x: 0, y: collectionView.contentOffset.y + collectionView.adjustedContentInset.top) }
        let restore = !lastUnfiltered && nowUnfiltered ? savedBrowse : nil
        if restore != nil { savedBrowse = nil }
        lastUnfiltered = nowUnfiltered
        let oldEntries = entries
        allItems = LibraryPrefs.feedByAdded ? items : order.apply(items)
        rebuildEntries()
        masonry.invalidateHeights()
        if keepPosition, restore == nil, incrementalUpdate(from: oldEntries) {
            emptyLabel.isHidden = !allItems.isEmpty
            DispatchQueue.main.async { self.updateInlinePlayback() }
            return
        }
        if let r = restore {
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            collectionView.setContentOffset(CGPoint(x: 0, y: r.y - collectionView.adjustedContentInset.top), animated: false)
            restingAtTop = r.y <= 1
            emptyLabel.isHidden = !allItems.isEmpty
            DispatchQueue.main.async { self.updateInlinePlayback() }
            return
        }
        let offset = collectionView.contentOffset
        collectionView.reloadData()
        if keepPosition {
            collectionView.layoutIfNeeded()
            collectionView.setContentOffset(offset, animated: false)
        } else {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
            restingAtTop = true
        }
        if allItems.isEmpty {
            emptyLabel.text = isUnfiltered ? L("feed.empty.library") : L("feed.empty.noMatch")
        }
        emptyLabel.isHidden = !allItems.isEmpty
        DispatchQueue.main.async { self.updateInlinePlayback() }
    }

    private func entryKey(_ e: [FeedItem]) -> String { (grouped ? e.first?.postId : e.first?.mediaId) ?? "" }

    /// After a change in the library (a delete, new tags, an AI result, a sync), updates the
    /// grid without reloading it: removed cards fade out, changed cards update in
    /// place, everything else stays as it is (no flash, no lost scroll position). Returns false
    /// when cards were added or reordered; the caller then reloads.
    private func incrementalUpdate(from old: [[FeedItem]]) -> Bool {
        guard !old.isEmpty, !entries.isEmpty, collectionView.numberOfSections == 1,
              collectionView.numberOfItems(inSection: 0) == old.count else { return false }
        let oldKeys = old.map(entryKey), newKeys = entries.map(entryKey)
        let keep = Set(newKeys)
        guard oldKeys.filter({ keep.contains($0) }) == newKeys else { return false }   // additions or a new order
        let removed = oldKeys.indices.filter { !keep.contains(oldKeys[$0]) }
        if !removed.isEmpty {
            let ips = removed.map { IndexPath(item: $0, section: 0) }
            // The grid finishes any pending layout before a batch, asking for cells at their old
            // places: they have to get the old entries, or a card moves up showing the next one's.
            let fresh = entries
            entries = old
            collectionView.layoutIfNeeded()
            collectionView.performBatchUpdates {
                entries = fresh
                collectionView.deleteItems(at: ips)
            }
        }
        // changed cards: refresh the visible ones in place
        let oldByKey = Dictionary(old.map { (entryKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        let changed = collectionView.indexPathsForVisibleItems.filter { ip in
            ip.item < entries.count && oldByKey[entryKey(entries[ip.item])] != entries[ip.item]
        }
        for ip in changed { (collectionView.cellForItem(at: ip) as? FeedCell)?.refresh(entries[ip.item]) }
        return true
    }

    /// Single mode: one entry per media. Grouped: one entry per post, media in original order.
    private func rebuildEntries() {
        guard grouped else { entries = allItems.map { [$0] }; return }
        entries = LibraryPrefs.feedByAdded ? FeedOrder.postsInPlace(allItems) : order.posts(allItems)
    }

    private func entry(at ip: IndexPath) -> [FeedItem] { entries[ip.item % entries.count] }

    #if DEBUG
    /// The stress test of the buttons on top: every card on screen shows its own entry, and no
    /// entry is there twice. What is wrong goes to TL_FEED_CHECK (a file).
    private func debugCheckCards() {
        guard let path = ProcessInfo.processInfo.environment["TL_FEED_CHECK"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            var out: [String] = []
            let keys = self.entries.map(self.entryKey)
            if Set(keys).count != keys.count { out.append("entries repeat: \(keys.count) vs \(Set(keys).count)") }
            var shown: [String] = []
            for case let cell as FeedCell in self.collectionView.visibleCells {
                guard let ip = self.collectionView.indexPath(for: cell) else { out.append("cell without a place"); continue }
                let want = self.entries[ip.item].map(\.mediaId), have = cell.items.map(\.mediaId)
                if want != have { out.append("item \(ip.item) shows \(have.first?.prefix(6) ?? "-") wants \(want.first?.prefix(6) ?? "-")") }
                shown += have
            }
            if Set(shown).count != shown.count { out.append("twice on screen: \(shown.count) vs \(Set(shown).count)") }
            let line = "grouped=\(self.grouped) byAdded=\(LibraryPrefs.feedByAdded) cells=\(shown.count) " + (out.isEmpty ? "ok" : out.joined(separator: "; ")) + "\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
            else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
        }
    }
    #endif
    private var sectionCount: Int { entries.isEmpty ? 0 : 1 }

    // MARK: Search chips

    func textFieldShouldReturn(_ tf: UITextField) -> Bool {
        commitTypedText()
        exitSearch()
        return true
    }

    func textFieldDidBeginEditing(_ tf: UITextField) { enterSearch() }

    /// A term to search for: a capsule in the field.
    private func addTerm(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !terms.contains(t) else { return }
        SearchHistory.add(t)
        insertToken(key: TokenQuery.termKey(t))
        applyTokens()
    }

    private func clearTerms() {
        searchField.tokens = searchField.tokens.filter { !(($0.representedObject as? String)?.hasPrefix("t:") ?? false) }
        query = TokenQuery(keys: searchField.tokens.compactMap { $0.representedObject as? String })
        updateExitButton()
    }

    /// The × beside the bar: the whole search goes (capsules and text) and the list closes.
    private func clearSearch() {
        searchField.tokens = []
        searchField.text = nil
        applyTokens()
        exitSearch()
        updateExitButton()
    }

    /// A tag was renamed: the search follows the new name.
    private func replaceTerm(_ old: String, with new: String) {
        for key in [TokenQuery.termKey(old), TokenQuery.minus + TokenQuery.termKey(old)] {
            if let k = searchField.tokens.firstIndex(where: { ($0.representedObject as? String) == key }) {
                searchField.removeToken(at: k)
                searchField.insertToken(makeToken(key.hasPrefix(TokenQuery.minus) ? TokenQuery.minus + TokenQuery.termKey(new) : TokenQuery.termKey(new)), at: k)
            }
        }
        query = TokenQuery(keys: searchField.tokens.compactMap { $0.representedObject as? String })
    }

    private func filterChip(_ title: String, color: UIColor, id: String, remove: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.image = UIImage(systemName: "xmark")
        cfg.imagePlacement = .trailing
        cfg.imagePadding = 6
        cfg.preferredSymbolConfigurationForImage = .init(pointSize: 10, weight: .bold)
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = color
        cfg.contentInsets = .init(top: 6, leading: 10, bottom: 6, trailing: 10)
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in remove() })
        b.accessibilityIdentifier = id
        b.accessibilityLabel = L("feed.removeFilter", title)
        return b
    }

    private var plainSearchIcon: UIView?
    /// Once something is searched for, the mascot mode's search icon.
    private func updateSearchIcon() {
        if plainSearchIcon == nil { plainSearchIcon = searchField.leftView }
        searchField.leftView = Mascot.isOn && !terms.isEmpty ? UIImageView(image: Mascot.icon("search", side: 24)) : plainSearchIcon
    }

    private func renderChips() {
        updateSearchIcon()
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let a = filter.author {
            chipStack.addArrangedSubview(filterChip(L("feed.chip.author", a.hasPrefix("@") ? a : "@" + a), color: .systemIndigo, id: "chip-author") { [weak self] in
                self?.filter.author = nil; self?.renderChips(); self?.reload() })
        }
        for l in filter.labels {
            chipStack.addArrangedSubview(filterChip(L("feed.chip.label", l), color: .systemGreen, id: "chip-label-\(l)") { [weak self] in
                self?.filter.labels.removeAll { $0 == l }; self?.renderChips(); self?.reload() })
        }
        if filter.albumOnly {
            chipStack.addArrangedSubview(filterChip(L("card.album"), color: .systemIndigo, id: "chip-album") { [weak self] in
                self?.filter.albumOnly = false; self?.renderChips(); self?.reload() })
        }
        if filter.looseOnly {
            chipStack.addArrangedSubview(filterChip(L("card.loose"), color: .systemIndigo, id: "chip-loose") { [weak self] in
                self?.filter.looseOnly = false; self?.renderChips(); self?.reload() })
        }
        if filter.recentOnly {
            chipStack.addArrangedSubview(filterChip(L("place.recent"), color: .systemOrange, id: "chip-recent") { [weak self] in
                self?.filter.recentOnly = false; self?.renderChips(); self?.reload() })
        }
        if let k = filter.kind {
            chipStack.addArrangedSubview(filterChip(k == .video ? L("feed.chip.videos") : L("feed.chip.photos"), color: .systemPink, id: "chip-kind") { [weak self] in
                self?.filter.kind = nil; self?.renderChips(); self?.reload() })
        }
        if let f = filter.folder {
            chipStack.addArrangedSubview(filterChip(L("search.token.folder", f), color: .systemTeal, id: "chip-folder") { [weak self] in
                self?.filter.folder = nil; self?.renderChips(); self?.reload() })
        }
        if LibraryPrefs.badOnly {
            chipStack.addArrangedSubview(filterChip(L("feed.chip.bad"), color: .systemRed, id: "chip-bad") { LibraryPrefs.badOnly = false })
        }
        // the chip row is there only when something filters 浏览
        let empty = chipStack.arrangedSubviews.isEmpty
        if chipScroll.isHidden != empty {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
                self.chipScroll.isHidden = empty
                self.chipScroll.alpha = empty ? 0 : 1
                self.view.layoutIfNeeded()
            }
        }
    }

    // MARK: Search mode

    /// Tapping the field: the list of suggestions (or filters) opens under it.
    private func enterSearch() {
        guard !searching else { return }
        searching = true
        detachInline()   // (not just paused: a paused video layer can go black)
        Task { [weak self] in
            let (tags, folders) = await Task.detached { (Core.allTags(), Core.folders()) }.value
            guard let self, self.searching else { return }
            self.tagCache = tags
            self.folderCache = folders
            self.rebuildSuggestions()
        }
        rebuildSuggestions()
        view.layoutIfNeeded()   // the field's final place (it may have just unfolded) before the list is placed under it
        suggestions.scrollToTop()
        suggestions.isHidden = false
        view.bringSubviewToFront(suggestions)
        if searchChrome.superview === view { view.bringSubviewToFront(searchChrome) }
        searchChrome.bringSubviewToFront(exitButton)
        searchChrome.bringSubviewToFront(exportButton)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.suggestions.alpha = 1 }
        updateExitButton()
    }

    /// Return or another tab: the list closes; the search itself stays.
    private func exitSearch() {
        searchField.resignFirstResponder()
        guard searching else { return }
        searching = false
        unfolded = false
        commitTypedText()
        updateExitButton()
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: {
            self.suggestions.alpha = 0
        }) { _ in
            if !self.searching { self.suggestions.isHidden = true }
            self.view.bringSubviewToFront(self.activityPanel)
            self.view.bringSubviewToFront(self.toast)
            self.updateInlinePlayback()
        }
    }

    @objc private func searchTextChanged() {
        if searchField.markedTextRange == nil {
            // a word followed by a space becomes a capsule (a condition, or text to search for)
            let (keys, rest) = TokenQuery.split(searchField.text ?? "")
            if !keys.isEmpty {
                for k in keys { addKey(k) }
                searchField.text = rest
            }
            applyTokens()
        }
        if searching { rebuildSuggestions() }
    }

    /// A capsule from typed text. A word right after a pending L("place.folders") capsule names the folder
    /// (matched to an existing folder regardless of case); a second folder replaces the first.
    private func addKey(_ key: String) {
        var k = key
        let last = searchField.tokens.last?.representedObject as? String
        // a word right after a pending L("place.folders") (or "-文件夹") names the folder
        if k.hasPrefix("t:") || k.hasPrefix(TokenQuery.minus + "t:"), last == TokenQuery.pendingFolder || last == TokenQuery.minus + TokenQuery.pendingFolder {
            searchField.removeToken(at: searchField.tokens.count - 1)
            let word = k.hasPrefix(TokenQuery.minus) ? String(k.dropFirst(3)) : String(k.dropFirst(2))
            k = (last == TokenQuery.pendingFolder ? "" : TokenQuery.minus) + TokenQuery.folderKey(word)
        }
        let negative = k.hasPrefix(TokenQuery.minus)
        let bare = negative ? String(k.dropFirst()) : k
        if bare.hasPrefix("d:") {
            let typed = String(bare.dropFirst(2))
            let name = folderCache.first { $0.name.lowercased() == typed.lowercased() }?.name ?? typed
            k = (negative ? TokenQuery.minus : "") + TokenQuery.folderKey(name)
            // one folder to look in (a new one replaces it); folders to leave out add up
            if !negative { searchField.tokens = searchField.tokens.filter { !(($0.representedObject as? String)?.hasPrefix("d:") ?? false) } }
        }
        guard !searchField.tokens.contains(where: { ($0.representedObject as? String) == k }) else { return }
        if bare.hasPrefix("t:") {
            let t = String(bare.dropFirst(2)).lowercased()
            k = (negative ? TokenQuery.minus : "") + TokenQuery.termKey(t)
            if !negative { SearchHistory.add(t) }
        }
        insertToken(key: k)
    }

    /// Text left in the field when the search closes becomes a capsule too (the last word may
    /// be a condition, or a folder's name after L("place.folders"), typed without a space after it).
    private func commitTypedText() {
        let t = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchField.text = nil
        if !t.isEmpty { addKey(TokenQuery.key(for: t, after: nil)) }
        // a L("place.folders") capsule still waiting for a name means nothing: it goes
        if let last = searchField.tokens.last?.representedObject as? String, last == TokenQuery.pendingFolder || last == TokenQuery.minus + TokenQuery.pendingFolder { searchField.removeToken(at: searchField.tokens.count - 1) }
        applyTokens()
    }

    /// What a capsule reads (VoiceOver: with "排除" for a minus capsule).
    private func tokenTitle(_ key: String) -> String { TokenQuery.spoken(key) }

    /// A capsule: its symbol (a minus capsule a ⊖) and title.
    private func makeToken(_ key: String) -> UISearchToken {
        let icon = TokenQuery.symbol(key).flatMap { UIImage(systemName: $0) }
        let token = UISearchToken(icon: TokenQuery.isExcluded(key) ? icon?.withTintColor(.systemRed, renderingMode: .alwaysOriginal) : icon, text: TokenQuery.title(key))
        token.representedObject = key
        return token
    }

    private func insertToken(key: String) {
        searchField.insertToken(makeToken(key), at: searchField.tokens.count)
    }

    /// The capsules decide the search: conditions, then the texts (all must match).
    private func applyTokens() {
        let q = TokenQuery(keys: searchField.tokens.compactMap { $0.representedObject as? String })
        updateExitButton()
        guard q != query else { return }
        query = q
        reload()
    }

    /// The × shows while searching and while a search is in effect; it also says (to VoiceOver)
    /// what the search is.
    private func updateExitButton() {
        let words = searchField.tokens.compactMap { ($0.representedObject as? String).map(tokenTitle) } + [searchField.text ?? ""].filter { !$0.isEmpty }
        syncSearchFold(animated: true)
        let show = searching || !words.isEmpty
        // exporting is offered while a search or a filter is in effect (not while only typing begins)
        let showExport = !words.isEmpty || !currentFilter.isEmpty
        updateSearchActions()
        // These buttons are siblings of the header, so hiding the header cannot hide them.
        exitButton.isHidden = !show
        exportButton.isHidden = !showExport
        exitButton.accessibilityValue = words.joined(separator: L("list.separator"))
        guard show != exitShown || showExport != exportShown else { return }
        exitShown = show; exportShown = showExport
        // switch the old constraints off before the new ones on (never two required ones at odds)
        [headerTrailing, headerBesideExit, headerBesideExport, exportBesideExit, exportAtEdge].forEach { $0?.isActive = false }
        headerTrailing.isActive = !show && !showExport
        headerBesideExit.isActive = show && !showExport
        headerBesideExport.isActive = showExport
        exportBesideExit.isActive = show
        exportAtEdge.isActive = !show
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            for (b, on) in [(self.exitButton, show), (self.exportButton, showExport)] {
                b.alpha = on ? 1 : 0
                b.transform = on ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
            self.view.layoutIfNeeded()
        } completion: { _ in
            if !self.exitShown && self.exitButton.alpha == 0 { self.exitButton.isHidden = true }
            if !self.exportShown && self.exportButton.alpha == 0 { self.exportButton.isHidden = true }
        }
    }

    // MARK: Export of a search

    /// The export button: a small popover (the switches, then 导出) for exactly the media the
    /// search shows now.
    private func showExport() {
        searchField.resignFirstResponder()
        guard shownGeneration == reloadGeneration else { return alert(L("search.busy.title"), L("search.busy.message")) }
        let ids = allItems.map(\.mediaId)
        let host = UIHostingController(rootView: SearchExportView(count: ids.count) { [weak self] in
            self?.dismiss(animated: true) {
                let options = SearchExportPrefs.options
                self?.exportAndShare(fileName: SearchExportPrefs.fileName(terms: self?.query.terms ?? [])) { out in try Core.exportMedia(ids, options: options, to: out) }
            }
        })
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .popover
        host.sizingOptions = .preferredContentSize
        if let pop = host.popoverPresentationController {
            let anchor = exportButton
            pop.sourceView = anchor
            pop.sourceRect = anchor.bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = self
        }
        present(host, animated: true)
    }

    /// A real popover on the iPhone too (not a full sheet).
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    private func updatePlaceholder() {
        searchField.placeholder = L("search.placeholder")
    }

    private func updateSuggestionFooter() {
        let stats = ActivityCenter.shared.statsLine
        suggestions.setFooter((stats.isEmpty ? "" : stats + "\n") + SearchHighlight.guide)
    }

    private func rebuildSuggestions() {
        let typed = (searchField.text ?? "").trimmingCharacters(in: .whitespaces)
        suggestions.sections = tokenSuggestions(typed)
        updateSuggestionFooter()
    }

    /// The shared list (conditions, words, tags, folders, recent searches; with a minus typed,
    /// the same as exclusions) as system list rows.
    private func tokenSuggestions(_ typed: String) -> [SearchSuggestionsView.Section] {
        let keys = searchField.tokens.compactMap { $0.representedObject as? String }
        return SearchSuggestions.sections(typed: typed, keys: keys, tags: tagCache, folders: folderCache).map { sec in
            .init(title: sec.title, rows: sec.rows.map { r in
                let tint: UIColor = switch r.tint { case .accent: .tintColor; case .folder: .systemTeal; case .secondary: .secondaryLabel; case .exclude: .systemRed }
                return SearchSuggestionsView.Row(id: r.id, title: r.title, subtitle: r.subtitle, symbol: r.symbol, tint: tint, destructive: r.destructive,
                                                 action: r.action.map { a in { [weak self] in self?.perform(a) } })
            })
        }
    }

    private func perform(_ a: SearchSuggestion.Action) {
        switch a {
        case .key(let k):
            searchField.text = nil
            addKey(k)
            applyTokens()
        case .folder(let name, let excluded):
            searchField.text = nil
            // the pending L("place.folders") capsule gives way to the folder
            if let last = searchField.tokens.last?.representedObject as? String, last == TokenQuery.pendingFolder || last == TokenQuery.minus + TokenQuery.pendingFolder {
                searchField.removeToken(at: searchField.tokens.count - 1)
            }
            addKey((excluded ? TokenQuery.minus : "") + TokenQuery.folderKey(name))
            applyTokens()
        case .clearHistory:
            SearchHistory.clear()
        }
        rebuildSuggestions()
    }

    private func groupChanged() {
        grouped.toggle()
        groupToggle.isOn = grouped
        UserDefaults.standard.set(grouped, forKey: "grouped")
        rebuildEntries()
        masonry.invalidateHeights()
        collectionView.reloadData()
        DispatchQueue.main.async { self.updateInlinePlayback() }
        #if DEBUG
        debugCheckCards()
        #endif
    }

    /// The links typed into the quick download card; they stay when it closes without downloading.
    private let quickDownloadDraft = QuickDownloadDraft()

    /// The quick download button: a small popover for links, as on the Mac.
    /// 下载帖子 on the app's icon: whatever is open closes, back to 浏览, and the card.
    private func answerQuickDownloadRequest() {
        guard QuickDownloadRequest.take() else { return }
        let open = { [weak self] in
            guard let self else { return }
            (self.view.window?.rootViewController as? AdaptiveRootViewController)?.showBrowse()
            self.onShowBrowse?()
            self.exitSearch()
            self.showQuickDownload()
        }
        if let presented = view.window?.rootViewController?.presentedViewController { presented.dismiss(animated: false, completion: open) } else { open() }
    }

    private func showQuickDownload() {
        searchField.resignFirstResponder()
        // the width: a popover on a phone stays about 28 pt off each side, and cuts off what is wider
        let draft = quickDownloadDraft
        let host = UIHostingController(rootView: QuickDownloadPopover(draft: draft, width: min(380, view.bounds.width - 60), openSettings: { [weak self] in
            self?.dismiss(animated: true) { self?.openDownloads() }
        }, download: { [weak self] in
            guard let self else { return }
            if let failure = SettingsViewController.startLinks(draft.links) {
                let a = UIAlertController(title: failure.title, message: failure.message, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                self.presentedViewController?.present(a, animated: true)
            } else {
                draft.links = ""
                self.dismiss(animated: true)
            }
        }))
        host.modalPresentationStyle = .popover
        host.sizingOptions = .preferredContentSize
        // The system popover supplies one continuous glass surface, including its arrow.
        host.view.backgroundColor = .clear
        if let pop = host.popoverPresentationController {
            let anchor = downloadButton
            pop.sourceView = anchor
            pop.sourceRect = anchor.bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = self
        }
        present(host, animated: true)
    }

    private func openDownloads() {
        let vc = SettingsViewController()
        vc.onLibraryChanged = { [weak self] in self?.reload(keepPosition: true) }
        let nav = UINavigationController(rootViewController: vc)
        vc.loadViewIfNeeded()
        vc.openDownloads(links: quickDownloadDraft.links)
        quickDownloadDraft.links = ""
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private var pendingReload: DispatchWorkItem?

    @objc private func libraryChanged(_ n: Notification) {
        if n.object as AnyObject? === self { return }   // our own change, already applied
        pendingReload?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.presentedViewController == nil || self.presentedViewController is UINavigationController else { return }
            self.reload(keepPosition: true)
        }
        pendingReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func updateSortButton() {
        sortButton.isOn = LibraryPrefs.feedByAdded
    }

    private func setByAdded(_ on: Bool) {
        LibraryPrefs.feedByAdded = on
        updateSortButton()
        updateShuffleControl()
        savedBrowse = nil   // a new order: the old position means nothing
        reload()
    }

    /// 浏览 tapped twice on the tab bar, or pulled down at the top.
    func reshuffle() {
        guard !LibraryPrefs.feedByAdded else { return }
        order.reshuffle()
        savedBrowse = nil   // a new order: the old position means nothing
        reload()
    }

    // MARK: Collection

    func numberOfSections(in cv: UICollectionView) -> Int { sectionCount }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String, at ip: IndexPath) -> UICollectionReusableView {
        let v = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: FeedEndView.kind, for: ip) as! FeedEndView
        v.configure(count: entries.count, grouped: grouped)
        return v
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: FeedCell.reuseID, for: ip) as! FeedCell
        cell.delegate = self
        cell.highlight = query.marks
        let e = entry(at: ip)
        cell.startPage = cardPages.page(of: entryKey(e), count: e.count)
        cell.refresh(e)
        return cell
    }

    /// Decode upcoming images before their cards appear (same size the cells request).
    func collectionView(_ cv: UICollectionView, cancelPrefetchingForItemsAt ips: [IndexPath]) {
        let items = ips.filter { $0.section < sectionCount && $0.item < entries.count }.compactMap { entry(at: $0).first }
        MediaLoader.shared.cancelPrefetch(items, maxPixel: MediaPageView.pixelSize)
    }

    func collectionView(_ cv: UICollectionView, prefetchItemsAt ips: [IndexPath]) {
        guard !entries.isEmpty else { return }
        for ip in ips { if let first = entry(at: ip).first { MediaPageView.prefetch(first) } }
    }

    /// A card came on screen: re-check which video plays (a short result list never scrolls,
    /// so scrolling alone would never start it).
    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        scheduleInlineUpdate()
    }

    /// Re-checks which video plays at most every 0.12 s, also while scrolling: a video starts
    /// as soon as it is (mostly) in view, not only once the scrolling stops. (A delay restarted
    /// by every scroll event only fired after the scrolling had settled.)
    private func scheduleInlineUpdate() {
        guard pendingInline == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            self?.pendingInline = nil
            self?.updateInlinePlayback()
        }
        pendingInline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        if let host = inlineHost, host.isDescendant(of: cell) { detachInline() }
    }

    /// The cards rest at their top (the user has not scrolled down): kept there when the space
    /// above them changes (the search bar folds or comes back, the tab bar's row changes).
    private var restingAtTop = true

    func scrollViewDidScroll(_ sv: UIScrollView) {
        if sv === collectionView, sv.isTracking || sv.isDecelerating {
            restingAtTop = sv.contentOffset.y <= -sv.adjustedContentInset.top + 1
        }
        guard sv === collectionView else { return }
        scheduleInlineUpdate()
    }

    func feedCellPageDidChange(_ cell: FeedCell) {
        cardPages.set(cell.page, for: entryKey(cell.items))
        updateInlinePlayback()
    }

    func feedCell(_ cell: FeedCell, heightChangedTo height: CGFloat) {
        guard let ip = collectionView.indexPath(for: cell) else { return }
        // later passes move with the pass's height: what is on screen stays where it is
        let grown = masonry.resize(item: ip.item, height: height)
        if grown != 0, ip.section > 0 { collectionView.contentOffset.y += grown * CGFloat(ip.section) }
    }

    func feedCell(_ cell: FeedCell, didTapTag label: String) { addTerm(label) }
    func feedCellDidTapRecent(_ cell: FeedCell) {
        guard !filter.recentOnly else { return }
        filter.recentOnly = true; renderChips(); reload()
    }

    /// Long-press menu of a tag chip.
    func feedCell(_ cell: FeedCell, menuForTag t: TagView, of item: FeedItem) -> UIMenu {
        UIMenu(title: t.label, children: tagActions(t, item: item))
    }

    func feedCell(_ cell: FeedCell, didTapPage index: Int) {
        guard let item = cell.currentItem else { return }
        // a video goes on from where it was playing in the card
        let time = item.kind == .video && inlineHost === cell.currentPageView ? inlinePlayer.currentTime() : .zero
        let vc: UIViewController
        // every media of the list, photos and videos alike, so swiping goes on into the next post
        // (found by the media itself: with posts not grouped, a post's media are separate entries)
        let all = entries.flatMap { $0 }
        if let start = all.firstIndex(where: { $0.mediaId == item.mediaId }) {
            vc = PhotoViewController(items: all, index: start, videoStart: time)
        } else {
            vc = PhotoViewController(items: cell.items, index: index, videoStart: time)
        }
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    /// Attaches the shared muted player to the video page closest to the viewport's center.
    private func updateInlinePlayback() {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        var best: (MediaPageView, CGFloat)?
        for cell in collectionView.visibleCells.compactMap({ $0 as? FeedCell }) {
            guard let page = cell.currentPageView, page.item?.kind == .video else { continue }
            let f = page.convert(page.bounds, to: collectionView).intersection(visible)
            let ratio = f.isNull ? 0 : (f.width * f.height) / max(page.bounds.width * page.bounds.height, 1)
            if ratio > 0.6, ratio > (best?.1 ?? 0) { best = (page, ratio) }
        }
        guard let target = best?.0 else { detachInline(); return }
        guard target !== inlineHost else { return }
        detachInline()
        guard let item = target.item else { return }
        inlineHost = target
        // Load the asset off the main thread, then attach.
        let asset = AVURLAsset(url: item.fileURL)
        Task { [weak self, weak target] in
            _ = try? await asset.load(.isPlayable)
            let playerItem = AVPlayerItem(asset: asset)
            await MainActor.run {
                guard let self, let target, self.inlineHost === target, target.item?.mediaId == item.mediaId else { return }
                self.inlinePlayer.replaceCurrentItem(with: playerItem)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                target.playerLayer.opacity = 0
                CATransaction.commit()
                target.playerLayer.player = self.inlinePlayer
                self.readyObservation = target.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                    guard layer.isReadyForDisplay else { return }
                    DispatchQueue.main.async {
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        layer.opacity = 1
                        CATransaction.commit()
                    }
                }
                target.playBadge.isHidden = true
                target.accessibilityValue = L("feed.autoplaying")
                self.inlinePlayer.play()
            }
        }
    }

    /// Stops the inline video and takes it off its card: the card's still frame shows again.
    /// (Every pause goes through here: a paused video layer left on a card can lose its frame —
    /// after the full-screen player, or in the background — and then shows black.)
    private func detachInline() {
        inlinePlayer.pause()
        readyObservation = nil
        inlineHost?.playerLayer.player = nil
        inlineHost?.playBadge.isHidden = inlineHost?.item?.kind != .video
        inlineHost?.accessibilityValue = nil
        inlineHost = nil
    }

    // MARK: Tag editing

    /// The long-press preview has the card's own rounded shape (the system's rectangle showed the
    /// background in the four corners).
    private func cardPreview(_ cv: UICollectionView, _ ip: IndexPath) -> UITargetedPreview? {
        guard let cell = cv.cellForItem(at: ip) else { return nil }
        let p = UIPreviewParameters()
        p.visiblePath = UIBezierPath(roundedRect: cell.contentView.bounds, cornerRadius: cell.contentView.layer.cornerRadius)
        p.backgroundColor = .clear
        return UITargetedPreview(view: cell.contentView, parameters: p)
    }
    func collectionView(_ cv: UICollectionView, contextMenuConfiguration config: UIContextMenuConfiguration, highlightPreviewForItemAt ip: IndexPath) -> UITargetedPreview? { cardPreview(cv, ip) }
    func collectionView(_ cv: UICollectionView, contextMenuConfiguration config: UIContextMenuConfiguration, dismissalPreviewForItemAt ip: IndexPath) -> UITargetedPreview? { cardPreview(cv, ip) }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = ips.first, let cell = cv.cellForItem(at: ip) as? FeedCell, let item = cell.currentItem else { return nil }
        // on the post text, a long press selects words (the text view's own gesture)
        if cell.isOnText(cv.convert(point, to: cell)) { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            var top: [UIMenuElement] = []
            if !item.isLoose, let key = item.authorKey {
                top.append(UIAction(title: L("card.menu.onlyAuthor", item.authorDisplay), image: UIImage(systemName: "person.crop.circle")) { _ in self.onlyAuthor(key) })
                if let sn = item.screenName, let u = URL(string: "https://x.com/\(sn)") {
                    top.append(UIAction(title: L("card.menu.openProfile", sn), image: UIImage(systemName: "arrow.up.right.square")) { _ in UIApplication.shared.open(u) })
                }
            }
            var tagging: [UIMenuElement] = [
                UIAction(title: L("card.menu.tagMedia"), image: UIImage(systemName: "tag")) { _ in self.showTagPicker(item, post: cell.items, wholePost: false) },
            ]
            if !item.isLoose {
                tagging.append(UIAction(title: L("card.menu.tagPost"), image: UIImage(systemName: "square.stack")) { _ in self.showTagPicker(item, post: cell.items, wholePost: true) })
            }
            let pending = item.tags.filter { $0.isAI && !$0.isUser }
            if !pending.isEmpty {
                tagging.append(UIAction(title: L("card.menu.approveAll"), image: UIImage(systemName: "checkmark.seal")) { _ in
                    pending.forEach { try? Core.addTag($0.label, to: item.mediaId) }
                    self.reload(keepPosition: true)
                })
            }
            let taggers = ModelStore.shared.taggerIds
            if !taggers.isEmpty {
                let ref = Core.MediaRef(mediaId: item.mediaId, path: item.path, kind: item.kind.rawValue, text: item.text)
                // one entry per model (built-in or external), the default starred
                let perModel: [UIMenuElement] = taggers.map { id in
                    UIMenu(title: ModelStore.shared.displayName(id), image: UIImage(systemName: id == ModelStore.shared.activeTaggerId ? "star.fill" : ExternalModels.isExternal(id) ? "network" : "cpu"), children: [
                        UIAction(title: L("card.menu.retagAdd"), image: UIImage(systemName: "plus.circle")) { _ in AutoTagger.shared.retag([ref], model: id, replaceOld: false) },
                        UIAction(title: L("card.menu.retagReplace"), image: UIImage(systemName: "arrow.triangle.2.circlepath")) { _ in AutoTagger.shared.retag([ref], model: id, replaceOld: true) },
                    ])
                }
                tagging.append(taggers.count == 1
                    ? UIMenu(title: L("card.menu.retag"), image: UIImage(systemName: "sparkles"), children: (perModel.first as? UIMenu)?.children ?? [])
                    : UIMenu(title: L("card.menu.retag"), image: UIImage(systemName: "sparkles"), children: perModel))
            }
            if !item.tags.isEmpty {
                tagging.append(UIAction(title: L("card.menu.sources"), image: UIImage(systemName: "info.circle")) { _ in self.showSources(item) })
            }
            let perTag: [UIMenuElement] = item.tags.map { t in
                UIMenu(title: t.label, image: UIImage(systemName: t.isAI ? (t.isUser ? "checkmark.seal.fill" : "sparkles") : "tag"), children: self.tagActions(t, item: item))
            }
            var folderItems: [UIMenuElement] = [self.folderAddMenu(title: L("common.addToFolder"), image: "folder.badge.plus", media: [item.mediaId])]
            folderItems.append(self.folderAddMenu(title: L("card.menu.postToFolder"), image: "folder.fill.badge.plus", posts: [item.postId]))
            let inFolders = Core.mediaFolders(item.mediaId)
            if !inFolders.isEmpty {
                folderItems.append(UIMenu(title: L("common.removeFromFolder"), image: UIImage(systemName: "folder.badge.minus"), children: inFolders.map { f in
                    UIMenu(title: f, image: UIImage(systemName: "folder"), children: [
                        UIAction(title: L("card.menu.removeMedia")) { _ in _ = try? Core.removeFromFolder(f, media: [item.mediaId]); NotificationCenter.default.post(name: .libraryChanged, object: nil); self.reload(keepPosition: true) },
                        UIAction(title: L("card.menu.removePost")) { _ in _ = try? Core.removeFromFolder(f, posts: [item.postId]); NotificationCenter.default.post(name: .libraryChanged, object: nil); self.reload(keepPosition: true) },
                    ])
                }))
            }
            let redownload = UIAction(title: item.bad == nil ? L("card.menu.redownload") : L("card.menu.redownloadBad"), image: UIImage(systemName: "arrow.clockwise.icloud"),
                                      attributes: [], state: .off) { _ in self.repair(item) }
            var delete: [UIMenuElement] = []
            if !item.tags.isEmpty {
                delete.append(UIMenu(title: L("card.menu.deleteTag"), image: UIImage(systemName: "tag.slash"), children: item.tags.map { t in
                    UIAction(title: t.label, image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in self.deleteTag(t, from: item) }
                }))
            }
            delete.append(UIAction(title: L("card.menu.deleteMedia"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.deleteMedia([item]) })
            delete.append(UIAction(title: L("card.menu.deletePost"), image: UIImage(systemName: "trash.square"), attributes: .destructive) { _ in
                self.deletePost(item) })
            var children: [UIMenuElement] = []
            if !top.isEmpty { children.append(UIMenu(title: "", options: .displayInline, children: top)) }
            children.append(UIMenu(title: "", options: .displayInline, children: tagging))
            if !perTag.isEmpty { children.append(UIMenu(title: "", options: .displayInline, children: perTag)) }
            children.append(UIMenu(title: "", options: .displayInline, children: folderItems))
            if item.canRedownload { children.append(UIMenu(title: "", options: .displayInline, children: [redownload])) }
            children.append(UIMenu(title: "", options: .displayInline, children: delete))
            return UIMenu(children: children)
        })
    }

    /// Actions for one tag of one media (card menu and the tag chip's own long-press menu).
    private func tagActions(_ t: TagView, item: FeedItem) -> [UIMenuElement] {
        var acts: [UIMenuElement] = [
            UIAction(title: L("card.menu.onlyTag"), image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { [weak self] _ in self?.onlyLabel(t.label) },
            UIAction(title: L("card.menu.searchTag"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.addTerm(t.label) },
        ]
        if t.isAI && !t.isUser {
            acts.append(UIAction(title: L("card.menu.approve"), image: UIImage(systemName: "checkmark.seal")) { [weak self] _ in
                try? Core.addTag(t.label, to: item.mediaId); self?.reload(keepPosition: true)
            })
        }
        acts.append(UIAction(title: L("card.menu.renameTag"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.renameTag(t.label) })
        acts.append(UIAction(title: L("card.menu.deleteTag"), image: UIImage(systemName: "tag.slash"), attributes: .destructive) { [weak self] _ in self?.deleteTag(t, from: item) })
        return acts
    }

    // MARK: Folders

    /// Shows only one folder's media (nil = everything).
    func showFolder(_ name: String?) {
        filter.folder = name
        renderChips()
        reload()
    }

    /// "Add to folder" menu: existing folders plus a new one.
    private func folderAddMenu(title: String, image: String, media: [String] = [], posts: [String] = []) -> UIMenu {
        let pick = UIDeferredMenuElement.uncached { [weak self] done in
            var acts: [UIMenuElement] = Core.folders().map { f in
                UIAction(title: f.name, image: UIImage(systemName: "folder")) { _ in self?.addToFolder(f.name, media: media, posts: posts) }
            }
            acts.append(UIAction(title: L("common.newFolderEllipsis"), image: UIImage(systemName: "folder.badge.plus")) { _ in
                self?.askFolderName { name in self?.addToFolder(name, media: media, posts: posts) }
            })
            done(acts)
        }
        return UIMenu(title: title, image: UIImage(systemName: image), children: [pick])
    }

    private func addToFolder(_ name: String, media: [String], posts: [String]) {
        do {
            let receipt = try Core.action(.folderAdd, media: media, posts: posts, folder: name)
            let n = receipt.count
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            toast.show(n == 0 ? L("folder.already", name) : L("folder.added", n, name), action: n == 0 ? nil : L("common.undo")) { [weak self] in
                do { self?.toast.show(try Core.undo(receipt)) } catch { self?.toast.show(error.localizedDescription) }
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.reload(keepPosition: true)
            }
        } catch { alert(L("common.couldNotAddToFolder"), error.localizedDescription) }
    }

    func askFolderName(_ done: @escaping (String) -> Void) {
        let a = UIAlertController(title: L("common.newFolder"), message: nil, preferredStyle: .alert)
        a.addTextField { $0.placeholder = L("common.folderName") }
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("common.create"), style: .default) { _ in
            let n = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { done(n) }
        })
        present(a, animated: true)
    }

    // MARK: Renaming

    /// Renames a tag on every media (also merges into an existing tag of the new name).
    private func renameTag(_ old: String) {
        let a = UIAlertController(title: L("tag.rename.title", old), message: L("tag.rename.message"), preferredStyle: .alert)
        a.addTextField { $0.text = old; $0.clearButtonMode = .whileEditing; $0.accessibilityIdentifier = "renameField" }
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("common.rename"), style: .default) { [weak self] _ in
            let new = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new.lowercased() != old else { return }
            do {
                let name = try Core.renameTag(old, to: new)
                self?.replaceTerm(old, with: name)
                if let i = self?.filter.labels.firstIndex(of: old) { self?.filter.labels[i] = name }
                self?.renderChips()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.reload(keepPosition: true)
                self?.toast.show(L("tag.renamed", old, name))
            } catch { self?.alert(L("common.couldNotRename"), error.localizedDescription) }
        })
        present(a, animated: true)
    }

    // MARK: Filters, deletion, repair

    private func onlyAuthor(_ key: String) {
        filter.author = key
        renderChips()
        reload()
    }

    private func onlyLabel(_ label: String) {
        if !filter.labels.contains(label) { filter.labels.append(label) }
        renderChips()
        reload()
    }

    private func deleteTag(_ t: TagView, from item: FeedItem) {
        try? Core.removeTag(t.label, from: item.mediaId)
        reload(keepPosition: true)
        toast.show(L("tag.deleted", t.label), action: L("common.undo")) { [weak self] in
            // Put back the same origin (yours, AI, or endorsed).
            if t.isAI { try? Core.addTag(t.label, to: item.mediaId, ai: true) }
            if t.isUser { try? Core.addTag(t.label, to: item.mediaId) }
            self?.reload(keepPosition: true)
        }
    }

    private func deleteMedia(_ items: [FeedItem]) {
        do { afterDelete(try Core.action(.trash, media: items.map(\.mediaId))) }
        catch { toast.show(error.localizedDescription) }
    }

    private func deletePost(_ item: FeedItem) {
        do { afterDelete(try Core.action(.trash, posts: [item.postId])) }
        catch { toast.show(error.localizedDescription) }
    }

    private func afterDelete(_ receipt: Core.ActionReceipt) {
        guard receipt.count > 0 else { return }
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        reload(keepPosition: true)
        toast.show(L("trash.moved", receipt.count), action: L("common.undo")) { [weak self] in
            do { self?.toast.show(try Core.undo(receipt)) } catch { self?.toast.show(error.localizedDescription) }
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.reload(keepPosition: true)
        }
    }

    private func repair(_ item: FeedItem) {
        let overlay = BusyOverlay(title: L("common.redownloading"))
        overlay.show(in: view)
        Task.detached(priority: .userInitiated) {
            let r = Result { try Core.repair(item.mediaId) }
            await MainActor.run {
                overlay.dismiss {}
                switch r {
                case .success(.replaced): self.toast.show(L("repair.fixed"))
                case .success(.replacedNew): self.alert(L("repair.replacedNew.title"), L("repair.replacedNew.message"))
                case .success(.fromPeers): self.alert(L("repair.fromPeers.title"), L("repair.fromPeers.message"))
                case .failure(let e): self.alert(L("repair.failed"), e.localizedDescription)
                }
                MediaLoader.shared.forget(item)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self.reload(keepPosition: true)
            }
        }
    }

    private func alert(_ title: String, _ message: String? = nil) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
        present(a, animated: true)
    }

    func feedCellDidTapAddTag(_ cell: FeedCell) {
        guard let item = cell.currentItem else { return }
        showTagPicker(item, post: cell.items, wholePost: false)
    }

    /// The tag adder (search, existing tags, create): from the "+" chip and from the long-press
    /// menu's "添加标签" items alike.
    private func showTagPicker(_ item: FeedItem, post: [FeedItem], wholePost: Bool) {
        guard let scope = try? Core.postScope(item.postId) else { alert(L("post.unreadable.title"), L("common.tryAgain")); return }
        let model = TagPickerModel(media: item, scope: scope, wholePost: wholePost)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(TagPickerView(model: model) { [weak self, weak host] in
            host?.dismiss(animated: true)
            self?.reload(keepPosition: true)
        })
        // the sheet's glass shows through the list
        host.view.backgroundColor = .clear
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    private func showSources(_ item: FeedItem) {
        let vc = TagSourcesViewController(item: item)
        let nav = UINavigationController(rootViewController: vc)
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        present(nav, animated: true)
    }

}

/// Full-width divider at the end of the feed: "共 12 条帖子，已经到底".
final class FeedEndView: UICollectionReusableView {
    static let kind = "feed-end"
    static let height: CGFloat = 64
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let left = UIView(), right = UIView()
        [left, right].forEach { $0.backgroundColor = .separator; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityIdentifier = "feedEnd"
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.centerYAnchor.constraint(equalTo: centerYAnchor), right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.heightAnchor.constraint(equalToConstant: 1), right.heightAnchor.constraint(equalToConstant: 1),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -12),
            right.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12), right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, grouped: Bool) {
        let a = NSMutableAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "checkmark.circle")!.withTintColor(.secondaryLabel)))
        a.append(NSAttributedString(string: "  " + L(grouped ? "feed.end.posts" : "feed.end.media", count)))
        label.attributedText = a
        accessibilityLabel = label.text
    }
}

/// Short message above the bottom bar with an optional action (e.g. undo).
final class ToastView: UIView {
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 18
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 2
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        button.tintColor = .systemYellow
        button.addAction(UIAction { [weak self] _ in self?.action?(); self?.hide() }, for: .touchUpInside)
        button.accessibilityIdentifier = "toastAction"
        let st = UIStackView(arrangedSubviews: [label, button])
        st.spacing = 14
        st.alignment = .center
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            st.topAnchor.constraint(equalTo: topAnchor, constant: 12), st.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            st.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), st.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        alpha = 0
        isHidden = true
        accessibilityIdentifier = "toast"
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, action title: String? = nil, _ action: (() -> Void)? = nil) {
        label.text = text
        button.setTitle(title, for: .normal)
        button.isHidden = title == nil
        self.action = action
        hideWork?.cancel()
        isHidden = false
        superview?.bringSubviewToFront(self)
        transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.5) { self.alpha = 1; self.transform = .identity }
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: { self.alpha = 0 }) { _ in self.isHidden = true; self.action = nil }
    }
}


/// A view whose visibility another view follows (the search bar and its separate chip row).
final class FollowedView: UIView {
    weak var follower: UIView?
    override var alpha: CGFloat { didSet { follower?.alpha = alpha } }
    override var isHidden: Bool { didSet { follower?.isHidden = isHidden } }
}


/// The 浏览 grid: cards as tall as their content in columns (as many as the width allows, each
/// card in the shortest column), and the footer at the end.
/// The placement is `FeedMasonry` (shared with the Mac).
/// A button of the search row: a round plate, filled while on (as in Control Center). The symbol
/// stays the same in both states and is never a filled or circled one: inside a round plate those
/// read as a circle in a circle.
final class RoundSearchButton: UIControl {
    private let icon = UIImageView()
    private let circle = UIView()
    private let onValue: String?, offValue: String?

    var isOn = false { didSet { update() } }

    init(symbol: String, label: String, identifier: String, onValue: String? = nil, offValue: String? = nil) {
        self.onValue = onValue
        self.offValue = offValue
        super.init(frame: .zero)
        circle.isUserInteractionEnabled = false
        circle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(circle)
        icon.image = UIImage(systemName: symbol)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(equalToConstant: 44),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor), circle.centerYAnchor.constraint(equalTo: centerYAnchor),
            circle.widthAnchor.constraint(equalToConstant: 36), circle.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        circle.layer.cornerRadius = 18
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityIdentifier = identifier
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        circle.backgroundColor = isOn ? .tintColor : .tertiarySystemFill
        icon.tintColor = isOn ? .white : .label
        accessibilityTraits = isOn ? [.button, .selected] : .button
        accessibilityValue = isOn ? onValue : offValue
    }

    override func tintColorDidChange() { super.tintColorDidChange(); update() }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }
}

final class FeedMasonryLayout: UICollectionViewLayout {
    /// The height of entry `i` at a column width.
    var height: ((Int, CGFloat) -> CGFloat)?
    private var plan: FeedMasonry?
    private var dirty = true
    private var passes = 0

    /// The entries changed (new order, other text, grouping): heights are read again.
    func invalidateHeights() { dirty = true; invalidateLayout() }

    /// One card is this tall now. Returns how much a pass of the grid grew.
    func resize(item: Int, height: CGFloat) -> CGFloat {
        let grown = plan?.resize(item: item, height: height) ?? 0
        invalidateLayout()
        return grown
    }

    /// The width the cards may use: the view less its safe area at the sides (a floating tab
    /// rail, a notch in landscape), which the collection view adds to its content insets.
    private func usableWidth(_ cv: UICollectionView) -> CGFloat {
        max(0, cv.bounds.width - cv.adjustedContentInset.left - cv.adjustedContentInset.right)
    }

    private func metrics(_ cv: UICollectionView) -> FeedMasonry.Metrics {
        let width = usableWidth(cv)
        let columns = LibraryPrefs.feedColumns(width: width, height: cv.bounds.height, base: 400, maxColumns: 4)
        return FeedMasonry.Metrics(width: width, columns: columns, side: width > 700 ? 24 : 12, columnGap: 14, rowGap: 18, footer: FeedEndView.height)
    }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        passes = cv.numberOfSections
        let count = passes > 0 ? cv.numberOfItems(inSection: 0) : 0
        let m = metrics(cv)
        if dirty || plan?.metrics != m || plan?.frames.count != count {
            plan = FeedMasonry(count: count, metrics: m) { [weak self] i, w in self?.height?(i, w) ?? w * 1.25 }
            dirty = false
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView.map(usableWidth) ?? 0, height: plan?.contentHeight(passes: passes) ?? 0)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let plan else { return [] }
        let found = plan.elements(in: rect, passes: passes)
        var out = found.items.map { e -> UICollectionViewLayoutAttributes in
            let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: e.item, section: e.pass))
            a.frame = plan.frame(item: e.item, pass: e.pass)
            return a
        }
        for s in found.footers { if let a = layoutAttributesForSupplementaryView(ofKind: FeedEndView.kind, at: IndexPath(item: 0, section: s)) { out.append(a) } }
        return out
    }

    override func layoutAttributesForItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let plan, ip.item < plan.frames.count, ip.section < passes else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: ip)
        a.frame = plan.frame(item: ip.item, pass: ip.section)
        return a
    }

    override func layoutAttributesForSupplementaryView(ofKind kind: String, at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let plan, ip.section < passes else { return nil }
        let a = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: kind, with: ip)
        a.frame = plan.footerFrame(pass: ip.section)
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let cv = collectionView else { return false }
        return abs(newBounds.width - cv.bounds.width) > 0.5
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        // a batch update (cards removed, a pass appended) changes what is placed where
        if context.invalidateDataSourceCounts || context.invalidateEverything { dirty = true }
        super.invalidateLayout(with: context)
    }
}

private final class QuickDownloadDraft: ObservableObject {
    @Published var links = ""
}

private struct QuickDownloadPopover: View {
    @ObservedObject var draft: QuickDownloadDraft
    let width: CGFloat
    let openSettings: () -> Void
    let download: () -> Void

    var body: some View {
        QuickDownloadCard(links: $draft.links, width: width, openSettings: openSettings, download: download)
    }
}

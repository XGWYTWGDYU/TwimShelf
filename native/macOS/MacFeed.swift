import AppKit
import SwiftUI
import AVFoundation

/// One card: media pager above the caption (author, text, link, tags).
final class FeedCard: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("FeedCard")
    static let mediaRatio: CGFloat = 1.25

    var onOpen: ((FeedItem) -> Void)?
    var onTag: ((String) -> Void)?
    var onAddTag: ((FeedCard, NSView, NSRect) -> Void)?
    var onRecent: (() -> Void)?
    var onPage: (() -> Void)?
    /// Right-click menu of a tag pill.
    var menuForTag: ((TagView, FeedItem) -> NSMenu?)?
    private(set) var items: [FeedItem] = []
    private(set) var page = 0

    let mediaView = SwipeMediaView()
    let mediaImage = ImageLayerView()
    let playerLayer = AVPlayerLayer()
    private let playBadge = NSImageView()
    private let badBadge = NSTextField(labelWithString: L("card.badge.damaged"))
    private let counter = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let author = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let link = NSButton()
    let tagScroll = MacHScroll()
    private var tags: TagStripView { tagScroll.strip }

    var current: FeedItem? { items.indices.contains(page) ? items[page] : nil }

    override func loadView() {
        let root = MacCardView()
        view = root

        mediaView.wantsLayer = true
        mediaView.layer?.cornerRadius = 18
        mediaView.layer?.cornerCurve = .continuous
        mediaView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        mediaView.layer?.masksToBounds = true
        // a quiet neutral behind images that do not fill the frame (black bars looked like a broken image)
        mediaView.layer?.backgroundColor = MacCardView.mediaFill.cgColor
        playerLayer.videoGravity = .resizeAspect
        mediaView.layer?.addSublayer(playerLayer)
        playBadge.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: L("place.videos"))
        playBadge.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        playBadge.contentTintColor = .white.withAlphaComponent(0.9)
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        counter.textColor = .white
        counter.wantsLayer = true
        counter.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        counter.layer?.cornerRadius = 8
        for (b, sym, sel) in [(prevButton, "chevron.left.circle.fill", #selector(prev)), (nextButton, "chevron.right.circle.fill", #selector(next))] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            b.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            b.contentTintColor = .white.withAlphaComponent(0.85)
            b.target = self; b.action = sel
        }
        badBadge.font = .systemFont(ofSize: 11, weight: .bold)
        badBadge.textColor = .white
        badBadge.wantsLayer = true
        badBadge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        badBadge.layer?.cornerRadius = 8
        badBadge.isHidden = true
        badBadge.setAccessibilityIdentifier("badBadge")
        [mediaImage, playBadge, counter, prevButton, nextButton, badBadge].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; mediaView.addSubview($0) }

        author.font = .systemFont(ofSize: 13, weight: .semibold)
        author.lineBreakMode = .byTruncatingTail
        body.font = MacCardLayout.bodyFont
        // the whole text: the card is as tall as it needs
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 11)
        link.alignment = .left
        link.lineBreakMode = .byTruncatingMiddle
        link.target = self; link.action = #selector(openLink)
        tags.sideInset = 14
        tags.onTag = { [weak self] l in self?.onTag?(l) }
        tags.onRecent = { [weak self] in self?.onRecent?() }
        tags.onAdd = { [weak self] v, r in if let self { self.onAddTag?(self, v, r) } }
        tags.menuForTag = { [weak self] t in self?.current.flatMap { it in self?.menuForTag?(t, it) } }
        // laid out by hand (`MacCardLayout`): the grid knows every card's height without laying it out
        [mediaView, author, body, link, tagScroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = true; root.addSubview($0) }
        NSLayoutConstraint.activate([
            mediaImage.topAnchor.constraint(equalTo: mediaView.topAnchor), mediaImage.bottomAnchor.constraint(equalTo: mediaView.bottomAnchor),
            mediaImage.leadingAnchor.constraint(equalTo: mediaView.leadingAnchor), mediaImage.trailingAnchor.constraint(equalTo: mediaView.trailingAnchor),
            playBadge.centerXAnchor.constraint(equalTo: mediaView.centerXAnchor), playBadge.centerYAnchor.constraint(equalTo: mediaView.centerYAnchor),
            counter.topAnchor.constraint(equalTo: mediaView.topAnchor, constant: 10), counter.trailingAnchor.constraint(equalTo: mediaView.trailingAnchor, constant: -10),
            badBadge.topAnchor.constraint(equalTo: mediaView.topAnchor, constant: 10), badBadge.leadingAnchor.constraint(equalTo: mediaView.leadingAnchor, constant: 10),
            prevButton.leadingAnchor.constraint(equalTo: mediaView.leadingAnchor, constant: 8), prevButton.centerYAnchor.constraint(equalTo: mediaView.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: mediaView.trailingAnchor, constant: -8), nextButton.centerYAnchor.constraint(equalTo: mediaView.centerYAnchor),
        ])
        mediaView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        // Two-finger horizontal swipe over the media flips through a post's pages.
        mediaView.onSwipe = { [weak self] forward in
            guard let self, self.items.count > 1 else { return false }
            if forward { self.next() } else { self.prev() }
            return true
        }
    }

    /// The white part of the card under a layer of glass, its lower corners the card's (one per
    /// card, created once).
    private lazy var captionGlass: NSView? = {
        guard #available(macOS 26.0, *), ProcessInfo.processInfo.environment["TL_NO_CARD_GLASS"] == nil else { return nil }
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 18
        clip.layer?.cornerCurve = .continuous
        clip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clip.layer?.masksToBounds = true
        let g = NSGlassEffectView()
        g.cornerRadius = 0
        // past the clip's sides and bottom: the glass's own rim light would show there as a line
        g.frame = NSRect(x: -3, y: -3, width: 6, height: 6)
        g.autoresizingMask = [.width, .height]
        clip.addSubview(g)
        view.addSubview(clip, positioned: .above, relativeTo: mediaView)
        return clip
    }()

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        if baseWidth != b.width || base == nil { base = MacCardLayout(item: items.first, width: b.width); baseWidth = b.width }
        guard let base else { return }
        // the media takes what the card has above its caption: the grid says how tall the card is
        let l = base.withMedia(height: b.height - base.captionHeight)
        // AppKit's y runs upwards: every part placed from the top edge
        func top(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: b.height - r.maxY, width: r.width, height: r.height) }
        mediaView.frame = top(CGRect(x: 0, y: 0, width: b.width, height: l.mediaHeight))
        captionGlass?.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - l.mediaHeight)
        author.frame = l.author.map(top) ?? .zero
        body.frame = l.body.map(top) ?? .zero
        link.frame = l.link.map(top) ?? .zero
        tagScroll.frame = NSRect(x: 0, y: MacCardLayout.bottom, width: b.width, height: MacCardLayout.tagsHeight)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = mediaView.bounds
        view.effectiveAppearance.performAsCurrentDrawingAppearance { mediaView.layer?.backgroundColor = MacCardView.mediaFill.cgColor }
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playerLayer.player = nil
        mediaImage.image = nil
        MacMediaLoader.shared.cancel(imageToken); imageToken = nil
        tagScroll.scrollToStart()
        // forget what was shown: a reused card must load its image again (refresh() keeps the
        // image only for a card that is still on screen)
        items = []
    }

    static let decodePixels: CGFloat = 900
    private var imageToken: MacMediaLoader.Token?

    /// The page the next `configure` opens on.
    var startPage = 0
    /// The card's parts at this width, with the first page's height (measuring text is slow, and
    /// this is laid out on every frame while the card changes height).
    private var base: MacCardLayout?
    private var baseWidth: CGFloat = 0
    /// All of the card but its media, at its width.
    var captionHeight: CGFloat { base?.captionHeight ?? 0 }

    func configure(_ items: [FeedItem]) {
        self.items = items
        tagScroll.scrollToStart()
        page = min(max(startPage, 0), max(items.count - 1, 0))
        base = nil
        view.needsLayout = true
        show()
    }

    /// Same media as shown: update tags, text and badges in place (no image reload; the page and
    /// an inline video keep going). Otherwise a full configure.
    #if DEBUG
    var debugHasImage: Bool { mediaImage.image != nil }
    #endif

    func refresh(_ items: [FeedItem]) {
        guard !items.isEmpty, items.map(\.mediaId) == self.items.map(\.mediaId) else { return configure(items) }
        self.items = items
        base = nil
        view.needsLayout = true
        if let it = current { badBadge.isHidden = it.bad == nil; badBadge.stringValue = " \(it.badText ?? "") " }
        showCaption()
    }

    var showsInlineVideo = false { didSet { playBadge.isHidden = current?.kind != .video || showsInlineVideo } }

    private func show() {
        guard let it = current else { return }
        playerLayer.player = nil
        showsInlineVideo = false
        MacMediaLoader.shared.cancel(imageToken)
        let id = it.mediaId
        badBadge.isHidden = it.bad == nil
        badBadge.stringValue = " \(it.badText ?? "") "
        // a decoded picture is shown in the same frame; one decoded later fades in, instead of
        // popping onto an empty card
        let cached = MacMediaLoader.shared.isCached(it, maxPixel: Self.decodePixels)
        mediaImage.image = nil
        imageToken = MacMediaLoader.shared.load(it, maxPixel: Self.decodePixels) { [weak self] img in
            if img == nil { MacMediaLoader.shared.reportIfBroken(it) }
            guard let self, self.current?.mediaId == id else { return }
            if !cached {
                let fade = CATransition(); fade.type = .fade; fade.duration = 0.15
                self.mediaImage.layer?.add(fade, forKey: "fade")
            }
            self.mediaImage.image = img
            self.imageToken = nil
        }
        showCaption()
    }

    /// The words being searched for, highlighted in the fields that were searched.
    var highlight = SearchMarks.none { didSet { if highlight != oldValue { showCaption() } } }
    static let highlightAttrs: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45)]

    private func marked(_ text: String, _ terms: [String], font: NSFont?, color: NSColor) -> NSAttributedString {
        let a = NSMutableAttributedString(string: text, attributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: color])
        SearchHighlight.apply(terms, to: a, Self.highlightAttrs)
        return a
    }

    /// Counter, page buttons, author, text, link and tags of the current media.
    private func showCaption() {
        guard let it = current else { return }
        let multi = items.count > 1
        counter.isHidden = !multi
        counter.stringValue = " \(page + 1)/\(items.count) "
        prevButton.isHidden = !multi || page == 0
        nextButton.isHidden = !multi || page == items.count - 1
        var a = it.authorName ?? ""
        if let sn = it.screenName { a += (a.isEmpty ? "" : "  ") + "@\(sn)" }
        if it.isLoose { a = "◌ " + (it.isAlbum ? L("card.album") : L("card.loose")) }
        author.attributedStringValue = marked(a, highlight.author, font: author.font, color: it.isLoose ? .systemIndigo : .labelColor)
        author.isHidden = a.isEmpty
        body.isSelectable = true   // the text can be selected and copied
        body.attributedStringValue = marked(it.text ?? "", highlight.text, font: body.font, color: body.textColor ?? .labelColor)
        body.isHidden = (it.text ?? "").isEmpty
        link.title = it.url ?? ""
        link.isHidden = it.url == nil
        tags.set(it.tags, recent: it.isRecent, highlight: highlight.tags)
        tagScroll.needsLayout = true
        view.needsLayout = true
    }

    /// Turns to a page without animation (a media shown from elsewhere).
    func show(page p: Int) {
        guard items.indices.contains(p), p != page else { return }
        page = p
        show()
        onPage?()
    }

    /// A short glow around the card: "this one".
    func flash() {
        guard let l = view.layer else { return }
        let ring = CALayer()
        ring.frame = view.bounds.insetBy(dx: 1.5, dy: 1.5)
        ring.cornerRadius = l.cornerRadius
        ring.cornerCurve = .continuous
        ring.borderWidth = 3
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.zPosition = 50
        l.addSublayer(ring)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1; a.toValue = 0
        a.beginTime = CACurrentMediaTime() + 0.9
        a.duration = 0.6
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        ring.add(a, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { ring.removeFromSuperlayer() }
    }

    @objc private func prev() { if page > 0 { page -= 1; slide(forward: false); show(); onPage?() } else { bounce() } }
    @objc private func next() { if page < items.count - 1 { page += 1; slide(forward: true); show(); onPage?() } else { bounce() } }

    private func slide(forward: Bool) {
        let t = CATransition()
        t.type = .push
        t.subtype = forward ? .fromRight : .fromLeft
        t.duration = 0.22
        t.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mediaView.layer?.add(t, forKey: "page")
    }

    /// At the first/last page: a small shake instead of nothing.
    private func bounce() {
        guard items.count > 1 else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -8, 6, -3, 0]
        a.duration = 0.25
        mediaImage.layer?.add(a, forKey: "bounce")
    }
    @objc private func clicked() { if let c = current { onOpen?(c) } }
    @objc private func openLink() { if let s = current?.url, let u = URL(string: s) { NSWorkspace.shared.open(u) } }

}

/// Where the parts of a Mac card go (the same numbers for the grid's heights and the card's
/// layout): media 4:5, then author, the whole text and the link — each only when the post has
/// it — then the tag row. As on iOS (`CardLayout`).
struct MacCardLayout {
    static let side: CGFloat = 14, captionTop: CGFloat = 10, gap: CGFloat = 5, authorHeight: CGFloat = 17, linkHeight: CGFloat = 16
    static let tagsGap: CGFloat = 8, tagsHeight: CGFloat = 20, bottom: CGFloat = 14
    static let bodyFont = NSFont.systemFont(ofSize: 13)

    private(set) var mediaHeight: CGFloat
    var author: CGRect?
    var body: CGRect?
    var link: CGRect?
    private(set) var height: CGFloat
    /// All of the card but its media.
    var captionHeight: CGFloat { height - mediaHeight }

    /// The same card with its media this tall.
    func withMedia(height h: CGFloat) -> MacCardLayout {
        var l = self
        let d = h - mediaHeight
        l.mediaHeight = h
        l.height += d
        l.author = author?.offsetBy(dx: 0, dy: d)
        l.body = body?.offsetBy(dx: 0, dy: d)
        l.link = link?.offsetBy(dx: 0, dy: d)
        return l
    }

    init(item it: FeedItem?, width w: CGFloat) {
        mediaHeight = (w * (it?.cardMediaRatio ?? FeedCard.mediaRatio)).rounded()
        var y = mediaHeight + Self.captionTop
        let inner = w - Self.side * 2
        var gap: CGFloat = 0
        if let it, it.isLoose || it.authorName != nil || it.screenName != nil {
            author = CGRect(x: Self.side, y: y, width: inner, height: Self.authorHeight)
            y += Self.authorHeight
            gap = Self.gap
        }
        if let text = it?.text, !text.isEmpty {
            y += gap
            let h = Self.textHeight(text, width: inner)
            body = CGRect(x: Self.side, y: y, width: inner, height: h)
            y += h
            gap = Self.gap
        }
        if it?.url != nil {
            y += gap
            link = CGRect(x: Self.side, y: y, width: inner, height: Self.linkHeight)
            y += Self.linkHeight
        }
        if author == nil && body == nil && link == nil { y = mediaHeight }
        height = ceil(y + Self.tagsGap + Self.tagsHeight + Self.bottom)
    }

    /// The text's height as the card's wrapping label lays it out (one label kept for measuring).
    private static let probe: NSTextField = {
        let f = NSTextField(wrappingLabelWithString: "")
        f.font = bodyFont
        f.maximumNumberOfLines = 0
        f.lineBreakMode = .byWordWrapping
        return f
    }()
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        probe.stringValue = text
        return ceil(probe.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 17)
    }
}

/// Main window content: highlighted search chips, then the random card grid, shown once to its end.
final class MacFeedViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
    /// Settings asks the feed to show one folder (object: name, or nil for everything).
    static let showFolderNote = Notification.Name("MacShowFolder")
    /// object = a tag label: show only media with that tag.
    static let showLabelNote = Notification.Name("MacShowLabel")
    private var allItems: [FeedItem] = []
    private var entries: [[FeedItem]] = []
    /// The search, from the toolbar's token field (as on iOS): texts, tag source, fields, and
    /// the conditions 文件夹 / 最近 / 外部导入.
    private(set) var query = TokenQuery() { didSet { collection.visibleItems().forEach { ($0 as? FeedCard)?.highlight = query.marks } } }
    var terms: [String] { query.terms }
    /// Settings → 语义模糊搜索.
    var fuzzy: Bool { LibraryPrefs.fuzzySearch }
    /// A tag clicked on a card (or L("card.menu.searchTag")) goes into the toolbar's search field.
    var onSearchTag: ((String) -> Void)?
    /// A tag was renamed: the search field's capsule follows.
    var onRenameTerm: ((String, String) -> Void)?
    /// Ends the toolbar's search (`reveal` shows a media the search hid).
    var onClearSearch: (() -> Void)?
    /// A media to show once the next result is on screen (`reveal`).
    private var pendingReveal: FeedItem?
    var grouped = UserDefaults.standard.object(forKey: "grouped") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(grouped, forKey: "grouped"); rebuildEntries(); masonry.invalidateHeights(); collection.reloadData(); updateInline()
            // a search finds whole posts only as post cards
            if !terms.isEmpty || !currentFilter.isEmpty { reload(keepPosition: true) }
        }
    }
    /// Random order from the system RNG; ranks survive reloads until the next reshuffle.
    private var order = FeedOrder()
    /// "Only this author" / "only this tag" filters set from the right-click menus.
    private var filter = FeedFilter()
    private var sectionCount: Int { entries.isEmpty ? 0 : 1 }
    private let toast = MacToast()
    /// Position in the unfiltered feed before a search/filter, restored when it is closed.
    private var savedBrowse: NSPoint?
    private var lastUnfiltered = true
    /// The player or photo viewer covering the feed (nil when browsing).
    private var viewer: NSView?
    /// A player that went to picture in picture: kept alive while its floating window plays.
    private var pipPlayer: MacPlayerView?

    private let scroll = NSScrollView()
    private let collection = ResizingFeedCollectionView()
    private let chipBar = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let activityPanel = MacActivityPanel()
    private let inlinePlayer = AVPlayer()
    private weak var inlineCard: FeedCard?
    private var generation = 0

    override func loadView() {
        // one background from the window's top edge down, under the toolbar and the chip row
        let root = MacOpaqueView(color: MacCardView.feedBackground)
        let layout = masonry
        layout.height = { [weak self] i, w in
            guard let self, i < self.entries.count else { return w * FeedCard.mediaRatio }
            let e = self.entries[i]
            self.cardHeights.prepare(width: w, sizeKey: "")
            let key = self.entryKey(e)
            let caption = self.cardHeights.height(key + "#\(e.first?.cardContentKey ?? 0)") { MacCardLayout(item: e.first, width: w).captionHeight }
            return caption + cardMediaHeight(e, width: w, position: CGFloat(self.cardPages.page(of: key, count: e.count)))
        }
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [MacCardView.feedBackground]
        collection.register(FeedCard.self, forItemWithIdentifier: FeedCard.id)
        collection.register(MacFeedEnd.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter, withIdentifier: MacFeedEnd.id)
        let menu = NSMenu()
        menu.delegate = self
        collection.menu = menu
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.stringValue = ActivityCenter.shared.statsLine
        statsLabel.isHidden = true      // the window's subtitle shows it now
        NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statsLabel.stringValue = ActivityCenter.shared.statsLine }
        }
        chipBar.orientation = .horizontal
        chipBar.spacing = 8
        chipBar.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)
        [chipBar, scroll, emptyLabel, statsLabel, activityPanel, toast].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            chipBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chipBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            statsLabel.centerYAnchor.constraint(equalTo: chipBar.centerYAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            chipBar.trailingAnchor.constraint(lessThanOrEqualTo: statsLabel.leadingAnchor, constant: -10),
            activityPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            activityPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        view = root
        inlinePlayer.isMuted = true
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? AVPlayerItem) === self.inlinePlayer.currentItem else { return }
            self.inlinePlayer.seek(to: .zero); self.inlinePlayer.play()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: .libraryChanged, object: nil)
        NotificationCenter.default.addObserver(forName: LibraryPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderChips(); self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: Self.showLabelNote, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let l = n.object as? String else { return }
                self.filter.labels = [l]
                self.renderChips(); self.reload()
            }
        }
        NotificationCenter.default.addObserver(forName: Self.showFolderNote, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.showFolder(n.object as? String); self?.view.window?.makeKeyAndOrderFront(nil) }
        }
        NotificationCenter.default.addObserver(forName: SyncService.warning, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let text = n.userInfo?["text"] as? String else { return }
                if n.userInfo?["settings"] as? Bool == true {
                    self.toast.show(text, action: L("feed.openSystemSettings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!) }
                } else { self.toast.show(text) }
            }
        }
        renderChips()
        reload()
    }

    /// Card heights by entry (measuring post text is the costly part of laying out the grid).
    private let cardHeights = CardHeightCache()
    private let masonry = MacFeedMasonryLayout()

    private func entryKey(_ e: [FeedItem]) -> String { (grouped ? e.first?.postId : e.first?.mediaId) ?? "" }

    /// After a change in the library, updates the grid without reloading it: removed cards fade
    /// out, changed cards update in place (no flash, no lost position). False when
    /// cards were added or reordered; the caller then reloads.
    private func incrementalUpdate(from old: [[FeedItem]]) -> Bool {
        guard !old.isEmpty, !entries.isEmpty, collection.numberOfSections == 1,
              collection.numberOfItems(inSection: 0) == old.count else { return false }
        let oldKeys = old.map(entryKey), newKeys = entries.map(entryKey)
        let keep = Set(newKeys)
        guard oldKeys.filter({ keep.contains($0) }) == newKeys else { return false }
        let removed = oldKeys.indices.filter { !keep.contains(oldKeys[$0]) }
        if !removed.isEmpty {
            let ips = Set(removed.map { IndexPath(item: $0, section: 0) })
            // The grid finishes any pending layout before a batch, asking for cards at their old
            // places: they have to get the old entries, or a card moves up showing the next one's.
            let fresh = entries
            entries = old
            collection.layoutSubtreeIfNeeded()
            collection.animator().performBatchUpdates({
                entries = fresh
                collection.deleteItems(at: ips)
            })
        }
        let oldByKey = Dictionary(old.map { (entryKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        for ip in collection.indexPathsForVisibleItems() where ip.item < entries.count && oldByKey[entryKey(entries[ip.item])] != entries[ip.item] {
            (collection.item(at: ip) as? FeedCard)?.refresh(entries[ip.item])
        }
        return true
    }

    // MARK: Data

    private var currentFilter: FeedFilter {
        var f = filter
        if LibraryPrefs.badOnly { f.badOnly = true }
        return query.filter(over: f)
    }

    private let reloadWork = LatestWork()
    private let sizesWatcher = MediaSizesWatcher()
    #if DEBUG
    /// The debug tour: turns the card with the most pages to its end and back; reports its height
    /// on each frame (it must move smoothly to each page's height) and where the card under it is.
    func debugCardPages(_ report: @escaping (String) -> Void) {
        guard let ip = collection.indexPathsForVisibleItems().filter({ (collection.item(at: $0) as? FeedCard)?.items.count ?? 0 > 1 }).min(), let card = collection.item(at: ip) as? FeedCard else { return report("no card with pages") }
        var log = "pages \(card.items.map { "\($0.width)x\($0.height)" }) width \(Int(card.view.bounds.width)):"
        var sampled: [Int] = []
        let sampler = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in sampled.append(Int(card.view.bounds.height)) }
        RunLoop.main.add(sampler, forMode: .common)
        func stop(_ i: Int) {
            guard i < card.items.count else {
                sampler.invalidate()
                card.show(page: 0)
                return report(log)
            }
            sampled.removeAll()
            card.show(page: i)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                let w = card.view.bounds.width
                let want = card.captionHeight + cardMediaHeight(card.items, width: w, position: CGFloat(i))
                var steps: [Int] = []
                for v in sampled where steps.last != v { steps.append(v) }
                log += " p\(i) got \(Int(card.view.bounds.height)) want \(Int(want)) mediaGapFree \(abs(card.mediaView.bounds.height - ceil(w * card.items[i].cardMediaRatio)) < 1.5) frames \(steps.count);"
                stop(i + 1)
            }
        }
        stop(1)
    }
    #endif

    private var cardPages = CardPages()
    private var resizing: [(card: FeedCard, from: CGFloat, to: CGFloat, start: CFTimeInterval)] = []
    private var resizeTimer: Timer?

    /// A card turned its page: it goes to that page's height with a spring, and the cards under it
    /// move along.
    private func pageChanged(_ card: FeedCard) {
        cardPages.set(card.page, for: entryKey(card.items))
        let width = card.view.bounds.width
        guard width > 0 else { return }
        resizing.removeAll { $0.card === card }
        let to = card.captionHeight + cardMediaHeight(card.items, width: width, position: CGFloat(card.page))
        resizing.append((card, card.view.bounds.height, to, CACurrentMediaTime()))
        guard resizeTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.resizeStep() } }
        RunLoop.main.add(t, forMode: .common)
        resizeTimer = t
    }

    private func resizeStep() {
        let now = CACurrentMediaTime()
        for r in resizing {
            guard let ip = collection.indexPath(for: r.card) else { continue }
            // critically damped: quick at first, settling without a bounce
            let x = (now - r.start) * 16
            let done = x > 7
            let h = done ? r.to : r.from + (r.to - r.from) * CGFloat(1 - (1 + x) * exp(-x))
            let grown = masonry.resize(item: ip.item, height: h)
            // later passes move with the pass's height: what is on screen stays where it is
            if grown != 0, ip.section > 0, let clip = collection.enclosingScrollView?.contentView {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + grown * CGFloat(ip.section)))
            }
        }
        resizing.removeAll { (now - $0.start) * 16 > 7 || collection.indexPath(for: $0.card) == nil }
        collection.layoutSubtreeIfNeeded()
        if resizing.isEmpty { resizeTimer?.invalidate(); resizeTimer = nil }
    }

    func reload(keepPosition: Bool = false) {
        generation += 1
        let gen = generation
        let f = currentFilter
        let activeFilter = f
        let fields = query.searchFields
        var req = FeedRequest(terms: terms, scope: query.scope, newestFirst: LibraryPrefs.feedByAdded, fuzzy: fuzzy, fields: fields, filter: activeFilter, wholePosts: grouped)
        // a search that asks for something and its opposite finds nothing, without asking the core
        let contradictory = query.isContradictory
        let wantsVectors = !contradictory && fuzzy && (fields.tags || fields.text || !fields.author) && !terms.isEmpty && ModelStore.shared.activeEmbedderId != nil
        reloadWork.submit { [weak self] isCurrent in
            guard let self, isCurrent() else { return }
            if wantsVectors, let q = await AIEngine.shared.queryVectors(req.terms) { req.termVectors = q.vectors; req.embedModel = q.model }
            guard isCurrent() else { return }
            let items = contradictory ? [] : await Task.detached(priority: .userInitiated) { (try? Core.feed(req)) ?? [] }.value
            guard gen == self.generation else { return }
            self.shownGeneration = gen
            self.sizesWatcher.watch(items) { [weak self] in self?.reload(keepPosition: true) }
            defer {
                if let r = self.pendingReveal {
                    self.pendingReveal = nil
                    DispatchQueue.main.async { self.scrollTo(r) }
                }
            }
            let nowUnfiltered = self.terms.isEmpty && activeFilter.isEmpty && !contradictory
            if self.lastUnfiltered && !nowUnfiltered { self.savedBrowse = self.scroll.contentView.bounds.origin }
            let restore = !self.lastUnfiltered && nowUnfiltered ? self.savedBrowse : nil
            if restore != nil { self.savedBrowse = nil }
            self.lastUnfiltered = nowUnfiltered
            let oldEntries = self.entries
            self.allItems = LibraryPrefs.feedByAdded ? items : self.order.apply(items)
            self.rebuildEntries()
            self.masonry.invalidateHeights()
            if keepPosition, restore == nil, self.incrementalUpdate(from: oldEntries) {
                self.emptyLabel.isHidden = !items.isEmpty
                DispatchQueue.main.async { self.updateInline() }
                return
            }
            let origin = self.scroll.contentView.bounds.origin
            self.collection.reloadData()
            if let r = restore { self.collection.layoutSubtreeIfNeeded(); self.scroll.contentView.scroll(to: r); self.scroll.reflectScrolledClipView(self.scroll.contentView) }
            else if keepPosition { self.scroll.contentView.scroll(to: origin) } else { self.collection.scroll(.zero) }
            self.emptyLabel.stringValue = nowUnfiltered ? L("feed.empty.library.mac") : L("feed.empty.noMatch")
            self.emptyLabel.isHidden = !items.isEmpty
            DispatchQueue.main.async { self.updateInline() }
        }
    }

    func reshuffle() {
        order.reshuffle(); savedBrowse = nil; reload()
    }

    var onByAddedChanged: ((Bool) -> Void)?
    /// 按添加时间排序, newest first.
    func setByAdded(_ on: Bool) {
        LibraryPrefs.feedByAdded = on
        onByAddedChanged?(on)
        savedBrowse = nil
        reload()
    }

    /// "在浏览中查看帖子" from a grid: the card of that media's post in the middle of the
    /// browse, turned to that media and briefly marked. A search or filter that hides it is
    /// cleared first (the browse order stays as it was).
    func reveal(_ item: FeedItem) {
        if allItems.contains(where: { $0.mediaId == item.mediaId }) { return scrollTo(item) }
        pendingReveal = item
        filter = FeedFilter()
        if LibraryPrefs.badOnly && item.bad == nil { LibraryPrefs.badOnly = false }
        renderChips()
        if query != TokenQuery() { onClearSearch?() } else { reload() }
    }

    private func scrollTo(_ item: FeedItem) {
        guard let i = entries.firstIndex(where: { $0.contains { $0.mediaId == item.mediaId } }), sectionCount > 0 else {
            toast.show(L("feed.reveal.notFound"))
            return
        }
        let ip = IndexPath(item: i, section: 0)
        collection.layoutSubtreeIfNeeded()
        collection.scrollToItems(at: [ip], scrollPosition: .centeredVertically)
        collection.layoutSubtreeIfNeeded()
        DispatchQueue.main.async {
            guard let card = self.collection.item(at: ip) as? FeedCard else { return }
            if let page = card.items.firstIndex(where: { $0.mediaId == item.mediaId }) { card.show(page: page) }
            card.flash()
            self.updateInline()
        }
    }

    private func rebuildEntries() {
        guard grouped else { entries = allItems.map { [$0] }; return }
        entries = LibraryPrefs.feedByAdded ? FeedOrder.postsInPlace(allItems) : order.posts(allItems)
    }

    /// The media of everything the current search shows (all of it, not only what is on screen),
    /// and whether that is already the answer to the latest search.
    var resultMediaIds: [String] { allItems.map(\.mediaId) }
    var resultsAreCurrent: Bool { shownGeneration == generation }
    private var shownGeneration = -1

    private var pendingReload: DispatchWorkItem?
    @objc private func libraryChanged() {
        pendingReload?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload(keepPosition: true) }
        pendingReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    // MARK: Chips

    /// The toolbar's search changed.
    func applyQuery(_ q: TokenQuery) {
        guard q != query else { return }
        query = q
        renderChips()
        reload()
    }

    /// A tag to search for, from a card: it becomes a capsule in the toolbar's search field.
    func addTerm(_ raw: String) { onSearchTag?(raw) }

    private func chip(_ title: String, color: NSColor, id: String, remove: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: remove)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 12
        b.layer?.backgroundColor = color.cgColor
        b.attributedTitle = NSAttributedString(string: "  \(title)  ✕  ", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        b.setAccessibilityIdentifier(id)
        return b
    }

    private func renderChips() {
        chipBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let k = filter.kind { chipBar.addArrangedSubview(chip(k == .video ? L("feed.chip.videos") : L("feed.chip.photos"), color: .systemBlue, id: "chip-kind") { [weak self] in self?.filter.kind = nil; self?.renderChips(); self?.reload() }) }
        if filter.review == .unreviewed { chipBar.addArrangedSubview(chip(L("place.unreviewed"), color: .systemOrange, id: "chip-review") { [weak self] in self?.filter.review = .any; self?.renderChips(); self?.reload() }) }
        if let a = filter.author {
            chipBar.addArrangedSubview(chip(L("feed.chip.author", a.hasPrefix("@") ? a : "@" + a), color: .systemIndigo, id: "chip-author") { [weak self] in self?.filter.author = nil; self?.renderChips(); self?.reload() })
        }
        for l in filter.labels {
            chipBar.addArrangedSubview(chip(L("feed.chip.label", l), color: .systemGreen, id: "chip-label") { [weak self] in self?.filter.labels.removeAll { $0 == l }; self?.renderChips(); self?.reload() })
        }
        if filter.review == .reviewed { chipBar.addArrangedSubview(chip(L("place.reviewed"), color: .systemGreen, id: "chip-reviewed") { [weak self] in self?.filter.review = .any; self?.renderChips(); self?.reload() }) }
        if filter.albumOnly { chipBar.addArrangedSubview(chip(L("card.album"), color: .systemIndigo, id: "chip-album") { [weak self] in self?.filter.albumOnly = false; self?.renderChips(); self?.reload() }) }
        if filter.looseOnly { chipBar.addArrangedSubview(chip(L("card.loose"), color: .systemIndigo, id: "chip-loose") { [weak self] in self?.filter.looseOnly = false; self?.renderChips(); self?.reload() }) }
        if filter.recentOnly { chipBar.addArrangedSubview(chip(L("place.recent"), color: .systemOrange, id: "chip-recent") { [weak self] in self?.filter.recentOnly = false; self?.renderChips(); self?.reload() }) }
        if let f = filter.folder { chipBar.addArrangedSubview(chip(L("search.token.folder", f), color: .systemTeal, id: "chip-folder") { [weak self] in self?.showFolder(nil) }) }
        if LibraryPrefs.badOnly { chipBar.addArrangedSubview(chip(L("feed.chip.bad"), color: .systemRed, id: "chip-bad") { LibraryPrefs.badOnly = false }) }
        // the search itself shows as capsules in the toolbar's search field
        onChipsChanged?()
    }

    /// A filter chip is on (a tag from the tags page, 仅视频, 未认可…): that is a search too.
    var hasChipFilter: Bool { !filter.isEmpty || LibraryPrefs.badOnly }
    var onChipsChanged: (() -> Void)?

    // MARK: Collection

    func numberOfSections(in cv: NSCollectionView) -> Int { sectionCount }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at ip: IndexPath) -> NSView {
        let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: MacFeedEnd.id, for: ip) as! MacFeedEnd
        v.configure(count: entries.count, grouped: grouped)
        return v
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        #if DEBUG
        let t0 = CACurrentMediaTime(); defer { debugConfigureTime += CACurrentMediaTime() - t0; debugConfigures += 1 }
        #endif
        let card = cv.makeItem(withIdentifier: FeedCard.id, for: ip) as! FeedCard
        card.menuForTag = { [weak self] t, item in self?.tagMenu(t, item: item) }
        card.highlight = query.marks
        let e = entries[ip.item % entries.count]
        card.startPage = cardPages.page(of: entryKey(e), count: e.count)
        card.refresh(e)
        card.onOpen = { [weak self] it in self?.open(it) }
        card.onTag = { [weak self] l in self?.addTerm(l) }
        card.onRecent = { [weak self] in guard let self, !self.filter.recentOnly else { return }; self.toggleRecentOnly() }
        card.onAddTag = { [weak self] card, anchor, rect in self?.showTagPicker(card, anchor: anchor, rect: rect) }
        card.onPage = { [weak self, weak card] in
            if let card { self?.pageChanged(card) }
            self?.updateInline()
        }
        return card
    }


    /// A card came on screen: re-check which video plays (a short result list never scrolls).
    private var pendingInline: DispatchWorkItem?
    func collectionView(_ cv: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt ip: IndexPath) {
        pendingInline?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.updateInline() }
        pendingInline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func collectionView(_ cv: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt ip: IndexPath) {
        if item === inlineCard { detachInline() }
    }

    /// While scrolling: load pictures a screen ahead, and choose the autoplay video only once the
    /// scroll pauses (swapping players at every scroll event during a fling cost frames and made
    /// cards flash between poster and video).
    @objc private func scrolled() {
        prefetchAhead()
        pendingInline?.cancel()
        if let card = inlineCard, !card.view.frame.intersects(scroll.contentView.documentVisibleRect) { detachInline() }
        let w = DispatchWorkItem { [weak self] in self?.updateInline() }
        pendingInline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    private var lastPrefetchY: CGFloat = .nan
    private func prefetchAhead() {
        let visible = scroll.contentView.documentVisibleRect
        let y = visible.minY
        if abs(y - lastPrefetchY) < visible.height / 4 { return }   // at most every quarter screen
        let down = lastPrefetchY.isNaN || y >= lastPrefetchY
        lastPrefetchY = y
        let ahead = down ? NSRect(x: visible.minX, y: visible.maxY, width: visible.width, height: visible.height)
                         : NSRect(x: visible.minX, y: visible.minY - visible.height, width: visible.width, height: visible.height)
        guard !entries.isEmpty, let attrs = collection.collectionViewLayout?.layoutAttributesForElements(in: ahead) else { return }
        // nearest first: the loader decodes the newest request first
        let ips = attrs.filter { $0.representedElementCategory == .item }.compactMap(\.indexPath)
            .sorted { down ? $0 > $1 : $0 < $1 }
        MacMediaLoader.shared.prefetch(ips.compactMap { entries[$0.item % entries.count].first }, maxPixel: FeedCard.decodePixels)
    }

    /// Muted autoplay for the most visible video card.
    private func updateInline() {
        // not while a collection covers 浏览
        if covered { detachInline(); return }
        let visible = scroll.contentView.documentVisibleRect
        var best: (FeedCard, CGFloat)?
        for case let card as FeedCard in collection.visibleItems() where card.current?.kind == .video {
            let f = card.view.frame.intersection(visible)
            let r = f.isNull ? 0 : (f.width * f.height) / max(card.view.frame.width * card.view.frame.height, 1)
            if r > 0.6, r > (best?.1 ?? 0) { best = (card, r) }
        }
        guard let card = best?.0, let item = card.current else { detachInline(); return }
        if card === inlineCard, (inlinePlayer.currentItem?.asset as? AVURLAsset)?.url == item.fileURL { return }
        detachInline()
        #if DEBUG
        debugInlineSwaps += 1
        #endif
        inlinePlayer.replaceCurrentItem(with: AVPlayerItem(url: item.fileURL))
        card.playerLayer.player = inlinePlayer
        card.showsInlineVideo = true
        inlineCard = card
        inlinePlayer.play()
    }

    private func detachInline() {
        inlinePlayer.pause()
        inlineCard?.playerLayer.player = nil
        inlineCard?.showsInlineVideo = false
        inlineCard = nil
    }

    /// Opens a media inside the main window (never a new window): the player or photo viewer
    /// covers the feed until it is closed.
    /// Opens a media of another list (a grid of the 文件夹 page): ← → goes through that list.
    func openMedia(_ item: FeedItem, in list: [FeedItem]) { open(item, list: list) }

    private func open(_ item: FeedItem, list: [FeedItem]? = nil) {
        let t = inlineCard?.current?.mediaId == item.mediaId ? inlinePlayer.currentTime() : .zero
        detachInline()
        if let p = pipPlayer { p.teardown(); pipPlayer = nil }
        let v: NSView
        if item.kind == .video, list == nil, entries.allSatisfy({ !$0.contains { $0.mediaId == item.mediaId } }) {
            // a video on its own (not in any list here): the player alone, with picture in picture
            let p = MacPlayerView(url: item.fileURL, startAt: t)
            p.onClose = { [weak self, weak p] in p?.teardown(); self?.closeViewer() }
            p.onPiPStart = { [weak self, weak p] in self?.pipPlayer = p; self?.closeViewer(keepPlayer: true) }
            p.onPiPRestore = { [weak self, weak p] in if let p { self?.showViewer(p) } }
            p.onPiPEnd = { [weak self, weak p] in
                guard let self, let p, self.pipPlayer === p else { return }
                if self.viewer !== p { p.teardown() }
                self.pipPlayer = nil
            }
            v = p
        } else {
            // every media of the list in its order, so ← → goes on past the post into the next
            // (a video included: it plays as a page of the viewer)
            let listed = list ?? entries.flatMap { $0 }
            let group = listed.contains { $0.mediaId == item.mediaId } ? listed : allItems.filter { $0.postId == item.postId }.sorted { $0.ordinal < $1.ordinal }
            // photos and videos alike: the viewer shows a video as a page, playing from where it was
            let ph = MacPhotoView(items: group.isEmpty ? [item] : group, index: group.firstIndex { $0.mediaId == item.mediaId } ?? 0, videoStart: t)
            ph.onClose = { [weak self, weak ph] in ph?.teardown(); self?.closeViewer() }
            v = ph
        }
        showViewer(v)
    }

    private func showViewer(_ v: NSView) {
        viewer?.removeFromSuperview()
        viewer = v
        v.translatesAutoresizingMaskIntoConstraints = false
        // the whole window (over the sidebar too), not only 浏览's pane
        let host = viewerHost?() ?? view
        host.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        v.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; $0.timingFunction = .springy; v.animator().alphaValue = 1 }
        // Media gets the whole window: hide the toolbar (it overlapped the viewer's close button)
        // and the undo toast; the viewer itself covers the rest of the feed.
        setImmersive(true)
        toast.isHidden = true
        view.window?.makeFirstResponder(v)
    }

    private func closeViewer(keepPlayer: Bool = false) {
        guard let v = viewer else { return }
        viewer = nil
        setImmersive(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; $0.timingFunction = .springy; v.animator().alphaValue = 0 }) { v.removeFromSuperview() }
        view.window?.makeFirstResponder(responderAfterViewer?() ?? collection)
        DispatchQueue.main.async { self.updateInline() }
    }

    var isShowingViewer: Bool { viewer != nil }

    /// Viewer mode: no toolbar, no traffic lights, transparent title bar — the media fills the
    /// whole window. Leaving restores the normal window chrome.
    /// The media viewer opened (true) or closed (false); the settings panel steps aside.
    var onViewer: ((Bool) -> Void)?

    private func setImmersive(_ on: Bool) {
        onViewer?(on)
        guard let w = view.window else { return }
        w.toolbar?.isVisible = !on
        // the title bar is always see-through: the feed background runs under the toolbar
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        // the window title would otherwise show over the media's top-left corner
        w.titleVisibility = on ? .hidden : .visible
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = on }
    }

    #if DEBUG
    var debugSections: Int { collection.numberOfSections }

    /// Sends synthetic trackpad gestures (with phases) to the first multi-page card.

    func debugSwipeTest() -> String {
        guard let card = collection.visibleItems().compactMap({ $0 as? FeedCard }).first(where: { $0.items.count > 1 }) else { return "no multi-page card visible" }
        func gesture(dx: Int32, dy: Int32, momentum: Bool = false) {
            for (i, phase) in [1, 2, 2, 2, 4].enumerated() {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i == 4 ? 0 : dy, wheel2: i == 4 ? 0 : dx, wheel3: 0) else { continue }
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)            // continuous (trackpad)
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: momentum ? 0 : Int64(phase))   // scroll phase
                cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum ? Int64(phase) : 0)  // momentum phase
                if let e = NSEvent(cgEvent: cg) { card.mediaView.scrollWheel(with: e) }
            }
        }
        var log: [String] = []
        let y0 = scroll.contentView.bounds.origin.y
        log.append("start page=\(card.page) of \(card.items.count)")
        gesture(dx: -30, dy: 0); log.append("after swipe one way page=\(card.page)")
        gesture(dx: 30, dy: 0); log.append("after swipe back page=\(card.page)")
        gesture(dx: -30, dy: 0, momentum: true); log.append("after momentum-only page=\(card.page)")
        let p = card.page
        gesture(dx: 0, dy: -30); gesture(dx: 0, dy: 30); log.append("after vertical gesture page=\(card.page) unchanged=\(card.page == p) feedScrolled=\(scroll.contentView.bounds.origin.y != y0)")
        // control: the same synthetic vertical gesture straight to the scroll view
        let y1 = scroll.contentView.bounds.origin.y
        for (i, phase) in [1, 2, 2, 2, 4].enumerated() {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i == 4 ? 0 : -30, wheel2: 0, wheel3: 0) else { continue }
            cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1); cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase))
            if let e = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: e) }
        }
        log.append("control: scroll view itself scrolled=\(scroll.contentView.bounds.origin.y != y1)")
        // realistic gestures: (dx, dy) per event, phases began, changed…, ended
        func path(_ steps: [(Int32, Int32)], began: Bool = true) {
            for (i, st) in steps.enumerated() {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: st.1, wheel2: st.0, wheel3: 0) else { continue }
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
                let phase: Int64 = i == steps.count - 1 ? 4 : (i == 0 && began ? 1 : 2)
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)
                if let e = NSEvent(cgEvent: cg) { card.mediaView.scrollWheel(with: e) }
            }
        }
        var p0 = card.page
        SwipeMediaView.forwarded = 0
        path([(3, -2), (4, -12), (2, -15), (3, -18), (0, 0)])          // vertical with sideways jitter at the start
        log.append("diagonal-ish vertical: page unchanged=\(card.page == p0) eventsToFeed=\(SwipeMediaView.forwarded)/5")
        p0 = card.page; SwipeMediaView.forwarded = 0
        path([(-1, 0), (-8, -2), (-14, -3), (-20, -2), (-10, 0), (0, 0)])   // sideways with a little vertical drift
        log.append("sideways with drift: paged=\(card.page != p0) eventsToFeed=\(SwipeMediaView.forwarded)/6")
        p0 = card.page; SwipeMediaView.forwarded = 0
        path([(-30, -4), (-30, -4), (0, 0)], began: false)               // a gesture that began elsewhere
        log.append("began elsewhere: page unchanged=\(card.page == p0) eventsToFeed=\(SwipeMediaView.forwarded)/3")
        p0 = card.page; SwipeMediaView.forwarded = 0
        path([(-6, -6), (-6, -6), (0, 0)])                                  // 45°: scrolling wins
        log.append("diagonal 45°: page unchanged=\(card.page == p0) eventsToFeed=\(SwipeMediaView.forwarded)/3")
        p0 = card.page; SwipeMediaView.forwarded = 0
        path([(1, 0), (0, 0)])                                              // a tap-sized twitch: nothing lost
        log.append("tiny: page unchanged=\(card.page == p0) eventsToFeed=\(SwipeMediaView.forwarded)/2")
        return log.joined(separator: "\n")
    }

    func debugOpenFirstPhoto() { if let it = allItems.first(where: { $0.kind == .photo }) { open(it) } }
    /// Opens the first photo of a post with several media; returns the viewer.
    /// Opens the tag adder as the long-press menu's "为整个帖子添加标签…" does; returns its window.
    func debugShowTagPicker() -> NSWindow? {
        guard let card = collection.visibleItems().compactMap({ $0 as? FeedCard }).first(where: { $0.items.count > 1 }) ?? collection.visibleItems().compactMap({ $0 as? FeedCard }).first else { return nil }
        showTagPicker(card, anchor: card.view, rect: card.view.bounds, wholePost: true)
        return tagPopover?.contentViewController?.view.window
    }

    func debugOpenGroupPhoto() -> MacPhotoView? {
        let posts = Dictionary(grouping: allItems, by: \.postId).filter { $0.value.count > 1 }
        guard let it = posts.values.first?.sorted(by: { $0.ordinal < $1.ordinal }).first(where: { $0.kind == .photo }) else { return nil }
        open(it)
        return viewer as? MacPhotoView
    }
    func debugCloseViewer() { closeViewer() }
    var debugTagPopoverWindow: NSWindow? { tagPopover?.contentViewController?.view.window }
    var debugTagPopoverShown: String { tagPopover.map { "\($0.isShown)" } ?? "no popover" }
    /// Scrolls the feed to a fraction of its height (0 = top, 1 = bottom).
    func debugScroll(toFraction f: CGFloat) {
        guard let clip = collection.enclosingScrollView?.contentView else { return }
        let maxY = max(0, collection.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maxY * f))
        collection.enclosingScrollView?.reflectScrolledClipView(clip)
    }
    /// Gives the first visible card many tags, then sends a sideways and a vertical trackpad
    /// gesture to its tag row: the row must scroll sideways, and the vertical one must scroll the feed.
    /// Step 1 (sideways) and step 2 (vertical, after reading step 1's result): scroll views
    /// apply gestures asynchronously, so each result is read a moment later.
    func debugTagScrollTest(step: Int) -> String {
        guard let card = collection.visibleItems().compactMap({ $0 as? FeedCard }).min(by: { $0.view.frame.minY < $1.view.frame.minY }), let it = card.current else { return "no card" }
        let row = card.tagScroll
        func gesture(dx: Int32, dy: Int32) {
            for (i, phase) in [1, 2, 2, 2, 4].enumerated() {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i == 4 ? 0 : dy, wheel2: i == 4 ? 0 : dx, wheel3: 0) else { continue }
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase))
                if let e = NSEvent(cgEvent: cg) { row.scrollWheel(with: e) }
            }
        }
        switch step {
        case 1:
            for i in 1...14 { try? Core.addTag("测试标签\(i)", to: it.mediaId) }
            let ids = Set(card.items.map(\.mediaId))
            card.refresh(((try? Core.feed(FeedRequest())) ?? []).filter { ids.contains($0.mediaId) }.sorted { $0.ordinal < $1.ordinal })
            card.view.layoutSubtreeIfNeeded()
            gesture(dx: -60, dy: 0)   // fingers to the left: reveals the tags on the right
            return "tags=\(row.strip.count) content=\(Int(row.strip.frame.width)) row=\(Int(row.contentView.bounds.width))"
        case 2:
            debugMark = (scroll.contentView.bounds.origin.y, row.contentView.bounds.origin.x)
            gesture(dx: 0, dy: -60)
            return "after sideways gesture x=\(Int(row.contentView.bounds.origin.x))"
        default:
            return "after vertical gesture rowX unchanged=\(row.contentView.bounds.origin.x == debugMark.1) feedScrolled=\(scroll.contentView.bounds.origin.y != debugMark.0)"
        }
    }
    private var debugMark: (CGFloat, CGFloat) = (0, 0)
    var debugInlineSwaps = 0
    var debugConfigureTime = 0.0
    var debugConfigures = 0
    /// Visible cards that show a post but no picture.
    func debugBlankCards() -> Int {
        let visible = scroll.contentView.documentVisibleRect
        return collection.visibleItems().compactMap { $0 as? FeedCard }
            .filter { $0.view.frame.intersects(visible) && !$0.items.isEmpty && !$0.debugHasImage }.count
    }
    #endif

    // MARK: Tag menu (right-click)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let p = collection.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        guard let ip = collection.indexPathForItem(at: p), let card = collection.item(at: ip) as? FeedCard, let item = card.current else { return }
        if !item.isLoose, let key = item.authorKey {
            menu.addItem(ClosureMenuItem(L("card.menu.onlyAuthor", item.authorDisplay)) { [weak self] in self?.filter.author = key; self?.renderChips(); self?.reload() })
            if let sn = item.screenName, let u = URL(string: "https://x.com/\(sn)") {
                menu.addItem(ClosureMenuItem(L("card.menu.openProfile", sn)) { NSWorkspace.shared.open(u) })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(L("card.menu.tagMedia")) { [weak self] in self?.showTagPicker(card, anchor: card.view, rect: card.view.bounds, wholePost: false) })
        if !item.isLoose { menu.addItem(ClosureMenuItem(L("card.menu.tagPost")) { [weak self] in self?.showTagPicker(card, anchor: card.view, rect: card.view.bounds, wholePost: true) }) }
        let pending = item.tags.filter { $0.isAI && !$0.isUser }
        if !pending.isEmpty {
            menu.addItem(ClosureMenuItem(L("card.menu.approveAll")) { [weak self] in
                pending.forEach { try? Core.addTag($0.label, to: item.mediaId) }; self?.reload(keepPosition: true) })
        }
        let taggers = ModelStore.shared.taggerIds
        if !taggers.isEmpty {
            let ref = Core.MediaRef(mediaId: item.mediaId, path: item.path, kind: item.kind.rawValue, text: item.text)
            let retag = NSMenuItem(title: L("card.menu.retag"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for id in taggers {
                let modelMenu = NSMenu()
                modelMenu.addItem(ClosureMenuItem(L("card.menu.retagAdd")) { AutoTagger.shared.retag([ref], model: id, replaceOld: false) })
                modelMenu.addItem(ClosureMenuItem(L("card.menu.retagReplace")) { AutoTagger.shared.retag([ref], model: id, replaceOld: true) })
                let mi = NSMenuItem(title: (id == ModelStore.shared.activeTaggerId ? "★ " : "") + ModelStore.shared.displayName(id), action: nil, keyEquivalent: "")
                mi.submenu = modelMenu
                sub.addItem(mi)
            }
            retag.submenu = sub
            menu.addItem(retag)
        }
        if !item.tags.isEmpty { menu.addItem(ClosureMenuItem(L("card.menu.sources")) { [weak self] in self?.showSources(item) }) }
        if !item.tags.isEmpty { menu.addItem(.separator()) }
        for t in item.tags {
            let mi = NSMenuItem(title: (t.isAI ? (t.isUser ? "✓ " : "✦ ") : "") + t.label, action: nil, keyEquivalent: "")
            mi.submenu = tagMenu(t, item: item)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(folderMenuItem(L("common.addToFolder"), media: [item.mediaId]))
        menu.addItem(folderMenuItem(L("card.menu.postToFolder"), posts: [item.postId]))
        let inFolders = Core.mediaFolders(item.mediaId)
        if !inFolders.isEmpty {
            let out = NSMenuItem(title: L("common.removeFromFolder"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for f in inFolders {
                sub.addItem(ClosureMenuItem(L("mac.folder.removeMedia", f)) { [weak self] in _ = try? Core.removeFromFolder(f, media: [item.mediaId]); self?.reload(keepPosition: true) })
                sub.addItem(ClosureMenuItem(L("mac.folder.removePost", f)) { [weak self] in _ = try? Core.removeFromFolder(f, posts: [item.postId]); self?.reload(keepPosition: true) })
            }
            out.submenu = sub
            menu.addItem(out)
        }
        if item.canRedownload {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(item.bad == nil ? L("card.menu.redownload") : L("card.menu.redownloadBad")) { [weak self] in self?.repair(item) })
        }
        menu.addItem(.separator())
        if !item.tags.isEmpty {
            let del = NSMenuItem(title: L("card.menu.deleteTag"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for t in item.tags { sub.addItem(ClosureMenuItem(t.label) { [weak self] in self?.deleteTag(t, from: item) }) }
            del.submenu = sub
            menu.addItem(del)
        }
        menu.addItem(ClosureMenuItem(L("card.menu.deleteMedia")) { [weak self] in self?.deleteMedia([item]) })
        menu.addItem(ClosureMenuItem(L("card.menu.deletePost")) { [weak self] in self?.deletePost(item) })
    }

    /// Menu for one tag of one media (card menu and right-click on a tag pill).
    private func tagMenu(_ t: TagView, item: FeedItem) -> NSMenu {
        let sub = NSMenu()
        sub.addItem(ClosureMenuItem(L("card.menu.onlyTag")) { [weak self] in
            guard let self else { return }
            if !self.filter.labels.contains(t.label) { self.filter.labels.append(t.label) }
            self.renderChips(); self.reload()
        })
        sub.addItem(ClosureMenuItem(L("card.menu.searchTag")) { [weak self] in self?.addTerm(t.label) })
        if t.isAI && !t.isUser { sub.addItem(ClosureMenuItem(L("card.menu.approve")) { [weak self] in try? Core.addTag(t.label, to: item.mediaId); self?.reload(keepPosition: true) }) }
        sub.addItem(ClosureMenuItem(L("card.menu.renameTag")) { [weak self] in self?.renameTag(t.label) })
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem(L("card.menu.deleteTag")) { [weak self] in self?.deleteTag(t, from: item) })
        return sub
    }

    // MARK: Folders

    /// Where the media viewer goes (the window's root view: over the sidebar too).
    var viewerHost: (() -> NSView)?
    /// What gets the keyboard when the viewer closes (the grid it was opened from).
    var responderAfterViewer: (() -> NSResponder?)?
    /// A collection covers 浏览 (the sidebar chose something else): no inline video.
    private(set) var covered = false
    func setCovered(_ on: Bool) {
        covered = on
        // hidden, not only covered: its tooltips and tracking areas must not act under the page
        view.isHidden = on
        if on { detachInline() } else { updateInline() }
    }

    /// Shows a collection's media in 浏览 (its 在浏览中查看): its filter as chips.
    func showFromFolders(_ f: FeedFilter, title: String) {
        filter = f
        renderChips()
        reload()
    }

    func showFolder(_ name: String?) {
        filter.folder = name
        renderChips()
        reload()
    }

    func toggleLooseOnly() { filter.looseOnly.toggle(); renderChips(); reload() }
    var looseOnly: Bool { filter.looseOnly }
    func toggleRecentOnly() { filter.recentOnly.toggle(); renderChips(); reload() }
    var recentOnly: Bool { filter.recentOnly }
    func showMessage(_ text: String) { toast.show(text) }
    var currentFolder: String? { filter.folder }

    private func folderMenuItem(_ title: String, media: [String] = [], posts: [String] = []) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for f in Core.folders() { sub.addItem(ClosureMenuItem(f.name) { [weak self] in self?.addToFolder(f.name, media: media, posts: posts) }) }
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ClosureMenuItem(L("common.newFolderEllipsis")) { [weak self] in
            macPrompt(self?.view.window, title: L("common.newFolder"), placeholder: L("common.folderName")) { n in
                let n = n.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { self?.addToFolder(n, media: media, posts: posts) } }
        })
        mi.submenu = sub
        return mi
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
        } catch { macAlert(view.window, L("common.couldNotAddToFolder"), error.localizedDescription) }
    }

    // MARK: Renaming

    /// Renames a tag on every media (merges into an existing tag of the new name); undoable.
    func renameTag(_ old: String) {
        macPrompt(view.window, title: L("tag.rename.title", old), message: L("tag.rename.message"), placeholder: old) { [weak self] text in
            let new = text.trimmingCharacters(in: .whitespaces)
            guard let self, !new.isEmpty, new.lowercased() != old else { return }
            do {
                let name = try Core.renameTag(old, to: new)
                self.onRenameTerm?(old, name)
                if let i = self.filter.labels.firstIndex(of: old) { self.filter.labels[i] = name }
                self.renderChips()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self.reload(keepPosition: true)
                self.toast.show(L("tag.renamed", old, name))
            } catch { macAlert(self.view.window, L("common.couldNotRename"), error.localizedDescription) }
        }
    }

    // MARK: Deletion and repair

    private func deleteTag(_ t: TagView, from item: FeedItem) {
        try? Core.removeTag(t.label, from: item.mediaId)
        reload(keepPosition: true)
        toast.show(L("tag.deleted", t.label), action: L("common.undo")) { [weak self] in
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
        toast.show(L("common.redownloading"))
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Core.repair(item.mediaId) }
            DispatchQueue.main.async {
                switch r {
                case .success(.replaced): self.toast.show(L("repair.fixed"))
                case .success(.replacedNew): macAlert(self.view.window, L("repair.replacedNew.title"), L("repair.replacedNew.message"))
                case .success(.fromPeers): macAlert(self.view.window, L("repair.fromPeers.title"), L("repair.fromPeers.message"))
                case .failure(let e): self.toast.hide(); macAlert(self.view.window, L("repair.failed"), e.localizedDescription)
                }
                MacMediaLoader.shared.forget()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self.reload(keepPosition: true)
            }
        }
    }

    private func showSources(_ item: FeedItem) {
        let lines = item.tags.map { t -> String in
            let who = t.isUser && t.isAI ? L("tag.source.both") : (t.isAI ? "AI" : L("tag.source.me"))
            let models = t.models.map { ModelStore.shared.displayName($0) }
            return models.isEmpty ? L("tag.sourceLine", t.label, who) : L("tag.sourceLineModels", t.label, who, models.joined(separator: L("list.separator")))
        }
        macAlert(view.window, L("tag.sources.title"), lines.joined(separator: "\n"))
    }

    private var tagPopover: NSPopover?
    /// The tag adder, from the "+" pill and from the menu's L("card.addTag") items alike: the same view
    /// as on iOS (`TagPickerView`), floating in a popover beside the card.
    private func showTagPicker(_ card: FeedCard, anchor: NSView, rect: NSRect, wholePost: Bool = false) {
        guard let item = card.current else { return }
        guard let scope = try? Core.postScope(item.postId) else { macAlert(view.window, L("post.unreadable.title"), L("common.tryAgain")); return }
        let model = TagPickerModel(media: item, scope: scope, wholePost: wholePost)
        model.onChange = { [weak self] in self?.reload(keepPosition: true) }
        let pop = NSPopover()
        let host = NSHostingController(rootView: TagPickerView(model: model) { [weak pop] in pop?.performClose(nil) })
        host.view.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        pop.contentViewController = host
        pop.contentSize = NSSize(width: 360, height: 480)
        pop.behavior = .transient
        pop.animates = true
        pop.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
        tagPopover = pop
        // released when it closes (it holds the picker and the whole tag list)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.tagPopover === pop { self?.tagPopover = nil } }
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

}

final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void = {}
    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }
    @objc private func fire() { handler() }
}

/// Full-width divider at the end of the feed: "共 12 条帖子，已经到底".
final class MacFeedEnd: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("MacFeedEnd")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let left = NSBox(), right = NSBox()
        [left, right].forEach { $0.boxType = .separator; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setAccessibilityIdentifier("feedEnd")
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.centerYAnchor.constraint(equalTo: centerYAnchor), right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -12),
            right.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12), right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, grouped: Bool) {
        label.stringValue = "✓  " + L(grouped ? "feed.end.posts" : "feed.end.media", count)
    }
}

/// Short message at the bottom of the feed with an optional action (e.g. undo).
final class MacToast: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton()
    private var action: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        button.isBordered = false
        button.target = self
        button.action = #selector(fire)
        button.setAccessibilityIdentifier("toastAction")
        let st = NSStackView(views: [label, button])
        st.spacing = 14
        st.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 14)
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([st.topAnchor.constraint(equalTo: topAnchor), st.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     st.leadingAnchor.constraint(equalTo: leadingAnchor), st.trailingAnchor.constraint(equalTo: trailingAnchor)])
        alphaValue = 0
        isHidden = true
        setAccessibilityIdentifier("toast")
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, action title: String? = nil, _ action: (() -> Void)? = nil) {
        label.stringValue = text
        button.isHidden = title == nil
        button.attributedTitle = NSAttributedString(string: title ?? "", attributes: [.foregroundColor: NSColor.systemYellow, .font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        self.action = action
        hideWork?.cancel()
        isHidden = false
        layer?.zPosition = 100
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; $0.timingFunction = .springy; animator().alphaValue = 1 }
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; $0.timingFunction = .springy; animator().alphaValue = 0 }) { [weak self] in self?.isHidden = true; self?.action = nil }
    }

    @objc private func fire() { action?(); hide() }
}

/// Media area of a card that turns two-finger horizontal trackpad swipes into page flips, while
/// vertical scrolling keeps scrolling the feed. One flip per gesture; momentum is ignored.
/// Which way a two-finger gesture goes, decided once per gesture from its first movement.
enum SwipeAxis {
    case horizontal, vertical
    /// Movement needed before deciding (pt), and how much more horizontal than vertical a
    /// gesture must be to page instead of scroll. Scrolling wins every doubtful case.
    static let decideAfter: CGFloat = 10
    static let ratio: CGFloat = 2
    /// nil = not enough movement yet.
    static func decide(dx: CGFloat, dy: CGFloat) -> SwipeAxis? {
        let (ax, ay) = (abs(dx), abs(dy))
        guard ax + ay >= decideAfter else { return nil }
        return ax >= ay * ratio ? .horizontal : .vertical
    }
}

/// The media area of a card. A two-finger gesture that starts on it is held back until it has
/// moved 10 pt; then it either pages (clearly sideways: twice as much horizontal as vertical
/// movement) or is handed to the feed in full, buffered events included, so a vertical scroll
/// never loses its start and never flips a page. A gesture that began elsewhere (the feed
/// scrolled the card under the pointer) always scrolls. Momentum after a page flip is swallowed.
final class SwipeMediaView: NSView {
    /// forward = next page. Returns false when there is nothing to flip (the event then scrolls the feed).
    var onSwipe: ((Bool) -> Bool)?
    private enum State { case idle, deciding, horizontal, vertical }
    private var state = State.idle
    private var buffer: [NSEvent] = []
    private var dx: CGFloat = 0, dy: CGFloat = 0
    private var accum: CGFloat = 0
    private var fired = false
    private var lastWasPage = false
    #if DEBUG
    /// Events handed on to the feed (self-test).
    static var forwarded = 0
    #endif
    private func forward(_ e: NSEvent) {
        #if DEBUG
        Self.forwarded += 1
        #endif
        super.scrollWheel(with: e)
    }

    override func scrollWheel(with e: NSEvent) {
        // Mouse wheels (no phases) always scroll the feed.
        guard e.hasPreciseScrollingDeltas, onSwipe != nil else { return forward(e) }
        if !e.momentumPhase.isEmpty { if lastWasPage { return }; return forward(e) }
        if e.phase == .mayBegin { return forward(e) }
        if e.phase == .began { state = .deciding; buffer = []; dx = 0; dy = 0; accum = 0; fired = false; lastWasPage = false }
        let ending = e.phase == .ended || e.phase == .cancelled
        switch state {
        case .idle, .vertical:
            forward(e)
        case .deciding:
            buffer.append(e)
            dx += e.scrollingDeltaX; dy += e.scrollingDeltaY
            if let axis = SwipeAxis.decide(dx: dx, dy: dy) {
                if axis == .horizontal { state = .horizontal; lastWasPage = true; page(by: dx, e); buffer = [] }
                else { state = .vertical; flush() }
            } else if ending { flush() }   // too small to mean anything: let the feed have it
        case .horizontal:
            page(by: e.scrollingDeltaX, e)
        }
        if ending { state = .idle; buffer = [] }
    }

    /// Hands the held-back events to the feed, in order.
    private func flush() {
        let held = buffer
        buffer = []
        for h in held { forward(h) }
    }

    private func page(by delta: CGFloat, _ e: NSEvent) {
        // finger direction: with natural scrolling the deltas already follow the fingers
        accum += e.isDirectionInvertedFromDevice ? delta : -delta
        if !fired, abs(accum) > 40 {
            fired = true
            // fingers moving left = next page (like Photos); nothing to flip → the feed scrolls
            if onSwipe?(accum < 0) == false { state = .vertical; lastWasPage = false }
        }
    }
}

/// A feed card: a lighter surface with a hairline edge, so cards stand apart from the feed
/// background in light and dark mode (the system control and window colors are nearly equal).
final class MacCardView: NSView {
    static func dynamic(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: dark, alpha: 1) : NSColor(white: light, alpha: 1) }
    }
    /// 浏览's background: not quite white. Its cards are white, with no grey anywhere.
    static let feedBackground = dynamic(light: 0.975, dark: 0.07)
    static let fill = dynamic(light: 1.0, dark: 0.16)
    static let mediaFill = dynamic(light: 1.0, dark: 0.11)
    static let edge = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : .clear }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        // a very faint ring around the card; the media clip themselves to its corners
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 18, cornerHeight: 18, transform: nil)
    }
    override var wantsUpdateLayer: Bool { true }
    // resolved here, so a light/dark switch recolors cards (a cgColor set once would not)
    override func updateLayer() {
        layer?.backgroundColor = Self.fill.cgColor
        layer?.borderColor = Self.edge.cgColor
    }
}

/// A one-line row that scrolls sideways (trackpad, or Shift + mouse wheel) when its content is
/// wider than the row. Vertical scrolling passes through to the feed, so the row never traps it.
final class MacHScroll: NSScrollView {
    let strip = TagStripView()
    private var passing = false

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
        documentView = strip
        strip.onResize = { [weak self] in self?.tile() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The strip is as wide as its pills (sized by hand: no constraints to solve while scrolling).
    override func tile() {
        super.tile()
        let f = NSRect(x: 0, y: 0, width: max(strip.contentWidth, contentView.bounds.width), height: contentView.bounds.height)
        if strip.frame != f { strip.frame = f }
    }

    func scrollToStart() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with e: NSEvent) {
        // decide once per gesture (and per wheel click): mostly vertical → the feed scrolls
        if e.phase == .began || e.phase == .mayBegin || (e.phase.isEmpty && e.momentumPhase.isEmpty) {
            passing = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) || strip.frame.width <= contentView.bounds.width + 0.5
        }
        if passing { (superview?.enclosingScrollView ?? nextResponder)?.scrollWheel(with: e); return }
        // moved by hand: a scroll view without a horizontal scroller ignores sideways scrolling
        let maxX = max(0, strip.frame.width - contentView.bounds.width)
        let dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 10
        let x = min(maxX, max(0, contentView.bounds.origin.x - dx))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// The tags of a card, drawn as pills by one view: no subviews, layers or constraints, so a card
/// coming on screen costs a few text measurements instead of a dozen buttons to lay out (that
/// was most of the time per frame while scrolling fast). Click a pill to search for the tag,
/// right-click for its menu, "+" to add a tag.
final class TagStripView: NSView, NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        pills.first { $0.rect.contains(point) }.flatMap(Self.tip) ?? ""
    }

    var onTag: ((String) -> Void)?
    var onRecent: (() -> Void)?
    var onAdd: ((NSView, NSRect) -> Void)?
    var menuForTag: ((TagView) -> NSMenu?)?
    var onResize: (() -> Void)?
    /// Room before the first and after the last pill (the card's margin).
    var sideInset: CGFloat = 0

    private enum Kind { case recent, tag(TagView), add }
    private struct Pill { let kind: Kind; let text: NSAttributedString?; var rect: NSRect }
    private var pills: [Pill] = []
    private(set) var contentWidth: CGFloat = 0
    var count: Int { pills.count }
    private static let height: CGFloat = 20, gap: CGFloat = 5, pad: CGFloat = 7
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let boldFont = NSFont.systemFont(ofSize: 12, weight: .bold)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func set(_ tags: [TagView], recent: Bool, highlight: [String] = []) {
        var list: [Pill] = []
        if recent { list.append(Pill(kind: .recent, text: NSAttributedString(string: L("card.recentPill"), attributes: [.font: Self.boldFont, .foregroundColor: NSColor.white]), rect: .zero)) }
        for t in tags {
            let prefix = t.isAI ? (t.isUser ? "✓ " : "✦ ") : ""
            let text = NSMutableAttributedString(string: prefix + t.label, attributes: [.font: Self.font, .foregroundColor: NSColor.tagColor(t)])
            SearchHighlight.apply(highlight, to: text, FeedCard.highlightAttrs)
            list.append(Pill(kind: .tag(t), text: text, rect: .zero))
        }
        list.append(Pill(kind: .add, text: nil, rect: .zero))
        var x: CGFloat = sideInset
        for i in list.indices {
            let w = list[i].text.map { ceil($0.size().width) + Self.pad * 2 } ?? 24
            list[i].rect = NSRect(x: x, y: 0, width: w, height: Self.height)
            x += w + Self.gap
        }
        pills = list
        contentWidth = max(0, x - Self.gap + sideInset)
        // The strip itself owns its tooltips: AppKit does not retain a tooltip's owner, and a
        // temporary string as owner was freed before the tooltip showed (a crash).
        removeAllToolTips()
        for p in pills where Self.tip(for: p) != nil { addToolTip(p.rect, owner: self, userData: nil) }
        needsDisplay = true
        onResize?()
    }

    private static func tip(for p: Pill) -> String? {
        switch p.kind {
        case .tag(let t) where !t.models.isEmpty: return L("format.labelValue", "AI", t.models.map { ModelStore.shared.displayName($0) }.joined(separator: L("list.separator")))
        case .recent: return L("card.recent.tip")
        case .add: return L("card.addTag")
        default: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for p in pills where p.rect.intersects(dirtyRect) {
            let bg: NSColor
            switch p.kind {
            case .recent: bg = .systemOrange
            case .tag(let t): bg = NSColor.tagColor(t).withAlphaComponent(0.16)
            case .add: bg = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
            }
            bg.setFill()
            NSBezierPath(roundedRect: p.rect, xRadius: 10, yRadius: 10).fill()
            if let text = p.text {
                let size = text.size()
                text.draw(at: NSPoint(x: p.rect.minX + Self.pad, y: p.rect.midY - size.height / 2))
            } else {
                let z = Self.plus.size
                Self.plus.draw(in: NSRect(x: p.rect.midX - z.width / 2, y: p.rect.midY - z.height / 2, width: z.width, height: z.height))
            }
        }
    }

    /// "+" in the secondary label color (a palette color resolves when drawn, so it follows light/dark mode).
    private static let plus: NSImage = NSImage(systemSymbolName: "plus", accessibilityDescription: L("card.addTag"))?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold).applying(.init(paletteColors: [.secondaryLabelColor]))) ?? NSImage()

    private func pill(at event: NSEvent) -> Pill? {
        let p = convert(event.locationInWindow, from: nil)
        return pills.first { $0.rect.contains(p) }
    }

    // a click on a pill is a click on it; elsewhere it is the card's
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return pills.contains { $0.rect.contains(p) } ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let p = pill(at: event) else { return }
        switch p.kind {
        case .recent: onRecent?()
        case .tag(let t): onTag?(t.label)
        case .add: onAdd?(self, p.rect)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if case .tag(let t)? = pill(at: event)?.kind { return menuForTag?(t) }
        return nil
    }

    // VoiceOver: each pill is a button
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? {
        pills.map { p in
            let e = NSAccessibilityElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityFrameInParentSpace(p.rect)
            switch p.kind {
            case .recent: e.setAccessibilityLabel(L("place.recent")); e.setAccessibilityIdentifier("recentBadge")
            case .tag(let t): e.setAccessibilityLabel(t.label); e.setAccessibilityIdentifier(t.label)
            case .add: e.setAccessibilityLabel(L("card.addTag")); e.setAccessibilityIdentifier("addTag")
            }
            return e
        }
    }
}

/// Shows a picture as its layer's contents, scaled by the GPU. An NSImageView redraws (and
/// rescales) its image on the main thread whenever a card appears, which during a fast scroll
/// took more time per frame than everything else together.
final class ImageLayerView: NSView {
    var image: NSImage? {
        didSet { layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
}


/// The 浏览 grid on the Mac: cards as tall as their content in as many columns as fit (each card
/// in the shortest column), one section per pass of the looping feed with its footer. The
/// placement is `FeedMasonry` (shared with iOS).
/// During a live resize only visible cells need to lay out text. Re-measure the full
/// masonry once the drag ends, including a drag that leaves the column width unchanged.
private final class ResizingFeedCollectionView: NSCollectionView {
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        (collectionViewLayout as? MacFeedMasonryLayout)?.invalidateHeights()
    }
}

final class MacFeedMasonryLayout: NSCollectionViewLayout {
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

    private func metrics(_ cv: NSCollectionView) -> FeedMasonry.Metrics {
        let width = cv.enclosingScrollView?.contentSize.width ?? cv.bounds.width
        let columns = LibraryPrefs.feedColumns(width: width - 40, height: cv.enclosingScrollView?.contentSize.height ?? cv.bounds.height, base: 300, maxColumns: 6)
        return FeedMasonry.Metrics(width: width, columns: columns, side: 20, columnGap: 16, rowGap: 18, top: 12, footer: 56)
    }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        passes = cv.numberOfSections
        let count = passes > 0 ? cv.numberOfItems(inSection: 0) : 0
        let m = metrics(cv)
        if dirty || plan?.metrics != m || plan?.frames.count != count {
            let previous = plan
            let approximate = cv.inLiveResize && previous?.frames.count == count
            plan = FeedMasonry(count: count, metrics: m) { [weak self] i, w in
                if approximate, let previous, previous.metrics.columnWidth > 0 {
                    return previous.frames[i].height * w / previous.metrics.columnWidth
                }
                return self?.height?(i, w) ?? w * FeedCard.mediaRatio
            }
            dirty = false
        }
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: plan?.metrics.width ?? 0, height: (plan?.contentHeight(passes: passes) ?? 0) + 12)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let plan else { return [] }
        let found = plan.elements(in: rect, passes: passes)
        var out = found.items.map { e -> NSCollectionViewLayoutAttributes in
            let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: e.item, section: e.pass))
            a.frame = plan.frame(item: e.item, pass: e.pass)
            return a
        }
        for s in found.footers { if let a = layoutAttributesForSupplementaryView(ofKind: NSCollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: s)) { out.append(a) } }
        return out
    }

    override func layoutAttributesForItem(at ip: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let plan, ip.item < plan.frames.count, ip.section < passes else { return nil }
        let a = NSCollectionViewLayoutAttributes(forItemWith: ip)
        a.frame = plan.frame(item: ip.item, pass: ip.section)
        return a
    }

    override func layoutAttributesForSupplementaryView(ofKind kind: NSCollectionView.SupplementaryElementKind, at ip: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let plan, ip.section < passes else { return nil }
        let a = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: kind, with: ip)
        a.frame = plan.footerFrame(pass: ip.section)
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let plan else { return true }
        return abs(newBounds.width - plan.metrics.width) > 0.5
    }

    override func invalidateLayout(with context: NSCollectionViewLayoutInvalidationContext) {
        // a batch update (cards removed, a pass appended) changes what is placed where
        if context.invalidateDataSourceCounts || context.invalidateEverything { dirty = true }
        super.invalidateLayout(with: context)
    }
}

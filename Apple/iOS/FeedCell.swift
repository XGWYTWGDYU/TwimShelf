import UIKit
import AVFoundation

/// One media page: poster/photo plus an optional inline video layer.
final class MediaPageView: UIView {
    let imageView = UIImageView()
    private let inlineStill = UIImageView()
    let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    let playerLayer = AVPlayerLayer()
    private let badBadge = PaddedLabel()
    private(set) var item: FeedItem?
    private var imageToken: MediaLoader.Token?
    func cancelImage() { MediaLoader.shared.cancel(imageToken); imageToken = nil }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelImage() }
        else if imageView.image == nil, let item { configure(item) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .feedCard
        imageView.contentMode = .scaleAspectFit
        playerLayer.videoGravity = .resizeAspect
        playBadge.tintColor = .white
        playBadge.contentMode = .center
        playBadge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        playBadge.layer.cornerRadius = 22
        playBadge.preferredSymbolConfiguration = .init(pointSize: 18, weight: .bold)
        addSubview(imageView)
        inlineStill.contentMode = .scaleAspectFit
        addSubview(inlineStill)
        layer.addSublayer(playerLayer)
        addSubview(playBadge)
        badBadge.text = L("bad.damaged")
        badBadge.font = .systemFont(ofSize: 12, weight: .bold)
        badBadge.textColor = .white
        badBadge.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        badBadge.layer.cornerRadius = 10
        badBadge.clipsToBounds = true
        badBadge.isHidden = true
        badBadge.accessibilityIdentifier = "badBadge"
        addSubview(badBadge)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath
        imageView.frame = bounds
        inlineStill.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        playBadge.frame = CGRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44)
        let s = badBadge.intrinsicContentSize
        badBadge.frame = CGRect(x: 12, y: 12, width: s.width, height: s.height)
    }

    /// One decode size for every card (≈ card width in pixels), so prefetch and display share cache entries.
    static var pixelSize: CGFloat {
        let screen = UIScreen.main
        return min(screen.bounds.width, 440) * screen.scale
    }

    static func prefetch(_ item: FeedItem) { MediaLoader.shared.prefetch([item], maxPixel: pixelSize) }

    var transitionImage: UIImage? { inlineStill.image ?? imageView.image }

    func showInlineStill(_ image: CGImage?) {
        inlineStill.image = image.map { UIImage(cgImage: $0) }
        if playerLayer.player == nil { playBadge.isHidden = item?.kind != .video || image != nil }
    }

    /// New data for the same media (tags, damage state): badges only.
    func update(_ item: FeedItem) {
        self.item = item
        badBadge.isHidden = item.bad == nil
        badBadge.text = item.badText
    }

    func configure(_ item: FeedItem) {
        cancelImage()
        self.item = item
        playBadge.isHidden = item.kind != .video
        badBadge.isHidden = item.bad == nil
        badBadge.text = item.badText
        setNeedsLayout()
        isAccessibilityElement = true
        accessibilityIdentifier = item.kind == .video ? "media-video" : "media-photo"
        accessibilityTraits = .button
        playerLayer.player = nil
        showInlineStill(nil)
        let px = Self.pixelSize
        if let img = MediaLoader.shared.cached(item, maxPixel: px) { imageView.image = img; return }
        imageView.image = nil
        let id = item.mediaId
        imageToken = MediaLoader.shared.load(item, maxPixel: px) { [weak self] img in
            if img == nil { MediaLoader.shared.reportIfBroken(item) }
            guard self?.item?.mediaId == id else { return }
            self?.imageView.image = img
        }
    }
}

protocol FeedCellDelegate: AnyObject {
    func feedCell(_ cell: FeedCell, didTapPage index: Int)
    func feedCell(_ cell: FeedCell, didTapTag label: String)
    func feedCellPageDidChange(_ cell: FeedCell)
    /// The pages are moving: the card is this tall now.
    func feedCell(_ cell: FeedCell, heightChangedTo height: CGFloat)
    func feedCellDidTapAddTag(_ cell: FeedCell)
    func feedCell(_ cell: FeedCell, menuForTag tag: TagView, of item: FeedItem) -> UIMenu
    func feedCellDidTapRecent(_ cell: FeedCell)
}

/// A card: media pager (one page, or a post's whole group) above the caption. A card is as tall as
/// its content: the whole post text shows, and a part a post does not have (text, link) takes no
/// room. Laid out by hand (`CardLayout`), so the grid knows every card's height without
/// laying cards out. The text is selectable word by word (long-press, as in Notes).
extension UIColor {
    /// 浏览's background: not quite white. Its cards are white.
    static let feedBackground = UIColor { $0.userInterfaceStyle == .dark ? .black : UIColor(white: 0.975, alpha: 1) }
    static let feedCard = UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : .white }
}

final class FeedCell: UICollectionViewCell, UIScrollViewDelegate, UITextViewDelegate {
    static let reuseID = "FeedCell"
    weak var delegate: FeedCellDelegate?
    private(set) var items: [FeedItem] = []
    private(set) var page = 0

    private let pager = PagerScrollView()
    private var pages: [MediaPageView] = []
    private let counter = PaddedLabel()
    private let authorLabel = UILabel()
    private let bodyView = UITextView()
    private let linkButton = UIButton(type: .system)
    /// The chips of the tag row, placed by hand (`layoutTags`): a stack view sized by Auto Layout
    /// kept the width of the page before after a swipe back and stretched one chip across it.
    private let tagRow = UIView()
    private var tagChips: [UIButton] = []
    private let tagScroll = UIScrollView()

    var currentItem: FeedItem? { items.indices.contains(page) ? items[page] : nil }
    var currentPageView: MediaPageView? { pages.indices.contains(page) ? pages[page] : nil }

    /// The white part of the card under a layer of glass (one per card, created once).
    private lazy var captionGlass: UIVisualEffectView? = {
        guard #available(iOS 26.0, *), ProcessInfo.processInfo.environment["TL_NO_CARD_GLASS"] == nil else { return nil }
        let e = UIGlassEffect(style: .regular)
        e.isInteractive = false
        let g = UIVisualEffectView(effect: e)
        g.cornerConfiguration = .corners(radius: .fixed(0))
        g.isUserInteractionEnabled = false
        contentView.insertSubview(g, aboveSubview: pager)
        return g
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .feedCard
        // a very faint ring around the card; the content below is clipped, the shadow must not be
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.masksToBounds = false
        contentView.layer.cornerRadius = 22
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.delegate = self
        pager.onResize = { [weak self] in self?.layoutPages() }
        pager.backgroundColor = .feedCard
        pager.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        counter.textColor = .white
        counter.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        counter.layer.cornerRadius = 10
        counter.clipsToBounds = true

        authorLabel.font = .preferredFont(forTextStyle: .subheadline)
        authorLabel.adjustsFontForContentSizeCategory = true
        // selectable like a note: long-press picks a word, the handles widen it, the menu copies
        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.isScrollEnabled = false
        bodyView.backgroundColor = .clear
        bodyView.textContainerInset = .zero
        bodyView.textContainer.lineFragmentPadding = 0
        bodyView.dataDetectorTypes = [.link]
        bodyView.adjustsFontForContentSizeCategory = true
        bodyView.font = .preferredFont(forTextStyle: .body)
        bodyView.delegate = self
        bodyView.accessibilityIdentifier = "postText"
        linkButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        linkButton.titleLabel?.adjustsFontForContentSizeCategory = true
        linkButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        linkButton.contentHorizontalAlignment = .leading
        linkButton.contentEdgeInsets = .zero
        linkButton.addTarget(self, action: #selector(openLink), for: .touchUpInside)

        tagScroll.showsHorizontalScrollIndicator = false
        // the row spans the whole card and its inset moves the chips in: scrolled chips then end at
        // the card's own edge, not at an invisible line 16 pt inside it
        tagScroll.contentInset = UIEdgeInsets(top: 0, left: CardLayout.Metrics.regular.side, bottom: 0, right: CardLayout.Metrics.regular.side)
        tagScroll.addSubview(tagRow)
        [pager, counter, authorLabel, bodyView, linkButton, tagScroll].forEach { contentView.addSubview($0) }
    }

    /// Each chip at its own width, side by side, the row as tall as the tag row; the "+" a circle.
    private func layoutTags() {
        let m = CardLayout.Metrics.of(traitCollection)
        let h = m.tagsHeight, gap = m.tagGap
        var x: CGFloat = 0
        for c in tagChips {
            let w = c.accessibilityIdentifier == "addTag" ? h : ceil(c.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: h)).width)
            c.frame = CGRect(x: x, y: 0, width: w, height: h)
            x += w + gap
        }
        let width = max(0, x - gap)
        tagRow.frame = CGRect(x: 0, y: 0, width: width, height: h)
        tagScroll.contentSize = CGSize(width: width, height: h)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        guard w > 0 else { return }
        if base?.width != w || base?.textSize != traitCollection.preferredContentSizeCategory || base?.compact != traitCollection[CompactCardsTrait.self] { base = CardLayout(item: items.first, width: w, traits: traitCollection) }
        guard let base else { return }
        // the media takes what the card has above its caption: the grid says how tall the card is
        let l = base.withMedia(height: contentView.bounds.height - base.captionHeight)
        pager.frame = CGRect(x: 0, y: 0, width: w, height: l.pagerHeight)
        let cs = counter.intrinsicContentSize
        counter.frame = CGRect(x: w - 12 - cs.width, y: 12, width: cs.width, height: cs.height)
        authorLabel.frame = l.author ?? .zero
        bodyView.frame = l.body ?? .zero
        linkButton.frame = l.link ?? .zero
        // the tags at the bottom of the card (the card is exactly as tall as `CardLayout.height`)
        let m = CardLayout.Metrics.of(traitCollection)
        tagScroll.contentInset = UIEdgeInsets(top: 0, left: m.side, bottom: 0, right: m.side)
        tagScroll.frame = CGRect(x: 0, y: contentView.bounds.height - m.bottom - m.tagsHeight, width: w, height: m.tagsHeight)
        layoutTags()
        // past the card's sides and bottom: the glass's own rim light would show there as a line
        captionGlass?.frame = CGRect(x: -3, y: l.pagerHeight, width: w + 6, height: contentView.bounds.height - l.pagerHeight + 3)
    }

    /// Whether a point (in the cell) is on the post text: a long press there selects text instead
    /// of opening the card's menu.
    func isOnText(_ p: CGPoint) -> Bool { !bodyView.isHidden && bodyView.frame.contains(p) }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let all = currentItem?.text, !all.isEmpty else { return nil }
        let copyAll = UIAction(title: L("card.copyAllText"), image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = all }
        return UIMenu(children: suggestedActions + [copyAll])
    }

    /// Called by the pager when its size or page count changes.
    private func layoutPages() {
        let w = pager.bounds.width, h = pager.bounds.height
        guard w > 0 else { return }
        for (i, v) in pages.enumerated() { v.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h) }
        // only sideways, however tall the page is at the moment
        let content = CGSize(width: w * CGFloat(pages.count), height: 0)
        if pager.contentSize != content {
            pager.contentSize = content
            pager.contentOffset.x = CGFloat(page) * w
        }
        for (v, it) in zip(pages, items) where v.imageView.image == nil { v.configure(it) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pages.forEach { $0.playerLayer.player = nil; $0.cancelImage() }
        // a reused cell always gets a full configure (refresh() is for cells still on screen)
        items = []
    }

    /// Same media as shown: update tags, text and badges in place (no image reload, the current
    /// page and an inline video keep going). Otherwise a full configure.
    /// The words being searched for, highlighted in the fields that were searched.
    var highlight = SearchMarks.none { didSet { if highlight != oldValue, currentItem != nil { updateCaption() } } }
    static let highlightAttrs: [NSAttributedString.Key: Any] = [.backgroundColor: UIColor.systemYellow.withAlphaComponent(0.45)]

    func refresh(_ items: [FeedItem]) {
        guard items.map(\.mediaId) == self.items.map(\.mediaId), !items.isEmpty else { return configure(items) }
        self.items = items
        base = nil
        setNeedsLayout()
        for (v, it) in zip(pages, items) { v.update(it) }
        updateCaption()
    }

    /// The page the next `configure` opens on.
    var startPage = 0
    /// The card's parts at this width, with the first page's height (measuring text is slow, and
    /// this is laid out on every frame while pages are turned).
    private var base: CardLayout?

    func configure(_ items: [FeedItem]) {
        self.items = items
        page = min(max(startPage, 0), max(items.count - 1, 0))
        base = nil
        setNeedsLayout()
        while pages.count < items.count { let v = MediaPageView(); pages.append(v); pager.addSubview(v) }
        while pages.count > items.count { pages.removeLast().removeFromSuperview() }
        for (v, it) in zip(pages, items) { v.configure(it) }
        pager.isScrollEnabled = items.count > 1
        pager.contentOffset.x = CGFloat(page) * pager.bounds.width
        layoutPages()
        updateCaption()
    }

    private func updateCaption() {
        guard let it = currentItem else { return }
        counter.isHidden = items.count < 2
        counter.text = "\(page + 1)/\(items.count)"

        let author = NSMutableAttributedString()
        if it.isLoose {
            // Loose media has no post: a distinct marker instead of author, text and link.
            let icon = NSTextAttachment(image: UIImage(systemName: "square.dashed")!.withTintColor(.systemIndigo))
            author.append(NSAttributedString(attachment: icon))
            author.append(NSAttributedString(string: " " + (it.isAlbum ? L("card.album") : L("card.loose")), attributes: [.font: UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traitCollection), .foregroundColor: UIColor.systemIndigo]))
        }
        if let name = it.authorName {
            author.append(NSAttributedString(string: name, attributes: [.font: UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traitCollection), .foregroundColor: UIColor.label]))
        }
        if let sn = it.screenName {
            author.append(NSAttributedString(string: (author.length > 0 ? "  " : "") + "@\(sn)", attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection), .foregroundColor: UIColor.secondaryLabel]))
        }
        SearchHighlight.apply(highlight.author, to: author, Self.highlightAttrs)
        authorLabel.attributedText = author
        authorLabel.isHidden = author.length == 0
        let body = NSMutableAttributedString(string: it.text ?? "", attributes: [.font: UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection), .foregroundColor: UIColor.label])
        SearchHighlight.apply(highlight.text, to: body, Self.highlightAttrs)
        bodyView.attributedText = body
        bodyView.isHidden = (it.text ?? "").isEmpty
        linkButton.setTitle(it.url, for: .normal)
        linkButton.isHidden = it.url == nil
        setNeedsLayout()

        tagChips.forEach { $0.removeFromSuperview() }
        var chips: [UIButton] = []
        let m = CardLayout.Metrics.of(traitCollection)
        if it.isRecent { chips.append(TagChip.recent(metrics: m, target: self, action: #selector(recentTapped))) }
        for t in it.tags {
            let chip = TagChip.make(t, metrics: m, target: self, action: #selector(tagTapped(_:)), highlight: highlight.tags)
            // Long-press a tag: only this tag, search, endorse, delete.
            chip.menu = delegate?.feedCell(self, menuForTag: t, of: it)
            chip.showsMenuAsPrimaryAction = false
            chips.append(chip)
        }
        chips.append(TagChip.addButton(metrics: m, target: self, action: #selector(addTagTapped)))
        chips.forEach(tagRow.addSubview)
        tagChips = chips
        layoutTags()
        // a reused card keeps the old row's scroll position: the first chip would start cut off
        tagScroll.setContentOffset(CGPoint(x: -tagScroll.contentInset.left, y: 0), animated: false)
    }

    @objc private func tagTapped(_ b: UIButton) {
        if let label = b.accessibilityIdentifier { delegate?.feedCell(self, didTapTag: label) }
    }
    @objc private func recentTapped() { delegate?.feedCellDidTapRecent(self) }
    @objc private func addTagTapped() { UISelectionFeedbackGenerator().selectionChanged(); delegate?.feedCellDidTapAddTag(self) }
    @objc private func tapped() { delegate?.feedCell(self, didTapPage: page) }
    @objc private func openLink() {
        if let s = currentItem?.url, let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased()) { UIApplication.shared.open(u) }
    }

    /// Turns to a page without animation (a media shown from elsewhere).
    func show(page p: Int) {
        guard items.indices.contains(p), pager.bounds.width > 0 else { return }
        page = p
        pager.contentOffset.x = CGFloat(p) * pager.bounds.width
        updateCaption()
        delegate?.feedCellPageDidChange(self)
    }

    /// A short glow around the card: "this one".
    func flash() {
        let ring = CALayer()
        ring.frame = contentView.bounds.insetBy(dx: 1.5, dy: 1.5)
        ring.cornerRadius = contentView.layer.cornerRadius
        ring.cornerCurve = .continuous
        ring.borderWidth = 3
        ring.borderColor = UIColor.tintColor.cgColor
        contentView.layer.addSublayer(ring)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1; a.toValue = 0
        a.beginTime = CACurrentMediaTime() + 0.9
        a.duration = 0.6
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        ring.add(a, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { ring.removeFromSuperlayer() }
        UIView.animate(withDuration: 0.18, animations: { self.transform = CGAffineTransform(scaleX: 1.02, y: 1.02) }) { _ in
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) { self.transform = .identity }
        }
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard sv.bounds.width > 0, !items.isEmpty else { return }
        let position = sv.contentOffset.x / sv.bounds.width
        let p = min(max(Int(position.rounded()), 0), items.count - 1)
        if p != page { page = p; updateCaption(); delegate?.feedCellPageDidChange(self) }
        // the card follows the finger from the height of one page to the next's
        if items.count > 1, let base {
            delegate?.feedCell(self, heightChangedTo: base.captionHeight + cardMediaHeight(items, width: sv.bounds.width, position: position))
        }
    }
}

/// 浏览 on a phone in two columns: the cards draw smaller (`CardLayout.Metrics.compact`).
struct CompactCardsTrait: UITraitDefinition {
    static let defaultValue = false
}

/// Where the parts of a card go (the same numbers for the grid's heights and the card's layout):
/// media 4:5, then author, text and link — each only when the post has it — then the tag row.
struct CardLayout {
    /// The spacing of a card. Compact: a phone showing two columns, where the text (two content
    /// sizes smaller, `FeedViewController.updateCompactCards`) and the tags shrink with the card.
    struct Metrics {
        var side: CGFloat = 16, captionTop: CGFloat = 12, authorGap: CGFloat = 6, linkGap: CGFloat = 4
        var tagsGap: CGFloat = 10, tagsHeight: CGFloat = 26, bottom: CGFloat = 14, linkHeight: CGFloat = 20
        var tagFont: CGFloat = 13, tagPad: CGFloat = 9, tagDot: CGFloat = 7, tagGap: CGFloat = 6
        static let regular = Metrics()
        static let compact = Metrics(side: 11, captionTop: 9, authorGap: 4, linkGap: 3, tagsGap: 8, tagsHeight: 21, bottom: 10, linkHeight: 17,
                                     tagFont: 11, tagPad: 7, tagDot: 6, tagGap: 4)
        static func of(_ traits: UITraitCollection) -> Metrics { traits[CompactCardsTrait.self] ? .compact : .regular }
    }

    private(set) var pagerHeight: CGFloat
    var author: CGRect?
    var body: CGRect?
    var link: CGRect?
    private(set) var height: CGFloat
    let width: CGFloat
    let textSize: UIContentSizeCategory
    /// All of the card but its media.
    var captionHeight: CGFloat { height - pagerHeight }

    /// The same card with its media this tall.
    func withMedia(height h: CGFloat) -> CardLayout {
        var l = self
        let d = h - pagerHeight
        l.pagerHeight = h
        l.height += d
        l.author = author?.offsetBy(dx: 0, dy: d)
        l.body = body?.offsetBy(dx: 0, dy: d)
        l.link = link?.offsetBy(dx: 0, dy: d)
        return l
    }

    let compact: Bool

    /// Cached font metrics and average glyph widths per dynamic-type / compact trait combination,
    /// used both to avoid repeated font descriptor lookups and to estimate post text heights in
    /// pure arithmetic (microseconds per thousand cards) during layout transitions.
    struct Estimator: @unchecked Sendable {
        let metrics: Metrics
        let headlineLineHeight: CGFloat
        let bodyFont: UIFont
        let firstLineHeight: CGFloat
        let lineStep: CGFloat
        let narrowWidth: CGFloat
        let wideWidth: CGFloat

        @MainActor private static var cache: [String: Estimator] = [:]

        @MainActor static func of(_ traits: UITraitCollection) -> Estimator {
            let key = traits.preferredContentSizeCategory.rawValue + (traits[CompactCardsTrait.self] ? "#compact" : "")
            if let e = cache[key] { return e }
            let m = Metrics.of(traits)
            let hl = ceil(max(
                UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits).lineHeight,
                UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight
            ))
            let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            let attrs: [NSAttributedString.Key: Any] = [.font: body]
            let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            let oneLine = ("Ag 文" as NSString).boundingRect(with: unbounded, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).height
            let twoLines = ("Ag 文\nAg 文" as NSString).boundingRect(with: unbounded, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).height
            let latin = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789"
            let han = "的一是不了人我在有他这为之大来以个中上们"
            let latinW = (latin as NSString).boundingRect(with: unbounded, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).width
            let hanW = (han as NSString).boundingRect(with: unbounded, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).width
            let e = Estimator(
                metrics: m,
                headlineLineHeight: hl,
                bodyFont: body,
                firstLineHeight: oneLine,
                lineStep: max(body.lineHeight, twoLines - oneLine),
                narrowWidth: latinW / CGFloat(latin.count),
                wideWidth: hanW / CGFloat(han.count)
            )
            cache[key] = e
            return e
        }

        func estimatedTextHeight(_ text: String, width: CGFloat) -> CGFloat {
            guard width > 0 else { return ceil(firstLineHeight) + 1 }
            let limit = width * 0.94
            var lines = 0
            var lineW: CGFloat = 0
            for scalar in text.unicodeScalars {
                if scalar == "\n" {
                    lines += max(1, Int(ceil(lineW / limit)))
                    lineW = 0
                } else {
                    lineW += scalar.value < 0x0500 ? narrowWidth : wideWidth
                }
            }
            lines += lineW == 0 ? 1 : max(1, Int(ceil(lineW / limit)))
            return ceil(firstLineHeight + CGFloat(max(0, lines - 1)) * lineStep) + 1
        }

        func estimatedCaptionHeight(item it: FeedItem?, width w: CGFloat) -> CGFloat {
            let m = metrics
            var y = m.captionTop
            let inner = w - m.side * 2
            var gap: CGFloat = 0
            var hasHeader = false
            if let it, it.isLoose || it.authorName != nil || it.screenName != nil {
                y += headlineLineHeight
                gap = m.authorGap
                hasHeader = true
            }
            var hasBody = false
            if let text = it?.text, !text.isEmpty {
                y += gap
                y += estimatedTextHeight(text, width: inner)
                gap = m.linkGap
                hasBody = true
            }
            let hasLink = it?.url != nil
            if hasLink {
                y += gap + m.linkHeight
            }
            if !hasHeader && !hasBody && !hasLink { y = 0 }
            return ceil(y + m.tagsGap + m.tagsHeight + m.bottom)
        }

        /// Thread-safe exact caption height (all UIKit fonts and metrics are captured in `self`).
        func exactCaptionHeight(hasAuthor: Bool, text: String?, hasLink: Bool, width w: CGFloat) -> CGFloat {
            let m = metrics
            var y = m.captionTop
            let inner = w - m.side * 2
            var gap: CGFloat = 0
            if hasAuthor {
                y += headlineLineHeight
                gap = m.authorGap
            }
            var hasBody = false
            if let text, !text.isEmpty {
                y += gap
                let r = (text as NSString).boundingRect(
                    with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: bodyFont],
                    context: nil
                )
                y += ceil(r.height) + 1
                gap = m.linkGap
                hasBody = true
            }
            if hasLink {
                y += gap + m.linkHeight
            }
            if !hasAuthor && !hasBody && !hasLink { y = 0 }
            return ceil(y + m.tagsGap + m.tagsHeight + m.bottom)
        }
    }

    @MainActor init(item it: FeedItem?, width w: CGFloat, traits: UITraitCollection) {
        let est = Estimator.of(traits)
        let m = est.metrics
        width = w
        textSize = traits.preferredContentSizeCategory
        compact = traits[CompactCardsTrait.self]
        pagerHeight = ceil(w * (it?.cardMediaRatio ?? 1.25))
        var y = pagerHeight + m.captionTop
        let inner = w - m.side * 2
        var gap: CGFloat = 0
        if let it, it.isLoose || it.authorName != nil || it.screenName != nil {
            let h = est.headlineLineHeight
            author = CGRect(x: m.side, y: y, width: inner, height: h)
            y += h
            gap = m.authorGap
        }
        if let text = it?.text, !text.isEmpty {
            y += gap
            let h = Self.textHeight(text, width: inner, font: est.bodyFont)
            body = CGRect(x: m.side, y: y, width: inner, height: h)
            y += h
            gap = m.linkGap
        }
        if it?.url != nil {
            y += gap
            link = CGRect(x: m.side, y: y, width: inner, height: m.linkHeight)
            y += m.linkHeight
        }
        // no caption at all: the tags follow the media closely
        if author == nil && body == nil && link == nil { y = pagerHeight }
        height = ceil(y + m.tagsGap + m.tagsHeight + m.bottom)
    }

    /// The whole text's height at this width, as the card's text view lays it out.
    static func textHeight(_ text: String, width: CGFloat, font f: UIFont) -> CGFloat {
        let r = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: f], context: nil)
        return ceil(r.height) + 1
    }

    @MainActor static func textHeight(_ text: String, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        textHeight(text, width: width, font: Estimator.of(traits).bodyFont)
    }

}

/// A tag as Finder shows one: a neutral rounded box with a hairline edge, a dot in the colour
/// of where the tag comes from (blue mine, purple AI, green an AI tag I approved), the name in
/// the text colour.
enum TagChip {
    static func color(_ t: TagView) -> UIColor {
        t.isUser && t.isAI ? .systemGreen : (t.isAI ? .systemPurple : .systemBlue)
    }

    /// A dot of this colour, as an image (a button's leading image).
    static func dot(_ color: UIColor, side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The box every chip shares.
    private static func base(_ m: CardLayout.Metrics) -> UIButton.Configuration {
        var cfg = UIButton.Configuration.plain()
        cfg.background.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.035) }
        cfg.background.strokeColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.11) }
        cfg.background.strokeWidth = 1
        cfg.background.cornerRadius = round(m.tagsHeight * 0.3)
        cfg.cornerStyle = .fixed
        cfg.baseForegroundColor = .label
        cfg.contentInsets = .init(top: 0, leading: m.tagPad, bottom: 0, trailing: m.tagPad + 1)
        cfg.imagePadding = m.tagGap
        cfg.titleLineBreakMode = .byTruncatingTail
        let size = m.tagFont
        cfg.titleTextAttributesTransformer = .init { var a = $0; a.font = .systemFont(ofSize: size, weight: .medium); return a }
        return cfg
    }

    static func make(_ t: TagView, metrics m: CardLayout.Metrics = .regular, target: Any?, action: Selector, highlight: [String] = []) -> UIButton {
        var cfg = base(m)
        let marks = SearchHighlight.ranges(of: highlight, in: t.label)
        if marks.isEmpty { cfg.title = t.label } else {
            let a = NSMutableAttributedString(string: t.label)
            for r in marks { a.addAttributes(FeedCell.highlightAttrs, range: r) }
            cfg.attributedTitle = AttributedString(a)
        }
        cfg.image = dot(color(t), side: m.tagDot)
        let b = UIButton(configuration: cfg)
        b.accessibilityIdentifier = t.label
        let who = t.isUser && t.isAI ? L("tag.source.both") : (t.isAI ? "AI" : L("tag.source.me"))
        b.accessibilityValue = who
        if !t.models.isEmpty { b.accessibilityHint = L("tag.taggedBy", t.models.map { ModelStore.shared.displayName($0) }.joined(separator: L("list.separator"))) }
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }
}

extension TagChip {
    /// L("place.recent"): not a tag (cannot be edited or removed); it expires 5 days after the
    /// download. The same box, an orange dot.
    static func recent(metrics m: CardLayout.Metrics = .regular, target: Any?, action: Selector) -> UIButton {
        var cfg = base(m)
        cfg.title = L("place.recent")
        cfg.image = dot(.systemOrange, side: m.tagDot)
        let b = UIButton(configuration: cfg)
        b.accessibilityIdentifier = "recentBadge"
        b.accessibilityHint = L("card.recent.tip.ios")
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }

    /// The "+" at the end of every tag row: the same box, square.
    static func addButton(metrics m: CardLayout.Metrics = .regular, target: Any?, action: Selector) -> UIButton {
        var cfg = base(m)
        cfg.image = UIImage(systemName: "plus")
        cfg.preferredSymbolConfigurationForImage = .init(pointSize: m.tagFont - 2, weight: .semibold)
        cfg.baseForegroundColor = .secondaryLabel
        cfg.contentInsets = .zero
        let b = UIButton(configuration: cfg)
        // a square as tall as the tags beside it (the row places it so)
        b.accessibilityLabel = L("card.addTag")
        b.accessibilityIdentifier = "addTag"
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

/// Scroll view that reports size changes, so pages are laid out once its real size is known.
final class PagerScrollView: UIScrollView {
    var onResize: (() -> Void)?
    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize { lastSize = bounds.size; onResize?() }
    }
}



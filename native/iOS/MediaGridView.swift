import MetalKit
import UIKit

protocol MediaGridViewDelegate: AnyObject {
    func mediaGrid(_ g: MediaGridView, didTap index: Int)
    func mediaGrid(_ g: MediaGridView, menuFor index: Int) -> UIMenu?
    func mediaGrid(_ g: MediaGridView, didSettleAt level: Int)
    func mediaGridSelectionChanged(_ g: MediaGridView)
}

/// The media of a folder or collection as a square grid that zooms like Photos — built on the
/// measured engine (`ZoomEngine`, `GridConfig`, research/FINDINGS.md) and drawn with Metal:
///  * a full-screen `MTKView` draws every tile; a transparent `UIScrollView` on top only gives
///    the scrolling physics and the gestures. Each scroll frame is drawn at once with the offset
///    the scroll view just computed; a 120 Hz display link drives zooms and animations.
///  * pinch: one lattice anchored at the photo under the fingers; 5 / 3 / 1 columns are layers
///    that cross-fade (time plus gesture), latched by direction; release springs to the latched
///    layer. A pinch during the settle takes over; a drag ends the settle at once.
///  * tap opens; long press lifts the tile (a stand-in in the scroll view) into the menu; a
///    removal waits until the menu has flown back, then the later tiles slide into the gap.
///  * "选择": tap tiles, or drag sideways across them, to select.
/// The Mac has the same grid in `MacMediaGridView`.
final class MediaGridView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, MTKViewDelegate, UIContextMenuInteractionDelegate {
    weak var delegate: MediaGridViewDelegate?
    private let metalView = MTKView()
    private let scrollView = UIScrollView()
    private let footerLabel = UILabel()
    private var renderer: GridRenderer?
    private(set) var scene: GridScene?
    private var drawn: [Tile] = []
    private var pinch: UIPinchGestureRecognizer!
    private let drag = UIPanGestureRecognizer()
    private var syncingScroll = false
    private var displayLink: CADisplayLink?
    private var needsDraw = true
    private var frameTime: CFTimeInterval = CACurrentMediaTime()
    private var menuOverlay: UIImageView?
    private var menuDismissing = false
    /// Work held until the menu has flown back (a removal from the menu).
    private var afterMenu: [() -> Void] = []
    private var pendingTiles: [ZoomGridTile]?
    static let footerHeight: CGFloat = 52

    var tiles: [ZoomGridTile] { scene?.tiles ?? pendingTiles ?? [] }
    var selecting = false { didSet { if !selecting { selected = [] }; scene?.selecting = selecting; redraw() } }
    /// Selected tiles by the id of their first media (survives reloads).
    var selected: Set<String> = [] { didSet { scene?.selected = selected; redraw() } }
    var level: Int { scene?.engine.rest.level ?? initialLevel }
    var levelCount: Int { scene?.engine.cfg.levels ?? 3 }
    var columns: Int { scene.map { $0.engine.cfg.columns[$0.engine.rest.level] } ?? 3 }
    var isZooming: Bool { scene?.engine.isZooming == true }
    var initialLevel = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.colorPixelFormat = .bgra8Unorm      // blend in sRGB-encoded space, as Photos does
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.delegate = self
        metalView.frame = bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metalView)
        renderer = GridRenderer(view: metalView, budgetMB: 220)
        renderer?.thumbnails.onLoaded = { [weak self] in self?.needsDraw = true }
        renderer?.thumbnails.onFailed = { MediaLoader.shared.reportIfBroken($0) }

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        scrollView.accessibilityIdentifier = "mediaGrid"
        addSubview(scrollView)
        footerLabel.font = .preferredFont(forTextStyle: .footnote)
        footerLabel.textColor = .secondaryLabel
        footerLabel.textAlignment = .center
        scrollView.addSubview(footerLabel)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        scrollView.addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: pinch)
        scrollView.addGestureRecognizer(tap)
        drag.addTarget(self, action: #selector(dragged(_:)))
        drag.delegate = self
        scrollView.addGestureRecognizer(drag)
        scrollView.addInteraction(UIContextMenuInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)       // keeps firing while the user scrolls
            displayLink = link
        } else if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private var scale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    private func config() -> GridConfig {
        var cfg = GridConfig(width: bounds.width, height: bounds.height, scale: scale,
                             insetTop: safeAreaInsets.top, insetBottom: safeAreaInsets.bottom + Self.footerHeight, count: 0)
        cfg.columns = GridConfig.columns(forWidth: bounds.width)
        return cfg
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let cfg = config()
        if scene == nil {
            let s = GridScene(cfg: cfg, level: initialLevel)
            s.onRestChanged = { [weak self] in self?.applyRestToScroll() }
            s.onContentHeightChanged = { [weak self] in self?.updateContentHeight() }
            s.selecting = selecting
            s.selected = selected
            scene = s
            if let t = pendingTiles { pendingTiles = nil; s.setTiles(t) }
            applyRestToScroll()
            updateThumbnailSizes()
        } else if let s = scene {
            let c = s.engine.cfg
            if c.width != cfg.width || c.height != cfg.height || c.insetTop != cfg.insetTop || c.insetBottom != cfg.insetBottom || c.scale != cfg.scale {
                s.setConfig(cfg)
                if c.width != cfg.width || c.scale != cfg.scale { updateThumbnailSizes() }
            }
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        needsDraw = true
    }

    // MARK: Content

    func setTiles(_ t: [ZoomGridTile], footer: String) {
        footerLabel.text = footer
        guard let scene else { pendingTiles = t; return }
        scene.setTiles(t)
        renderer?.thumbnails.warm(t.map(\.item))
        lastPrefetch = .nan
        let ids = Set(t.map(\.item.mediaId))
        if !selected.isSubset(of: ids) { selected = selected.intersection(ids) }
        redraw()
        updateAccessibility()
    }

    func selectAll(_ on: Bool) {
        selected = on ? Set(tiles.map(\.item.mediaId)) : []
        delegate?.mediaGridSelectionChanged(self)
    }

    /// Runs `work` (a removal) once the long-press menu has flown back to its tile, so the grid
    /// stays still until then; at once when no menu is open.
    func afterMenuCloses(_ work: @escaping () -> Void) {
        if menuDismissing || menuOverlay != nil { afterMenu.append(work) } else { work() }
    }

    private func redraw() { needsDraw = true }

    // MARK: Scroll view ↔ resting layout

    private func applyRestToScroll() {
        guard let scene else { return }
        let cfg = scene.engine.cfg, r = scene.engine.rest
        syncingScroll = true
        scrollView.contentInset = UIEdgeInsets(top: cfg.insetTop, left: 0, bottom: cfg.insetBottom, right: 0)
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: cfg.insetTop, left: 0, bottom: safeAreaInsets.bottom, right: 0)
        let h = cfg.contentHeight(level: r.level, phase: r.phase)
        scrollView.contentSize = CGSize(width: cfg.width, height: h)
        scrollView.contentOffset = CGPoint(x: 0, y: r.offset - cfg.insetTop)
        syncingScroll = false
        placeFooter(h)
        needsDraw = true
        updateAccessibility()
    }

    private func updateContentHeight() {
        guard let scene else { return }
        let cfg = scene.engine.cfg, r = scene.engine.rest
        let h = cfg.contentHeight(level: r.level, phase: r.phase)
        syncingScroll = true
        scrollView.contentSize = CGSize(width: cfg.width, height: h)
        syncingScroll = false
        placeFooter(h)
        let maxOffset = cfg.maxOffset(level: r.level, phase: r.phase)
        if r.offset > maxOffset + 0.5 {
            scrollView.setContentOffset(CGPoint(x: 0, y: maxOffset - cfg.insetTop), animated: true)
        }
        needsDraw = true
    }

    private func placeFooter(_ contentHeight: CGFloat) {
        footerLabel.frame = CGRect(x: 0, y: contentHeight + 8, width: bounds.width, height: Self.footerHeight - 16)
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard !syncingScroll, let scene, !scene.engine.isZooming else { return }
        scene.engine.rest.offset = sv.contentOffset.y + scene.engine.cfg.insetTop
        scene.realignBeforeTopShows()
        // drawn right away with the new offset — once per display frame (see `drawOnce`)
        drawOnce(CACurrentMediaTime())
    }

    /// One draw per display frame at most. A second draw in the same frame waits on the main
    /// thread for a free drawable — a whole frame — which made fast scrolling run at half rate
    /// whenever a thumbnail arrived during it; the extra request waits for the next frame.
    private var linkFrame = 0, drawnFrame = -1
    private func drawOnce(_ t: CFTimeInterval) {
        guard drawnFrame != linkFrame else { needsDraw = true; return }
        drawnFrame = linkFrame
        frameTime = t
        metalView.draw()
        needsDraw = false
    }

    /// A touch during the release settle hands control straight to scrolling.
    func scrollViewWillBeginDragging(_ sv: UIScrollView) {
        if menuDismissing { releaseMenuPhoto() }
        guard let scene, scene.engine.isZooming else { return }
        scene.finishZoomNow()
        if !scene.engine.isZooming { zoomDidEnd() }
    }

    func scrollViewWillEndDragging(_ sv: UIScrollView, withVelocity v: CGPoint, targetContentOffset target: UnsafeMutablePointer<CGPoint>) {
        // a fling that will land near the top re-aligns now, while the content is flying
        guard let scene else { return }
        if target.pointee.y + scene.engine.cfg.insetTop < scene.engine.cfg.height { scene.realignToTop() }
    }

    func scrollViewShouldScrollToTop(_ sv: UIScrollView) -> Bool { scene?.realignToTop(); return true }
    func scrollViewDidEndDecelerating(_ sv: UIScrollView) { if (scene?.engine.rest.offset ?? 1) <= 0.5 { scene?.realignToTop() }; updateAccessibility() }
    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate d: Bool) { if !d { if (scene?.engine.rest.offset ?? 1) <= 0.5 { scene?.realignToTop() }; updateAccessibility() } }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard let scene else { return }
        linkFrame += 1      // a new display frame: one draw allowed again
        if stepZoom != nil { advanceStep(link.targetTimestamp) }
        if scene.isAnimating || needsDraw { drawOnce(link.targetTimestamp) }
        // a reflow (tiles deleted or restored) ends here: the accessibility elements are made then,
        // not while the tiles still move
        if wasAnimating && !scene.isAnimating { updateAccessibility() }
        wasAnimating = scene.isAnimating
    }
    private var wasAnimating = false

    // MARK: Pinch

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === pinch && other === scrollView.panGestureRecognizer
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === drag {
            // only while selecting, and only a sideways start (vertical drags scroll)
            guard selecting, !isZooming else { return false }
            let v = drag.velocity(in: self)
            return abs(v.x) > abs(v.y)
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    private var wasZooming = false

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let scene, !scene.engine.items.isEmpty else { return }
        let f = g.location(in: self)
        let now = CACurrentMediaTime()
        switch g.state {
        case .began:
            stepZoom = nil
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            scrollView.isScrollEnabled = false            // also cancels the pan in flight
            if !scene.engine.isZooming { scene.engine.rest.offset = scrollView.contentOffset.y + scene.engine.cfg.insetTop }
            g.scale = 1                                   // Photos measures scale from recognition, not touch-down
            scene.engine.beginPinch(at: f, time: now)
            frameTime = now
            beginZoomUI()
        case .changed:
            scene.engine.pinchChanged(scale: g.scale, finger: f)
        case .ended, .cancelled, .failed:
            scene.engine.release(velocity: g.velocity, scale: g.scale)
            scrollView.isScrollEnabled = true             // a new touch may scroll during the settle
        default:
            break
        }
    }

    private func beginZoomUI() {
        wasZooming = true
        UIView.animate(withDuration: 0.15) { self.footerLabel.alpha = 0 }
    }

    /// Called after a zoom has come to rest.
    private func zoomDidEnd() {
        wasZooming = false
        scrollView.isScrollEnabled = true
        UIView.animate(withDuration: 0.2) { self.footerLabel.alpha = 1 }
        updateAccessibility()
        delegate?.mediaGrid(self, didSettleAt: level)
    }

    /// One step in (−1) or out (+1) about the middle of the screen, as a short pinch (menus).
    private var stepZoom: (from: CGFloat, to: CGFloat, start: CFTimeInterval, finger: CGPoint)?
    func step(_ delta: Int) {
        guard let scene, !scene.isBusy, !scene.engine.items.isEmpty else { return }
        let r = scene.engine.rest
        let target = min(max(r.level - delta, 0), scene.engine.cfg.levels - 1)
        guard target != r.level else { return }
        let cfg = scene.engine.cfg
        // the scale that lands just past the target's side, so the latch takes it
        let ratio = cfg.side(target) / cfg.side(r.level)
        let mid = CGPoint(x: bounds.midX, y: cfg.insetTop + (bounds.height - cfg.insetTop - cfg.insetBottom) / 2)
        scene.engine.rest.offset = scrollView.contentOffset.y + cfg.insetTop
        let now = CACurrentMediaTime()
        scene.engine.beginPinch(at: mid, time: now)
        scrollView.isScrollEnabled = false
        beginZoomUI()
        stepZoom = (1, ratio, now, mid)
    }

    private func advanceStep(_ now: CFTimeInterval) {
        guard let s = stepZoom, let scene else { return }
        let t = CGFloat(min(1, (now - s.start) / 0.3))
        let e = 1 - pow(1 - t, 3)
        scene.engine.pinchChanged(scale: s.from * pow(s.to / s.from, e), finger: s.finger)
        if t >= 1 {
            stepZoom = nil
            scene.engine.release(velocity: 0, scale: s.to)
        }
    }

    // MARK: Frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let scene, let renderer else { return }
        let zooming = scene.engine.isZooming
        scene.frame(at: frameTime, into: &drawn)
        if zooming && !scene.engine.isZooming { zoomDidEnd() }
        let bg = UIColor.systemBackground.resolvedColor(with: traitCollection)
        let ph = UIColor.secondarySystemBackground.resolvedColor(with: traitCollection)
        renderer.placeholder = Self.simd(ph)
        let c = Self.simd(bg)
        renderer.draw(drawn, in: metalView, scale: scale, background: MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1)) { key in
            scene.tile(key: key).map { ($0.item, $0.count, scene.isSelected(key: key)) }
        }
        prefetch()
    }

    private var lastPrefetch: CGFloat = .nan
    /// At rest, the small thumbnails of two screens above and below are made ready, again each
    /// time the grid has moved a third of a screen.
    private func prefetch() {
        guard let scene, let renderer, !scene.isAnimating else { return }
        let r = scene.engine.rest
        guard lastPrefetch.isNaN || abs(r.offset - lastPrefetch) > scene.engine.cfg.height / 3 else { return }
        lastPrefetch = r.offset
        renderer.thumbnails.prefetch(scene.nearbyKeys(screens: 2).compactMap { scene.tile(key: $0)?.item })
    }

    /// Thumbnail sizes follow the levels; a whole new set is put on disk in the background.
    private func updateThumbnailSizes() {
        guard let scene, let renderer else { return }
        renderer.setThumbnailSizes(scene.engine.cfg)
        renderer.thumbnails.warm(scene.tiles.map(\.item))
        lastPrefetch = .nan
    }
    private static func simd(_ c: UIColor) -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), 1)
    }

    // MARK: Tap and drag selection

    private func index(at p: CGPoint) -> Int? {
        guard let scene, !scene.isAnimating else { return nil }
        return scene.engine.restIndex(at: p)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let i = index(at: g.location(in: self)) else { return }
        if selecting { toggle(i) } else { delegate?.mediaGrid(self, didTap: i) }
    }

    private func toggle(_ i: Int) {
        guard let id = scene?.tile(at: i)?.item.mediaId else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        delegate?.mediaGridSelectionChanged(self)
    }

    private var dragStart: Int?
    private var dragSelects = true
    private var dragBase: Set<String> = []

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            guard let i = index(at: p), let id = scene?.tile(at: i)?.item.mediaId else { return }
            dragStart = i
            dragBase = selected
            dragSelects = !selected.contains(id)
            fallthrough
        case .changed:
            guard let s = dragStart, let i = index(at: p) else { return }
            let ids = Set(tiles[min(s, i)...max(s, i)].map(\.item.mediaId))
            selected = dragSelects ? dragBase.union(ids) : dragBase.subtracting(ids)
            delegate?.mediaGridSelectionChanged(self)
        default:
            dragStart = nil
        }
    }

    // MARK: Long-press menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let scene, let i = index(at: interaction.view!.convert(location, to: self)),
              let tile = scene.tile(at: i), let menu = delegate?.mediaGrid(self, menuFor: i) else { return nil }
        let item = tile.item
        let key = scene.engine.items[i]
        let start = MediaLoader.shared.anyCached(item, near: 600) ?? renderer?.thumbnails.image(for: item).map { UIImage(cgImage: $0) }
        return UIContextMenuConfiguration(identifier: NSNumber(value: key), previewProvider: { [weak self] in
            GridPreviewController(item: item, placeholder: start, bounds: self?.window?.bounds ?? UIScreen.main.bounds)
        }) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let key = (identifier as? NSNumber)?.intValue, let overlay = makeOverlay(key: key) else { return nil }
        let p = UIPreviewParameters()
        p.visiblePath = UIBezierPath(roundedRect: overlay.bounds, cornerRadius: GridConfig.cornerRadius)
        return UITargetedPreview(view: overlay, parameters: p)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        // the menu flies back to the tile's place, which has not moved (a removal waits for this)
        guard let overlay = menuOverlay else { return nil }
        let p = UIPreviewParameters()
        p.visiblePath = UIBezierPath(roundedRect: overlay.bounds, cornerRadius: GridConfig.cornerRadius)
        return UITargetedPreview(view: overlay, parameters: p)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        menuDismissing = true
        let finish = { [weak self] in
            guard let self else { return }
            self.menuDismissing = false
            // draw the tile back into the grid first and drop the stand-in a frame later, so no
            // frame shows neither
            self.scene?.engine.hiddenPhoto = nil
            self.frameTime = CACurrentMediaTime()
            self.metalView.draw()
            let overlay = self.menuOverlay
            self.menuOverlay = nil
            DispatchQueue.main.async {
                overlay?.removeFromSuperview()
                let work = self.afterMenu
                self.afterMenu = []
                work.forEach { $0() }
            }
        }
        if let animator { animator.addCompletion(finish) } else { finish() }
    }

    /// Scrolling while the menu is still flying back: UIKit aims at where the tile was and does
    /// not follow the scroll, so the tile goes back to the grid now and the stand-in fades out.
    private func releaseMenuPhoto() {
        guard scene?.engine.hiddenPhoto != nil else { return }
        scene?.engine.hiddenPhoto = nil
        frameTime = CACurrentMediaTime()
        metalView.draw()
        if let overlay = menuOverlay { UIView.animate(withDuration: 0.12) { overlay.alpha = 0 } }
    }

    /// A UIKit stand-in for the lifted tile, exactly over it, inside the scroll view (it moves
    /// with the grid if scrolling starts while the menu flies back); the grid stops drawing it.
    private func makeOverlay(key: Int) -> UIImageView? {
        guard let scene, let index = scene.engine.items.firstIndex(of: key), let tile = scene.tile(key: key) else { return nil }
        let frame = scene.engine.restFrame(index, scene.engine.rest)
        menuOverlay?.removeFromSuperview()
        let iv = UIImageView(image: renderer?.thumbnails.image(for: tile.item).map { UIImage(cgImage: $0) })
        iv.backgroundColor = .secondarySystemBackground
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.frame = convert(frame, to: scrollView)
        scrollView.addSubview(iv)
        menuOverlay = iv
        scene.engine.hiddenPhoto = key
        needsDraw = true
        return iv
    }

    // MARK: Accessibility

    /// The tiles on screen, as buttons (selected ones marked), in reading order.
    private func updateAccessibility() {
        guard let scene, !scene.isAnimating else { return }
        var out: [Tile] = []
        scene.engine.restTiles(scene.engine.rest, into: &out)
        var els: [UIAccessibilityElement] = []
        for t in out.sorted(by: { $0.index < $1.index }) {
            guard let tile = scene.tile(key: t.photo) else { continue }
            let f = CGRect(x: t.x, y: t.y, width: t.side, height: t.side)
            guard f.intersects(bounds) else { continue }
            let e = UIAccessibilityElement(accessibilityContainer: scrollView)
            e.accessibilityFrameInContainerSpace = convert(f, to: scrollView)
            e.accessibilityIdentifier = tile.item.kind == .video ? "grid-video" : "grid-photo"
            e.accessibilityLabel = (tile.item.kind == .video ? L("place.videos") : L("place.photos")) + (tile.count > 1 ? L("grid.tile.postCount", tile.count) : "")
            let sel = selecting && selected.contains(tile.item.mediaId)
            e.accessibilityTraits = sel ? [.button, .selected] : .button
            els.append(e)
        }
        scrollView.accessibilityElements = els + [footerLabel]
    }
}

/// The long-press preview: the whole media, never cropped, at one large size whatever the grid's
/// column count — as wide as the screen allows (or 70 % of its height for tall media).
final class GridPreviewController: UIViewController {
    private let item: FeedItem
    private let imageView = UIImageView()
    private let area: CGSize

    init(item: FeedItem, placeholder: UIImage?, bounds: CGRect) {
        self.item = item
        area = CGSize(width: bounds.width - 24, height: bounds.height * 0.7)
        super.init(nibName: nil, bundle: nil)
        imageView.image = placeholder
        fit(placeholder?.size)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fit(_ size: CGSize?) {
        guard let size, size.width > 0, size.height > 0 else { preferredContentSize = CGSize(width: area.width, height: area.width); return }
        let k = min(area.width / size.width, area.height / size.height)
        preferredContentSize = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "gridPreview"
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
        if item.kind == .video {
            let play = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44)))
            play.tintColor = .white
            play.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(play)
            NSLayoutConstraint.activate([play.centerXAnchor.constraint(equalTo: view.centerXAnchor), play.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        }
        let px = max(area.width, area.height) * (view.window?.screen.scale ?? 3)
        MediaLoader.shared.load(item, maxPixel: px) { [weak self] img in
            guard let self, let img else { return }
            self.imageView.image = img
            self.fit(img.size)
        }
    }
}

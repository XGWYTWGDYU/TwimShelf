import AppKit
import MetalKit

protocol MacMediaGridDelegate: AnyObject {
    func mediaGrid(_ g: MacMediaGridView, didOpen index: Int)
    func mediaGrid(_ g: MacMediaGridView, menuFor index: Int) -> NSMenu?
    func mediaGrid(_ g: MacMediaGridView, didSettleAt level: Int)
    func mediaGridSelectionChanged(_ g: MacMediaGridView)
}

/// The zoomable media grid on the Mac — the same grid as `MediaGridView` on iOS, on the same
/// measured engine (`ZoomEngine`, research/FINDINGS.md) and Metal renderer:
///  * a `MTKView` draws every tile; a transparent `NSScrollView` on top gives the scrolling
///    (momentum, elastic edges, the scroller) and receives the trackpad. Each scroll frame is
///    drawn at once with the new offset; a display link drives zooms and animations.
///  * pinch the trackpad to zoom between the three levels exactly as on the phone (the pointer
///    is the fingers); a two-finger double tap, ⌘+ / ⌘− or the … menu go one level. Scrolling
///    during the settle ends it at once.
///  * click opens a media (toggles it while selecting; drag across tiles to select several);
///    right-click gives the same menu as a long press on iOS.
final class MacMediaGridView: NSView {
    weak var delegate: MacMediaGridDelegate?
    private let metalView = MTKView()
    private let scrollView = GridScrollView()
    private let document = GridDocumentView()
    private let footerLabel = NSTextField(labelWithString: "")
    private var renderer: GridRenderer?
    private(set) var scene: GridScene?
    private var drawn: [Tile] = []
    private var link: CADisplayLink?
    private var needsDraw = true
    private var frameTime: CFTimeInterval = CACurrentMediaTime()
    private var syncingScroll = false
    private var pendingTiles: [ZoomGridTile]?
    fileprivate var lastPrefetch: CGFloat = .nan
    static let footerHeight: CGFloat = 52
    /// Extra room at the bottom (the selection bar while selecting).
    var bottomInset: CGFloat = 0 { didSet { needsLayout = true } }

    var tiles: [ZoomGridTile] { scene?.tiles ?? pendingTiles ?? [] }
    var selecting = false { didSet { if !selecting { selected = [] }; scene?.selecting = selecting; needsDraw = true } }
    var selected: Set<String> = [] { didSet { scene?.selected = selected; needsDraw = true } }
    var initialLevel = 1
    var level: Int { scene?.engine.rest.level ?? initialLevel }
    var levelCount: Int { scene?.engine.cfg.levels ?? 3 }
    var columns: Int { scene.map { $0.engine.cfg.columns[$0.engine.rest.level] } ?? 0 }
    var isZooming: Bool { scene?.engine.isZooming == true }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("mediaGrid")
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.colorPixelFormat = .bgra8Unorm      // blend in sRGB-encoded space, as Photos does
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.delegate = self
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)
        renderer = GridRenderer(view: metalView, budgetMB: 400)
        renderer?.thumbnails.onLoaded = { [weak self] in self?.needsDraw = true }
        renderer?.thumbnails.onFailed = { MacMediaLoader.shared.reportIfBroken($0) }

        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = document
        scrollView.autoresizingMask = [.width, .height]
        scrollView.grid = self
        document.grid = self
        addSubview(scrollView)
        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.alignment = .center
        document.addSubview(footerLabel)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, link == nil {
            let l = displayLink(target: self, selector: #selector(frameTick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else if window == nil {
            link?.invalidate()
            link = nil
        }
        needsDraw = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDraw = true
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func config() -> GridConfig {
        var cfg = GridConfig(width: bounds.width, height: bounds.height, scale: scale,
                             insetTop: safeAreaInsets.top, insetBottom: Self.footerHeight + bottomInset, count: 0)
        cfg.columns = GridConfig.columns(forWidth: bounds.width)
        return cfg
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        scrollView.frame = bounds
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

    // MARK: Content

    func setTiles(_ t: [ZoomGridTile], footer: String) {
        footerLabel.stringValue = footer
        guard let scene else { pendingTiles = t; return }
        scene.setTiles(t)
        renderer?.thumbnails.warm(t.map(\.item))
        lastPrefetch = .nan
        let ids = Set(t.map(\.item.mediaId))
        if !selected.isSubset(of: ids) { selected = selected.intersection(ids) }
        needsDraw = true
    }

    func selectAll(_ on: Bool) {
        selected = on ? Set(tiles.map(\.item.mediaId)) : []
        delegate?.mediaGridSelectionChanged(self)
    }

    // MARK: Scroll view ↔ resting layout

    /// The scroll offset in the engine's terms: the content y at the top inset line.
    private var offset: CGFloat { scrollView.contentView.bounds.origin.y + (scene?.engine.cfg.insetTop ?? 0) }

    private func applyRestToScroll() {
        guard let scene else { return }
        let cfg = scene.engine.cfg, r = scene.engine.rest
        syncingScroll = true
        scrollView.contentInsets = NSEdgeInsets(top: cfg.insetTop, left: 0, bottom: cfg.insetBottom, right: 0)
        let h = cfg.contentHeight(level: r.level, phase: r.phase)
        document.frame = NSRect(x: 0, y: 0, width: cfg.width, height: max(h, 1))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: r.offset - cfg.insetTop))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        syncingScroll = false
        placeFooter(h)
        needsDraw = true
    }

    private func updateContentHeight() {
        guard let scene else { return }
        let cfg = scene.engine.cfg, r = scene.engine.rest
        let h = cfg.contentHeight(level: r.level, phase: r.phase)
        syncingScroll = true
        document.frame.size.height = max(h, 1)
        syncingScroll = false
        placeFooter(h)
        let maxOffset = cfg.maxOffset(level: r.level, phase: r.phase)
        if r.offset > maxOffset + 0.5 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = .springy
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: maxOffset - cfg.insetTop))
            }
        }
        needsDraw = true
    }

    private func placeFooter(_ contentHeight: CGFloat) {
        footerLabel.frame = NSRect(x: 0, y: contentHeight + 14, width: bounds.width, height: 18)
    }

    @objc private func scrolled() {
        guard !syncingScroll, let scene, !scene.engine.isZooming else { return }
        scene.engine.rest.offset = offset
        scene.realignBeforeTopShows()
        if scene.engine.rest.offset <= 0.5 { scene.realignToTop() }
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

    /// A scroll starting during the release settle hands control straight to scrolling.
    fileprivate func scrollWillBegin() {
        guard let scene, scene.engine.isZooming, !(scene.engine.zoom?.pinching == true) else { return }
        scene.finishZoomNow()
        if !scene.engine.isZooming { zoomDidEnd() }
    }

    @objc private func frameTick(_ l: CADisplayLink) {
        guard let scene else { return }
        linkFrame += 1      // a new display frame: one draw allowed again
        #if DEBUG
        bench?.tick(self, l)
        #endif
        if stepZoom != nil { advanceStep(l.targetTimestamp) }
        if scene.isAnimating || needsDraw { drawOnce(l.targetTimestamp) }
    }

    // MARK: Pinch (trackpad)

    private var pinchScale: CGFloat = 1
    private var pinchSamples: [(t: CFTimeInterval, s: CGFloat)] = []

    fileprivate func magnify(_ e: NSEvent) {
        guard let scene, !scene.engine.items.isEmpty else { return }
        let f = convert(e.locationInWindow, from: nil)
        let now = CACurrentMediaTime()
        switch e.phase {
        case .began:
            stepZoom = nil
            if !scene.engine.isZooming { scene.engine.rest.offset = offset }
            pinchScale = 1
            pinchSamples = [(now, 1)]
            scene.engine.beginPinch(at: f, time: now)
            frameTime = now
            beginZoomUI()
        case .changed:
            guard (scene.engine.zoom?.pinching == true) else { return }
            pinchScale *= 1 + e.magnification
            pinchSamples.append((now, pinchScale))
            pinchSamples.removeAll { now - $0.t > 0.12 }
            scene.engine.pinchChanged(scale: pinchScale, finger: f)
        case .ended, .cancelled:
            guard (scene.engine.zoom?.pinching == true) else { return }
            var v: CGFloat = 0
            if let first = pinchSamples.first, now - first.t > 0.01 { v = (pinchScale - first.s) / CGFloat(now - first.t) }
            if now - (pinchSamples.last?.t ?? 0) > 0.08 { v = 0 }     // the fingers stopped before lifting
            scene.engine.release(velocity: v, scale: pinchScale)
        default:
            break
        }
    }

    private func beginZoomUI() {
        scrollView.isZooming = true
        footerLabel.animator().alphaValue = 0
    }

    private func zoomDidEnd() {
        scrollView.isZooming = false
        footerLabel.animator().alphaValue = 1
        delegate?.mediaGrid(self, didSettleAt: level)
    }

    /// One level in (−1) or out (+1) about the middle, as a short pinch (keys, menus).
    private var stepZoom: (to: CGFloat, start: CFTimeInterval, finger: CGPoint)?
    func step(_ delta: Int) {
        guard let scene, !scene.isBusy, !scene.engine.items.isEmpty else { return }
        let r = scene.engine.rest, cfg = scene.engine.cfg
        let target = min(max(r.level - delta, 0), cfg.levels - 1)
        guard target != r.level else { return }
        let mid = CGPoint(x: bounds.midX, y: (bounds.height - cfg.insetBottom) / 2)
        scene.engine.rest.offset = offset
        let now = CACurrentMediaTime()
        scene.engine.beginPinch(at: mid, time: now)
        beginZoomUI()
        stepZoom = (cfg.side(target) / cfg.side(r.level), now, mid)
    }

    private func advanceStep(_ now: CFTimeInterval) {
        guard let s = stepZoom, let scene else { return }
        let t = CGFloat(min(1, (now - s.start) / 0.3))
        let e = 1 - pow(1 - t, 3)
        scene.engine.pinchChanged(scale: pow(s.to, e), finger: s.finger)
        if t >= 1 { stepZoom = nil; scene.engine.release(velocity: 0, scale: s.to) }
    }

    /// Two-finger double tap: one level in, or back out from the biggest.
    fileprivate func smartMagnify() { step(level < levelCount - 1 ? -1 : 1) }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, window?.firstResponder === document else {
            return super.performKeyEquivalent(with: e)
        }
        switch e.charactersIgnoringModifiers {
        case "=", "+": step(-1); return true
        case "-": step(1); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    // MARK: Clicks, selection, menu

    fileprivate func index(at p: NSPoint) -> Int? {
        guard let scene, !scene.isAnimating else { return nil }
        return scene.engine.restIndex(at: convert(p, from: document))
    }

    private var dragStart: Int?
    private var dragSelects = true
    private var dragBase: Set<String> = []
    private var dragged = false

    fileprivate func mouseDown(at p: NSPoint) {
        dragged = false
        dragStart = index(at: p)
        dragBase = selected
        if let i = dragStart, let id = scene?.tile(at: i)?.item.mediaId { dragSelects = !selected.contains(id) }
    }

    fileprivate func mouseDragged(to p: NSPoint) {
        guard selecting, let s = dragStart, let i = index(at: p) else { return }
        dragged = true
        let ids = Set(tiles[min(s, i)...max(s, i)].map(\.item.mediaId))
        selected = dragSelects ? dragBase.union(ids) : dragBase.subtracting(ids)
        delegate?.mediaGridSelectionChanged(self)
    }

    fileprivate func mouseUp(at p: NSPoint) {
        defer { dragStart = nil }
        guard !dragged, let i = index(at: p), i == dragStart else { return }
        if selecting {
            guard let id = scene?.tile(at: i)?.item.mediaId else { return }
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            delegate?.mediaGridSelectionChanged(self)
        } else {
            delegate?.mediaGrid(self, didOpen: i)
        }
    }

    fileprivate func menu(at p: NSPoint) -> NSMenu? {
        guard let i = index(at: p) else { return nil }
        return delegate?.mediaGrid(self, menuFor: i)
    }

    #if DEBUG
    fileprivate var bench: GridBench?
    fileprivate var debugDrawMS: Double = 0
    /// Scrolls and zooms fast, measuring frame times and tiles drawn without a picture
    /// (TL_GRID_BENCH); writes the report and calls `done`.
    func debugBench(out: URL, label: String, done: @escaping () -> Void) {
        bench = GridBench(out: out, label: label) { [weak self] in self?.bench = nil; done() }
    }
    func debugScrollBy(_ dy: CGFloat) { debugScroll(by: dy) }
    fileprivate func debugScroll(by dy: CGFloat) {
        guard let scene else { return }
        let cfg = scene.engine.cfg, r = scene.engine.rest
        let maxY = cfg.maxOffset(level: r.level, phase: r.phase) - cfg.insetTop
        let y = min(max(scrollView.contentView.bounds.origin.y + dy, -cfg.insetTop), maxY)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
    }
    fileprivate var debugAtBottom: Bool {
        guard let scene else { return true }
        let r = scene.engine.rest
        return r.offset >= scene.engine.cfg.maxOffset(level: r.level, phase: r.phase) - 1
    }
    fileprivate func debugPinchBegin(at p: CGPoint) {
        guard let scene else { return }
        scene.engine.rest.offset = offset
        scene.engine.beginPinch(at: p, time: CACurrentMediaTime())
        beginZoomUI()
    }
    fileprivate func debugPinchChange(_ s: CGFloat, at p: CGPoint) { scene?.engine.pinchChanged(scale: s, finger: p) }
    fileprivate func debugPinchEnd(_ s: CGFloat) { scene?.engine.release(velocity: 0, scale: s) }
    fileprivate var debugBlank: (Int, Int) { (renderer?.lastBlank ?? 0, renderer?.lastTileCount ?? 0) }

    /// The resting frame of tile i, in this view (the tour).
    func debugTileFrame(_ i: Int) -> CGRect? {
        guard let scene, i < scene.engine.items.count else { return nil }
        return scene.engine.restFrame(i, scene.engine.rest)
    }
    /// Pinches as a trackpad would: one scale per frame from `at` (the tour).
    func debugPinch(at p: CGPoint, scales: [CGFloat]) {
        guard let scene else { return }
        scene.engine.rest.offset = offset
        scene.engine.beginPinch(at: p, time: CACurrentMediaTime())
        beginZoomUI()
        for (k, s) in scales.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k + 1) / 60) { [weak self] in
                self?.scene?.engine.pinchChanged(scale: s, finger: p)
                self?.debugLastScale = s
            }
        }
    }
    private var debugLastScale: CGFloat = 1
    /// What the grid shows now, as a PNG (the tour).
    func debugSnapshot(to url: URL) {
        guard let scene, let renderer else { return }
        var t: [Tile] = []
        scene.frame(at: CACurrentMediaTime(), into: &t)
        guard let img = renderer.snapshot(t, size: bounds.size, scale: scale, background: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1), info: { key in
            scene.tile(key: key).map { ($0.item, $0.count, scene.isSelected(key: key)) }
        }) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    func debugRelease() { scene?.engine.release(velocity: 0, scale: debugLastScale) }
    var debugInfo: String {
        guard let scene else { return "-" }
        let i = scene.engine.info()
        return String(format: "columns %d side %.1f fade %.2f → %d %@", i.columns, i.side, i.level, scene.engine.cfg.columns[i.target], scene.engine.isZooming ? "zooming" : "rest")
    }
    #endif
}

extension MacMediaGridView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let scene, let renderer else { return }
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { debugDrawMS = (CACurrentMediaTime() - t0) * 1000 }
        #endif
        let zooming = scene.engine.isZooming
        scene.frame(at: frameTime, into: &drawn)
        if zooming && !scene.engine.isZooming { zoomDidEnd() }
        var bg = SIMD4<Float>(1, 1, 1, 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bg = Self.simd(.windowBackgroundColor)
            renderer.placeholder = Self.simd(.quaternaryLabelColor, over: .windowBackgroundColor)
        }
        renderer.draw(drawn, in: metalView, scale: scale, background: MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)) { key in
            scene.tile(key: key).map { ($0.item, $0.count, scene.isSelected(key: key)) }
        }
        prefetch()
    }

    private static func simd(_ c: NSColor, over base: NSColor? = nil) -> SIMD4<Float> {
        guard let s = c.usingColorSpace(.sRGB) else { return SIMD4(0.5, 0.5, 0.5, 1) }
        var r = s.redComponent, g = s.greenComponent, b = s.blueComponent
        if let base = base?.usingColorSpace(.sRGB) {
            let a = s.alphaComponent
            r = r * a + base.redComponent * (1 - a); g = g * a + base.greenComponent * (1 - a); b = b * a + base.blueComponent * (1 - a)
        }
        return SIMD4(Float(r), Float(g), Float(b), 1)
    }

    /// At rest, the small thumbnails of two screens above and below are made ready, again each
    /// time the grid has moved a third of a screen.
    fileprivate func prefetch() {
        guard let scene, let renderer, !scene.isAnimating else { return }
        let r = scene.engine.rest
        guard lastPrefetch.isNaN || abs(r.offset - lastPrefetch) > scene.engine.cfg.height / 3 else { return }
        lastPrefetch = r.offset
        renderer.thumbnails.prefetch(scene.nearbyKeys(screens: 2).compactMap { scene.tile(key: $0)?.item })
    }

    /// Thumbnail sizes follow the levels; a whole new set is put on disk in the background.
    fileprivate func updateThumbnailSizes() {
        guard let scene, let renderer else { return }
        renderer.setThumbnailSizes(scene.engine.cfg)
        renderer.thumbnails.warm(scene.tiles.map(\.item))
        lastPrefetch = .nan
    }
}

/// Ignores scrolling while a zoom runs; a scroll starting during a settle ends it.
private final class GridScrollView: NSScrollView {
    weak var grid: MacMediaGridView?
    var isZooming = false
    override func scrollWheel(with e: NSEvent) {
        if e.phase == .began || (e.phase == [] && e.momentumPhase == []) { grid?.scrollWillBegin() }
        if isZooming { return }
        super.scrollWheel(with: e)
    }
    override func magnify(with e: NSEvent) { grid?.magnify(e) }
    override func smartMagnify(with e: NSEvent) { grid?.smartMagnify() }
}

/// The scroll view's content: as tall as the grid, transparent; takes the clicks.
private final class GridDocumentView: NSView {
    weak var grid: MacMediaGridView?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    private func point(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); grid?.mouseDown(at: point(e)) }
    override func mouseDragged(with e: NSEvent) { grid?.mouseDragged(to: point(e)) }
    override func mouseUp(with e: NSEvent) { grid?.mouseUp(at: point(e)) }
    override func menu(for e: NSEvent) -> NSMenu? { grid?.menu(at: point(e)) }
    override func magnify(with e: NSEvent) { grid?.magnify(e) }
    override func smartMagnify(with e: NSEvent) { grid?.smartMagnify() }
}

#if DEBUG
/// The grid benchmark: phases of fast scrolling and zooming, driven by the display link.
fileprivate final class GridBench {
    struct Sample { var interval: Double; var draw: Double; var blank: Int; var tiles: Int }
    private let out: URL, label: String, done: () -> Void
    private var phase = 0
    private var phaseStart: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var samples: [String: [Sample]] = [:]
    private var order: [String] = []
    private let names = ["scroll-down", "scroll-up", "zoom-out-in", "settle", "scroll-small", "zoom-in-big", "settle2"]

    init(out: URL, label: String, done: @escaping () -> Void) { self.out = out; self.label = label; self.done = done }

    func tick(_ g: MacMediaGridView, _ l: CADisplayLink) {
        let now = l.timestamp
        if phaseStart == 0 { phaseStart = now; last = now; begin(g); return }
        let dt = now - last
        last = now
        let t = now - phaseStart
        let name = names[phase]
        if samples[name] == nil { order.append(name) }
        let (b, n) = g.debugBlank
        samples[name, default: []].append(Sample(interval: dt * 1000, draw: g.debugDrawMS, blank: b, tiles: n))
        let mid = CGPoint(x: g.bounds.midX, y: g.bounds.midY)
        switch name {
        case "scroll-down", "scroll-small": g.debugScroll(by: 5000 * dt)           // 5000 pt/s, a hard fling
        case "scroll-up": g.debugScroll(by: -5000 * dt)
        case "zoom-out-in": g.debugPinchChange(CGFloat(exp(-0.7 * sin(t * 2.2))), at: mid)   // out to the densest and back, repeatedly
        case "zoom-in-big": g.debugPinchChange(CGFloat(exp(min(t, 1.2) * 1.4)), at: mid)
        default: break
        }
        let length: Double = ["settle": 1.2, "settle2": 1.2, "zoom-in-big": 1.6][name] ?? 3
        if t >= length { next(g) }
    }

    private func begin(_ g: MacMediaGridView) {
        let name = names[phase]
        let mid = CGPoint(x: g.bounds.midX, y: g.bounds.midY)
        if name == "zoom-out-in" || name == "zoom-in-big" { g.debugPinchBegin(at: mid) }
    }

    private func next(_ g: MacMediaGridView) {
        let name = names[phase]
        if name == "zoom-out-in" { g.debugPinchEnd(CGFloat(exp(-0.7 * sin(3 * 2.2)))) }
        if name == "zoom-in-big" { g.debugPinchEnd(CGFloat(exp(1.2 * 1.4))) }
        phase += 1
        phaseStart = last
        guard phase < names.count else { report(); done(); return }
        begin(g)
    }

    private func report() {
        func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
        var lines = ["# \(label)"]
        for name in order {
            let s = samples[name] ?? []
            let iv = s.map(\.interval), dr = s.map(\.draw)
            let budget = pct(iv, 0.5)
            let hitches = iv.filter { $0 > budget * 1.5 }.count
            let blankFrames = s.filter { $0.blank > 0 }.count
            let blankShare = s.map { Double($0.blank) / Double(max(1, $0.tiles)) }
            lines.append(String(format: "%@: frames %d, interval p50 %.1f ms max %.1f, hitches %d, draw p50 %.2f p95 %.2f max %.2f ms, frames with blanks %d (%.0f%%), blank tiles avg %.1f%% max %.1f%%",
                                name, s.count, budget, iv.max() ?? 0, hitches, pct(dr, 0.5), pct(dr, 0.95), dr.max() ?? 0,
                                blankFrames, 100 * Double(blankFrames) / Double(max(1, s.count)),
                                100 * blankShare.reduce(0, +) / Double(max(1, s.count)), 100 * (blankShare.max() ?? 0)))
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: out) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close() }
        else { try? text.write(to: out, atomically: true, encoding: .utf8) }
    }
}
#endif

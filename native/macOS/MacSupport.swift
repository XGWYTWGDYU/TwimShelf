import AppKit
import AVFoundation
import ImageIO

/// Off-main thumbnail decoding with an in-memory cache (AppKit counterpart of MediaLoader).
final class MacMediaLoader {
    static let shared = MacMediaLoader()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "mac.media.decode", qos: .userInitiated, attributes: .concurrent)

    private var pressureObserver: NSObjectProtocol?
    private var generation = 0
    init() {
        cache.totalCostLimit = 192 * 1024 * 1024
        pressureObserver = NotificationCenter.default.addObserver(forName: MemoryPressure.changed, object: nil, queue: .main) { [weak self] _ in self?.forget() }
        Self.targetSpace = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// The screen's color space: pictures are converted to it while decoding, on a worker.
    /// Otherwise Core Animation converts every picture on the main thread as it first draws it,
    /// which was the largest single cost of a fast scroll.
    nonisolated(unsafe) private static var targetSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Drops cached thumbnails (after a file was replaced).
    func forget() { generation &+= 1; cache.removeAllObjects(); reported.removeAll(); prefetchJobs = [] }
    deinit { if let pressureObserver { NotificationCenter.default.removeObserver(pressureObserver) } }

    /// Whether a picture is already decoded (shown at once, no fade).
    func isCached(_ item: FeedItem, maxPixel: CGFloat) -> Bool { cache.object(forKey: "\(item.path)@\(Int(maxPixel))" as NSString) != nil }

    /// Media that failed to decode are reported to the core once per launch, which verifies the
    /// file and records the damage (the card then shows a badge and offers a re-download).
    private var reported = Set<String>()
    func reportIfBroken(_ item: FeedItem) {
        guard !reported.contains(item.mediaId) else { return }
        reported.insert(item.mediaId)
        // async all the way (a thread blocked on a semaphore while Swift concurrency loads the
        // asset could starve the shared thread pool)
        Task.detached(priority: .utility) {
            // A video whose poster frame failed may still play fine: only an unplayable one counts.
            if item.kind == .video, (try? await AVURLAsset(url: item.fileURL).load(.isPlayable)) == true { return }
            let reason = Core.reportBad(item.mediaId)
            if reason != item.bad { await MainActor.run { NotificationCenter.default.post(name: .libraryChanged, object: nil) } }
        }
    }

    /// A request a caller may cancel (a card scrolled away no longer needs its picture).
    typealias Token = UInt64

    @discardableResult
    func load(_ item: FeedItem, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) -> Token? {
        load(path: item.path, isVideo: item.kind == .video, maxPixel: maxPixel, completion: completion)
    }

    /// Cached pictures come back at once (no flash); others are decoded by a few workers, the
    /// newest request first, so a fast scroll decodes what is on screen now instead of a backlog
    /// of cards already gone. Main thread only.
    @discardableResult
    func load(path: String, isVideo: Bool, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) -> Token? {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = "\(path)@\(Int(maxPixel))"
        if let img = cache.object(forKey: key as NSString) { completion(img); return nil }
        nextToken += 1
        let token = nextToken
        waiting[key, default: []].append((token, completion))
        #if DEBUG
        let t0 = CACurrentMediaTime(); debugRequests += 1
        debugStart[token] = t0
        #endif
        if !running.contains(key) {
            prefetchJobs.removeAll { $0.key == key }
            jobs.removeAll { $0.key == key }
            jobs.append(Job(key: key, path: path, isVideo: isVideo, maxPixel: maxPixel))
        }
        pump()
        return token
    }

    /// Forgets a request; its picture is not decoded if nobody else wants it.
    func cancel(_ token: Token?) {
        guard let token else { return }
        for (k, list) in waiting where list.contains(where: { $0.0 == token }) {
            let rest = list.filter { $0.0 != token }
            waiting[k] = rest.isEmpty ? nil : rest
            if rest.isEmpty { jobs.removeAll { $0.key == k } }
        }
    }

    /// Decodes pictures about to scroll into view, after everything visible.
    func prefetch(_ items: [FeedItem], maxPixel: CGFloat) {
        var fresh: [Job] = []
        for it in items {
            let key = "\(it.path)@\(Int(maxPixel))"
            guard cache.object(forKey: key as NSString) == nil, !running.contains(key), !jobs.contains(where: { $0.key == key }) else { continue }
            fresh.append(Job(key: key, path: it.path, isVideo: it.kind == .video, maxPixel: maxPixel))
        }
        prefetchJobs = Array((prefetchJobs.filter { j in !fresh.contains { $0.key == j.key } } + fresh).suffix(24))
        pump()
    }

    private struct Job { let key: String; let path: String; let isVideo: Bool; let maxPixel: CGFloat }
    private var nextToken: Token = 0
    private var waiting: [String: [(Token, (NSImage?) -> Void)]] = [:]
    private var jobs: [Job] = []          // wanted now, newest last
    private var prefetchJobs: [Job] = []  // ahead of the scroll, newest last
    private var running = Set<String>()
    private let workers = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))

    private func pump() {
        while running.count < workers, let job = jobs.popLast() ?? prefetchJobs.popLast() {
            running.insert(job.key)
            let version = generation
            queue.async { [weak self] in
                let img = autoreleasepool { Self.decode(job) }
                DispatchQueue.main.async { self?.finish(job, img, version: version) }
            }
        }
    }

    private func finish(_ job: Job, _ img: NSImage?, version: Int) {
        #if DEBUG
        let tf = CACurrentMediaTime(); defer { debugFinishTime += CACurrentMediaTime() - tf }
        #endif
        running.remove(job.key)
        if version == generation, let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cache.setObject(img, forKey: job.key as NSString, cost: cg.width * cg.height * 4)
        }
        let list = waiting.removeValue(forKey: job.key) ?? []
        for (token, done) in list {
            #if DEBUG
            if let t0 = debugStart.removeValue(forKey: token) { debugLatency.append(CACurrentMediaTime() - t0) }
            #endif
            _ = token
            done(img)
        }
        pump()
    }

    private static func decode(_ job: Job) -> NSImage? {
        let url = URL(fileURLWithPath: job.path)
        let cg: CGImage?
        if job.isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: job.maxPixel, height: job.maxPixel)
            cg = try? gen.copyCGImage(at: .zero, actualTime: nil)
        } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: job.maxPixel,
            ] as CFDictionary)
        } else { cg = nil }
        return cg.map { c in
            let ready = render(c, in: targetSpace) ?? c
            return NSImage(cgImage: ready, size: NSSize(width: ready.width, height: ready.height))
        }
    }

    /// Redraws a picture into a bitmap in `space` with the layout Core Animation uses directly.
    private static func render(_ img: CGImage, in space: CGColorSpace) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
    #if DEBUG
    var debugRequests = 0
    var debugLatency: [Double] = []
    var debugFinishTime = 0.0
    private var debugStart: [Token: Double] = [:]
    #endif
}

extension NSColor {
    static let twitterBlue = NSColor(srgbRed: 0.114, green: 0.631, blue: 0.949, alpha: 1)
    static func tagColor(_ t: TagView) -> NSColor { t.isUser && t.isAI ? .systemGreen : (t.isAI ? .systemPurple : .systemBlue) }
}


// MARK: - Progress UI

/// A slim progress bar: a quiet track and a solid fill in the accent colour that follows the value
/// smoothly. With no value (a task whose size is not known) a short piece of fill passes along
/// the track, slowly. Nothing else: no gradient, no shine.
final class MacSlimBar: NSView {
    private let fill = CALayer()
    private var value: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        fill.cornerRadius = 2
        fill.cornerCurve = .continuous
        fill.anchorPoint = .zero
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: 4).isActive = true
        setAccessibilityElement(false)
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { refreshColors() }
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            fill.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    func set(_ v: Double?) {
        let wasUnknown = value == nil
        value = v.map { min(max($0, 0), 1) }
        place(animated: true, restart: wasUnknown != (value == nil))
    }

    private func place(animated: Bool, restart: Bool = false) {
        guard bounds.width > 0 else { return }
        fill.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || restart)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if let v = value {
            fill.frame = CGRect(x: 0, y: 0, width: max(bounds.height, bounds.width * CGFloat(v)), height: bounds.height)
            CATransaction.commit()
        } else {
            // unknown size: a piece of a third of the track passes along it
            let w = bounds.width * 0.32
            fill.frame = CGRect(x: -w, y: 0, width: w, height: bounds.height)
            CATransaction.commit()
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = -w
            a.toValue = bounds.width
            a.duration = 1.5
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.repeatCount = .infinity
            fill.add(a, forKey: "pass")
        }
    }
}

/// One running task: the current item's thumbnail flips in, plus title, detail and progress.
final class MacActivityCard: NSView {
    private let thumb = NSImageView()
    private let symbol = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = MacSlimBar()
    private var previewPath: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        symbol.contentTintColor = .controlAccentColor
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, detailLabel, bar])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        [thumb, symbol, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor), thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 40), thumb.heightAnchor.constraint(equalToConstant: 40),
            symbol.centerXAnchor.constraint(equalTo: thumb.centerXAnchor), symbol.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12), text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 2), text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ a: Activity) {
        titleLabel.stringValue = a.title
        detailLabel.stringValue = a.detail
        bar.set(a.progress)
        let sym: String = switch a.kind { case .download: "arrow.down.circle.fill"; case .model: "shippingbox.fill"; case .tagging: "sparkles"; case .sync: "arrow.triangle.2.circlepath"; case .verify: "checkmark.shield.fill"; case .importing: "square.and.arrow.down.on.square.fill" }
        // the mascot mode: shopping for a download, the camera for AI tagging
        let mascot: String? = !Mascot.isOn ? nil : a.kind == .download ? "bag" : a.kind == .tagging ? "camera" : nil
        symbol.image = mascot.map { Mascot.icon($0, side: 36) } ?? NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        // the crab lies on the card as it is, with no tile around it
        thumb.layer?.backgroundColor = mascot != nil ? NSColor.clear.cgColor : NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        guard a.previewPath != previewPath else { return }
        previewPath = a.previewPath
        guard let path = a.previewPath else { thumb.image = nil; symbol.isHidden = false; return }
        MacMediaLoader.shared.load(path: path, isVideo: a.previewIsVideo, maxPixel: 120) { [weak self] img in
            guard let self, self.previewPath == path else { return }
            self.flip(to: img)
        }
    }

    /// Card-deal flip around the vertical axis: rotate out, swap the image, rotate in.
    private func flip(to img: NSImage?) {
        guard let layer = thumb.layer else { thumb.image = img; return }
        var p = CATransform3DIdentity
        p.m34 = -1 / 300
        let half = CABasicAnimation(keyPath: "transform")
        half.fromValue = CATransform3DRotate(p, 0, 0, 1, 0)
        half.toValue = CATransform3DRotate(p, .pi / 2, 0, 1, 0)
        half.duration = 0.18
        half.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.thumb.image = img
            self?.symbol.isHidden = img != nil
            let back = CABasicAnimation(keyPath: "transform")
            back.fromValue = CATransform3DRotate(p, -.pi / 2, 0, 1, 0)
            back.toValue = CATransform3DRotate(p, 0, 0, 1, 0)
            back.duration = 0.22
            back.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(back, forKey: "flipIn")
        }
        layer.add(half, forKey: "flipOut")
        CATransaction.commit()
    }
}

/// Floating glass panel listing running tasks; slides in/out.
final class MacActivityPanel: NSVisualEffectView {
    private let stack = NSStackView()
    private var cards: [Activity.Kind: MacActivityCard] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            widthAnchor.constraint(equalToConstant: 340),
        ])
        alphaValue = 0
        isHidden = true
        NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render(ActivityCenter.shared.activities) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func render(_ list: [Activity]) {
        let kinds = Set(list.map(\.kind))
        for (k, v) in cards where !kinds.contains(k) { cards[k] = nil; v.removeFromSuperview() }
        for a in list {
            let c = cards[a.kind] ?? { let c = MacActivityCard(); stack.addArrangedSubview(c); c.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; cards[a.kind] = c; return c }()
            c.update(a)
        }
        let show = !list.isEmpty
        guard show == isHidden else { return }
        if show { isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3; ctx.timingFunction = .springy
            animator().alphaValue = show ? 1 : 0
        }) { [weak self] in if !show { self?.isHidden = true } }
    }
}

// MARK: - Grouped settings form

/// Settings content laid out like System Settings: each section is a header, a rounded group of
/// rows separated by hairlines, and an optional footer. In a row the label sits on the leading
/// side and its controls on the trailing side; action buttons line up on the trailing edge. The
/// column keeps a readable width in a wide window. Panes rebuild only when their structure
/// changes; live values are pushed into the views they keep references to.
final class MacForm: NSView {
    static let maxWidth: CGFloat = 680
    /// Groups tinted instead of opaque, for a form inside a popover's glass (an opaque group
    /// there looks like a white board laid on the glass).
    var translucentGroups = false
    private let stack = NSStackView()
    /// Rows of the current section's group.
    private var current: NSStackView?
    /// The trailing button row last added, so consecutive `button` calls share one row.
    private var actionRow: NSStackView?
    private static let rowInset = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // below the sidebar's holding priority (260): a column capped at maxWidth must never
        // make the split view narrow the content pane (the sidebar jumped to its widest)
        let fill = stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        fill.priority = .init(255)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20), stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth), stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            fill, stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
        ])
        // Content determines a long document's height. A short document may grow
        // to the viewport without stretching the groups or leaving an ambiguous height.
        let contentHeight = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24)
        contentHeight.priority = NSLayoutConstraint.Priority(1)
        contentHeight.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func clear() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() }; current = nil; actionRow = nil }

    /// Ends the current section: what follows (e.g. a row of buttons) goes under the groups.
    func endSection() { current = nil; actionRow = nil }

    private func addToColumn(_ v: NSView, spacingBefore: CGFloat) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(spacingBefore, after: last) }
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// Starts a new section; following calls add rows to its group. (`symbol` and `color` are
    /// kept for callers; section headers are plain text, as in System Settings.)
    func card(_ title: String, symbol: String = "", color: NSColor = .controlAccentColor, footer: String? = nil) {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.lineBreakMode = .byTruncatingTail
        let head = Self.inset(t, NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        addToColumn(head, spacingBefore: stack.arrangedSubviews.isEmpty ? 0 : 26)
        let box = MacSettingsCard()
        box.translucent = translucentGroups
        let rows = NSStackView()
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: box.topAnchor), rows.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: box.leadingAnchor), rows.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        addToColumn(box, spacingBefore: 8)
        current = rows
        actionRow = nil
        if let footer {
            let f = NSTextField(wrappingLabelWithString: footer)
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            addToColumn(Self.inset(f, NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)), spacingBefore: 6)
        }
    }

    private static func inset(_ v: NSView, _ e: NSEdgeInsets) -> NSView {
        let c = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: c.topAnchor, constant: e.top), v.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -e.bottom),
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: e.left), v.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -e.right),
        ])
        return c
    }

    /// Adds a row to the current group (a hairline above every row but the first); outside a
    /// section the view goes straight into the column.
    private func addRow(_ content: NSView, fill: Bool, insets: NSEdgeInsets = MacForm.rowInset) {
        actionRow = nil
        guard let rows = current else {
            addToColumn(content, spacingBefore: 12)
            return
        }
        if !rows.arrangedSubviews.isEmpty {
            let line = NSBox(); line.boxType = .separator
            let wrap = Self.inset(line, NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0))
            rows.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let row = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        // content centred vertically; a row is at least 40 pt (one line of text sits in the middle)
        let snug = content.topAnchor.constraint(equalTo: row.topAnchor, constant: insets.top)
        snug.priority = .defaultLow
        var cs = [
            snug, content.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: insets.top),
            content.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: insets.left),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ]
        cs.append(fill ? content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -insets.right)
                       : content.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -insets.right))
        NSLayoutConstraint.activate(cs)
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    /// A label-and-controls row: the title (with an optional secondary line under it) on the
    /// leading side, the controls on the trailing side. Returns the title label.
    @discardableResult
    func field(_ title: String, detail: String? = nil, _ controls: [NSView]) -> NSTextField {
        let t = NSTextField(labelWithString: title)
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lead: NSView = t
        if let detail, !detail.isEmpty {
            let d = NSTextField(labelWithString: detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            d.lineBreakMode = .byTruncatingTail
            d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let v = NSStackView(views: [t, d]); v.orientation = .vertical; v.alignment = .leading; v.spacing = 2
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lead = v
        }
        field(lead, controls)
        return t
    }

    /// The same row with a custom leading view.
    func field(_ lead: NSView, _ controls: [NSView]) {
        let trail = NSStackView(views: controls)
        trail.spacing = 8
        trail.setHuggingPriority(.required, for: .horizontal)
        trail.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let h = NSStackView(views: [lead, spacer, trail])
        h.spacing = 12
        h.alignment = .centerY
        addRow(h, fill: true)
    }

    @discardableResult
    func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        add(l)
        return l
    }

    @discardableResult
    func label(_ text: String, size: CGFloat = 13, mono: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        add(l)
        return l
    }

    /// An action button. Buttons line up on the trailing edge; consecutive ones share a row.
    /// With `label` the button gets a row of its own with that label on the leading side (a
    /// group never shows a lone button in an empty row).
    @discardableResult
    func button(_ title: String, label: String? = nil, detail: String? = nil, symbol: String? = nil, destructive: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading }
        if destructive { b.hasDestructiveAction = true; b.contentTintColor = .systemRed }
        b.isEnabled = enabled
        if let label {
            field(label, detail: detail, [b])
        } else if let r = actionRow { r.insertArrangedSubview(b, at: r.arrangedSubviews.count) } else {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let r = NSStackView(views: [spacer, b])
            r.spacing = 8
            addRow(r, fill: true)
            actionRow = r
        }
        return b
    }

    /// A row of controls; when the column is too narrow it wraps onto more lines, instead of
    /// forcing the panel wider. A plain `NSView()` is a spacer that pushes what follows to the
    /// trailing side while everything fits on one line.
    func row(_ views: [NSView]) {
        add(MacFlowRow(views))
    }

    func separator() {}

    func add(_ v: NSView, fill: Bool = true) {
        addRow(v, fill: fill)
        if !fill, let control = v as? NSControl { control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
    }

    /// A full-width row without the inner padding (a link row draws its own).
    func addFlush(_ v: NSView) { addRow(v, fill: true, insets: NSEdgeInsets()) }
}

final class ClosureButton: NSButton {
    private var handler: (() -> Void)?
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        toolTip = title
        bezelStyle = .push
        controlSize = .regular
        if #available(macOS 26.0, *) { borderShape = .capsule }
        handler = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { handler?() }
}

final class ClosureSwitch: NSSwitch {
    private var handler: ((Bool) -> Void)?
    convenience init(on: Bool, changed: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        state = on ? .on : .off
        handler = changed
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { handler?(state == .on) }
}

/// Runs work off the main thread and reports through an alert on failure.
func macRun<T>(_ window: NSWindow?, _ work: @escaping () throws -> T, done: @escaping (T) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let r = Result { try work() }
        DispatchQueue.main.async {
            switch r {
            case .success(let v): done(v)
            case .failure(let e): AppLog.error("ui", L("mac.actionFailed", e.localizedDescription)); macAlert(window, L("activity.failed"), e.localizedDescription)
            }
        }
    }
}

/// Runs long work off the main thread under a sheet with a live progress line and (optionally)
/// a Cancel button.
func macRunProgress<T>(_ window: NSWindow?, title: String, progress: @escaping () -> String?, cancel: (() -> Void)? = nil,
                       _ work: @escaping () throws -> T, done: @escaping (T) -> Void) {
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
    let spin = NSProgressIndicator(); spin.style = .spinning; spin.controlSize = .regular; spin.startAnimation(nil)
    let head = NSTextField(labelWithString: title); head.font = .boldSystemFont(ofSize: 13)
    let line = NSTextField(labelWithString: L("mac.preparing")); line.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); line.textColor = .secondaryLabelColor
    var views: [NSView] = [spin, head, line]
    if let cancel {
        let b = ClosureButton(title: L("common.cancel")) { cancel() }
        b.setAccessibilityIdentifier("progressCancel")
        views.append(b)
    }
    let st = NSStackView(views: views); st.orientation = .vertical; st.spacing = 10
    st.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
    sheet.contentView = st
    window?.beginSheet(sheet)
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { if let p = progress() { line.stringValue = p } } }
    DispatchQueue.global(qos: .userInitiated).async {
        let r = Result { try work() }
        DispatchQueue.main.async {
            timer.invalidate()
            window?.endSheet(sheet)
            switch r {
            case .success(let v): done(v)
            case .failure(let e): AppLog.error("ui", L("mac.actionFailed", e.localizedDescription)); macAlert(window, L("activity.failed"), e.localizedDescription)
            }
        }
    }
}

func macAlert(_ window: NSWindow?, _ title: String, _ message: String? = nil) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message ?? ""
    if let window { a.beginSheetModal(for: window) } else { a.runModal() }
}

func macPrompt(_ window: NSWindow?, title: String, message: String = "", placeholder: String = "", initial: String = "", done: @escaping (String) -> Void) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    tf.placeholderString = placeholder
    tf.stringValue = initial
    a.accessoryView = tf
    a.addButton(withTitle: L("common.ok"))
    a.addButton(withTitle: L("common.cancel"))
    a.window.initialFirstResponder = tf
    let handle: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { done(tf.stringValue) } }
    if let window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
}

/// Asks a question with several choices; `done` receives the chosen index (or nil when cancelled).
func macChoose(_ window: NSWindow?, title: String, message: String = "", options: [String], done: @escaping (Int) -> Void) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    for o in options { a.addButton(withTitle: o) }
    a.addButton(withTitle: L("common.cancel"))
    let handle: (NSApplication.ModalResponse) -> Void = { r in
        let i = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if i >= 0 && i < options.count { done(i) }
    }
    if let window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
}

/// Asks where an import or download goes: no folder, a new folder (suggested name) or an
/// existing one. `done(nil)` = no folder; not called when cancelled.
func macChooseFolder(_ window: NSWindow?, title: String, suggested: String?, message: String = L("folderPicker.message.mac"), done: @escaping (String?) -> Void) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
    var values: [String?] = [nil]
    pop.addItem(withTitle: L("mac.noFolder"))
    if let s = suggested, !s.isEmpty { pop.addItem(withTitle: L("folderPicker.new", s)); values.append(s) }
    for f in Core.folders() where f.name != suggested { pop.addItem(withTitle: L("format.quotedCount", f.name, f.count)); values.append(f.name) }
    if values.count > 1, suggested != nil { pop.selectItem(at: 1) }
    a.accessoryView = pop
    a.addButton(withTitle: L("common.import"))
    a.addButton(withTitle: L("common.cancel"))
    let handle: (NSApplication.ModalResponse) -> Void = { r in if r == .alertFirstButtonReturn { done(values[max(0, pop.indexOfSelectedItem)]) } }
    if let window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
}


/// Lays its views out left to right and wraps them onto further lines when they do not fit.
/// Labels longer than the whole width are truncated to it.
final class MacFlowRow: NSView {
    private let items: [NSView]
    private let spacing: CGFloat = 8, lineSpacing: CGFloat = 6
    private var lastHeight: CGFloat = -1

    init(_ views: [NSView]) {
        items = views
        super.init(frame: .zero)
        for v in views { v.translatesAutoresizingMaskIntoConstraints = true; addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private static func isSpacer(_ v: NSView) -> Bool { type(of: v) == NSView.self && v.subviews.isEmpty }

    private func size(of v: NSView, max w: CGFloat) -> NSSize {
        if let t = v as? NSTextField, t.cell?.wraps == true { t.preferredMaxLayoutWidth = w }
        var s = v.fittingSize
        if s.width > w { s.width = w; if let t = v as? NSTextField { t.lineBreakMode = .byTruncatingTail } }
        return s
    }

    /// Places the views for `width`; returns the height used.
    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        let real = items.filter { !Self.isSpacer($0) && !$0.isHidden }
        let sizes = real.map { size(of: $0, max: width) }
        // one line? then spacers share the leftover room
        let oneLine = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(real.count - 1, 0)) <= width
        var lines: [[(NSView, NSSize)]] = [[]]
        var x: CGFloat = 0
        for (v, s) in zip(real, sizes) {
            if !lines[lines.count - 1].isEmpty, x + spacing + s.width > width { lines.append([]); x = 0 }
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + s.width
            lines[lines.count - 1].append((v, s))
        }
        var y: CGFloat = 0
        if oneLine, items.contains(where: Self.isSpacer) {
            let h = sizes.map(\.height).max() ?? 0
            let used = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(real.count - 1, 0))
            let spacers = items.filter(Self.isSpacer).count
            let gap = (width - used) / CGFloat(spacers)
            var cx: CGFloat = 0
            var first = true
            for v in items where !v.isHidden {
                if Self.isSpacer(v) { if apply { v.frame = NSRect(x: cx, y: 0, width: gap, height: 1) }; cx += gap; continue }
                let s = sizes[real.firstIndex(of: v)!]
                if !first { cx += spacing }
                first = false
                if apply { v.frame = NSRect(x: cx, y: (h - s.height) / 2, width: s.width, height: s.height) }
                cx += s.width
            }
            return h
        }
        for v in items where Self.isSpacer(v) { if apply { v.frame = .zero } }
        for line in lines where !line.isEmpty {
            let h = line.map(\.1.height).max() ?? 0
            var cx: CGFloat = 0
            for (v, s) in line {
                if apply { v.frame = NSRect(x: cx, y: y + (h - s.height) / 2, width: s.width, height: s.height) }
                cx += s.width + spacing
            }
            y += h + lineSpacing
        }
        return max(y - lineSpacing, 0)
    }

    override func layout() {
        super.layout()
        let h = place(width: bounds.width, apply: true)
        if abs(h - lastHeight) > 0.5 { lastHeight = h; invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: lastHeight >= 0 ? lastHeight : place(width: max(bounds.width, 300), apply: false))
    }
}


extension CAMediaTimingFunction {
    /// Fast start, long soft landing (like a damped spring): every animation of the Mac app uses
    /// it instead of a straight line.
    static let springy = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
}

/// Opaque form groups keep their colors when appearance changes while settings is open.
final class MacSettingsCard: NSView {
    var translucent = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (translucent ? NSColor.labelColor.withAlphaComponent(0.05) : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = (translucent ? NSColor.clear : NSColor.separatorColor).cgColor
    }
}

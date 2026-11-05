import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Custom MP4 player shown inside the main window (no extra window, no AVPlayerView). Mouse and
/// trackpad equivalents of the touch gestures: double-click = play/pause ·
/// press-and-hold = 2.5× · Space / ←→ / ↑↓ / Esc / F keys. The controls (play · progress · time ·
/// share · close · picture in picture) sit right on the video, without a bar behind them.
final class MacPlayerView: NSView, AVPictureInPictureControllerDelegate {
    /// Called when the user closes the player (close button or Esc).
    var onClose: (() -> Void)?
    /// Picture in picture started (the host hides the player but keeps it) / ended.
    var onPiPStart: (() -> Void)?
    var onPiPRestore: (() -> Void)?
    var onPiPEnd: (() -> Void)?
    private let player: AVPlayer
    private let playerLayer = AVPlayerLayer()
    private let hud = NSTextField(labelWithString: "")
    private let bar = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "0:00 / 0:00")
    private let playButton = NSButton()
    private let closeButton = NSButton()
    private let pipButton = NSButton()
    private let shareButton = NSButton()
    private let fileURL: URL
    private var pip: AVPictureInPictureController?
    private let controls = NSView()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var hideTimer: Timer?
    private var holdTimer: Timer?
    private var boosting = false
    private var dragMode = 0 // 0 none, 1 seek
    private var dragStart = NSPoint.zero
    private var startValue: Double = 0
    private var scrubbing = false
    /// Read once: whether a sideways drag seeks (off with 视频禁用手势; see `LibraryPrefs.playerGesturesOff`).
    let dragSeeks = !LibraryPrefs.playerGesturesOff
    /// Shown as a page of the media viewer: no picture in picture, and the viewer handles the keys.
    var embedded = false { didSet { pipButton.isHidden = embedded || pip == nil } }

    private var duration: Double { let d = player.currentItem?.duration.seconds ?? 0; return d.isFinite ? d : 0 }

    /// Share menu for the video file (other apps, AirDrop, Messages…).
    @objc private func shareTapped() { NSSharingServicePicker(items: [fileURL]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY) }

    init(url: URL, startAt: CMTime) {
        fileURL = url
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 2
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)

        hud.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        hud.textColor = .white
        hud.alignment = .center
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hud.layer?.cornerRadius = 12
        hud.alphaValue = 0

        // no bar behind the controls: a soft shadow keeps them readable on bright video
        controls.wantsLayer = true
        controls.shadow = {
            let sh = NSShadow()
            sh.shadowColor = .black.withAlphaComponent(0.6)
            sh.shadowBlurRadius = 6
            sh.shadowOffset = .zero
            return sh
        }()
        playButton.isBordered = false
        playButton.contentTintColor = .white
        playButton.target = self
        playButton.action = #selector(togglePlay)
        bar.target = self
        bar.action = #selector(scrub)
        bar.isContinuous = true
        time.textColor = .white
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for (b, sym, label, id, sel) in [(closeButton, "xmark", L("viewer.close"), "playerClose", #selector(closeTapped)),
                                         (pipButton, "pip.enter", L("viewer.pip"), "playerPiP", #selector(togglePiP)), (shareButton, "square.and.arrow.up", L("viewer.share"), "playerShare", #selector(shareTapped))] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
            b.contentTintColor = .white
            b.toolTip = label
            b.setAccessibilityIdentifier(id)
            b.target = self; b.action = sel
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        // the speed: a Mac without a touch screen has no finger to hold for 2.5×
        speedButton.isBordered = false
        speedButton.toolTip = L("player.speed")
        speedButton.setAccessibilityIdentifier("playerSpeed")
        speedButton.target = self
        speedButton.action = #selector(speedTapped)
        updateSpeedTitle()
        let row = NSStackView(views: [playButton, bar, time, speedButton, shareButton, closeButton, pipButton])
        row.spacing = 12
        row.setCustomSpacing(16, after: time)
        row.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(row)
        [hud, controls].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor), hud.topAnchor.constraint(equalTo: topAnchor, constant: 60),
            hud.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20), controls.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 14), row.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in self?.sync() }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
        if startAt > .zero { player.seek(to: startAt, toleranceBefore: .zero, toleranceAfter: .zero) }
        applyAudioPolicy()
        audioObserver = NotificationCenter.default.addObserver(forName: AudioPolicy.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAudioPolicy() }
        }
        player.playImmediately(atRate: 1)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        scheduleHide()
        if AVPictureInPictureController.isPictureInPictureSupported(), let p = AVPictureInPictureController(playerLayer: playerLayer) {
            p.delegate = self
            pip = p
        } else { pipButton.isHidden = true }
    }

    // MARK: Close, picture in picture

    @objc private func closeTapped() { onClose?() }

    private let speedButton = NSButton(title: "1×", target: nil, action: nil)
    /// The chosen speed (a hold boosts from it to 2.5× and comes back to it).
    private var speed: Float = 1
    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]
    private static func speedText(_ r: Float) -> String { (r == r.rounded() ? String(Int(r)) : String(r)) + "×" }
    private func updateSpeedTitle() {
        speedButton.attributedTitle = NSAttributedString(string: Self.speedText(speed), attributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
    }
    @objc private func speedTapped() {
        let menu = NSMenu()
        for r in Self.speeds {
            let item = NSMenuItem(title: Self.speedText(r), action: #selector(speedChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r
            item.state = r == speed ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: speedButton.bounds.height + 4), in: speedButton)
    }
    @objc private func speedChosen(_ item: NSMenuItem) {
        guard let r = item.representedObject as? Float else { return }
        speed = r
        updateSpeedTitle()
        if player.rate != 0 { player.rate = r }
        scheduleHide()
    }

    @objc private func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) { onPiPStart?() }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        onPiPRestore?(); done(true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { onPiPEnd?() }
    var isInPiP: Bool { pip?.isPictureInPictureActive ?? false }
    required init?(coder: NSCoder) { fatalError() }

    private var audioObserver: NSObjectProtocol?

    /// Reminder pill near the top of the video that fades out after a few seconds.
    /// The user chose to hear this video through the speakers (reset when headphones go away).
    private var allowSpeaker = false
    private var hadHeadphones = AudioPolicy.headphonesConnected
    private weak var soundPrompt: NSView?

    private func applyAudioPolicy() {
        let now = AudioPolicy.headphonesConnected
        if hadHeadphones && !now { allowSpeaker = false }
        hadHeadphones = now
        let mute = AudioPolicy.shouldMute(allowSpeaker: allowSpeaker)
        player.isMuted = mute
        if !mute { soundPrompt?.removeFromSuperview(); return }
        guard soundPrompt == nil else { return }
        let url = fileURL
        Task { [weak self] in
            guard await AudioPolicy.hasAudio(url) else { return }
            await MainActor.run { self?.showSoundPrompt() }
        }
    }

    /// "没有连接耳机，已静音 · 开启声音".
    private func showSoundPrompt() {
        guard soundPrompt == nil, player.isMuted else { return }
        let l = NSTextField(labelWithString: AudioPolicy.promptText)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .white
        let on = ClosureButton(title: L("audio.turnOn")) { [weak self] in
            self?.allowSpeaker = true
            self?.player.isMuted = false
            self?.soundPrompt?.removeFromSuperview()
        }
        on.setAccessibilityIdentifier("soundOn")
        let box = NSStackView(views: [l, on])
        box.spacing = 10
        box.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        box.layer?.cornerRadius = 14
        box.setAccessibilityIdentifier("audioBanner")
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([box.centerXAnchor.constraint(equalTo: centerXAnchor), box.topAnchor.constraint(equalTo: topAnchor, constant: 110)])
        soundPrompt = box
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak box] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; $0.timingFunction = .springy; box?.animator().alphaValue = 0 }) { box?.removeFromSuperview() }
        }
    }

    func teardown() {
        if let a = audioObserver { NotificationCenter.default.removeObserver(a); audioObserver = nil }
        player.pause()
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    private func sync() {
        let t = player.currentTime().seconds
        if !scrubbing, duration > 0 { bar.doubleValue = t / duration }
        time.stringValue = "\(Self.fmt(t)) / \(Self.fmt(duration))"
        playButton.image = NSImage(systemSymbolName: player.timeControlStatus == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s); return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }

    private func flash(_ text: String, sticky: Bool = false) {
        hud.stringValue = "  \(text)  "
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; $0.timingFunction = .springy; hud.animator().alphaValue = 1 }
        if !sticky { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in if self?.hud.stringValue == "  \(text)  " { self?.hideHUD() } } }
    }
    private func hideHUD() { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; $0.timingFunction = .springy; hud.animator().alphaValue = 0 } }

    private func scheduleHide() {
        hideTimer?.invalidate()
        controls.animator().alphaValue = 1
        NSCursor.unhide()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self, self.player.timeControlStatus != .paused else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; $0.timingFunction = .springy; self.controls.animator().alphaValue = 0 }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    @objc func togglePlay() {
        if player.timeControlStatus == .paused { player.playImmediately(atRate: speed); flash("▶︎") } else { player.pause(); flash("❚❚") }
        sync(); scheduleHide()
    }

    @objc private func scrub() {
        scrubbing = true
        player.seek(to: CMTime(seconds: bar.doubleValue * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if NSApp.currentEvent?.type == .leftMouseUp { scrubbing = false }
    }

    func seek(by seconds: Double) {
        let t = min(max(player.currentTime().seconds + seconds, 0), duration)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        flash("\(Self.fmt(t)) / \(Self.fmt(duration))")
    }

    // MARK: Mouse gestures

    override func mouseMoved(with event: NSEvent) { scheduleHide() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { togglePlay(); return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragMode = 0
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, self.dragMode == 0 else { return }
            self.boosting = true
            self.player.rate = 2.5
            self.flash("2.5× ▶▶", sticky: true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        if dragMode == 0, !boosting, hypot(dx, dy) > 8 {
            holdTimer?.invalidate()
            // only sideways drags seek (unless that is turned off); vertical drags do nothing
            // a drag seeks only from a touch screen (a finger); a mouse or a trackpad drag does
            // nothing — those have the bar, the arrow keys and the speed menu
            if abs(dx) > abs(dy), dragSeeks, event.subtype == .touch { dragMode = 1; startValue = player.currentTime().seconds; scrubbing = true }
            else { dragMode = -1 }
        }
        if dragMode == 1 {
            let span = min(max(duration, 1), 120)
            let t = min(max(startValue + Double(dx / bounds.width) * span, 0), duration)
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if duration > 0 { bar.doubleValue = t / duration }
            flash("\(Self.fmt(t)) / \(Self.fmt(duration))", sticky: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        if boosting { boosting = false; player.rate = speed }
        scrubbing = false
        if dragMode != 0 || hud.alphaValue > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.hideHUD() } }
        dragMode = 0
    }

    // MARK: Keyboard

    /// Space, ↑ ↓ (volume) and F, for the viewer that shows this player as a page.
    func handleViewerKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: togglePlay()
        case 126: player.volume = min(player.volume + 0.1, 1); flash("🔊 \(Int(player.volume * 100))%")
        case 125: player.volume = max(player.volume - 0.1, 0); flash("🔊 \(Int(player.volume * 100))%")
        case 3: window?.toggleFullScreen(nil)
        default: return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: togglePlay()                 // space
        case 123: seek(by: -5)                // ←
        case 124: seek(by: 5)                 // →
        case 126: player.volume = min(player.volume + 0.1, 1); flash("🔊 \(Int(player.volume * 100))%")
        case 125: player.volume = max(player.volume - 0.1, 0); flash("🔊 \(Int(player.volume * 100))%")
        case 53: onClose?()                   // esc
        case 3: window?.toggleFullScreen(nil) // f
        default: super.keyDown(with: event)
        }
    }
}

/// Media viewer for a post inside the main window: ← → (or the arrow buttons, or a sideways
/// two-finger swipe) go through every photo and video of the list it was opened from; double-click
/// or pinch zooms; Esc or ✕ closes; the share button and ⌘C hand the current file to other apps.
///
/// The pages lie side by side in a strip (the current one and both neighbours, loaded ahead): a
/// swipe moves the strip with the fingers, so the next photo comes in beside this one, and on
/// release the strip settles on the nearest page, carried on by the swipe's speed. The motion is
/// driven frame by frame (a display link), so a new swipe can catch a page mid-way. Over the
/// bottom, the post's author and text (`PostCaptionView`); a click on a photo hides or shows it
/// with the buttons.
final class MacPhotoView: NSView {
    var onClose: (() -> Void)?
    private let items: [FeedItem]
    /// Where the first video starts (it was already playing in the feed).
    private var videoStart: CMTime
    private(set) var index: Int
    private let strip = NSView()
    private var pages: [Int: MacViewerPage] = [:]
    /// How far the strip is moved from the current page (pt; negative = towards the next).
    private var offset: CGFloat = 0
    private static let gap: CGFloat = 40
    private let close = ViewerRoundButton(diameter: 34)
    private let share = ViewerRoundButton(diameter: 34)
    private let prev = ViewerRoundButton(diameter: 40)
    private let next = ViewerRoundButton(diameter: 40)
    private let counter = NSTextField(labelWithString: "")
    private let caption = CaptionHostView(rootView: PostCaptionView(item: nil))
    private var captionBottom: NSLayoutConstraint!
    private var chromeHidden = false

    convenience init(url: URL) {
        self.init(items: [FeedItem(mediaId: url.lastPathComponent, postId: "", ordinal: 0, kind: .photo, path: url.path, text: nil, authorName: nil, screenName: nil, url: nil, tags: [])], index: 0)
    }

    init(items: [FeedItem], index: Int, videoStart: CMTime = .zero) {
        self.items = items
        self.index = max(0, min(index, items.count - 1))
        self.videoStart = videoStart
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityIdentifier("photoViewer")
        strip.wantsLayer = true
        strip.layer?.masksToBounds = true
        addSubview(strip)
        func style(_ b: NSButton, _ sym: String, _ label: String, _ id: String, _ sel: Selector, size: CGFloat = 14) {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.symbolConfiguration = .init(pointSize: size, weight: .semibold)
            b.toolTip = label
            b.target = self
            b.action = sel
            b.setAccessibilityIdentifier(id)
        }
        style(close, "xmark", L("viewer.close.mac"), "photoClose", #selector(closeTapped))
        style(share, "square.and.arrow.up", L("viewer.share.mac"), "photoShare", #selector(shareTapped))
        style(prev, "chevron.left", L("viewer.previous.mac"), "photoPrev", #selector(goPrev), size: 16)
        style(next, "chevron.right", L("viewer.next.mac"), "photoNext", #selector(goNext), size: 16)
        counter.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        counter.textColor = .white
        counter.setAccessibilityIdentifier("photoCounter")
        caption.setAccessibilityIdentifier("postCaptionHost")
        [caption, close, share, prev, next, counter].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        captionBottom = caption.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor), caption.trailingAnchor.constraint(equalTo: trailingAnchor), captionBottom,
            caption.topAnchor.constraint(equalTo: topAnchor),
            close.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20), close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            share.centerYAnchor.constraint(equalTo: close.centerYAnchor), share.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            // below the (transparent) title bar strip
            counter.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16), counter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            prev.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), prev.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), next.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        preparePages()
        pages[self.index]?.activate(videoStart: videoStart, onClose: { [weak self] in self?.onClose?() })
        self.videoStart = .zero     // only the video that was opened goes on from where the feed was
        updateChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    var current: FeedItem { items[index] }
    private var page: MacViewerPage? { pages[index] }
    private var stride: CGFloat { bounds.width + Self.gap }

    // MARK: Pages

    /// The current page and its neighbours exist (made ahead, so a swipe shows them loaded);
    /// pages further away go.
    private func preparePages() {
        let want = Set((index - 1)...(index + 1)).filter { items.indices.contains($0) }
        for (i, p) in pages where !want.contains(i) { p.teardown(); p.removeFromSuperview(); pages[i] = nil }
        for i in want.sorted() where pages[i] == nil {
            let p = MacViewerPage(item: items[i])
            p.onSwipe = { [weak self] e in self?.swipe(e) ?? false }
            strip.addSubview(p)
            pages[i] = p
        }
        layoutPages()
    }

    private func layoutPages() {
        let b = bounds
        for (i, p) in pages {
            let f = NSRect(x: CGFloat(i - index) * stride + offset, y: 0, width: b.width, height: b.height)
            if p.frame != f { p.frame = f }
        }
    }

    override func layout() {
        super.layout()
        strip.frame = bounds
        layoutPages()
        captionMaxHeight = bounds.height * 0.5
    }

    /// The strip settled one page further (or back): that page is the current one now.
    private func commit(_ delta: Int) {
        guard delta != 0, items.indices.contains(index + delta) else { offset = 0; layoutPages(); return }
        page?.deactivate()
        index += delta
        offset += CGFloat(delta) * stride
        preparePages()
        page?.activate(videoStart: .zero, onClose: { [weak self] in self?.onClose?() })
        updateChrome()
        window?.makeFirstResponder(self)
    }

    /// Counter, arrows, buttons and caption for the current page.
    private func updateChrome() {
        let it = current
        let multi = items.count > 1
        prev.isHidden = !multi || index == 0 || chromeHidden
        next.isHidden = !multi || index == items.count - 1 || chromeHidden
        // the position within the current post
        let post = it.postId
        var lo = index, hi = index
        while lo > 0, items[lo - 1].postId == post, !post.isEmpty { lo -= 1 }
        while hi < items.count - 1, items[hi + 1].postId == post, !post.isEmpty { hi += 1 }
        counter.stringValue = multi && hi > lo ? "\(index - lo + 1) / \(hi - lo + 1)" : ""
        counter.setAccessibilityValue(counter.stringValue)
        counter.isHidden = chromeHidden
        // a video page has its own share and close among its controls
        close.isHidden = it.kind == .video || chromeHidden
        share.isHidden = it.kind == .video || chromeHidden
        // over a video, the caption sits above the player's controls
        captionBottom.constant = it.kind == .video ? -76 : 0
        setCaption()
    }

    private var captionMaxHeight: CGFloat = 320 { didSet { if abs(captionMaxHeight - oldValue) > 1 { setCaption() } } }
    private var captionStartsExpanded = false
    #if DEBUG
    func debugExpandCaption() { captionStartsExpanded = true; setCaption(); captionStartsExpanded = false }
    #endif
    private func setCaption() {
        let it = current
        caption.rootView = PostCaptionView(item: chromeHidden ? nil : it, maxExpandedHeight: captionMaxHeight, trailingInset: it.kind == .video ? 16 : 110,
                                           onHeight: { [weak self] h in self?.caption.contentHeight = h }, startsExpanded: captionStartsExpanded)
        caption.isHidden = chromeHidden || !PostCaptionView.shows(it)
    }

    // MARK: Moving between pages

    @objc func goPrev() { step(-1) }
    @objc func goNext() { step(1) }

    /// One page on, sliding (a step while the strip still moves finishes that move first).
    private func step(_ d: Int) {
        finishMotion()
        guard items.indices.contains(index + d) else { return bounce(d) }
        animate(to: -CGFloat(d) * stride, duration: 0.3) { [weak self] in self?.commit(d) }
        window?.makeFirstResponder(self)
    }

    /// At the first or last page: the strip gives a little and comes back.
    private func bounce(_ d: Int) {
        animate(to: -CGFloat(d) * 30, duration: 0.12) { [weak self] in self?.animate(to: 0, duration: 0.22) {} }
    }

    private var motion: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: Double, done: () -> Void)?
    private var link: CADisplayLink?

    private func animate(to target: CGFloat, duration: Double, done: @escaping () -> Void) {
        motion = (offset, target, CACurrentMediaTime(), duration, done)
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let m = motion else { stopLink(); return }
        let t = min(1, (CACurrentMediaTime() - m.start) / m.duration)
        let e = 1 - pow(1 - t, 3)        // ease out
        offset = m.from + (m.to - m.from) * CGFloat(e)
        layoutPages()
        if t >= 1 {
            motion = nil
            stopLink()
            m.done()
        }
    }

    private func stopLink() { link?.invalidate(); link = nil }

    /// Ends a move at once, where it was going.
    private func finishMotion() {
        guard let m = motion else { return }
        motion = nil
        stopLink()
        offset = m.to
        layoutPages()
        m.done()
    }

    // MARK: Swipes

    private var swiping = false
    private var swallowMomentum = false
    private var lastDelta: CGFloat = 0

    /// A sideways two-finger swipe moves the strip with the fingers; vertical scrolling and a
    /// zoomed-in photo are left alone. Returns whether the event was used.
    private func swipe(_ e: NSEvent) -> Bool {
        guard items.count > 1, e.hasPreciseScrollingDeltas, (page?.magnification ?? 1) <= 1.001 else { return false }
        if !e.momentumPhase.isEmpty { return swallowMomentum }
        if e.phase == .began || e.phase == .mayBegin {
            swiping = false
            swallowMomentum = false
            lastDelta = 0
        }
        guard swiping || abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.5 else { return false }
        if !swiping {
            // caught mid-way: the strip goes on from where it is
            motion = nil
            stopLink()
            swiping = true
            swallowMomentum = true
        }
        // with the fingers: natural scrolling's deltas already follow them
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        lastDelta = dx
        // resistance past the first and last page
        let atEnd = (offset + dx > 0 && index == 0) || (offset + dx < 0 && index == items.count - 1)
        offset = max(-stride, min(stride, offset + (atEnd ? dx * 0.3 : dx)))
        layoutPages()
        if e.phase == .ended || e.phase == .cancelled {
            swiping = false
            settle()
        }
        return true
    }

    /// The fingers let go: the nearest page, a flick carrying it on to the next.
    private func settle() {
        let projected = offset + lastDelta * 6
        var d = Int((-projected / stride).rounded())
        d = max(-1, min(1, d))
        if !items.indices.contains(index + d) { d = 0 }
        let distance = abs(-CGFloat(d) * stride - offset)
        animate(to: -CGFloat(d) * stride, duration: 0.18 + 0.2 * Double(min(1, distance / max(stride, 1)))) { [weak self] in self?.commit(d) }
    }

    /// Two-finger scrolling that reaches the viewer (a video page passes its own on).
    override func scrollWheel(with e: NSEvent) { if !swipe(e) { super.scrollWheel(with: e) } }

    #if DEBUG
    /// A sideways swipe as the trackpad sends it (phases, then the momentum after release), for the tour.
    func debugSwipe(dx: CGFloat, steps: Int = 8, end: Bool = true) -> [CGFloat] {
        var seen: [CGFloat] = []
        for i in 0..<steps {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx / CGFloat(steps)), wheel3: 0) else { continue }
            cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
            // phases: began, changed…, ended (or, with `end` off, still changing; a lone `end` step is the release)
            let phase: Int64 = steps == 1 && end ? 4 : i == 0 ? 1 : (i == steps - 1 && end ? 4 : 2)
            cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)
            if let e = NSEvent(cgEvent: cg) { scrollWheel(with: e) }
            seen.append(offset)
        }
        return seen
    }
    var debugOffset: CGFloat { offset }
    var debugPageCount: Int { pages.count }
    #endif

    // MARK: Buttons, keys, clicks

    /// Stops the video on screen (the viewer is closing).
    func teardown() {
        finishMotion()
        stopLink()
        pages.values.forEach { $0.teardown() }
    }

    override var acceptsFirstResponder: Bool { true }
    @objc private func closeTapped() { onClose?() }
    @objc private func shareTapped() { NSSharingServicePicker(items: [current.fileURL]).show(relativeTo: share.bounds, of: share, preferredEdge: .minY) }
    /// ⌘C: the file (and, for a photo, the image) on the clipboard.
    @objc func copy(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objs: [NSPasteboardWriting] = [current.fileURL as NSURL]
        if current.kind == .photo, let img = page?.image.image { objs.append(img) }
        pb.writeObjects(objs)
    }
    override func keyDown(with event: NSEvent) {
        // on a video whose sideways drag seeks, ← → seek too (the arrow buttons turn the page)
        if let p = page?.player {
            if p.dragSeeks, event.keyCode == 123 { p.seek(by: -5); return }
            if p.dragSeeks, event.keyCode == 124 { p.seek(by: 5); return }
            if p.handleViewerKey(event) { return }
        }
        switch event.keyCode {
        case 53: onClose?()
        case 123: goPrev()
        case 124: goNext()
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copy(nil) } else { super.keyDown(with: event) }
        }
    }

    private var pendingClick: DispatchWorkItem?
    override func mouseDown(with event: NSEvent) {
        guard current.kind == .photo, let p = page else { return }
        if event.clickCount == 2 {
            pendingClick?.cancel()
            p.toggleZoom(at: event.locationInWindow)
            return
        }
        // one click (not the first of a double click): the caption and buttons go or come back
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.chromeHidden.toggle()
            self.updateChrome()
        }
        pendingClick = w
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: w)
    }
}

/// The caption's host: as tall as the viewer (the caption sits at its bottom and may grow), but
/// only the caption itself takes clicks; above it they reach the media.
final class CaptionHostView: NSHostingView<PostCaptionView> {
    var contentHeight: CGFloat = 0
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        // not flipped: y runs up from the bottom edge
        return p.y <= contentHeight ? super.hitTest(point) : nil
    }
}

/// One page of the viewer: a zoomable photo, or a video (its poster until it is the current page,
/// then the player).
final class MacViewerPage: NSView {
    let item: FeedItem
    let scroll = PagingScrollView()
    let image = NSImageView()
    private(set) var player: MacPlayerView?
    var onSwipe: ((NSEvent) -> Bool)? { didSet { scroll.onSwipe = onSwipe } }
    private var imageToken: MacMediaLoader.Token?
    private var loadedPixels: CGFloat = 0

    init(item: FeedItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        scroll.allowsMagnification = item.kind == .photo
        scroll.minMagnification = 1
        scroll.maxMagnification = 6
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        image.imageScaling = .scaleProportionallyUpOrDown
        image.autoresizingMask = [.width, .height]
        scroll.documentView = image
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(zoomed), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        load(pixels: 2048)
    }
    required init?(coder: NSCoder) { fatalError() }

    var magnification: CGFloat { scroll.magnification }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        if scroll.magnification <= 1.001 { image.frame = scroll.contentView.bounds }
    }

    /// It became the page on screen: a video starts playing.
    func activate(videoStart: CMTime, onClose: @escaping () -> Void) {
        guard item.kind == .video, player == nil else { return }
        let p = MacPlayerView(url: item.fileURL, startAt: videoStart)
        p.embedded = true
        p.onClose = onClose
        p.frame = bounds
        p.autoresizingMask = [.width, .height]
        addSubview(p)
        player = p
    }

    /// Another page is current now: a video stops (its poster shows again), a zoom resets.
    func deactivate() {
        player?.teardown()
        player?.removeFromSuperview()
        player = nil
        if scroll.magnification > 1.001 { scroll.magnification = 1 }
    }

    func teardown() {
        deactivate()
        MacMediaLoader.shared.cancel(imageToken); imageToken = nil
        image.image = nil
        loadedPixels = 0
    }

    func toggleZoom(at windowPoint: NSPoint) {
        guard item.kind == .photo else { return }
        let p = scroll.contentView.convert(windowPoint, from: nil)
        if scroll.magnification > 1.01 { scroll.animator().magnification = 1 } else { scroll.animator().setMagnification(2.5, centeredAt: p) }
    }

    private func load(pixels: CGFloat) {
        guard pixels > loadedPixels else { return }
        loadedPixels = pixels
        MacMediaLoader.shared.cancel(imageToken)
        let id = item.mediaId
        imageToken = MacMediaLoader.shared.load(item, maxPixel: pixels) { [weak self] img in
            guard let self, self.item.mediaId == id else { return }
            if let img { self.image.image = img } else { self.loadedPixels = 0 }
        }
    }
    @objc private func zoomed() { if scroll.magnification > 1.2, item.kind == .photo { load(pixels: 4096) } }
}

/// The viewer's zoomable image: sideways two-finger swipes go to the viewer (to page) unless it
/// is zoomed in; everything else scrolls and zooms as usual.
final class PagingScrollView: NSScrollView {
    var onSwipe: ((NSEvent) -> Bool)?
    override func scrollWheel(with e: NSEvent) {
        if onSwipe?(e) == true { return }
        super.scrollWheel(with: e)
    }
}

/// A viewer control: a white symbol on a dark translucent circle (no white disc), slightly
/// brighter while hovered and pressed.
final class ViewerRoundButton: NSButton {
    private let diameter: CGFloat
    private var hovering = false { didSet { restyle() } }

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        restyle()
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }
    // a symbol image gives the button alignment insets, which would stretch the circle
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var isHighlighted: Bool { didSet { restyle() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func restyle() {
        let a: CGFloat = isHighlighted ? 0.7 : hovering ? 0.55 : 0.4
        layer?.backgroundColor = NSColor.black.withAlphaComponent(a).cgColor
    }
}

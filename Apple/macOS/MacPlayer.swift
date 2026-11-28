import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Custom MP4 player shown inside the main window (no extra window, no AVPlayerView).
/// Double-click = play/pause · Space / ←→ / ↑↓ / Esc / F keys. The controls (play · progress ·
/// time · speed · share · close · picture in picture) sit right on the video, without a bar behind them.
final class MacPlayerView: NSView, AVPictureInPictureControllerDelegate {
    /// Called when the user closes the player (close button or Esc).
    var onClose: (() -> Void)?
    /// Called when the user toggles the favorite button next to share.
    var onToggleFavorite: (() -> Void)?
    var isFavorited = false { didSet { updateFavoriteButton() } }
    /// Notifies the parent viewer when the bottom control bar shows or hides (so the caption follows).
    var onControlsVisible: ((Bool) -> Void)?
    /// Picture in picture started (the host hides the player but keeps it) / ended.
    var onPiPWillStart: (() -> Void)?
    var onPiPStart: (() -> Void)?
    var onPiPRestore: (() -> Void)?
    var onPiPEnd: (() -> Void)?
    var onPiPFailed: (() -> Void)?
    static let barHeight: CGFloat = 52
    static let starGold = NSColor(red: 0.96, green: 0.72, blue: 0.0, alpha: 1)
    private let player: AVPlayer
    private var initialSeekTime: CMTime?
    private let playerLayer = AVPlayerLayer()
    var onMediaGeometryChanged: (() -> Void)?
    private let hudBox = NSView()
    private let hud = NSTextField(labelWithString: "")
    private let scrubBar = MacTopEdgeScrubBar()
    private let time = NSTextField(labelWithString: "0:00 / 0:00")
    private let playButton = NSButton()
    private let closeButton = NSButton()
    private let pipButton = NSButton()
    private let favoriteButton = NSButton()
    private let shareButton = NSButton()
    private let fileURL: URL
    private var pip: AVPictureInPictureController?
    /// Solid black bottom dock (Twitter-style) with the progress track flush along its top edge.
    private let controls = NSView()
    private let dockSurface = NSView()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var hideTimer: Timer?
    private var scrubbing = false
    /// Shown as a page of the media viewer: the viewer handles the keys.
    var embedded = false

    private var duration: Double { let d = player.currentItem?.duration.seconds ?? 0; return d.isFinite ? d : 0 }
    var playbackPosition: CMTime { initialSeekTime ?? player.currentTime() }

    func mediaFrame(size: CGSize) -> CGRect {
        let frame = playerLayer.videoRect
        return frame.isEmpty ? AVMakeRect(aspectRatio: size, insideRect: bounds) : frame
    }

    /// Share menu for the video file (other apps, AirDrop, Messages…).
    @objc private func shareTapped() { NSSharingServicePicker(items: [fileURL]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY) }

    /// The player went back to its feed card: this view no longer pauses it.
    private(set) var handedBack = false
    /// It plays the feed card's own player (given back when it closes).
    let isLent: Bool

    /// `player`: the feed card's own player, playing this video now (it goes on here: nothing is
    /// loaded or sought), given back with `handBack`.
    init(url: URL, startAt: CMTime, player lent: AVPlayer? = nil) {
        fileURL = url
        isLent = lent != nil
        if let lent {
            player = lent
        } else {
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            item.preferredForwardBufferDuration = 2
            player = AVPlayer(playerItem: item)
        }
        player.automaticallyWaitsToMinimizeStalling = false
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        applyBackdropColor()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)

        hudBox.wantsLayer = true
        hudBox.appearance = NSAppearance(named: .darkAqua)
        hudBox.alphaValue = 0
        let hudBg: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 14
            hudBg = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 14
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            hudBg = v
        }
        hudBg.translatesAutoresizingMaskIntoConstraints = false
        hudBox.addSubview(hudBg)
        hud.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        hud.textColor = .white
        hud.alignment = .center
        hud.translatesAutoresizingMaskIntoConstraints = false
        hudBox.addSubview(hud)
        NSLayoutConstraint.activate([
            hudBg.topAnchor.constraint(equalTo: hudBox.topAnchor), hudBg.bottomAnchor.constraint(equalTo: hudBox.bottomAnchor),
            hudBg.leadingAnchor.constraint(equalTo: hudBox.leadingAnchor), hudBg.trailingAnchor.constraint(equalTo: hudBox.trailingAnchor),
            hud.topAnchor.constraint(equalTo: hudBox.topAnchor, constant: 10), hud.bottomAnchor.constraint(equalTo: hudBox.bottomAnchor, constant: -10),
            hud.leadingAnchor.constraint(equalTo: hudBox.leadingAnchor, constant: 16), hud.trailingAnchor.constraint(equalTo: hudBox.trailingAnchor, constant: -16),
        ])

        // Twitter-style solid black bottom dock with the progress bar flush along its top edge.
        controls.wantsLayer = true
        dockSurface.wantsLayer = true
        dockSurface.layer?.backgroundColor = NSColor.black.cgColor
        dockSurface.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(dockSurface)

        playButton.isBordered = false
        playButton.contentTintColor = .white
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        scrubBar.onScrub = { [weak self] frac, ended in
            guard let self else { return }
            self.scrubbing = !ended
            self.player.seek(to: CMTime(seconds: frac * self.duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if ended { self.scheduleHide() } else { self.hideTimer?.invalidate() }
        }
        scrubBar.translatesAutoresizingMaskIntoConstraints = false

        time.textColor = NSColor.white.withAlphaComponent(0.75)
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for (b, sym, label, id, sel) in [(closeButton, "xmark", L("viewer.close"), "playerClose", #selector(closeTapped)),
                                         (pipButton, "pip.enter", L("viewer.pip"), "playerPiP", #selector(togglePiP)),
                                         (favoriteButton, "star", L("common.favorite"), "playerFavorite", #selector(favoriteTapped)),
                                         (shareButton, "square.and.arrow.up", L("viewer.share"), "playerShare", #selector(shareTapped))] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
            b.contentTintColor = .white
            b.toolTip = label
            b.setAccessibilityIdentifier(id)
            b.target = self; b.action = sel
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        updateFavoriteButton()
        // the speed: a Mac without a touch screen has no finger to hold for 2.5×
        speedButton.isBordered = false
        speedButton.toolTip = L("player.speed")
        speedButton.setAccessibilityIdentifier("playerSpeed")
        speedButton.target = self
        speedButton.action = #selector(speedTapped)
        updateSpeedTitle()
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [playButton, time, spacer, speedButton, favoriteButton, shareButton, pipButton, closeButton])
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        dockSurface.addSubview(row)
        controls.addSubview(scrubBar)
        [hudBox, controls].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            hudBox.centerXAnchor.constraint(equalTo: centerXAnchor), hudBox.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor), controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor), controls.heightAnchor.constraint(equalToConstant: Self.barHeight + 9),
            dockSurface.leadingAnchor.constraint(equalTo: controls.leadingAnchor), dockSurface.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            dockSurface.bottomAnchor.constraint(equalTo: controls.bottomAnchor), dockSurface.heightAnchor.constraint(equalToConstant: Self.barHeight),
            scrubBar.leadingAnchor.constraint(equalTo: controls.leadingAnchor), scrubBar.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            scrubBar.centerYAnchor.constraint(equalTo: dockSurface.topAnchor), scrubBar.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: dockSurface.leadingAnchor, constant: 18), row.trailingAnchor.constraint(equalTo: dockSurface.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: dockSurface.centerYAnchor),
        ])

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in self?.sync() }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
        // the card's own player is at its moment already (and with sound now: the viewer's)
        if startAt > .zero, !isLent {
            initialSeekTime = startAt
            player.seek(to: startAt, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                DispatchQueue.main.async { if finished { self?.initialSeekTime = nil } }
            }
        }
        if isLent { player.isMuted = false }
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
    @objc private func favoriteTapped() { onToggleFavorite?() }
    private func updateFavoriteButton() {
        let label = isFavorited ? L("common.unfavorite") : L("common.favorite")
        favoriteButton.image = NSImage(systemSymbolName: isFavorited ? "star.fill" : "star", accessibilityDescription: label)
        favoriteButton.contentTintColor = isFavorited ? Self.starGold : .white
        favoriteButton.toolTip = label
    }

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

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) { onPiPWillStart?() }
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { onPiPStart?() }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        AppLog.error("pip", error.localizedDescription)
        onPiPFailed?()
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        onPiPRestore?(); done(true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { onPiPEnd?() }
    required init?(coder: NSCoder) { fatalError() }

    /// Closes an active PiP window immediately in-place (without flying back to the main window)
    /// when the user opens another video while this one is in PiP.
    func closePiPImmediately() -> AVPlayer? {
        hideTimer?.invalidate()
        onPiPWillStart = nil
        onPiPStart = nil
        onPiPRestore = nil
        onPiPEnd = nil
        onPiPFailed = nil
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        let activePiP = pip
        pip = nil
        activePiP?.delegate = nil
        let returned: AVPlayer? = isLent ? { handedBack = true; return player }() : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
        playerLayer.frame = .zero
        CATransaction.commit()
        if !handedBack { player.pause() }
        if activePiP?.isPictureInPictureActive == true {
            activePiP?.stopPictureInPicture()
        }
        return returned
    }

    func teardown() {
        // gone from the screen: no timer of this view hides the pointer afterwards
        hideTimer?.invalidate()
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        if !handedBack { player.pause() }
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
    }

    /// Gives the feed card its player back (playing on): this view lets go of it.
    func handBack() -> AVPlayer {
        handedBack = true
        teardown()
        playerLayer.player = nil
        return player
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackdropColor()
    }

    private func applyBackdropColor() {
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    private func sync() {
        onMediaGeometryChanged?()
        let t = player.currentTime().seconds
        if !scrubbing, duration > 0 { scrubBar.progress = t / duration }
        time.stringValue = "\(Self.fmt(t)) / \(Self.fmt(duration))"
        playButton.image = NSImage(systemSymbolName: player.timeControlStatus == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s); return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }

    private func flash(_ text: String, sticky: Bool = false) {
        hud.stringValue = text
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; $0.timingFunction = .springy; hudBox.animator().alphaValue = 1 }
        if !sticky { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in if self?.hud.stringValue == text { self?.hideHUD() } } }
    }
    private func hideHUD() { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; $0.timingFunction = .springy; hudBox.animator().alphaValue = 0 } }

    private func scheduleHide() {
        hideTimer?.invalidate()
        controls.animator().alphaValue = 1
        onControlsVisible?(true)
        NSCursor.unhide()
    }

    @objc func togglePlay() {
        if player.timeControlStatus == .paused { player.playImmediately(atRate: speed); flash("▶︎") } else { player.pause(); flash("❚❚") }
        sync(); scheduleHide()
    }

    func seek(by seconds: Double) {
        let t = min(max(player.currentTime().seconds + seconds, 0), duration)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        flash("\(Self.fmt(t)) / \(Self.fmt(duration))")
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) { scheduleHide() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { togglePlay() }
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
    var onPiPWillStart: (() -> Void)?
    var onPiPStart: (() -> Void)?
    var onPiPRestore: (() -> Void)?
    var onPiPEnd: (() -> Void)?
    var onPiPFailed: (() -> Void)?
    private var items: [FeedItem]
    private var videoPositions: [Int: CMTime] = [:]
    private let videoPosition: ((FeedItem) -> CMTime)?
    private let saveVideoPosition: ((FeedItem, CMTime) -> Void)?
    private(set) var index: Int
    private let strip = NSView()
    private var pages: [Int: MacViewerPage] = [:]
    /// How far the strip is moved from the current page (pt; negative = towards the next).
    private var offset: CGFloat = 0
    private static let gap: CGFloat = 40
    /// Landscape photo controls: Favorite, Share and Close housed together in one Liquid Glass capsule.
    private let photoPill = NSView()
    private let close = NSButton()
    private let favorite = NSButton()
    private let share = NSButton()
    /// Portrait photo controls: solid black bottom dock (matching Twitter).
    private let photoDock = NSView()
    private let dockCounter = NSTextField(labelWithString: "")
    private let dockFavorite = NSButton()
    private let dockShare = NSButton()
    private let dockClose = NSButton()
    private let prev = ViewerRoundButton(diameter: 40)
    private let next = ViewerRoundButton(diameter: 40)
    private let counter = NSTextField(labelWithString: "")
    private let caption = CaptionHostView(rootView: PostCaptionView(item: nil))
    private var captionBottom: NSLayoutConstraint!
    private var chromeHidden = false
    private var videoControlsVisible = true
    private var isPortraitLayout: Bool { bounds.width > 0 && bounds.height >= bounds.width }
    private var lastPortraitLayout: Bool?

    /// The feed card's player of the opened video (one player for both), and where it goes back.
    private var lentPlayer: AVPlayer?
    private let lentIndex: Int
    private let giveBack: ((AVPlayer) -> Void)?

    init(items: [FeedItem], index: Int, player: AVPlayer? = nil, giveBack: ((AVPlayer) -> Void)? = nil,
         videoPosition: ((FeedItem) -> CMTime)? = nil, saveVideoPosition: ((FeedItem, CMTime) -> Void)? = nil) {
        lentPlayer = player
        lentIndex = index
        self.giveBack = giveBack
        self.videoPosition = videoPosition
        self.saveVideoPosition = saveVideoPosition
        self.items = items
        self.index = max(0, min(index, items.count - 1))
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        applyAppearance()
        setAccessibilityIdentifier("photoViewer")
        strip.wantsLayer = true
        strip.layer?.masksToBounds = true
        addSubview(strip)
        func style(_ b: NSButton, _ sym: String, _ label: String, _ id: String, _ sel: Selector, size: CGFloat = 14) {
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.symbolConfiguration = .init(pointSize: size, weight: .semibold)
            b.toolTip = label
            b.target = self
            b.action = sel
            b.setAccessibilityIdentifier(id)
        }
        style(close, "xmark", L("viewer.close.mac"), "photoClose", #selector(closeTapped))
        style(favorite, "star", L("common.favorite"), "photoFavorite", #selector(toggleFavorite))
        style(share, "square.and.arrow.up", L("viewer.share.mac"), "photoShare", #selector(shareTapped))
        style(dockClose, "xmark", L("viewer.close.mac"), "photoDockClose", #selector(closeTapped))
        style(dockFavorite, "star", L("common.favorite"), "photoDockFavorite", #selector(toggleFavorite))
        style(dockShare, "square.and.arrow.up", L("viewer.share.mac"), "photoDockShare", #selector(shareTapped))
        style(prev, "chevron.left", L("viewer.previous.mac"), "photoPrev", #selector(goPrev), size: 16)
        style(next, "chevron.right", L("viewer.next.mac"), "photoNext", #selector(goNext), size: 16)

        // Landscape Liquid Glass pill holding Favorite + Share + Close
        photoPill.wantsLayer = true
        let pillBg: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 20
            pillBg = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 20
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            pillBg = v
        }
        pillBg.translatesAutoresizingMaskIntoConstraints = false
        photoPill.addSubview(pillBg)
        let pillRow = NSStackView(views: [favorite, share, close])
        pillRow.spacing = 6
        pillRow.alignment = .centerY
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        photoPill.addSubview(pillRow)
        for b in [favorite, share, close] {
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        NSLayoutConstraint.activate([
            pillBg.topAnchor.constraint(equalTo: photoPill.topAnchor), pillBg.bottomAnchor.constraint(equalTo: photoPill.bottomAnchor),
            pillBg.leadingAnchor.constraint(equalTo: photoPill.leadingAnchor), pillBg.trailingAnchor.constraint(equalTo: photoPill.trailingAnchor),
            pillRow.leadingAnchor.constraint(equalTo: photoPill.leadingAnchor, constant: 8),
            pillRow.trailingAnchor.constraint(equalTo: photoPill.trailingAnchor, constant: -8),
            pillRow.topAnchor.constraint(equalTo: photoPill.topAnchor, constant: 4),
            pillRow.bottomAnchor.constraint(equalTo: photoPill.bottomAnchor, constant: -4),
        ])

        // Portrait solid black dock holding counter + Favorite + Share + Close
        photoDock.wantsLayer = true
        photoDock.layer?.backgroundColor = NSColor.black.cgColor
        dockCounter.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        dockCounter.textColor = .white
        for b in [dockFavorite, dockShare, dockClose] {
            b.contentTintColor = .white
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        let dockSpacer = NSView()
        dockSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let dockRow = NSStackView(views: [dockCounter, dockSpacer, dockFavorite, dockShare, dockClose])
        dockRow.spacing = 12
        dockRow.alignment = .centerY
        dockRow.translatesAutoresizingMaskIntoConstraints = false
        photoDock.addSubview(dockRow)
        NSLayoutConstraint.activate([
            dockRow.leadingAnchor.constraint(equalTo: photoDock.leadingAnchor, constant: 18),
            dockRow.trailingAnchor.constraint(equalTo: photoDock.trailingAnchor, constant: -18),
            dockRow.centerYAnchor.constraint(equalTo: photoDock.centerYAnchor),
        ])

        counter.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        counter.setAccessibilityIdentifier("photoCounter")
        caption.setAccessibilityIdentifier("postCaptionHost")
        // Sized by its constraints only (it fills the viewer). With the default options the
        // SwiftUI content's size becomes required constraints: a loose media shows no caption,
        // its content is then 0 wide at most, and AppKit shrank the whole window to 0 to obey.
        caption.sizingOptions = []
        [caption, photoPill, photoDock, prev, next, counter].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        captionBottom = caption.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor), caption.trailingAnchor.constraint(equalTo: trailingAnchor), captionBottom,
            caption.topAnchor.constraint(equalTo: topAnchor),
            photoPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20), photoPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            photoDock.leadingAnchor.constraint(equalTo: leadingAnchor), photoDock.trailingAnchor.constraint(equalTo: trailingAnchor),
            photoDock.bottomAnchor.constraint(equalTo: bottomAnchor), photoDock.heightAnchor.constraint(equalToConstant: MacPlayerView.barHeight),
            // below the (transparent) title bar strip
            counter.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16), counter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            prev.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), prev.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), next.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        appearance = NSAppearance(named: .darkAqua)
        applyAppearance()
        preparePages()
        activatePage()
        updateChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.black.cgColor
        counter.textColor = .white
        share.contentTintColor = .white
        close.contentTintColor = .white
        updateFavoriteButtons()
    }

    private func updateFavoriteButtons() {
        let fav = current.isFavorite
        let label = fav ? L("common.unfavorite") : L("common.favorite")
        let img = NSImage(systemSymbolName: fav ? "star.fill" : "star", accessibilityDescription: label)
        let tint: NSColor = fav ? MacPlayerView.starGold : .white
        for b in [favorite, dockFavorite] {
            b.image = img
            b.contentTintColor = tint
            b.toolTip = label
        }
        page?.player?.isFavorited = fav
    }

    var current: FeedItem { items[index] }
    private var page: MacViewerPage? { pages[index] }
    private var stride: CGFloat { bounds.width + Self.gap }

    var mediaFrame: CGRect {
        guard let page else { return bounds }
        let item = current
        let size = item.width > 0 && item.height > 0 ? CGSize(width: item.width, height: item.height) : bounds.size
        return page.mediaFrame(in: self, size: size)
    }

    private func activatePage() {
        let time = videoPositions[index] ?? videoPosition?(current) ?? .zero
        videoControlsVisible = true
        page?.activate(videoStart: time, isFavorited: current.isFavorite,
                       onClose: { [weak self] in self?.onClose?() },
                       onToggleFavorite: { [weak self] in self?.toggleFavorite() },
                       onControlsVisible: { [weak self] on in
            guard let self else { return }
            self.videoControlsVisible = on
            self.updateChrome()
        },
                       onPiPWillStart: { [weak self] in self?.onPiPWillStart?() },
                       onPiPStart: { [weak self] in self?.onPiPStart?() },
                       onPiPRestore: { [weak self] in self?.onPiPRestore?() },
                       onPiPEnd: { [weak self] in self?.onPiPEnd?() },
                       onPiPFailed: { [weak self] in self?.onPiPFailed?() },
                       player: index == lentIndex ? lentPlayer : nil)
    }

    private func rememberCurrentVideo() {
        guard let player = page?.player else { return }
        let time = player.playbackPosition
        videoPositions[index] = time
        if !player.isLent { saveVideoPosition?(current, time) }
    }

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
        // the caption belongs to the post: while the strip moves towards another post's media
        // it fades with the fingers (and the new one fades in once that page settles)
        let towards = index + (offset < 0 ? 1 : -1)
        let leaving = offset != 0 && items.indices.contains(towards) && items[towards].postId != current.postId
        caption.alphaValue = leaving ? max(0, 1 - abs(offset) / max(1, stride * 0.4)) : 1
    }

    override func layout() {
        super.layout()
        strip.frame = bounds
        layoutPages()
        captionMaxHeight = bounds.height * 0.5
        let portrait = isPortraitLayout
        if lastPortraitLayout != portrait {
            lastPortraitLayout = portrait
            updateChrome()
        }
    }

    /// The strip settled one page further (or back): that page is the current one now.
    private func commit(_ delta: Int) {
        guard delta != 0, items.indices.contains(index + delta) else { offset = 0; layoutPages(); return }
        rememberCurrentVideo()
        page?.deactivate()
        index += delta
        offset += CGFloat(delta) * stride
        preparePages()
        activatePage()
        updateChrome()
        window?.makeFirstResponder(self)
    }

    /// Counter, arrows, buttons and caption for the current page.
    private func updateChrome() {
        let it = current
        let isVideo = it.kind == .video
        let hidden = isVideo ? !videoControlsVisible : chromeHidden
        let portrait = isPortraitLayout
        let multi = items.count > 1
        prev.isHidden = !multi || index == 0 || hidden
        next.isHidden = !multi || index == items.count - 1 || hidden
        // the position within the current post
        let post = it.postId
        var lo = index, hi = index
        while lo > 0, items[lo - 1].postId == post, !post.isEmpty { lo -= 1 }
        while hi < items.count - 1, items[hi + 1].postId == post, !post.isEmpty { hi += 1 }
        let counterText = multi && hi > lo ? "\(index - lo + 1) / \(hi - lo + 1)" : ""
        counter.stringValue = counterText
        counter.setAccessibilityValue(counterText)
        dockCounter.stringValue = counterText
        // Landscape photo: Liquid Glass pill with Share & Close; Portrait photo: solid black dock
        photoPill.isHidden = isVideo || portrait || chromeHidden
        photoDock.isHidden = isVideo || !portrait || chromeHidden
        counter.isHidden = hidden || counterText.isEmpty || (!isVideo && portrait)
        // Caption always sits in the media region right above the bottom dock (video or portrait photo)
        captionBottom.constant = isVideo ? -(MacPlayerView.barHeight + 4) : (portrait ? -MacPlayerView.barHeight : 0)
        updateFavoriteButtons()
        setCaption()
    }

    private var captionMaxHeight: CGFloat = 320 { didSet { if abs(captionMaxHeight - oldValue) > 1 { setCaption() } } }
    private var captionStartsExpanded = false
    #if DEBUG
    func debugExpandCaption() { captionStartsExpanded = true; setCaption(); captionStartsExpanded = false }
    #endif
    private func setCaption() {
        let it = current
        let isVideo = it.kind == .video
        let hidden = isVideo ? !videoControlsVisible : chromeHidden
        let trailing: CGFloat = (isVideo || isPortraitLayout) ? 16 : 160
        caption.rootView = PostCaptionView(item: hidden ? nil : it, maxExpandedHeight: captionMaxHeight, trailingInset: trailing,
                                           onHeight: { [weak self] h in self?.caption.contentHeight = h }, startsExpanded: captionStartsExpanded)
        caption.isHidden = hidden || !PostCaptionView.shows(it)
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
    func finishMotion() {
        guard let m = motion else { return }
        motion = nil
        stopLink()
        offset = m.to
        layoutPages()
        m.done()
    }

    // MARK: Swipes

    private var swiping = false
    /// What the fingers moved before the gesture was known to be sideways.
    private var pending = CGSize.zero
    /// The last moments of the fingers' movement (time, sideways distance), for their speed.
    private var samples: [(t: TimeInterval, dx: CGFloat)] = []

    /// Two-finger scrolling over the viewer. An unzoomed photo or a video has nothing to scroll,
    /// so the viewer takes every such event: a sideways gesture moves the strip with the fingers,
    /// anything else (and the momentum after it) is swallowed rather than bouncing the page's
    /// scroll view — which would otherwise start an elastic scroll of its own under the swipe and
    /// never see it end. A zoomed photo keeps its own scrolling (to pan). A mouse wheel (no
    /// precise deltas) is left alone: its clicks are not a swipe. Returns whether it was used.
    private func swipe(_ e: NSEvent) -> Bool {
        guard e.hasPreciseScrollingDeltas, (page?.magnification ?? 1) <= 1.001 else { return false }
        // the trackpad's momentum after the fingers left: the strip already settles on its own
        if !e.momentumPhase.isEmpty { return true }
        guard items.count > 1 else { return true }
        if e.phase == .mayBegin { return true }
        if e.phase == .began {
            swiping = false
            pending = .zero
            samples.removeAll()
        }
        // with the fingers: natural scrolling's deltas already follow them
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        let dy = e.scrollingDeltaY
        if !swiping {
            pending.width += dx; pending.height += dy
            if e.phase == .ended || e.phase == .cancelled { return true }
            // decided on what the fingers did so far, not on the first (often tiny) event
            guard abs(pending.width) > 4, abs(pending.width) > abs(pending.height) * 1.2 else { return true }
            // caught mid-way: the strip goes on from where it is (that move is given up)
            motion = nil
            stopLink()
            swiping = true
            move(by: pending.width, at: e.timestamp)
        } else if dx != 0 {
            move(by: dx, at: e.timestamp)
        }
        if e.phase == .ended || e.phase == .cancelled {
            swiping = false
            settle(velocity: e.phase == .cancelled ? 0 : fingerVelocity())
        }
        return true
    }

    private func move(by dx: CGFloat, at t: TimeInterval) {
        samples.append((t, dx))
        samples.removeAll { t - $0.t > 0.1 }
        // resistance past the first and last page
        let atEnd = (offset + dx > 0 && index == 0) || (offset + dx < 0 && index == items.count - 1)
        offset = max(-stride, min(stride, offset + (atEnd ? dx * 0.3 : dx)))
        layoutPages()
    }

    /// Points per second over the last tenth of a second (the release itself moves nothing).
    private func fingerVelocity() -> CGFloat {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let span = max(1.0 / 60, last.t - first.t)
        return samples.reduce(0) { $0 + $1.dx } / CGFloat(span)
    }

    /// The fingers let go: a flick goes on to the next page in its direction, a slow release
    /// settles on the nearest one. The strip carries on at about the fingers' speed.
    private func settle(velocity v: CGFloat = 0) {
        var d: Int
        if abs(v) > 350, (v < 0) == (offset <= 0) || abs(offset) < stride * 0.1 {
            d = v < 0 ? 1 : -1
        } else {
            d = Int((-(offset + v * 0.1) / stride).rounded())
        }
        d = max(-1, min(1, d))
        if !items.indices.contains(index + d) { d = 0 }
        let target = -CGFloat(d) * stride
        let distance = abs(target - offset)
        // an ease-out starts at three times its average speed: match the fingers' speed
        let matched = abs(v) > 1 ? Double(3 * distance / abs(v)) : 0.3
        animate(to: target, duration: min(0.38, max(0.16, matched))) { [weak self] in self?.commit(d) }
    }

    /// Two-finger scrolling that reaches the viewer (a video page passes its own on).
    override func scrollWheel(with e: NSEvent) { if !swipe(e) { super.scrollWheel(with: e) } }

    #if DEBUG
    /// A sideways swipe as the trackpad sends it (phases, then the momentum after release), for the tour.
    func debugSwipe(dx: CGFloat, dy: CGFloat = 0, steps: Int = 8, end: Bool = true, momentum: Int = 0) -> [CGFloat] {
        var seen: [CGFloat] = []
        // delivered as AppKit would: to the view under the pointer (a page's scroll view, a player)
        let target: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            let hit = self.hitTest(NSPoint(x: self.bounds.midX, y: self.bounds.midY)) ?? self
            hit.scrollWheel(with: e)
        }
        func send(_ x: CGFloat, _ y: CGFloat, phase: Int64, momentumPhase: Int64) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { return }
            cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
            cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)
            cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentumPhase)
            if let e = NSEvent(cgEvent: cg) { target(e) }
            seen.append(offset)
        }
        for i in 0..<steps {
            // phases: began, changed…, ended (or, with `end` off, still changing; a lone `end` step is the release)
            let phase: Int64 = steps == 1 && end ? 4 : i == 0 ? 1 : (i == steps - 1 && end ? 4 : 2)
            send(dx / CGFloat(steps), dy / CGFloat(steps), phase: phase, momentumPhase: 0)
        }
        // the trackpad's momentum after the release: began, changed…, ended, slowing down
        for i in 0..<momentum {
            let f = CGFloat(momentum - i) / CGFloat(max(1, momentum))
            send(dx / CGFloat(steps) * f, dy / CGFloat(steps) * f, phase: 0, momentumPhase: i == 0 ? 1 : (i == momentum - 1 ? 3 : 2))
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
        rememberCurrentVideo()
        // closing: the card's player goes back to it (playing on, or paused where it was left)
        if let p = lentPlayer {
            lentPlayer = nil
            pages[lentIndex]?.handBack()
            giveBack?(p)
        }
        pages.values.forEach { $0.teardown() }
    }

    /// Closes an active PiP window immediately in-place (caller removes `self` from superview first
    /// so PIP.framework has no replacementWindow to animate back to).
    func closePiPImmediately() {
        finishMotion()
        stopLink()
        rememberCurrentVideo()
        onPiPWillStart = nil
        onPiPStart = nil
        onPiPRestore = nil
        onPiPEnd = nil
        onPiPFailed = nil
        if lentPlayer != nil {
            lentPlayer = nil
            if let returned = pages[lentIndex]?.closePiPImmediately() {
                giveBack?(returned)
            }
        }
        pages.values.forEach { _ = $0.closePiPImmediately(); $0.teardown() }
    }

    override var acceptsFirstResponder: Bool { true }
    @objc private func closeTapped() { onClose?() }
    @objc private func toggleFavorite() {
        let next = !current.isFavorite
        guard (try? Core.action(next ? .favorite : .unfavorite, media: [current.mediaId])) != nil else { return }
        items[index].favorite = next
        updateFavoriteButtons()
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }
    @objc private func shareTapped() {
        let anchor = isPortraitLayout ? dockShare : share
        NSSharingServicePicker(items: [current.fileURL]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
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
            if event.keyCode == 123 { p.seek(by: -5); return }
            if event.keyCode == 124 { p.seek(by: 5); return }
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
    var onMediaGeometryChanged: (() -> Void)?
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

    func mediaFrame(in view: NSView, size: CGSize) -> CGRect {
        if let player { return player.convert(player.mediaFrame(size: size), to: view) }
        let frame = AVMakeRect(aspectRatio: image.image?.size ?? size, insideRect: image.bounds)
        return image.convert(frame, to: view).intersection(scroll.convert(scroll.bounds, to: view))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        if scroll.magnification <= 1.001 { image.frame = scroll.contentView.bounds }
    }

    /// It became the page on screen: a video starts playing.
    func activate(videoStart: CMTime, isFavorited: Bool = false, onClose: @escaping () -> Void,
                  onToggleFavorite: (() -> Void)? = nil, onControlsVisible: ((Bool) -> Void)? = nil,
                  onPiPWillStart: (() -> Void)? = nil, onPiPStart: (() -> Void)? = nil,
                  onPiPRestore: (() -> Void)? = nil, onPiPEnd: (() -> Void)? = nil,
                  onPiPFailed: (() -> Void)? = nil,
                  player lent: AVPlayer? = nil) {
        guard item.kind == .video, player == nil else { return }
        let p = MacPlayerView(url: item.fileURL, startAt: videoStart, player: lent)
        p.embedded = true
        p.isFavorited = isFavorited
        p.onMediaGeometryChanged = { [weak self] in self?.onMediaGeometryChanged?() }
        p.onClose = onClose
        p.onToggleFavorite = onToggleFavorite
        p.onControlsVisible = onControlsVisible
        p.onPiPWillStart = onPiPWillStart
        p.onPiPStart = onPiPStart
        p.onPiPRestore = onPiPRestore
        p.onPiPEnd = onPiPEnd
        p.onPiPFailed = onPiPFailed
        p.frame = bounds
        p.autoresizingMask = [.width, .height]
        addSubview(p)
        player = p
    }

    func closePiPImmediately() -> AVPlayer? {
        guard let p = player else { return nil }
        player = nil
        p.removeFromSuperview()
        return p.closePiPImmediately()
    }

    /// The viewer closes on the feed card's player: let go of it, playing.
    func handBack() {
        guard let p = player, p.isLent else { return }
        _ = p.handBack()
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
            self.onMediaGeometryChanged?()
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

/// Full-width hairline progress bar sitting flush on the top edge of the Twitter-style black video bar.
final class MacTopEdgeScrubBar: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var onScrub: ((Double, Bool) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func fraction(for event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        return bounds.width > 0 ? min(1, max(0, Double(x / bounds.width))) : 0
    }
    override func mouseDown(with event: NSEvent) {
        dragging = true
        let f = fraction(for: event)
        progress = f
        onScrub?(f, false)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let f = fraction(for: event)
        progress = f
        onScrub?(f, false)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let f = fraction(for: event)
        progress = f
        onScrub?(f, true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackH: CGFloat = (hovering || dragging) ? 4 : 2.5
        let y = (bounds.height - trackH) / 2
        let w = bounds.width
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: y, width: w, height: trackH)).fill()
        let fillW = max(0, min(w, w * CGFloat(progress)))
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: y, width: fillW, height: trackH)).fill()
        if hovering || dragging {
            let d: CGFloat = dragging ? 12 : 10
            let cx = max(d / 2, min(w - d / 2, fillW))
            NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: (bounds.height - d) / 2, width: d, height: d)).fill()
        }
    }
}

/// A viewer control: adaptive frosted circle (light glass in Light mode, dark glass in Dark mode),
/// slightly stronger while hovered and pressed.
final class ViewerRoundButton: NSButton {
    private let diameter: CGFloat
    private var hovering = false { didSet { restyle() } }

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.borderWidth = 0.5
        restyle()
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }
    // a symbol image gives the button alignment insets, which would stretch the circle
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var isHighlighted: Bool { didSet { restyle() } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func restyle() {
        contentTintColor = .white
        let a: CGFloat = isHighlighted ? 0.7 : hovering ? 0.55 : 0.4
        layer?.backgroundColor = NSColor.black.withAlphaComponent(a).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }
}


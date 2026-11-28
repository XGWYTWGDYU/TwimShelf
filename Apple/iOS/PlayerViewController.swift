import UIKit
import AVFoundation
import MediaPlayer
import AVKit
import SwiftUI

/// Custom fullscreen MP4 player (no AVPlayerViewController).
/// Double-tap: play/pause · left vertical pan: brightness · right vertical pan: volume
/// long-press: 2.5× while held · horizontal pan: seek · single tap: show/hide controls.
/// Bottom bar: play · progress · time · lock · close · picture in picture. The lock disables every
/// gesture and control (only the lock itself stays) until it is tapped again.
final class PlayerViewController: UIViewController, UIGestureRecognizerDelegate, AVPictureInPictureControllerDelegate, ViewerPage {
    /// A player shown as one page of the full-screen viewer (between the photos of a post): it
    /// plays while it is the page on screen, its close button closes the viewer, and — when the
    /// drags for seeking, volume and brightness are on, so a sideways swipe cannot turn the page —
    /// arrows on both sides step to the previous and next media.
    struct Embedding {
        var index: Int
        var hasPrevious: Bool
        var hasNext: Bool
        var step: (Int) -> Void
        var close: () -> Void
        /// It became the page on screen.
        var shown: () -> Void
        var canShowControls: () -> Bool = { true }
        /// The controls came or went (the viewer's caption follows them).
        var controlsVisible: (Bool) -> Void = { _ in }
        var mediaGeometryChanged: () -> Void = {}
        var layoutModeChanged: () -> Void = {}
        /// The video was turned on its own (the viewer hides its bar and caption and stops paging).
        var turned: (Bool) -> Void = { _ in }
        var paused: (CMTime) -> Void = { _ in }
        var keepsPlayingOnDismiss: () -> Bool = { false }
        var toggleFavorite: () -> Void = {}
        var pipWillStart: () -> Void = {}
        var pipDidStart: () -> Void = {}
        var pipRestore: (@escaping (Bool) -> Void) -> Void = { $0(true) }
        var pipDidStop: () -> Void = {}
    }
    var embedding: Embedding?
    var viewerIndex: Int { embedding?.index ?? 0 }
    /// Read once: whether this player has the seek / volume / brightness drags (see `LibraryPrefs.playerGesturesOff`).
    let dragGestures = !LibraryPrefs.playerGesturesOff
    static let starGold = UIColor(red: 0.96, green: 0.72, blue: 0.0, alpha: 1)
    /// Keeps a player alive while it plays in picture-in-picture after its screen was closed.
    private static var inPiP: PlayerViewController?
    private static var pipOwner: UIViewController?
    private var pipActive = false
    private weak var parkedPiPWindow: UIWindow?
    private var speedMenuBackdrop: UIControl?
    private var speedMenuCard: UIView?
    var isInPiP: Bool { pipActive || pip?.isPictureInPictureActive == true }
    var isFavorited = false { didSet { updateFavoriteButton() } }
    var onToggleFavorite: (() -> Void)?
    private let player: AVPlayer
    private let startAt: CMTime
    private var initialSeekTime: CMTime?
    private let playerLayer = AVPlayerLayer()
    private let posterView = UIImageView()
    private var posterObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playbackVisible = false

    private let controls = UIView()
    /// Container inside `controls` (which rotates with `stage`) that hosts the viewer's post
    /// caption above the bottom dock or compact-landscape bottom row.
    let captionContainer = CaptionContainerView()
    /// Solid black bottom dock (Twitter-style) with the full-width progress bar flush along its top edge.
    private let dockView = UIView()
    private let scrubBar = IOSTopEdgeScrubBar()
    private let closeButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let favoriteButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)
    private let buttonRow = UIStackView()
    private let barSpacer = UIView()
    /// Compact-landscape (phone landscape) overlay chrome: top-left back button, bottom dark scrim,
    /// bottom-right translucent action pill, and bottom inline [play · scrubber · time] row.
    private let landscapeScrim = LandscapeGradientView()
    private let landscapeBackButton = UIButton(type: .system)
    private let landscapeActionPill = UIView()
    private let landscapePillRow = UIStackView()
    private let landscapeBottomRow = UIStackView()
    private var dockConstraints: [NSLayoutConstraint] = []
    private var landscapeConstraints: [NSLayoutConstraint] = []
    private var lastCompactLandscape: Bool?
    private var playbackRate: Float = 1
    /// Everything the player shows (the video, its controls, gestures) lives on this stage. The
    /// rotate button turns only the stage a quarter turn: the app's own orientation is never
    /// changed, so nothing behind the player (the feed, the viewer) ever turns with it, nothing
    /// has to be turned back on the way out, and it works where the system does not let an app
    /// choose its orientation (an iPad with multitasking, the orientation lock).
    private let stage = UIView()
    /// The stage's safe area: the screen's, turned with the stage.
    private let safe = UILayoutGuide()
    private var safeTop: NSLayoutConstraint!, safeBottom: NSLayoutConstraint!, safeLeft: NSLayoutConstraint!, safeRight: NSLayoutConstraint!
    /// Quarter turns of the stage: 0 none, 1 clockwise, -1 counter-clockwise.
    private(set) var quarterTurns = 0
    private let url: URL
    private let lockButton = UIButton(type: .system)
    private let lockSlot = UIView()
    private var locked = false
    private var lockHideWork: DispatchWorkItem?
    private var pip: AVPictureInPictureController?
    private var volumeObservation: NSKeyValueObservation?
    private let playButton = UIButton(type: .system)
    private let timeLabel = UILabel()
    private let hud = HUDView()
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 10, height: 10))
    private var hideTimer: Timer?

    private enum PanMode { case none, seek, brightness, volume }
    private var panMode = PanMode.none
    private var panStartValue: Double = 0
    private var isScrubbing = false
    private var rateBeforeBoost: Float = 1

    private var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    /// `player`: the feed card's own player, playing this video now (it goes on here, nothing is
    /// loaded or sought); it is given back with `handBack`.
    init(url: URL, startAt: CMTime = .zero, player lent: AVPlayer? = nil) {
        self.url = url
        if let lent {
            player = lent
            self.startAt = .zero
        } else {
            let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]))
            item.preferredForwardBufferDuration = 2
            player = AVPlayer(playerItem: item)
            self.startAt = startAt
        }
        player.automaticallyWaitsToMinimizeStalling = false
        super.init(nibName: nil, bundle: nil)
    }

    /// The player went back to its feed card: this screen no longer pauses or seeks it.
    private(set) var handedBack = false
    func handBack() {
        handedBack = true
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        playerLayer.player = nil
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    /// While locked, system edge swipes need a second swipe (no accidental exits).
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { locked ? .all : [] }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Self.viewerBackdrop
        stage.backgroundColor = Self.viewerBackdrop
        stage.accessibilityIdentifier = "player"
        view.addSubview(stage)
        stage.addLayoutGuide(safe)
        safeTop = safe.topAnchor.constraint(equalTo: stage.topAnchor)
        safeBottom = stage.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        safeLeft = safe.leadingAnchor.constraint(equalTo: stage.leadingAnchor)
        safeRight = stage.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        NSLayoutConstraint.activate([safeTop, safeBottom, safeLeft, safeRight])
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        stage.layer.addSublayer(playerLayer)
        posterView.contentMode = .scaleAspectFit
        posterView.isHidden = true
        stage.addSubview(posterView)
        stage.addSubview(volumeView)
        buildControls()
        if !canShowControls {
            controls.alpha = 0
            lockButton.alpha = 0
        }
        buildGestures()

        hud.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(hud)
        NSLayoutConstraint.activate([hud.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
                                     hud.topAnchor.constraint(equalTo: safe.topAnchor, constant: 40)])

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            self?.syncProgress()
            self?.layoutMediaShade()
            self?.embedding?.mediaGeometryChanged()
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero)
            if self.playbackVisible || self.pip?.isPictureInPictureActive == true {
                self.player.play()
            }
        }
        if startAt > .zero {
            initialSeekTime = startAt
            player.seek(to: startAt, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                DispatchQueue.main.async { if finished { self?.initialSeekTime = nil } }
            }
        }
        applyAudioPolicy()
        audioObserver = NotificationCenter.default.addObserver(forName: AudioPolicy.changed, object: nil, queue: .main) { [weak self] _ in self?.applyAudioPolicy() }
        // a page of the viewer starts when it is the page on screen (the next one is made early)
        if embedding == nil { player.playImmediately(atRate: 1) }
        scheduleHide()

        setUpPiP()
        // The hidden MPVolumeView (used for the volume gesture) suppresses the system volume
        // HUD, so show our own when the hardware volume buttons are pressed.
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let v = change.newValue else { return }
            DispatchQueue.main.async {
                guard let self, self.panMode != .volume else { return }
                self.hud.show(symbol: v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", progress: Double(v))
                self.hud.hide(after: 1.2)
            }
        }
    }

    // MARK: Rotation

    static let viewerBackdrop: UIColor = .black

    /// Whether the stage (what the player shows) is wider than tall.
    private var isLandscape: Bool { stage.bounds.width > stage.bounds.height }
    /// Compact-screen landscape (iPhone physical or rotated landscape, not iPad).
    var isCompactLandscape: Bool { stage.bounds.width > stage.bounds.height && min(stage.bounds.width, stage.bounds.height) < 600 }
    /// Stage height in the player's own (possibly quarter-turned) coordinate space.
    var stageHeight: CGFloat { isViewLoaded && stage.bounds.height > 0 ? stage.bounds.height : view.bounds.height }
    /// Trailing clearance reserved for the bottom-right landscape action pill.
    var landscapeTrailingInset: CGFloat {
        guard isViewLoaded, isCompactLandscape else { return 16 }
        stage.layoutIfNeeded()
        return max(180, landscapeActionPill.bounds.width + 28)
    }

    /// Portrait ⇄ landscape for the video alone (the button at the bottom right).
    @objc private func rotate() {
        guard !locked else { return }
        setQuarterTurns(quarterTurns != 0 ? 0 : Self.turnTowardsHolding(screenLandscape: view.bounds.width > view.bounds.height, scene: view.window?.windowScene), animated: true)
    }

    /// Which way to turn: towards how the device is held when that is known (lying flat or with
    /// the orientation lock on it may not be), else clockwise.
    static func turnTowardsHolding(screenLandscape: Bool, scene: UIWindowScene?) -> Int {
        if !screenLandscape {
            switch UIDevice.current.orientation {
            case .landscapeRight: return -1   // turned clockwise: the top of the video at the left edge
            default: return 1                 // turned counter-clockwise, or not known
            }
        }
        // a landscape screen back to portrait, the way the device turns back upright
        return scene?.effectiveGeometry.interfaceOrientation == .landscapeLeft ? 1 : -1
    }

    func setQuarterTurns(_ turns: Int, animated: Bool) {
        guard turns != quarterTurns else { return }
        dismissSpeedMenu(animated: false)
        quarterTurns = turns
        rotateButton.accessibilityValue = (turns != 0) != (view.bounds.width > view.bounds.height) ? L("viewer.landscape") : L("viewer.portrait")
        let apply = {
            self.layoutStage()
            self.applyLayoutMode()
            self.stage.layoutIfNeeded()
        }
        if animated, view.window != nil {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: apply)
        } else { apply() }
        embedding?.turned(turns != 0)
        setControls(visible: true)
    }

    /// Places the stage over the whole view, turned by `quarterTurns`, with the screen's safe
    /// area turned along (the notch of a portrait iPhone is at the side of a turned video).
    private func layoutStage() {
        let b = view.bounds
        let turned = quarterTurns != 0
        stage.transform = .identity
        stage.bounds = CGRect(origin: .zero, size: turned ? CGSize(width: b.height, height: b.width) : b.size)
        stage.center = CGPoint(x: b.midX, y: b.midY)
        stage.transform = CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2)
        let i = view.safeAreaInsets
        let (t, l, bo, r): (CGFloat, CGFloat, CGFloat, CGFloat) = switch quarterTurns {
        case 1: (i.right, i.top, i.left, i.bottom)     // clockwise: the stage's top is the screen's right
        case -1: (i.left, i.bottom, i.right, i.top)    // counter-clockwise: its top is the screen's left
        default: (i.top, i.left, i.bottom, i.right)
        }
        safeTop.constant = t; safeLeft.constant = l; safeBottom.constant = bo; safeRight.constant = r
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutStage()
    }

    /// "自动横屏播放横屏视频": a video wider than tall, opened on a portrait screen, is turned.
    private func autoLandscapeIfWanted() {
        guard LibraryPrefs.autoLandscape, quarterTurns == 0, view.bounds.height > view.bounds.width else { return }
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, t) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            let s = size.applying(t)
            guard abs(s.width) > abs(s.height) else { return }
            await MainActor.run {
                guard let self, self.playbackVisible, self.quarterTurns == 0, self.view.bounds.height > self.view.bounds.width else { return }
                self.setQuarterTurns(Self.turnTowardsHolding(screenLandscape: false, scene: self.view.window?.windowScene), animated: true)
            }
        }
    }

    private var autoTurnChecked = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playbackVisible = true
        if let e = embedding {
            resumePlayback()
            updatePlayButton()
            showPageControls()
            e.shown()
        }
        if !autoTurnChecked { autoTurnChecked = true; autoLandscapeIfWanted() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playbackVisible = false
        // turned away from in the viewer: it stops (it plays on if it comes back)
        if let embedding, !isInPiP, !handedBack {
            if !embedding.keepsPlayingOnDismiss() { player.pause() }
            embedding.paused(initialSeekTime ?? player.currentTime())
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // a page left in the viewer comes back upright
        if embedding != nil, !isInPiP { setQuarterTurns(0, animated: false) }
        // A pager may reuse this controller. Keep its observers until deallocation.
        if isInPiP || Self.inPiP === self || handedBack || embedding?.keepsPlayingOnDismiss() == true { return }
        player.pause()
    }

    func mediaFrame(in view: UIView, size: CGSize) -> CGRect {
        let rect = playerLayer.videoRect
        return stage.convert(rect.isEmpty ? AVMakeRect(aspectRatio: size, insideRect: stage.bounds) : rect, to: view)
    }

    func showTransitionPoster(_ image: UIImage) {
        loadViewIfNeeded()
        guard !playerLayer.isReadyForDisplay else { return }
        posterView.image = image
        posterView.isHidden = false
        posterObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                self?.posterView.isHidden = true
                self?.posterView.image = nil
                self?.posterObservation = nil
            }
        }
    }

    // MARK: Picture in picture

    private func setUpPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { pipButton.isHidden = true; return }
        let p = AVPictureInPictureController(playerLayer: playerLayer)
        p?.delegate = self
        p?.canStartPictureInPictureAutomaticallyFromInline = true
        pip = p
    }

    @objc private func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func stopPiP() {
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
    }

    func closePiPImmediately() {
        pipActive = false
        parkedPiPWindow = nil
        dismissSpeedMenu(animated: false)
        let activePiP = pip
        pip = nil
        activePiP?.delegate = nil
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
        if Self.inPiP === self { Self.inPiP = nil }
        Self.pipOwner = nil
    }

    /// Parks `playerLayer` invisibly inside the `UIWindow` at its exact screen rect during
    /// `willStart -> didStart` so the fullscreen viewer can dismiss at Frame 0 without showing
    /// lingering player/placeholder frames while AVKit animates the PiP tile out from that rect.
    func parkLayerInWindowForPiP() {
        guard let win = view.window else { return }
        let frameInWindow = stage.layer.convert(playerLayer.frame, to: win.layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        win.layer.addSublayer(playerLayer)
        playerLayer.frame = frameInWindow
        playerLayer.opacity = 0.001
        CATransaction.commit()
        parkedPiPWindow = win
    }

    func restoreLayerToStageFromPiP() {
        parkedPiPWindow = nil
        guard isViewLoaded else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.superlayer !== stage.layer {
            stage.layer.insertSublayer(playerLayer, at: 0)
        }
        playerLayer.frame = stage.bounds
        playerLayer.opacity = 1
        CATransaction.commit()
    }

    func pauseIfHidden() {
        if !playbackVisible && !handedBack { player.pause() }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        pipActive = true
        Self.inPiP = self
        dismissSpeedMenu(animated: false)
        if let embedding {
            embedding.pipWillStart()
        } else {
            Self.pipOwner = self
            parkLayerInWindowForPiP()
            if presentingViewController != nil {
                dismiss(animated: false)
            }
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        restoreLayerToStageFromPiP()
        if let embedding {
            embedding.pipDidStart()
        } else if presentingViewController != nil {
            dismiss(animated: false)
        }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        restoreLayerToStageFromPiP()
        if let embedding {
            embedding.pipRestore(done)
            return
        }
        guard presentingViewController == nil, let host = Self.topViewController() else { done(true); return }
        modalPresentationStyle = .fullScreen
        host.present(self, animated: true) { done(true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        pipActive = false
        restoreLayerToStageFromPiP()
        if let embedding {
            embedding.pipDidStop()
        } else {
            if !playbackVisible { player.pause() }
            Self.pipOwner = nil
        }
        if Self.inPiP === self { Self.inPiP = nil }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pipActive = false
        restoreLayerToStageFromPiP()
        if Self.inPiP === self { Self.inPiP = nil }
        Self.pipOwner = nil
        embedding?.pipDidStop()
        hud.show(symbol: "pip", text: L("viewer.pipFailed"))
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }

    // MARK: Lock

    /// The lock sits in its slot among the buttons; while locked it slides sideways to the
    /// middle of the screen's width at the same height (springing there), and on unlocking it is
    /// back in its slot at once, so the two places never show a lock at the same time.
    private var lockAtSlot: [NSLayoutConstraint] = []
    private var lockAtCenter: [NSLayoutConstraint] = []

    @objc private func toggleLock() {
        dismissSpeedMenu(animated: false)
        locked.toggle()
        // the hidden controls must not take the touches meant for the lock (a turned stage still
        // hit-tested them at alpha 0, over the lock)
        controls.isUserInteractionEnabled = !locked
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        updateLockButton()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        if locked {
            hideTimer?.invalidate()
            stage.layoutIfNeeded()
            lockButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            NSLayoutConstraint.deactivate(lockAtSlot)
            NSLayoutConstraint.activate(lockAtCenter)
            UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.controls.alpha = 0 }
            UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3) { self.stage.layoutIfNeeded() }
            hud.show(symbol: "lock.fill", text: L("viewer.locked"))
            flashLockButton()
        } else {
            lockButton.backgroundColor = .clear
            NSLayoutConstraint.deactivate(lockAtCenter)
            NSLayoutConstraint.activate(lockAtSlot)
            UIView.performWithoutAnimation { stage.layoutIfNeeded() }
            hud.show(symbol: "lock.open.fill", text: L("viewer.unlocked"))
            setControls(visible: true)
        }
    }

    private func updateLockButton() {
        lockButton.setImage(UIImage(systemName: locked ? "lock.fill" : "lock.open", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        lockButton.accessibilityLabel = locked ? L("viewer.unlock") : L("viewer.lock")
        lockButton.accessibilityValue = locked ? L("viewer.locked") : L("viewer.notLocked")
    }

    /// While locked only the lock button exists; a tap anywhere shows it for a moment.
    private func flashLockButton() {
        lockHideWork?.cancel()
        UIView.animate(withDuration: 0.15, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.lockButton.alpha = 1 }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.locked else { return }
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.lockButton.alpha = 0 }
        }
        lockHideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    private var audioObserver: NSObjectProtocol?

    /// Headphones-only: mute unless headphones are the current output.
    /// The user chose to hear this video through the speaker (reset when headphones go away).
    private var allowSpeaker = false
    private var hadHeadphones = AudioPolicy.headphonesConnected
    private weak var soundPrompt: UIView?

    private func applyAudioPolicy() {
        let now = AudioPolicy.headphonesConnected
        if hadHeadphones && !now { allowSpeaker = false }   // unplugged: ask again
        hadHeadphones = now
        let mute = AudioPolicy.shouldMute(allowSpeaker: allowSpeaker)
        player.isMuted = mute
        updateMuteButton()
        if !mute { soundPrompt?.removeFromSuperview(); return }
        guard canShowControls, soundPrompt == nil else { return }
        let url = url
        Task { [weak self] in
            guard await AudioPolicy.hasAudio(url) else { return }
            await MainActor.run { self?.showSoundPrompt() }
        }
    }

    /// "没有连接耳机，已静音 · 开启声音": the user may hear this video through the speaker.
    private func showSoundPrompt() {
        guard canShowControls, soundPrompt == nil, player.isMuted else { return }
        let label = UILabel()
        label.text = AudioPolicy.promptText
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        let on = UIButton(type: .system)
        on.setTitle(L("audio.turnOn"), for: .normal)
        on.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        on.tintColor = .systemYellow
        on.accessibilityIdentifier = "soundOn"
        let box = UIStackView(arrangedSubviews: [UIImageView(image: UIImage(systemName: "speaker.slash.fill")), label, on])
        (box.arrangedSubviews[0] as? UIImageView)?.tintColor = .white
        box.spacing = 10
        box.alignment = .center
        box.isLayoutMarginsRelativeArrangement = true
        box.layoutMargins = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        box.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        box.layer.cornerRadius = 18
        box.accessibilityIdentifier = "audioBanner"
        on.addAction(UIAction { [weak self, weak box] _ in
            self?.allowSpeaker = true
            self?.player.isMuted = false
            UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: { box?.alpha = 0 }) { _ in box?.removeFromSuperview() }
        }, for: .touchUpInside)
        box.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(box)
        NSLayoutConstraint.activate([box.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
                                     box.topAnchor.constraint(equalTo: safe.topAnchor, constant: 60)])
        soundPrompt = box
        box.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { box.alpha = 1 }
        // it steps aside after a while; the video stays muted
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak box] in
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: { box?.alpha = 0 }) { _ in box?.removeFromSuperview() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutStage()
        applyLayoutMode()
        stage.layoutIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if parkedPiPWindow == nil { playerLayer.frame = stage.bounds }
        posterView.frame = stage.bounds
        CATransaction.commit()
        layoutMediaShade()
        embedding?.mediaGeometryChanged()
    }


    deinit {
        if playerLayer.superlayer !== stage.layer { playerLayer.removeFromSuperlayer() }
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let a = audioObserver { NotificationCenter.default.removeObserver(a); audioObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        volumeObservation = nil
        hideTimer?.invalidate()
        lockHideWork?.cancel()
    }

    private func resumePlayback() {
        if duration > 0, player.currentTime().seconds >= duration {
            player.seek(to: .zero)
        }
        player.playImmediately(atRate: playbackRate)
    }

    @objc private func toggleMute() {
        allowSpeaker = player.isMuted
        player.isMuted.toggle()
        updateMuteButton()
    }

    private func updateMuteButton() {
        let sym = player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        muteButton.accessibilityLabel = player.isMuted ? L("audio.turnOn") : nil
    }

    private static func formatRate(_ r: Float) -> String {
        r == floor(r) ? "\(Int(r))×" : String(format: "%g×", r)
    }

    private func updateSpeedButton() {
        speedButton.setTitle(Self.formatRate(playbackRate), for: .normal)
    }

    /// Presents a Liquid Glass / dark blurred speed picker directly inside `controls` (which rotates
    /// with `stage`), so quarter-turned videos always show properly oriented menu text instead of an
    /// unrotated window-level `UIMenu`.
    @objc private func toggleSpeedMenu() {
        if speedMenuBackdrop != nil {
            dismissSpeedMenu(animated: true)
            return
        }
        let backdrop = UIControl()
        backdrop.backgroundColor = .clear
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addTarget(self, action: #selector(closeSpeedMenuFromBackdrop), for: .touchDown)
        controls.addSubview(backdrop)

        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) }
        else { effect = UIBlurEffect(style: .systemChromeMaterialDark) }
        let glass = UIVisualEffectView(effect: effect)
        glass.overrideUserInterfaceStyle = .dark
        glass.layer.cornerRadius = 16
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.layer.borderWidth = 0.5
        glass.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        glass.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(glass)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)

        let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        for (idx, r) in rates.enumerated() {
            if idx > 0 {
                let sep = UIView()
                sep.backgroundColor = UIColor.white.withAlphaComponent(0.12)
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                stack.addArrangedSubview(sep)
            }
            let selected = abs(r - playbackRate) < 0.01
            let row = UIButton(type: .system)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            row.widthAnchor.constraint(equalToConstant: 132).isActive = true

            let title = UILabel()
            title.text = Self.formatRate(r)
            title.font = .monospacedDigitSystemFont(ofSize: 15, weight: selected ? .semibold : .regular)
            title.textColor = .white
            title.isUserInteractionEnabled = false
            title.translatesAutoresizingMaskIntoConstraints = false

            let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
            check.tintColor = .white
            check.isHidden = !selected
            check.isUserInteractionEnabled = false
            check.translatesAutoresizingMaskIntoConstraints = false

            row.addSubview(title)
            row.addSubview(check)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            row.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.playbackRate = r
                if self.player.timeControlStatus != .paused { self.player.rate = r }
                self.updateSpeedButton()
                self.dismissSpeedMenu(animated: true)
            }, for: .touchUpInside)
            stack.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: controls.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            glass.trailingAnchor.constraint(equalTo: speedButton.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: isCompactLandscape ? landscapeActionPill.topAnchor : speedButton.topAnchor, constant: -8),
        ])

        speedMenuBackdrop = backdrop
        speedMenuCard = glass
        glass.alpha = 0
        glass.transform = CGAffineTransform(scaleX: 0.86, y: 0.86).translatedBy(x: 8, y: 12)
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.84, initialSpringVelocity: 0) {
            glass.alpha = 1
            glass.transform = .identity
        }
    }

    @objc private func closeSpeedMenuFromBackdrop() {
        dismissSpeedMenu(animated: true)
    }

    private func dismissSpeedMenu(animated: Bool) {
        guard let backdrop = speedMenuBackdrop else { return }
        let card = speedMenuCard
        speedMenuBackdrop = nil
        speedMenuCard = nil
        guard animated else {
            backdrop.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut]) {
            card?.alpha = 0
            card?.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        } completion: { _ in
            backdrop.removeFromSuperview()
        }
    }

    // MARK: Controls

    private func buildControls() {
        controls.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(controls)

        // Twitter-style solid black bottom dock with the full-width progress bar flush along its top edge.
        dockView.backgroundColor = .black
        dockView.overrideUserInterfaceStyle = .dark
        dockView.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(dockView)

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.accessibilityLabel = L("viewer.close")
        closeButton.accessibilityIdentifier = "playerClose"

        pipButton.setImage(UIImage(systemName: "pip.enter", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        pipButton.tintColor = .white
        pipButton.addTarget(self, action: #selector(togglePiP), for: .touchUpInside)
        pipButton.accessibilityLabel = L("viewer.pip")
        pipButton.accessibilityIdentifier = "playerPiP"

        rotateButton.setImage(UIImage(systemName: "rotate.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        rotateButton.tintColor = .white
        rotateButton.addTarget(self, action: #selector(rotate), for: .touchUpInside)
        rotateButton.accessibilityLabel = L("viewer.rotate")
        rotateButton.accessibilityIdentifier = "playerRotate"

        lockButton.tintColor = .white
        lockButton.layer.cornerRadius = 20
        lockButton.addTarget(self, action: #selector(toggleLock), for: .touchUpInside)
        lockButton.accessibilityIdentifier = "playerLock"
        updateLockButton()

        playButton.tintColor = .white
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)

        scrubBar.onScrubBegan = { [weak self] in self?.scrubBegan() }
        scrubBar.onScrubChanged = { [weak self] f in self?.scrubChanged(fraction: f) }
        scrubBar.onScrubEnded = { [weak self] in self?.scrubEnded() }
        scrubBar.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(scrubBar)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        timeLabel.accessibilityIdentifier = "time"
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        favoriteButton.addTarget(self, action: #selector(toggleFavorite), for: .touchUpInside)
        favoriteButton.accessibilityIdentifier = "playerFavorite"
        updateFavoriteButton()

        shareButton.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        shareButton.tintColor = .white
        shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)
        shareButton.accessibilityLabel = L("viewer.share")
        shareButton.accessibilityIdentifier = "playerShare"

        muteButton.tintColor = .white
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        muteButton.accessibilityIdentifier = "playerMute"
        updateMuteButton()

        speedButton.tintColor = .white
        speedButton.setTitleColor(.white, for: .normal)
        speedButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        speedButton.addTarget(self, action: #selector(toggleSpeedMenu), for: .touchUpInside)
        speedButton.accessibilityLabel = L("player.speed")
        speedButton.accessibilityIdentifier = "playerSpeed"
        updateSpeedButton()

        // Compact-landscape overlay pieces (p3 design: top-left back button, bottom gradient scrim,
        // bottom-right dark translucent action pill, bottom inline play + scrubber + time row).
        landscapeScrim.isUserInteractionEnabled = false
        landscapeScrim.translatesAutoresizingMaskIntoConstraints = false
        controls.insertSubview(landscapeScrim, at: 0)

        captionContainer.translatesAutoresizingMaskIntoConstraints = false
        controls.insertSubview(captionContainer, aboveSubview: landscapeScrim)

        landscapeBackButton.setImage(UIImage(systemName: "arrow.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        landscapeBackButton.tintColor = .white
        landscapeBackButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        landscapeBackButton.layer.cornerRadius = 20
        landscapeBackButton.layer.borderWidth = 0.5
        landscapeBackButton.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        landscapeBackButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        landscapeBackButton.accessibilityLabel = L("viewer.close")
        landscapeBackButton.accessibilityIdentifier = "playerLandscapeClose"
        landscapeBackButton.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(landscapeBackButton)

        landscapeActionPill.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        landscapeActionPill.layer.cornerRadius = 20
        landscapeActionPill.layer.borderWidth = 0.5
        landscapeActionPill.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        landscapeActionPill.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(landscapeActionPill)

        landscapePillRow.spacing = 4
        landscapePillRow.alignment = .center
        landscapePillRow.translatesAutoresizingMaskIntoConstraints = false
        landscapeActionPill.addSubview(landscapePillRow)

        landscapeBottomRow.spacing = 10
        landscapeBottomRow.alignment = .center
        landscapeBottomRow.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(landscapeBottomRow)

        // Dock row for portrait phones & iPads
        buttonRow.spacing = 6
        buttonRow.alignment = .center
        barSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        dockView.addSubview(buttonRow)
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(lockButton)

        let g = safe
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: stage.topAnchor), controls.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: stage.leadingAnchor), controls.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            captionContainer.topAnchor.constraint(equalTo: g.topAnchor),
            captionContainer.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            captionContainer.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            dockView.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            dockView.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            dockView.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            buttonRow.topAnchor.constraint(equalTo: dockView.topAnchor, constant: 6),
            buttonRow.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -4),
            buttonRow.heightAnchor.constraint(equalToConstant: 44),
            landscapeScrim.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            landscapeScrim.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            landscapeScrim.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            landscapeScrim.heightAnchor.constraint(equalToConstant: 150),
            landscapeBackButton.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            landscapeBackButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            landscapeBackButton.widthAnchor.constraint(equalToConstant: 40),
            landscapeBackButton.heightAnchor.constraint(equalToConstant: 40),
            landscapeBottomRow.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 14),
            landscapeBottomRow.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -14),
            landscapeBottomRow.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -6),
            landscapeBottomRow.heightAnchor.constraint(equalToConstant: 36),
            landscapeActionPill.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -14),
            landscapeActionPill.bottomAnchor.constraint(equalTo: landscapeBottomRow.topAnchor, constant: -10),
            landscapeActionPill.heightAnchor.constraint(equalToConstant: 40),
            landscapePillRow.leadingAnchor.constraint(equalTo: landscapeActionPill.leadingAnchor, constant: 8),
            landscapePillRow.trailingAnchor.constraint(equalTo: landscapeActionPill.trailingAnchor, constant: -8),
            landscapePillRow.topAnchor.constraint(equalTo: landscapeActionPill.topAnchor),
            landscapePillRow.bottomAnchor.constraint(equalTo: landscapeActionPill.bottomAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 34), playButton.heightAnchor.constraint(equalToConstant: 36),
            favoriteButton.widthAnchor.constraint(equalToConstant: 32), favoriteButton.heightAnchor.constraint(equalToConstant: 36),
            shareButton.widthAnchor.constraint(equalToConstant: 32), shareButton.heightAnchor.constraint(equalToConstant: 36),
            lockSlot.widthAnchor.constraint(equalToConstant: 32), lockSlot.heightAnchor.constraint(equalToConstant: 36),
            pipButton.widthAnchor.constraint(equalToConstant: 32), pipButton.heightAnchor.constraint(equalToConstant: 36),
            rotateButton.widthAnchor.constraint(equalToConstant: 32), rotateButton.heightAnchor.constraint(equalToConstant: 36),
            muteButton.widthAnchor.constraint(equalToConstant: 32), muteButton.heightAnchor.constraint(equalToConstant: 36),
            speedButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 34), speedButton.heightAnchor.constraint(equalToConstant: 36),
            closeButton.widthAnchor.constraint(equalToConstant: 32), closeButton.heightAnchor.constraint(equalToConstant: 36),
            lockButton.widthAnchor.constraint(equalToConstant: 40), lockButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        dockConstraints = [
            scrubBar.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            scrubBar.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            scrubBar.centerYAnchor.constraint(equalTo: dockView.topAnchor),
            scrubBar.heightAnchor.constraint(equalToConstant: 24),
            captionContainer.bottomAnchor.constraint(equalTo: dockView.topAnchor, constant: -4),
        ]
        landscapeConstraints = [
            scrubBar.heightAnchor.constraint(equalToConstant: 28),
            captionContainer.bottomAnchor.constraint(equalTo: landscapeBottomRow.topAnchor, constant: -6),
        ]
        lockAtSlot = [lockButton.centerXAnchor.constraint(equalTo: lockSlot.centerXAnchor), lockButton.centerYAnchor.constraint(equalTo: lockSlot.centerYAnchor)]
        lockAtCenter = [lockButton.centerXAnchor.constraint(equalTo: stage.centerXAnchor), lockButton.centerYAnchor.constraint(equalTo: lockSlot.centerYAnchor)]
        applyLayoutMode()
        // in the viewer, with the drags on (a sideways swipe seeks): arrows to the neighbours
        if let e = embedding, dragGestures {
            for (on, symbol, label, id, action, left) in [(e.hasPrevious, "chevron.left", L("viewer.previous"), "playerPrevious", #selector(stepPrevious), true),
                                                          (e.hasNext, "chevron.right", L("viewer.next"), "playerNext", #selector(stepNext), false)] where on {
                let b = Self.makeAdaptiveNavButton(symbol: symbol, label: label, id: id, target: self, action: action)
                controls.addSubview(b)
                NSLayoutConstraint.activate([
                    b.widthAnchor.constraint(equalToConstant: 44), b.heightAnchor.constraint(equalToConstant: 44),
                    b.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
                    left ? b.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12) : b.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
                ])
            }
        }
        updatePlayButton()
    }

    private static func makeAdaptiveNavButton(symbol: String, label: String, id: String, target: Any, action: Selector) -> UIView {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) }
        else { effect = UIBlurEffect(style: .systemChromeMaterial) }
        let glass = UIVisualEffectView(effect: effect)
        glass.layer.cornerRadius = 22
        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        b.tintColor = .label
        b.accessibilityLabel = label
        b.accessibilityIdentifier = id
        b.addTarget(target, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(b)
        NSLayoutConstraint.activate([
            b.topAnchor.constraint(equalTo: glass.contentView.topAnchor), b.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            b.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor), b.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
        return glass
    }

    /// Switches cleanly between the solid black bottom dock (portrait phones & iPads) and the
    /// compact-landscape p3 overlay layout (iPhones in landscape or rotated landscape).
    private func applyLayoutMode() {
        let compact = isCompactLandscape
        guard lastCompactLandscape != compact else { return }
        let hadMode = lastCompactLandscape != nil
        lastCompactLandscape = compact

        NSLayoutConstraint.deactivate(dockConstraints)
        NSLayoutConstraint.deactivate(landscapeConstraints)
        NSLayoutConstraint.deactivate(lockAtSlot)
        NSLayoutConstraint.deactivate(lockAtCenter)
        for stack in [buttonRow, landscapePillRow, landscapeBottomRow] {
            for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        }
        scrubBar.removeFromSuperview()

        dockView.isHidden = compact
        landscapeScrim.isHidden = !compact
        landscapeBackButton.isHidden = !compact
        landscapeActionPill.isHidden = !compact
        landscapeBottomRow.isHidden = !compact

        if compact {
            [favoriteButton, shareButton, lockSlot, pipButton, rotateButton, muteButton, speedButton].forEach { landscapePillRow.addArrangedSubview($0) }
            [playButton, scrubBar, timeLabel].forEach { landscapeBottomRow.addArrangedSubview($0) }
            NSLayoutConstraint.activate(landscapeConstraints)
        } else {
            [playButton, timeLabel, barSpacer, favoriteButton, shareButton, lockSlot, pipButton, rotateButton, closeButton].forEach { buttonRow.addArrangedSubview($0) }
            controls.addSubview(scrubBar)
            NSLayoutConstraint.activate(dockConstraints)
        }
        NSLayoutConstraint.activate(locked ? lockAtCenter : lockAtSlot)
        if hadMode { embedding?.layoutModeChanged() }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        dismissSpeedMenu(animated: false)
        // the screen itself turned (the device was turned): it now fits by itself
        if quarterTurns != 0 { quarterTurns = 0; embedding?.turned(false) }
        coordinator.animate(alongsideTransition: { _ in
            self.layoutStage()
            self.applyLayoutMode()
            self.stage.layoutIfNeeded()
        })
    }

    /// Share the video file (to other apps, Files, AirDrop…).
    @objc private func share() {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = shareButton
        present(vc, animated: true)
    }

    @objc private func toggleFavorite() {
        if let embedding { embedding.toggleFavorite() } else { onToggleFavorite?() }
    }

    private func updateFavoriteButton() {
        let sym = isFavorited ? "star.fill" : "star"
        favoriteButton.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        favoriteButton.tintColor = isFavorited ? Self.starGold : .white
        favoriteButton.accessibilityLabel = isFavorited ? L("common.unfavorite") : L("common.favorite")
    }

    private func syncProgress() {
        let t = player.currentTime().seconds
        if !isScrubbing, duration > 0 { scrubBar.progress = Float(t / duration) }
        timeLabel.text = "\(Self.fmt(isScrubbing ? Double(scrubBar.progress) * duration : t)) / \(Self.fmt(duration))"
        updatePlayButton()
    }

    private func updatePlayButton() {
        let name = player.timeControlStatus == .paused ? "play.fill" : "pause.fill"
        playButton.accessibilityLabel = player.timeControlStatus == .paused ? L("viewer.play") : L("viewer.pause")
        playButton.accessibilityIdentifier = "playPause"
        playButton.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)), for: .normal)
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s)
        return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }

    private var canShowControls: Bool { embedding?.canShowControls() ?? true }

    func showPageControls() {
        setControls(visible: true)
        applyAudioPolicy()
    }

    func revealControlsForTransition() {
        guard !locked else { return }
        controls.alpha = 1
        lockButton.alpha = 1
    }

    func hideControlsForDismiss() {
        dismissSpeedMenu(animated: false)
        controls.alpha = 0
        lockButton.alpha = 0
    }

    private func setControls(visible: Bool) {
        hideTimer?.invalidate()
        if !visible { dismissSpeedMenu(animated: false) }
        guard !locked, canShowControls else { return }
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.controls.alpha = visible ? 1 : 0; self.lockButton.alpha = visible ? 1 : 0 }
        embedding?.controlsVisible(visible)
        if visible { scheduleHide() }
    }

    private func layoutMediaShade() {}

    /// Whether the controls are showing (the viewer's caption shows with them).
    var controlsShown: Bool { controls.alpha > 0.5 && !locked }
    /// How far up from the bottom the controls reach (the viewer's caption sits above them).
    var controlsClearance: CGFloat {
        guard isViewLoaded else { return 90 }
        stage.layoutIfNeeded()
        if isCompactLandscape {
            return stage.bounds.height - landscapeBottomRow.frame.minY + 6
        }
        return stage.bounds.height - dockView.frame.minY + 4
    }

    private func scheduleHide() {
        // Bottom controls stay visible on inactivity across all versions; single tap toggles manually.
        hideTimer?.invalidate()
    }

    @objc private func close() {
        if let e = embedding { e.close() } else { dismiss(animated: true) }
    }

    @objc private func stepPrevious() { embedding?.step(-1) }
    @objc private func stepNext() { embedding?.step(1) }

    @objc private func togglePlay() {
        guard !locked else { return }
        // no badge at the top: the play/pause button below shows the state and stays there
        if player.timeControlStatus == .paused { resumePlayback() } else { player.pause() }
        updatePlayButton()
        setControls(visible: true)
    }

    private func scrubBegan() { isScrubbing = true; hideTimer?.invalidate() }
    private func scrubChanged(fraction: Float) {
        let t = Double(fraction) * duration
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        syncProgress()
    }
    private func scrubEnded() { isScrubbing = false; scheduleHide() }

    // MARK: Gestures

    private func buildGestures() {
        let double = UITapGestureRecognizer(target: self, action: #selector(togglePlay))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap))
        single.require(toFail: double)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        long.minimumPressDuration = 0.25
        [double, single, long].forEach { $0.delegate = self; stage.addGestureRecognizer($0) }
        if dragGestures {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            // a finger or the Pencil: a trackpad's or a mouse's drag does not seek or set volume / brightness
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            stage.addGestureRecognizer(pan)
        } else {
            // without the drags, dragging down closes the player (or the viewer it is a page of),
            // as in the photo viewer
            let down = UISwipeGestureRecognizer(target: self, action: #selector(close))
            down.direction = .down
            down.delegate = self
            stage.addGestureRecognizer(down)
        }
    }

    private var singleTapPoint = CGPoint.zero
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        singleTapPoint = touch.location(in: stage)
        if let v = touch.view, v === lockButton || v.isDescendant(of: lockButton) { return false }
        // Locked: nothing but a single tap, which only reveals the lock button.
        if locked { return g is UITapGestureRecognizer && (g as! UITapGestureRecognizer).numberOfTapsRequired == 1 }
        if g is UISwipeGestureRecognizer { return true }
        // Leave the bottom dock / compact-landscape overlays and scrub bar to their own controls.
        guard controls.alpha > 0.01, let v = touch.view else { return true }
        if let menuBg = speedMenuBackdrop, v === menuBg || v.isDescendant(of: menuBg) { return false }
        if v === dockView || v.isDescendant(of: dockView)
            || v === scrubBar || v.isDescendant(of: scrubBar)
            || v === captionContainer || v.isDescendant(of: captionContainer)
            || v === landscapeBackButton || v.isDescendant(of: landscapeBackButton)
            || v === landscapeActionPill || v.isDescendant(of: landscapeActionPill)
            || v === landscapeBottomRow || v.isDescendant(of: landscapeBottomRow) { return false }
        return !(v is UIControl) && !(v.superview is UIControl)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UILongPressGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UILongPressGestureRecognizer)
    }

    @objc private func singleTap() {
        if locked {
            // a tap on the lock's place unlocks even when the lock itself missed it
            if lockButton.alpha > 0.5, lockButton.frame.insetBy(dx: -16, dy: -16).contains(singleTapPoint) { toggleLock(); return }
            flashLockButton(); return
        }
        setControls(visible: controls.alpha < 0.5)
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            rateBeforeBoost = player.rate == 0 ? 1 : player.rate
            player.rate = 2.5
            hud.show(symbol: "forward.fill", text: "2.5×", sticky: true)
        case .ended, .cancelled, .failed:
            player.rate = rateBeforeBoost
            hud.hide()
        default: break
        }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let tr = g.translation(in: stage)
        switch g.state {
        case .began:
            let v = g.velocity(in: stage)
            if abs(v.x) > abs(v.y) {
                panMode = .seek
                panStartValue = player.currentTime().seconds
                isScrubbing = true
            } else if g.location(in: stage).x < stage.bounds.midX {
                panMode = .brightness
                panStartValue = Double(view.window?.windowScene?.screen.brightness ?? UIScreen.main.brightness)
            } else {
                panMode = .volume
                panStartValue = Double(volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
            }
        case .changed:
            switch panMode {
            case .seek:
                // A full-width drag covers min(duration, 120 s); feels precise on short clips and still fast on long ones.
                let span = min(max(duration, 1), 120)
                let target = min(max(panStartValue + Double(tr.x / stage.bounds.width) * span, 0), duration)
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if duration > 0 { scrubBar.progress = Float(target / duration) }
                let delta = target - panStartValue
                hud.show(symbol: delta >= 0 ? "goforward" : "gobackward", text: "\(Self.fmt(target)) / \(Self.fmt(duration))", sticky: true)
            case .brightness:
                let v = clamp(panStartValue - Double(tr.y / (stage.bounds.height * 0.7)))
                (view.window?.windowScene?.screen ?? UIScreen.main).brightness = CGFloat(v)
                hud.show(symbol: "sun.max.fill", progress: v)
            case .volume:
                let v = clamp(panStartValue - Double(tr.y / (stage.bounds.height * 0.7)))
                if let s = volumeSlider { s.value = Float(v); s.sendActions(for: .valueChanged) } else { player.volume = Float(v) }
                hud.show(symbol: v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", progress: v)
            case .none: break
            }
        default:
            if panMode == .seek { isScrubbing = false }
            panMode = .none
            hud.hide(after: 0.4)
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    private var volumeSlider: UISlider? { volumeView.subviews.compactMap { $0 as? UISlider }.first }
}

/// Full-width hairline progress bar sitting flush on the top edge of the Twitter-style black video bar.
final class IOSTopEdgeScrubBar: UIControl {
    var progress: Float = 0 { didSet { setNeedsDisplay() } }
    var onScrubBegan: (() -> Void)?
    var onScrubChanged: ((Float) -> Void)?
    var onScrubEnded: (() -> Void)?
    private var dragging = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fraction(for touch: UITouch) -> Float {
        let x = touch.location(in: self).x
        return bounds.width > 0 ? Float(min(1, max(0, x / bounds.width))) : 0
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        dragging = true
        progress = fraction(for: touch)
        onScrubBegan?()
        onScrubChanged?(progress)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        progress = fraction(for: touch)
        onScrubChanged?(progress)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { progress = fraction(for: touch); onScrubChanged?(progress) }
        dragging = false
        onScrubEnded?()
    }

    override func cancelTracking(with event: UIEvent?) {
        dragging = false
        onScrubEnded?()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let trackH: CGFloat = dragging ? 4.5 : 2.5
        let y = (bounds.height - trackH) / 2
        let w = bounds.width
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.28).cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: w, height: trackH))
        let fillW = max(0, min(w, w * CGFloat(progress)))
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: fillW, height: trackH))
        let d: CGFloat = dragging ? 14 : 8
        let cx = max(d / 2, min(w - d / 2, fillW))
        ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: (bounds.height - d) / 2, width: d, height: d))
    }
}

/// Top-centered rounded-rectangle Liquid Glass HUD for player feedback (speed, seek, brightness, volume, lock).
final class HUDView: UIView {
    private let glass: UIVisualEffectView
    private let icon = UIImageView()
    private let label = UILabel()
    private let bar = UIProgressView(progressViewStyle: .bar)
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect(style: .regular)
        } else {
            effect = UIBlurEffect(style: .systemChromeMaterialDark)
        }
        glass = UIVisualEffectView(effect: effect)
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        backgroundColor = .clear
        alpha = 0
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "hud"

        glass.overrideUserInterfaceStyle = .dark
        glass.layer.cornerRadius = 14
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        icon.tintColor = .white
        icon.preferredSymbolConfiguration = .init(pointSize: 15, weight: .semibold)
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        bar.progressTintColor = .white
        bar.trackTintColor = UIColor.white.withAlphaComponent(0.25)
        bar.layer.cornerRadius = 2.5
        bar.clipsToBounds = true
        let stack = UIStackView(arrangedSubviews: [icon, label, bar])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
            bar.widthAnchor.constraint(equalToConstant: 120),
            bar.heightAnchor.constraint(equalToConstant: 5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(symbol: String, text: String? = nil, progress: Double? = nil, sticky: Bool = false) {
        icon.image = UIImage(systemName: symbol)
        label.text = text
        label.isHidden = text == nil
        accessibilityLabel = text
        bar.isHidden = progress == nil
        if let p = progress { bar.progress = Float(p) }
        hideWork?.cancel()
        if alpha < 1 { UIView.animate(withDuration: 0.12, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.alpha = 1 } }
        if !sticky && progress == nil { hide(after: 0.6) }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let w = DispatchWorkItem { UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.alpha = 0 } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    init(colors: [UIColor]) {
        super.init(frame: .zero)
        (layer as! CAGradientLayer).colors = colors.map(\.cgColor)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Pure geometry + thumbnail snapshot of a grid tile (matching Apple Photos' `PXRegionOfInterest`).
struct GridTileTransitionInfo {
    let mediaId: String
    let frame: CGRect
    let cornerRadius: CGFloat
    let image: UIImage?
}

/// Apple Photos-style custom modal transition for the Metal photo grid (`UIViewControllerAnimatedTransitioning`
/// over `.overFullScreen`, instead of UIKit's `.zoom`). The Metal grid stays live underneath and only hides
/// the active tile (`setHiddenMediaId`) while the morph view animates between the tile rect and full screen.
private final class GridViewerTransition: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {
    let sourceProvider: (FeedItem, UICoordinateSpace, Bool) -> GridTileTransitionInfo?
    let setHiddenMediaId: (String?) -> Void
    private var isPresenting = true

    /// One-shot handoff state populated when committing an interactive drag-down-to-dismiss.
    var interactiveDismissStartFrame: CGRect?
    var interactiveDismissBackdropAlpha: CGFloat?
    var interactiveDismissVelocity: CGPoint?

    init(source: @escaping (FeedItem, UICoordinateSpace, Bool) -> GridTileTransitionInfo?,
         setHiddenMediaId: @escaping (String?) -> Void) {
        self.sourceProvider = source
        self.setHiddenMediaId = setHiddenMediaId
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        isPresenting = true
        return self
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        isPresenting = false
        return self
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        isPresenting ? 0.34 : 0.28
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        if isPresenting {
            animatePresent(using: context)
        } else {
            animateDismiss(using: context)
        }
    }

    private static func aspectFillFrame(of content: CGSize, inside bounds: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = max(bounds.width / content.width, bounds.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func animatePresent(using context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let viewer = context.viewController(forKey: .to) as? PhotoViewController else {
            context.completeTransition(false)
            return
        }
        let finalFrame = context.finalFrame(for: viewer)
        viewer.view.frame = finalFrame
        container.addSubview(viewer.view)
        viewer.view.layoutIfNeeded()

        let source = sourceProvider(viewer.currentItem, container, false)
        if let img = source?.image {
            viewer.showInitialTransitionPoster(img)
        }
        let destFrame = viewer.mediaFrameIn(container)

        guard let source, let destFrame, !destFrame.isEmpty, !UIAccessibility.isReduceMotionEnabled else {
            viewer.view.alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                viewer.view.alpha = 1
                viewer.revealChrome()
            }, completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            })
            return
        }

        setHiddenMediaId(source.mediaId)

        let backdrop = UIView(frame: container.bounds)
        backdrop.backgroundColor = PlayerViewController.viewerBackdrop
        backdrop.alpha = 0
        container.addSubview(backdrop)

        // Explicit clipping container + inner image view: starts at exact center-cropped square
        // matching the Metal grid tile and smoothly un-crops into the full aspect-ratio destFrame
        // with zero blur-to-sharp or square-to-aspect pop.
        let morphContainer = UIView(frame: source.frame)
        morphContainer.backgroundColor = .secondarySystemBackground
        morphContainer.clipsToBounds = true
        morphContainer.layer.cornerCurve = .continuous
        morphContainer.layer.cornerRadius = source.cornerRadius

        let morphImage = viewer.currentMediaImage ?? source.image
        let inner = UIImageView(image: morphImage)
        inner.contentMode = .scaleToFill
        let contentSize = morphImage?.size ?? destFrame.size
        inner.frame = Self.aspectFillFrame(of: contentSize, inside: source.frame.size)
        morphContainer.addSubview(inner)
        container.addSubview(morphContainer)

        viewer.view.alpha = 0

        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.88) {
            morphContainer.frame = destFrame
            morphContainer.layer.cornerRadius = 0
            inner.frame = CGRect(origin: .zero, size: destFrame.size)
            backdrop.alpha = 1
        }
        animator.addCompletion { [weak self] _ in
            viewer.view.alpha = 1
            viewer.revealChrome()
            backdrop.removeFromSuperview()
            morphContainer.removeFromSuperview()
            // Viewer now fully covers the grid; restore the hidden tile immediately so PiP or
            // non-animated dismiss never leaves a hole in the Metal grid.
            self?.setHiddenMediaId(nil)
            context.completeTransition(!context.transitionWasCancelled)
        }
        animator.startAnimation()
    }

    private func animateDismiss(using context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let viewer = context.viewController(forKey: .from) as? PhotoViewController else {
            context.completeTransition(false)
            return
        }

        let handoffFrame = interactiveDismissStartFrame
        let startBackdropAlpha = interactiveDismissBackdropAlpha ?? 1.0
        let handoffVelocity = interactiveDismissVelocity
        interactiveDismissStartFrame = nil
        interactiveDismissBackdropAlpha = nil
        interactiveDismissVelocity = nil

        let target = sourceProvider(viewer.currentItem, container, true)
        let startFrame = handoffFrame.map { viewer.view.convert($0, to: container) }
            ?? viewer.mediaFrameIn(container)
            ?? viewer.view.bounds

        guard let target, !startFrame.isEmpty, !UIAccessibility.isReduceMotionEnabled else {
            setHiddenMediaId(nil)
            UIView.animate(withDuration: 0.22, animations: {
                viewer.view.alpha = 0
            }, completion: { _ in
                viewer.view.removeFromSuperview()
                context.completeTransition(true)
            })
            return
        }

        setHiddenMediaId(target.mediaId)

        let backdrop = UIView(frame: container.bounds)
        backdrop.backgroundColor = PlayerViewController.viewerBackdrop
        backdrop.alpha = startBackdropAlpha
        backdrop.isUserInteractionEnabled = false
        container.addSubview(backdrop)

        // Photos morph with a crisp aspect-fill UIImageView; live videos use a snapshot of the
        // current video rect inside a clipping container so the active playback frame flies back
        // smoothly with zero distortion.
        let morphContainer = UIView(frame: startFrame)
        morphContainer.clipsToBounds = true
        morphContainer.backgroundColor = .secondarySystemBackground
        morphContainer.layer.cornerCurve = .continuous
        morphContainer.layer.cornerRadius = 0
        morphContainer.isUserInteractionEnabled = false

        var innerView: UIView?
        if let photoImage = viewer.currentMediaImage {
            let iv = UIImageView(image: photoImage)
            iv.contentMode = .scaleToFill
            iv.frame = morphContainer.bounds
            morphContainer.addSubview(iv)
            innerView = iv
        } else if let snap = viewer.currentVideoSnapshot(in: startFrame) {
            snap.frame = morphContainer.bounds
            morphContainer.addSubview(snap)
            innerView = snap
        } else if let thumb = target.image {
            let iv = UIImageView(image: thumb)
            iv.contentMode = .scaleToFill
            iv.frame = morphContainer.bounds
            morphContainer.addSubview(iv)
            innerView = iv
        }
        container.addSubview(morphContainer)

        viewer.view.alpha = 0

        let initialVelocity: CGVector
        if let v = handoffVelocity {
            let dx = target.frame.midX - startFrame.midX
            let dy = target.frame.midY - startFrame.midY
            let vx = abs(dx) > 1 ? min(max(v.x / dx, -6), 6) : 0
            let vy = abs(dy) > 1 ? min(max(v.y / dy, -6), 6) : 0
            initialVelocity = CGVector(dx: vx, dy: vy)
        } else {
            initialVelocity = .zero
        }

        let timing = UISpringTimingParameters(dampingRatio: 0.92, initialVelocity: initialVelocity)
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), timingParameters: timing)
        let targetInnerFrame = Self.aspectFillFrame(of: startFrame.size, inside: target.frame.size)
        animator.addAnimations {
            morphContainer.frame = target.frame
            morphContainer.layer.cornerRadius = target.cornerRadius
            innerView?.frame = targetInnerFrame
            backdrop.alpha = 0
        }
        animator.addCompletion { [weak self] _ in
            // Draw the tile back into the Metal grid synchronously before dropping the morph view
            // on the next tick, so no frame ever shows neither.
            self?.setHiddenMediaId(nil)
            viewer.view.removeFromSuperview()
            DispatchQueue.main.async {
                morphContainer.removeFromSuperview()
                backdrop.removeFromSuperview()
            }
            context.completeTransition(true)
        }
        animator.startAnimation()
    }
}

/// Fullscreen photo with pinch/double-tap zoom.
/// Full-screen viewer: swipe left / right through every photo and video of the list it was opened
/// from (on past the end of a post into the next one), pinch or double-tap to zoom, tap or swipe down to close; the share button sends the
/// current file to other apps, Files, AirDrop, or copies it.
final class PhotoViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private var items: [FeedItem]
    private var index: Int
    private var videoPositions: [Int: CMTime] = [:]
    var videoPosition: ((FeedItem) -> CMTime)?
    var saveVideoPosition: ((FeedItem, CMTime) -> Void)?
    var onEnteringPiP: (() -> Void)?
    var onDismissed: (() -> Void)?
    private(set) var didMutate = false
    /// Keeps the viewer alive while one of its videos plays in picture-in-picture after dismissal.
    private static var inPiP: PhotoViewController?
    private var dismissingForPiP = false
    private var zoomSourceProvider: ((FeedItem) -> UIView?)?
    private var gridTransition: GridViewerTransition?
    private let backdropView = UIView()
    private var dismissPan: UIPanGestureRecognizer?
    private var dismissSwipe: UISwipeGestureRecognizer?
    private var panBaseMediaFrame: CGRect = .zero
    private var hasAppeared = false
    /// Portrait photo bar: solid black bottom dock (counter + favorite + share + close).
    private let photoDock = UIView()
    private let bar = UIStackView()
    /// Landscape photo controls: Favorite, Share and Close grouped on a single Liquid Glass capsule.
    private let photoGlassPill: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) }
        else { effect = UIBlurEffect(style: .systemChromeMaterial) }
        let v = UIVisualEffectView(effect: effect)
        v.layer.cornerRadius = 22
        v.clipsToBounds = true
        return v
    }()
    private let glassFavoriteButton = UIButton(type: .system)
    private let glassShareButton = UIButton(type: .system)
    private let glassCloseButton = UIButton(type: .system)
    private let topCounter = UILabel()
    private var isLandscapePhoto: Bool { view.bounds.width > view.bounds.height }
    private var lastLandscapePhoto: Bool?
    private let pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
    private let counter = UILabel()
    private let favoriteButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    /// The post of the media on screen, over the bottom (above the bar, or inside a video's rotating controls).
    private let caption = UIHostingController(rootView: PostCaptionView(item: nil))
    private let captionHost = PassThroughView()
    private var captionPhotoConstraints: [NSLayoutConstraint] = []
    private var captionVideoConstraints: [NSLayoutConstraint] = []
    private var captionAboveBar: NSLayoutConstraint!
    private var captionAboveLandscape: NSLayoutConstraint!

    /// The feed card's player of the opened video (one player for both), and where it goes back.
    private var lentPlayer: AVPlayer?
    private let lentIndex: Int
    private var lentPage: PlayerViewController?
    private let giveBack: ((AVPlayer) -> Void)?

    init(items: [FeedItem], index: Int, player: AVPlayer? = nil, giveBack: ((AVPlayer) -> Void)? = nil) {
        Self.inPiP?.stopPiPAndCleanup()
        self.items = items
        let firstIndex = max(0, min(index, items.count - 1))
        self.index = firstIndex
        self.lentIndex = firstIndex
        self.lentPlayer = player
        self.giveBack = giveBack
        super.init(nibName: nil, bundle: nil)
    }

    private func stopPiPAndCleanup() {
        let p = currentPlayer
        if Self.inPiP === self { Self.inPiP = nil }
        dismissingForPiP = false
        zoomSourceProvider = nil
        onEnteringPiP = nil
        if let lent = lentPlayer {
            lentPlayer = nil
            lentPage?.handBack()
            p?.closePiPImmediately()
            giveBack?(lent)
        } else {
            p?.closePiPImmediately()
        }
        if presentingViewController == nil {
            finishDismissal()
        }
    }

    func setGridTransition(source: @escaping (FeedItem, UICoordinateSpace, Bool) -> GridTileTransitionInfo?,
                           setHiddenMediaId: @escaping (String?) -> Void) {
        zoomSourceProvider = nil
        preferredTransition = nil
        let t = GridViewerTransition(source: source, setHiddenMediaId: setHiddenMediaId)
        gridTransition = t
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        transitioningDelegate = t
    }

    fileprivate var currentItem: FeedItem { items[index] }

    fileprivate var currentMediaImage: UIImage? {
        guard currentPlayer == nil else { return nil }
        return (pages.viewControllers?.first as? ZoomPage)?.currentImage
    }

    fileprivate func currentVideoSnapshot(in rectInView: CGRect) -> UIView? {
        guard let player = currentPlayer else { return nil }
        let localRect = player.view.convert(rectInView, from: view)
        guard !localRect.isEmpty else { return nil }
        return player.view.resizableSnapshotView(from: localRect, afterScreenUpdates: false, withCapInsets: .zero)
    }

    fileprivate func showInitialTransitionPoster(_ image: UIImage) {
        loadViewIfNeeded()
        if let player = currentPlayer { player.showTransitionPoster(image) }
        else { (pages.viewControllers?.first as? ZoomPage)?.showTransitionPoster(image) }
    }

    fileprivate func mediaFrameIn(_ coordinateView: UIView) -> CGRect? {
        guard let frame = mediaFrame, !frame.isEmpty else { return nil }
        return view.convert(frame, to: coordinateView)
    }

    func setZoomSource(_ source: @escaping (FeedItem) -> UIView?) {
        zoomSourceProvider = source
        modalPresentationStyle = .fullScreen
        let options = UIViewController.Transition.ZoomOptions()
        options.alignmentRectProvider = { context in
            guard let viewer = context.zoomedViewController as? PhotoViewController,
                  let frame = viewer.mediaFrame, !frame.isEmpty else { return nil }
            return AVMakeRect(aspectRatio: context.sourceView.bounds.size, insideRect: frame)
        }
        options.interactiveDismissShouldBegin = { [weak self] context in
            context.willBegin && self?.currentPlayer == nil
                && (self?.pages.viewControllers?.first as? ZoomPage)?.isZoomed != true
        }
        preferredTransition = .zoom(options: options) { context in
            guard let viewer = context.zoomedViewController as? PhotoViewController,
                  let origin = source(viewer.items[viewer.index]) else { return nil }
            if !viewer.hasAppeared,
               let image = (origin as? MediaPageView)?.transitionImage ?? (origin as? UIImageView)?.image {
                viewer.loadViewIfNeeded()
                if let player = viewer.currentPlayer { player.showTransitionPoster(image) }
                else { (viewer.pages.viewControllers?.first as? ZoomPage)?.showTransitionPoster(image) }
            }
            return origin
        }
    }

    private var mediaFrame: CGRect? {
        let item = items[index]
        let size = item.width > 0 && item.height > 0 ? CGSize(width: item.width, height: item.height) : view.bounds.size
        if let player = currentPlayer { return player.mediaFrame(in: view, size: size) }
        return (pages.viewControllers?.first as? ZoomPage)?.mediaFrame(in: view, size: size)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.isUserInteractionEnabled = true
        if preferredTransition == nil, let provider = zoomSourceProvider {
            setZoomSource(provider)
        }
        if !hasAppeared {
            hasAppeared = true
            revealChrome()
            currentPlayer?.showPageControls()
        } else {
            revealChrome()
            currentPlayer?.showPageControls()
        }
        #if DEBUG
        // tests: the viewer closes by itself after this many seconds (the card ↔ viewer video handoff)
        if let s = ProcessInfo.processInfo.environment["TL_VIEWER_AUTOCLOSE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in self?.dismiss(animated: true) }
        }
        #endif
    }

    fileprivate func revealChrome() {
        photoDock.alpha = 1
        photoGlassPill.alpha = 1
        topCounter.alpha = 1
        captionHost.alpha = 1
        currentPlayer?.revealControlsForTransition()
    }

    private func hideChrome() {
        photoDock.alpha = 0
        photoGlassPill.alpha = 0
        topCounter.alpha = 0
        captionHost.alpha = 0
        currentPlayer?.hideControlsForDismiss()
    }

    /// Lets touches pass straight through the dismissing viewer and UIKit's `.zoom` morph/dimming
    /// layers to the underlying feed/grid (`toView`) inside `containerView`, while keeping
    /// `containerView` and `toView` interactive.
    private func setDismissPassThrough(_ passThrough: Bool, coordinator: UIViewControllerTransitionCoordinator) {
        let container = coordinator.containerView
        let toView = coordinator.view(forKey: .to)
            ?? presentingViewController?.view.window?.rootViewController?.view
        view.isUserInteractionEnabled = !passThrough
        container.isUserInteractionEnabled = true
        for sub in container.subviews {
            let holdsTarget = toView.map { sub === $0 || $0.isDescendant(of: sub) } ?? false
            if !holdsTarget {
                sub.isUserInteractionEnabled = !passThrough
            } else {
                sub.isUserInteractionEnabled = true
            }
        }
        toView?.isUserInteractionEnabled = true
        for g in container.gestureRecognizers ?? [] {
            g.isEnabled = !passThrough
        }
    }

    /// Accelerates UIKit's `.zoom` spring so opening feels immediate and closing drops its long
    /// sub-pixel tail (which otherwise swallows immediate taps on the underlying grid/feed).
    private func quickenZoom(in window: UIWindow?, isDismiss: Bool) {
        guard let window, let coordinator = transitionCoordinator, coordinator.isAnimated else { return }
        let speed: Float = isDismiss ? 2.8 : 2.4
        let commitDismissPassThrough = { [weak self] (ctx: UIViewControllerTransitionCoordinatorContext) in
            guard let self, let coord = self.transitionCoordinator else { return }
            self.setDismissPassThrough(true, coordinator: coord)
            // UIKit's `.zoom` animator starts right after `viewWillDisappear` and may re-enable
            // its overlay wrappers / catch gestures; enforce pass-through again on the next tick.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isBeingDismissed, let c = self.transitionCoordinator, !c.isInteractive, !c.isCancelled else { return }
                self.setDismissPassThrough(true, coordinator: c)
            }
            _ = ctx
        }
        if coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { [weak self] ctx in
                if !ctx.isInteractive && !ctx.isCancelled {
                    if isDismiss { commitDismissPassThrough(ctx) }
                    window.layer.speed = speed
                }
            }
        } else {
            if isDismiss { commitDismissPassThrough(coordinator) }
            window.layer.speed = speed
        }
        coordinator.animate(alongsideTransition: { [weak self] ctx in
            if isDismiss && !ctx.isInteractive {
                self?.setDismissPassThrough(true, coordinator: coordinator)
            }
        }) { [weak self] ctx in
            window.layer.speed = 1
            if isDismiss {
                for g in coordinator.containerView.gestureRecognizers ?? [] { g.isEnabled = true }
                if ctx.isCancelled {
                    self?.setDismissPassThrough(false, coordinator: coordinator)
                }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard isBeingPresented else { return }
        dismissingForPiP = false
        view.isUserInteractionEnabled = true
        pages.view.transform = .identity
        backdropView.alpha = 1
        hasAppeared = true
        if preferredTransition != nil {
            quickenZoom(in: presentingViewController?.view.window, isDismiss: false)
        }
        // Reveal caption & controls in parallel with the zoom opening so they are ready on arrival.
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.revealChrome() })
        } else {
            revealChrome()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        if dismissingForPiP {
            // PiP is taking over: keep the player alive and avoid running `.zoom` / `finishDismissal` handback.
            return
        }
        view.isUserInteractionEnabled = false
        if preferredTransition != nil {
            quickenZoom(in: view.window, isDismiss: true)
        }
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in
                self.hideChrome()
            }, completion: { [weak self] context in
                if !context.isCancelled {
                    self?.finishDismissal()
                } else {
                    self?.view.isUserInteractionEnabled = true
                    self?.revealChrome()
                }
            })
        } else {
            finishDismissal()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if dismissingForPiP {
            // Let the underlying feed/grid resume interaction while the floating PiP window plays,
            // without handing back `lentPlayer` or dropping `onDismissed` for final cleanup later.
            onDismissed?()
            return
        }
        if isBeingDismissed || presentingViewController == nil {
            finishDismissal()
        }
    }

    private func finishDismissal() {
        if Self.inPiP === self { Self.inPiP = nil }
        if let p = lentPlayer {
            lentPlayer = nil
            lentPage?.handBack()
            giveBack?(p)
        }
        let done = onDismissed
        onDismissed = nil
        done?()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var prefersStatusBarHidden: Bool { true }
    private var currentPlayer: PlayerViewController? { pages.viewControllers?.first as? PlayerViewController }
    override var prefersHomeIndicatorAutoHidden: Bool { currentPlayer != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = gridTransition != nil ? .clear : PlayerViewController.viewerBackdrop
        backdropView.backgroundColor = PlayerViewController.viewerBackdrop
        backdropView.frame = view.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdropView)
        // the caption's shade reaches past the edges; while the viewer zooms open it must not
        // spill over what is behind it
        view.clipsToBounds = true
        view.accessibilityIdentifier = "photoViewer"
        pages.dataSource = items.count > 1 ? self : nil
        pages.delegate = self
        addChild(pages)
        pages.view.frame = view.bounds
        pages.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pages.view)
        pages.didMove(toParent: self)
        pages.setViewControllers([page(index)], direction: .forward, animated: false)

        // Portrait solid black bottom dock
        photoDock.backgroundColor = .black
        photoDock.overrideUserInterfaceStyle = .dark
        photoDock.alpha = 0
        photoDock.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(photoDock)

        counter.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        counter.textColor = .white
        counter.accessibilityIdentifier = "photoCounter"
        func styleDock(_ b: UIButton, _ sym: String, _ label: String, _ id: String, _ action: Selector) {
            b.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.accessibilityLabel = label
            b.accessibilityIdentifier = id
            b.addTarget(self, action: action, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        styleDock(favoriteButton, "star", L("common.favorite"), "photoFavorite", #selector(toggleFavorite))
        styleDock(shareButton, "square.and.arrow.up", L("viewer.share"), "photoShare", #selector(share))
        styleDock(closeButton, "xmark", L("viewer.close"), "photoClose", #selector(close))
        [counter, UIView(), favoriteButton, shareButton, closeButton].forEach { bar.addArrangedSubview($0) }
        bar.spacing = 8
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        photoDock.addSubview(bar)

        // Landscape Liquid Glass pill holding Favorite + Share + Close
        func styleGlass(_ b: UIButton, _ sym: String, _ label: String, _ id: String, _ action: Selector) {
            b.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
            b.tintColor = .label
            b.accessibilityLabel = label
            b.accessibilityIdentifier = id
            b.addTarget(self, action: action, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 38).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        styleGlass(glassFavoriteButton, "star", L("common.favorite"), "photoGlassFavorite", #selector(toggleFavorite))
        styleGlass(glassShareButton, "square.and.arrow.up", L("viewer.share"), "photoGlassShare", #selector(share))
        styleGlass(glassCloseButton, "xmark", L("viewer.close"), "photoGlassClose", #selector(close))
        let glassRow = UIStackView(arrangedSubviews: [glassFavoriteButton, glassShareButton, glassCloseButton])
        glassRow.spacing = 4
        glassRow.alignment = .center
        glassRow.translatesAutoresizingMaskIntoConstraints = false
        photoGlassPill.contentView.addSubview(glassRow)
        photoGlassPill.alpha = 0
        photoGlassPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(photoGlassPill)

        topCounter.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        topCounter.textColor = .label
        topCounter.alpha = 0
        topCounter.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topCounter)

        NSLayoutConstraint.activate([
            photoDock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            photoDock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            photoDock.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bar.topAnchor.constraint(equalTo: photoDock.topAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            glassRow.leadingAnchor.constraint(equalTo: photoGlassPill.contentView.leadingAnchor, constant: 8),
            glassRow.trailingAnchor.constraint(equalTo: photoGlassPill.contentView.trailingAnchor, constant: -8),
            glassRow.topAnchor.constraint(equalTo: photoGlassPill.contentView.topAnchor, constant: 4),
            glassRow.bottomAnchor.constraint(equalTo: photoGlassPill.contentView.bottomAnchor, constant: -4),
            photoGlassPill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            photoGlassPill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            topCounter.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            topCounter.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
        ])
        // the caption's host fills the screen above the bar (the caption sits at its bottom and
        // may grow when opened); only the caption itself takes touches
        caption.view.backgroundColor = .clear
        addChild(caption)
        captionHost.addSubview(caption.view)
        view.insertSubview(captionHost, belowSubview: photoDock)
        caption.didMove(toParent: self)
        caption.view.frame = captionHost.bounds
        caption.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captionHost.translatesAutoresizingMaskIntoConstraints = false
        captionPhotoConstraints = [
            captionHost.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            captionHost.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            captionHost.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ]
        captionAboveBar = captionHost.bottomAnchor.constraint(equalTo: photoDock.topAnchor, constant: -2)
        captionAboveLandscape = captionHost.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4)
        NSLayoutConstraint.activate(captionPhotoConstraints + [captionAboveBar])
        updateCounter()
        if gridTransition != nil {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
            dismissPan = pan
        } else {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(close))
            swipe.direction = .down
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
            dismissSwipe = swipe
        }
        pageChanged()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let landscape = isLandscapePhoto
        if lastLandscapePhoto != landscape {
            lastLandscapePhoto = landscape
            pageChanged()
        }
    }

    /// A photo is a zoomable page; a video is the player itself, so turning to it plays it.
    private func page(_ i: Int) -> UIViewController {
        guard items[i].kind == .video else {
            let p = ZoomPage(item: items[i], index: i)
            p.onClose = { [weak self] in self?.close() }
            p.onShown = { [weak self] in self?.shown(i) }
            return p
        }
        if i == lentIndex, let lentPage { return lentPage }
        let item = items[i]
        let start = videoPositions[i] ?? videoPosition?(item) ?? .zero
        let lent = i == lentIndex ? lentPlayer : nil
        let p = PlayerViewController(url: item.fileURL, startAt: start, player: lent)
        p.isFavorited = item.isFavorite
        if lent != nil { lentPage = p }
        p.embedding = .init(index: i, hasPrevious: i > 0, hasNext: i < items.count - 1,
                            step: { [weak self] d in self?.step(d) }, close: { [weak self] in self?.close() },
                            shown: { [weak self] in self?.shown(i) },
                            canShowControls: { [weak self] in self?.hasAppeared ?? true },
                            controlsVisible: { [weak self, weak p] on in
                                guard let self, let p, self.currentPlayer === p else { return }
                                // When hosted inside `p.captionContainer`, `p.controls.alpha` already fades the caption.
                                if self.captionHost.superview !== p.captionContainer {
                                    UIView.animate(withDuration: 0.2) { self.captionHost.alpha = on ? 1 : 0 }
                                }
                            },
                            layoutModeChanged: { [weak self, weak p] in
                                guard let self, let p, self.currentPlayer === p else { return }
                                self.updateCaption()
                            },
                            turned: { [weak self, weak p] _ in
                                guard let self, let p, self.currentPlayer === p else { return }
                                self.pageChanged()
                            },
                            paused: { [weak self] time in
                                guard let self else { return }
                                self.videoPositions[i] = time
                                if lent == nil { self.saveVideoPosition?(item, time) }
                            },
                            keepsPlayingOnDismiss: { [weak self] in
                                lent != nil && self?.isBeingDismissed == true
                            },
                            toggleFavorite: { [weak self] in self?.toggleFavorite() },
                            pipWillStart: { [weak self, weak p] in
                                guard let self else { return }
                                Self.inPiP = self
                                guard self.presentingViewController != nil else { return }
                                self.dismissingForPiP = true
                                // Clear `preferredTransition` without retaining the old Transition object
                                // so UIKit releases its internal zoom source-view hiding state immediately.
                                self.preferredTransition = nil
                                self.gridTransition?.setHiddenMediaId(nil)
                                p?.parkLayerInWindowForPiP()
                                self.onEnteringPiP?()
                                self.dismiss(animated: false)
                            },
                            pipDidStart: { [weak self] in
                                guard let self else { return }
                                Self.inPiP = self
                                if self.presentingViewController != nil {
                                    self.dismissingForPiP = true
                                    self.preferredTransition = nil
                                    self.gridTransition?.setHiddenMediaId(nil)
                                    self.onEnteringPiP?()
                                    self.dismiss(animated: false)
                                }
                            },
                            pipRestore: { [weak self] done in
                                guard let self else { done(true); return }
                                guard self.presentingViewController == nil, let host = PlayerViewController.topViewController() else {
                                    self.view.isUserInteractionEnabled = true
                                    self.revealChrome()
                                    self.currentPlayer?.showPageControls()
                                    done(true)
                                    return
                                }
                                self.dismissingForPiP = false
                                if let gt = self.gridTransition {
                                    self.modalPresentationStyle = .overFullScreen
                                    self.modalPresentationCapturesStatusBarAppearance = true
                                    self.transitioningDelegate = gt
                                } else {
                                    self.modalPresentationStyle = .fullScreen
                                }
                                host.present(self, animated: true) { [weak self] in
                                    self?.view.isUserInteractionEnabled = true
                                    self?.revealChrome()
                                    self?.currentPlayer?.showPageControls()
                                    done(true)
                                }
                            },
                            pipDidStop: { [weak self] in
                                guard let self else { return }
                                let retained = Self.inPiP === self
                                if retained { Self.inPiP = nil }
                                self.dismissingForPiP = false
                                if self.presentingViewController == nil {
                                    self.currentPlayer?.pauseIfHidden()
                                    self.finishDismissal()
                                }
                            })
        return p
    }

    /// A page appeared (a swipe, an arrow, or a swipe given up halfway): it is the current one.
    /// (The page view controller does not always report the end of a transition.)
    private func shown(_ i: Int) {
        guard pages.viewControllers?.first.map({ ($0 as? ViewerPage)?.viewerIndex == i }) == true else { return }
        index = i
        updateCounter()
        pageChanged()
    }

    /// The page on screen changed: the viewer's own bar is for photos (a video has its own
    /// controls), and while a video with the seek / volume / brightness drags is on screen, a
    /// sideways swipe belongs to it (its arrows turn the page instead).
    /// A video turned on its own fills the screen alone: no caption, no paging (a swipe would
    /// cross the turned picture) until it is turned back or left with its arrows.
    private func pageChanged() {
        let video = currentPlayer
        let turned = (video?.quarterTurns ?? 0) != 0
        let landscape = isLandscapePhoto
        photoDock.isHidden = video != nil || landscape
        photoGlassPill.isHidden = video != nil || !landscape
        topCounter.isHidden = video != nil || !landscape || (topCounter.text ?? "").isEmpty
        updateFavoriteButtons()
        updateCaption()
        let scroll = pages.view.subviews.compactMap { $0 as? UIScrollView }.first
        scroll?.isScrollEnabled = items.count > 1 && (video?.dragGestures != true) && !turned
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    /// The arrows of a video page.
    private func step(_ d: Int) {
        let i = index + d
        guard items.indices.contains(i) else { return }
        pages.setViewControllers([page(i)], direction: d > 0 ? .forward : .reverse, animated: true) { [weak self] _ in
            self?.index = i
            self?.updateCounter()
            self?.pageChanged()
        }
    }

    /// Mounts `captionHost` inside the current video's rotating `captionContainer` (so tapping the
    /// rotate button rotates the caption smoothly with the video and keeps it pinned directly above
    /// the dock or compact-landscape bar), or back in `view` for photos.
    /// Reparents the `UIHostingController` (`caption`) to match the owning view controller (`video`
    /// vs `self`) so UIKit never raises `UIViewControllerHierarchyInconsistency` when paging live.
    private func mountCaption(in video: PlayerViewController?) {
        if let video {
            video.loadViewIfNeeded()
            if captionHost.superview !== video.captionContainer || caption.parent !== video {
                NSLayoutConstraint.deactivate(captionPhotoConstraints + [captionAboveBar, captionAboveLandscape] + captionVideoConstraints)
                if caption.parent !== video {
                    if caption.parent != nil { caption.willMove(toParent: nil) }
                    captionHost.removeFromSuperview()
                    if caption.parent != nil { caption.removeFromParent() }
                    video.addChild(caption)
                    video.captionContainer.addSubview(captionHost)
                    caption.didMove(toParent: video)
                } else {
                    captionHost.removeFromSuperview()
                    video.captionContainer.addSubview(captionHost)
                }
                captionVideoConstraints = [
                    captionHost.topAnchor.constraint(equalTo: video.captionContainer.topAnchor),
                    captionHost.bottomAnchor.constraint(equalTo: video.captionContainer.bottomAnchor),
                    captionHost.leadingAnchor.constraint(equalTo: video.captionContainer.leadingAnchor),
                    captionHost.trailingAnchor.constraint(equalTo: video.captionContainer.trailingAnchor),
                ]
                NSLayoutConstraint.activate(captionVideoConstraints)
            }
        } else {
            let landscape = isLandscapePhoto
            if captionHost.superview !== view || caption.parent !== self {
                NSLayoutConstraint.deactivate(captionVideoConstraints)
                captionVideoConstraints = []
                if caption.parent !== self {
                    if caption.parent != nil { caption.willMove(toParent: nil) }
                    captionHost.removeFromSuperview()
                    if caption.parent != nil { caption.removeFromParent() }
                    addChild(caption)
                    view.insertSubview(captionHost, belowSubview: photoDock)
                    caption.didMove(toParent: self)
                } else {
                    captionHost.removeFromSuperview()
                    view.insertSubview(captionHost, belowSubview: photoDock)
                }
                NSLayoutConstraint.activate(captionPhotoConstraints)
            }
            captionAboveBar.isActive = !landscape
            captionAboveLandscape.isActive = landscape
        }
    }

    /// The caption for the media on screen: above the bar for a photo, or inside a video's rotating controls.
    private func updateCaption() {
        guard captionAboveBar != nil, captionAboveLandscape != nil else { return }
        let it = items[index]
        let video = currentPlayer
        let landscape = isLandscapePhoto
        mountCaption(in: video)
        let shows = PostCaptionView.shows(it)
        let compactLandscapeVideo = video?.isCompactLandscape == true
        let trailing: CGFloat = compactLandscapeVideo
            ? (video?.landscapeTrailingInset ?? 220)
            : ((video == nil && landscape) ? 160 : 16)
        let containerHeight = video != nil ? max(160, video!.stageHeight) : view.bounds.height
        captionHost.overrideUserInterfaceStyle = compactLandscapeVideo ? .dark : .unspecified
        caption.rootView = PostCaptionView(item: it, maxExpandedHeight: containerHeight * 0.45, trailingInset: trailing,
                                           onHeight: { [weak self] h in self?.captionHost.activeHeight = h })
        // Inside `video.captionContainer`, `video.controls.alpha` already drives visibility.
        captionHost.alpha = video != nil ? 1 : (hasAppeared ? 1 : 0)
        captionHost.isHidden = !shows
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in self.pageChanged() }
    }

    /// Dragging down closes a photo; a video handles it itself (or not at all, when its vertical
    /// drags set volume and brightness).
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === dismissPan {
            guard currentPlayer == nil,
                  (pages.viewControllers?.first as? ZoomPage)?.isZoomed != true,
                  let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: view)
            return v.y > 0 && v.y > abs(v.x)
        }
        return !(g is UISwipeGestureRecognizer && currentPlayer != nil)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard g === dismissPan else { return false }
        let pageScroll = pages.view.subviews.compactMap { $0 as? UIScrollView }.first
        return other === pageScroll?.panGestureRecognizer
    }

    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        guard let gt = gridTransition else { return }
        let t = g.translation(in: view)
        let v = g.velocity(in: view)
        switch g.state {
        case .began:
            panBaseMediaFrame = mediaFrame ?? view.bounds
            UIView.animate(withDuration: 0.12) { self.hideChrome() }
            let info = gt.sourceProvider(items[index], view, true)
            gt.setHiddenMediaId(info?.mediaId)
        case .changed:
            let progress = min(max(t.y / 320, 0), 1)
            let scale = max(0.42, 1 - progress * 0.48)
            pages.view.transform = CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: scale, y: scale)
            backdropView.alpha = max(0, 1 - progress * 1.15)
        case .ended, .cancelled, .failed:
            let shouldDismiss = (g.state == .ended) && (t.y > 90 || v.y > 500)
            if shouldDismiss {
                let c = pages.view.center
                let tf = pages.view.transform
                let translated = panBaseMediaFrame.offsetBy(dx: -c.x, dy: -c.y).applying(tf).offsetBy(dx: c.x, dy: c.y)
                gt.interactiveDismissStartFrame = translated
                gt.interactiveDismissBackdropAlpha = backdropView.alpha
                gt.interactiveDismissVelocity = v
                dismiss(animated: true) { [weak self] in
                    self?.finishDismissal()
                }
            } else {
                UIView.animate(withDuration: 0.26, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    self.pages.view.transform = .identity
                    self.backdropView.alpha = 1
                    self.revealChrome()
                } completion: { _ in
                    gt.setHiddenMediaId(nil)
                }
            }
        default:
            break
        }
    }

    private func updateCounter() {
        // the position within the current post, as the list shows it
        let post = items[index].postId
        var lo = index, hi = index
        while lo > 0, items[lo - 1].postId == post, !post.isEmpty { lo -= 1 }
        while hi < items.count - 1, items[hi + 1].postId == post, !post.isEmpty { hi += 1 }
        counter.text = hi > lo ? "\(index - lo + 1) / \(hi - lo + 1)" : nil
        counter.accessibilityValue = counter.text
        topCounter.text = counter.text
        topCounter.isHidden = currentPlayer != nil || !isLandscapePhoto || (topCounter.text ?? "").isEmpty
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let p = vc as? ViewerPage, p.viewerIndex > 0 else { return nil }
        return page(p.viewerIndex - 1)
    }
    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let p = vc as? ViewerPage, p.viewerIndex < items.count - 1 else { return nil }
        return page(p.viewerIndex + 1)
    }
    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let p = pvc.viewControllers?.first as? ViewerPage else { return }
        index = p.viewerIndex
        updateCounter()
        pageChanged()
    }

    private func updateFavoriteButtons() {
        let fav = items[index].isFavorite
        let sym = fav ? "star.fill" : "star"
        let label = fav ? L("common.unfavorite") : L("common.favorite")
        favoriteButton.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        favoriteButton.tintColor = fav ? PlayerViewController.starGold : .white
        favoriteButton.accessibilityLabel = label
        glassFavoriteButton.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        glassFavoriteButton.tintColor = fav ? PlayerViewController.starGold : .label
        glassFavoriteButton.accessibilityLabel = label
        currentPlayer?.isFavorited = fav
    }

    @objc private func toggleFavorite() {
        let next = !items[index].isFavorite
        guard (try? Core.action(next ? .favorite : .unfavorite, media: [items[index].mediaId])) != nil else { return }
        items[index].favorite = next
        didMutate = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateFavoriteButtons()
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }

    /// Share the current file (other apps, Files, AirDrop, Copy, Save Image).
    @objc private func share() {
        let vc = UIActivityViewController(activityItems: [items[index].fileURL], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = isLandscapePhoto ? glassShareButton : shareButton
        present(vc, animated: true)
    }
    /// (A turned video turned only itself: nothing to turn back.)
    @objc private func close() {
        dismiss(animated: true) { [weak self] in
            self?.finishDismissal()
        }
    }
}

/// Bottom vertical dark scrim for compact-landscape video overlay legibility.
private final class LandscapeGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        guard let g = layer as? CAGradientLayer else { return }
        g.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.72).cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Passes touches through unless they hit an interactive descendant (such as `PassThroughView`).
final class CaptionContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Takes touches only in its bottom `activeHeight` points (the caption); above, they reach what
/// is underneath.
final class PassThroughView: UIView {
    var activeHeight: CGFloat = 0
    override func point(inside p: CGPoint, with e: UIEvent?) -> Bool { p.y >= bounds.height - activeHeight && super.point(inside: p, with: e) }
}

/// A page of the full-screen viewer: its position in the list.
protocol ViewerPage: UIViewController { var viewerIndex: Int { get } }

/// One zoomable photo of the viewer.
final class ZoomPage: UIViewController, UIScrollViewDelegate, ViewerPage {
    let item: FeedItem
    let index: Int
    var viewerIndex: Int { index }
    var onClose: (() -> Void)?
    /// It became the page on screen.
    var onShown: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onShown?()
        loadPhoto(pixels: 2048)
    }
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    var currentImage: UIImage? { imageView.image }
    var isZoomed: Bool { scroll.zoomScale > 1.001 }
    func showTransitionPoster(_ image: UIImage) {
        loadViewIfNeeded()
        if imageView.image == nil { imageView.image = image }
    }
    func mediaFrame(in view: UIView, size: CGSize) -> CGRect {
        let frame = imageView.convert(AVMakeRect(aspectRatio: imageView.image?.size ?? size, insideRect: imageView.bounds), to: view)
        return frame.intersection(scroll.convert(scroll.bounds, to: view))
    }
    var onMediaGeometryChanged: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onMediaGeometryChanged?()
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { onMediaGeometryChanged?() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { onMediaGeometryChanged?() }

    init(item: FeedItem, index: Int) { self.item = item; self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.maximumZoomScale = item.kind == .video ? 1 : 5
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        view.addSubview(scroll)
        loadPhoto(pixels: 2048)
        let dbl = UITapGestureRecognizer(target: self, action: #selector(zoom(_:)))
        dbl.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapClose))
        single.require(toFail: dbl)
        view.addGestureRecognizer(dbl)
        view.addGestureRecognizer(single)
    }

    private var imageToken: MediaLoader.Token?
    private var loadedPixels: CGFloat = 0
    private func loadPhoto(pixels: CGFloat) {
        guard pixels > loadedPixels else { return }
        loadedPixels = pixels
        MediaLoader.shared.cancel(imageToken)
        imageToken = MediaLoader.shared.load(item, maxPixel: pixels) { [weak self] img in
            guard let self else { return }
            if let img { self.imageView.image = img }
            else { self.loadedPixels = 0 }
            self.onMediaGeometryChanged?()
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        MediaLoader.shared.cancel(imageToken); imageToken = nil
        loadedPixels = 0
        imageView.image = nil
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale > 1.2, item.kind == .photo { loadPhoto(pixels: 4096) }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    @objc private func zoom(_ g: UITapGestureRecognizer) {
        guard item.kind == .photo else { return }
        if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true); return }
        let p = g.location(in: imageView)
        scroll.zoom(to: CGRect(x: p.x - 80, y: p.y - 80, width: 160, height: 160), animated: true)
    }
    @objc private func tapClose() { onClose?() }
}

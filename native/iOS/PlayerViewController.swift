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
        /// The controls came or went (the viewer's caption follows them).
        var controlsVisible: (Bool) -> Void = { _ in }
    }
    var embedding: Embedding?
    var viewerIndex: Int { embedding?.index ?? 0 }
    /// Read once: whether this player has the seek / volume / brightness drags (see `LibraryPrefs.playerGesturesOff`).
    let dragGestures = !LibraryPrefs.playerGesturesOff
    /// Keeps a player alive while it plays in picture-in-picture after its screen was closed.
    private static var inPiP: PlayerViewController?
    private let player: AVPlayer
    private let startAt: CMTime
    private let playerLayer = AVPlayerLayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playbackVisible = false

    private let controls = UIView()
    private let closeButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    /// Portrait: buttons above, progress bar below (full width). Landscape: one row.
    private let barStack = UIStackView()
    private let buttonRow = UIStackView()
    private let barSpacer = UIView()
    /// Orientation chosen with the rotate button / auto-landscape (nil = follow the device).
    /// Inside the viewer, the viewer asks for it (only what is presented decides the orientation).
    private(set) var forcedMask: UIInterfaceOrientationMask?
    private weak var openedScene: UIWindowScene?
    private let url: URL
    private let lockButton = UIButton(type: .system)
    private let lockSlot = UIView()
    private var locked = false
    private var lockHideWork: DispatchWorkItem?
    private var pip: AVPictureInPictureController?
    private var volumeObservation: NSKeyValueObservation?
    private let playButton = UIButton(type: .system)
    private let slider = UISlider()
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

    init(url: URL, startAt: CMTime = .zero) {
        self.url = url
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]))
        item.preferredForwardBufferDuration = 2
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.startAt = startAt
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { forcedMask ?? .all }
    /// While locked, system edge swipes need a second swipe (no accidental exits).
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { locked ? .all : [] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "player"
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
        view.addSubview(volumeView)
        buildControls()
        buildGestures()

        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        NSLayoutConstraint.activate([hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40)])

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            self?.syncProgress()
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero)
            if self.playbackVisible || self.pip?.isPictureInPictureActive == true {
                self.player.play()
            }
        }
        if startAt > .zero { player.seek(to: startAt, toleranceBefore: .zero, toleranceAfter: .zero) }
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

    private var isLandscape: Bool { view.bounds.width > view.bounds.height }
    /// The screen's orientation when the player (or its viewer) opened: leaving goes back to it,
    /// whatever was turned inside (a turn in the viewer is the viewer's only).
    private var openedLandscape: Bool?

    /// Turns the screen between portrait and landscape (the video's own button, bottom right).
    @objc private func rotate() {
        guard !locked else { return }
        setOrientation(isLandscape ? .portrait : .landscapeRight)
        rotateButton.accessibilityValue = isLandscape ? L("viewer.portrait") : L("viewer.landscape")
    }

    /// What decides the orientation: this player, or the viewer it is a page of.
    private var orientationOwner: UIViewController {
        var v: UIViewController = self
        while let p = v.parent { v = p }
        return v
    }

    private func setOrientation(_ mask: UIInterfaceOrientationMask) {
        forcedMask = mask
        ViewerOrientation.turned = true
        orientationOwner.setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    /// "自动横屏播放横屏视频": a video wider than tall opens in landscape.
    private func autoLandscapeIfWanted() {
        guard LibraryPrefs.autoLandscape, UIDevice.current.userInterfaceIdiom == .phone, !isLandscape else { return }
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, t) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            let s = size.applying(t)
            if abs(s.width) > abs(s.height) { await MainActor.run { self?.setOrientation(.landscapeRight) } }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if openedLandscape == nil { openedLandscape = isLandscape; openedScene = view.window?.windowScene }
        playbackVisible = true
        if let e = embedding {
            resumePlayback()
            updatePlayButton()
            setControls(visible: true)
            e.shown()
        }
        autoLandscapeIfWanted()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playbackVisible = false
        // turned away from in the viewer: it stops (it plays on if it comes back)
        if embedding != nil, pip?.isPictureInPictureActive != true { player.pause() }
    }

    /// Closing after we turned the screen to landscape: turn back to portrait first, then close.
    /// (Asking only while the player goes away was too late: the feed also allows landscape, so
    /// it simply stayed in landscape.) Every way out comes through here: the close button and
    /// picture in picture.
    override func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        // closing something the player shows (an alert, a menu) also comes here: leave those alone
        guard presentedViewController == nil else { return super.dismiss(animated: animated, completion: completion) }
        restorePortrait { [weak self] in self?.superDismiss(animated: animated, completion: completion) }
    }

    /// Turns the screen back to how it was when the player opened (portrait or landscape) if
    /// this player turned it, then `done` (closing the player, or the viewer it is a page of).
    func restorePortrait(then done: @escaping () -> Void) {
        guard forcedMask != nil, let opened = openedLandscape, opened != isLandscape, let scene = view.window?.windowScene else {
            forcedMask = nil
            return done()
        }
        let back: UIInterfaceOrientationMask = opened ? .landscapeRight : .portrait
        forcedMask = back
        orientationOwner.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: back)) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.forcedMask = nil
            done()
        }
    }
    private func superDismiss(animated: Bool, completion: (() -> Void)?) { super.dismiss(animated: animated, completion: completion) }

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

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        Self.inPiP = self
        // Leave the fullscreen player; the video keeps playing in its floating window.
        if presentingViewController != nil { dismiss(animated: true) }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        guard presentingViewController == nil, let host = Self.topViewController() else { done(true); return }
        modalPresentationStyle = .fullScreen
        host.present(self, animated: true) { done(true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        if !playbackVisible { player.pause() }
        Self.inPiP = nil
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Self.inPiP = nil
        hud.show(symbol: "pip", text: L("viewer.pipFailed"))
    }

    private static func topViewController() -> UIViewController? {
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
        locked.toggle()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        updateLockButton()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        if locked {
            hideTimer?.invalidate()
            view.layoutIfNeeded()
            NSLayoutConstraint.deactivate(lockAtSlot)
            NSLayoutConstraint.activate(lockAtCenter)
            UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.controls.alpha = 0 }
            UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3) { self.view.layoutIfNeeded() }
            hud.show(symbol: "lock.fill", text: L("viewer.locked"))
            flashLockButton()
        } else {
            NSLayoutConstraint.deactivate(lockAtCenter)
            NSLayoutConstraint.activate(lockAtSlot)
            UIView.performWithoutAnimation { view.layoutIfNeeded() }
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
        if !mute { soundPrompt?.removeFromSuperview(); return }
        guard soundPrompt == nil else { return }
        let url = url
        Task { [weak self] in
            guard await AudioPolicy.hasAudio(url) else { return }
            await MainActor.run { self?.showSoundPrompt() }
        }
    }

    /// "没有连接耳机，已静音 · 开启声音": the user may hear this video through the speaker.
    private func showSoundPrompt() {
        guard soundPrompt == nil, player.isMuted else { return }
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
        view.addSubview(box)
        NSLayoutConstraint.activate([box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     box.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)])
        soundPrompt = box
        box.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { box.alpha = 1 }
        // it steps aside after a while; the video stays muted
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak box] in
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: { box?.alpha = 0 }) { _ in box?.removeFromSuperview() }
        }
    }

    /// A pill under the top edge that fades out after a few seconds.
    private func showBanner(_ text: String) {
        let label = PaddedLabel()
        label.insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        label.layer.cornerRadius = 16
        label.clipsToBounds = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.accessibilityIdentifier = "audioBanner"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
                                     label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)])
        label.alpha = 0
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { label.alpha = 1 }
        UIView.animate(withDuration: 0.4, delay: 4, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = view.bounds
        CATransaction.commit()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if embedding == nil, isBeingDismissed { ViewerOrientation.settle(scene: openedScene, landscape: openedLandscape ?? false) }
        // A pager may reuse this controller. Keep its observers until deallocation.
        if pip?.isPictureInPictureActive == true || Self.inPiP === self { return }
        player.pause()
    }

    deinit {
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
        player.playImmediately(atRate: 1)
    }

    // MARK: Controls

    private func buildControls() {
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        let top = GradientView(colors: [UIColor.black.withAlphaComponent(0.6), .clear])
        let bottom = bottomShade
        [top, bottom].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.isUserInteractionEnabled = false; controls.addSubview($0) }

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.accessibilityLabel = L("viewer.close")
        closeButton.accessibilityIdentifier = "playerClose"

        pipButton.setImage(UIImage(systemName: "pip.enter", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        pipButton.tintColor = .white
        pipButton.addTarget(self, action: #selector(togglePiP), for: .touchUpInside)
        pipButton.accessibilityLabel = L("viewer.pip")
        pipButton.accessibilityIdentifier = "playerPiP"

        rotateButton.setImage(UIImage(systemName: "rotate.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
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

        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(Self.thumb(12), for: .normal)
        slider.setThumbImage(Self.thumb(18), for: .highlighted)
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.accessibilityIdentifier = "time"
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        shareButton.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        shareButton.tintColor = .white
        shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)
        shareButton.accessibilityLabel = L("viewer.share")
        shareButton.accessibilityIdentifier = "playerShare"
        // Buttons: play · time … share · lock · close · picture in picture · rotate. The lock
        // button sits in its slot but lives outside `controls`, so it stays usable while
        // everything else is hidden. Portrait puts the progress bar on its own row below.
        [playButton, timeLabel, barSpacer, shareButton, lockSlot, closeButton, pipButton, rotateButton].forEach { buttonRow.addArrangedSubview($0) }
        buttonRow.spacing = 12
        buttonRow.alignment = .center
        barSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        barStack.addArrangedSubview(slider)
        barStack.addArrangedSubview(buttonRow)
        barStack.spacing = 6
        let bar = barStack
        [bar].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; controls.addSubview($0) }
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lockButton)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.topAnchor), controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor), controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.topAnchor.constraint(equalTo: controls.topAnchor), top.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: controls.trailingAnchor), top.heightAnchor.constraint(equalToConstant: 140),
            bottom.bottomAnchor.constraint(equalTo: controls.bottomAnchor), bottom.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: controls.trailingAnchor), bottomShadeHeight,
            closeButton.widthAnchor.constraint(equalToConstant: 36), closeButton.heightAnchor.constraint(equalToConstant: 44),
            pipButton.widthAnchor.constraint(equalToConstant: 36), pipButton.heightAnchor.constraint(equalToConstant: 44),
            rotateButton.widthAnchor.constraint(equalToConstant: 36), rotateButton.heightAnchor.constraint(equalToConstant: 44),
            lockSlot.widthAnchor.constraint(equalToConstant: 36), lockSlot.heightAnchor.constraint(equalToConstant: 44),
            lockButton.widthAnchor.constraint(equalToConstant: 40), lockButton.heightAnchor.constraint(equalToConstant: 40),
            bar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            shareButton.widthAnchor.constraint(equalToConstant: 36), shareButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        lockAtSlot = [lockButton.centerXAnchor.constraint(equalTo: lockSlot.centerXAnchor), lockButton.centerYAnchor.constraint(equalTo: lockSlot.centerYAnchor)]
        lockAtCenter = [lockButton.centerXAnchor.constraint(equalTo: view.centerXAnchor), lockButton.centerYAnchor.constraint(equalTo: lockSlot.centerYAnchor)]
        NSLayoutConstraint.activate(lockAtSlot)
        // in the viewer, with the drags on (a sideways swipe seeks): arrows to the neighbours
        if let e = embedding, dragGestures {
            for (on, symbol, label, id, action, left) in [(e.hasPrevious, "chevron.left", L("viewer.previous"), "playerPrevious", #selector(stepPrevious), true),
                                                          (e.hasNext, "chevron.right", L("viewer.next"), "playerNext", #selector(stepNext), false)] where on {
                let b = UIButton(type: .system)
                b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)), for: .normal)
                b.tintColor = .white
                b.backgroundColor = UIColor.black.withAlphaComponent(0.35)
                b.layer.cornerRadius = 22
                b.accessibilityLabel = label
                b.accessibilityIdentifier = id
                b.addTarget(self, action: action, for: .touchUpInside)
                b.translatesAutoresizingMaskIntoConstraints = false
                controls.addSubview(b)
                NSLayoutConstraint.activate([
                    b.widthAnchor.constraint(equalToConstant: 44), b.heightAnchor.constraint(equalToConstant: 44),
                    b.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    left ? b.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12) : b.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
                ])
            }
        }
        layoutBar()
        updatePlayButton()
    }

    /// Portrait: buttons on top, the progress bar below on its own row, so it stays usable on a
    /// narrow screen. Landscape: progress bar, then the buttons, on one row.
    private let sliderRow = UIStackView()

    private func layoutBar() {
        let landscape = isLandscape
        barStack.axis = landscape ? .horizontal : .vertical
        barStack.alignment = landscape ? .center : .fill
        barStack.spacing = landscape ? 16 : 4
        barSpacer.isHidden = landscape
        // progress bar below the buttons in portrait, before them in landscape
        // portrait: the time sits on the progress bar's row (beside the buttons it was squeezed)
        [slider, buttonRow, sliderRow].forEach { barStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        timeLabel.removeFromSuperview()
        if landscape {
            buttonRow.insertArrangedSubview(timeLabel, at: 1)
            barStack.addArrangedSubview(slider); barStack.addArrangedSubview(buttonRow)
        } else {
            sliderRow.axis = .horizontal
            sliderRow.spacing = 10
            sliderRow.alignment = .center
            sliderRow.addArrangedSubview(slider)
            sliderRow.addArrangedSubview(timeLabel)
            barStack.addArrangedSubview(buttonRow); barStack.addArrangedSubview(sliderRow)
        }
        // taking the rows out of the window dropped the lock's constraints to its slot (it then
        // floated off to a corner): put them back
        NSLayoutConstraint.activate(locked ? lockAtCenter : lockAtSlot)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.layoutBar(); self.view.layoutIfNeeded() })
    }

    /// Share the video file (to other apps, Files, AirDrop…).
    @objc private func share() {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = shareButton
        present(vc, animated: true)
    }

    private static func thumb(_ d: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { _ in
            UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: d, height: d)).fill()
        }
    }

    private func syncProgress() {
        let t = player.currentTime().seconds
        if !isScrubbing, duration > 0 { slider.value = Float(t / duration) }
        timeLabel.text = "\(Self.fmt(isScrubbing ? Double(slider.value) * duration : t)) / \(Self.fmt(duration))"
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

    private func setControls(visible: Bool) {
        hideTimer?.invalidate()
        guard !locked else { return }
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.controls.alpha = visible ? 1 : 0; self.lockButton.alpha = visible ? 1 : 0 }
        embedding?.controlsVisible(visible)
        if visible { scheduleHide() }
    }

    private let bottomShade = GradientView(colors: [.clear, UIColor.black.withAlphaComponent(0.7)])
    private lazy var bottomShadeHeight = bottomShade.heightAnchor.constraint(equalToConstant: 160)

    /// The viewer's caption (`height` points, 0 for none) sits above the controls: the controls'
    /// shade grows to take it in, one shade from the caption down to the bottom edge, coming and
    /// going with the controls (the caption draws none of its own over a video).
    func shadeCaption(height: CGFloat) {
        guard isViewLoaded else { return }
        let g = bottomShade.layer as! CAGradientLayer
        guard height > 0 else {
            bottomShadeHeight.constant = 160
            g.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
            g.locations = nil
            return
        }
        let total = max(160, controlsClearance + height)
        bottomShadeHeight.constant = total
        // clear over the caption's empty top padding, then as dark as the caption's own shade
        g.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        g.locations = [0, NSNumber(value: Double(min(0.5, 40 / total))), 1]
    }

    /// Whether the controls are showing (the viewer's caption shows with them).
    var controlsShown: Bool { controls.alpha > 0.5 && !locked }
    /// How far up from the bottom the controls reach (the viewer's caption sits above them).
    var controlsClearance: CGFloat {
        guard isViewLoaded else { return 120 }
        view.layoutIfNeeded()
        return view.bounds.height - barStack.convert(barStack.bounds, to: view).minY + 6
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        var delay: TimeInterval = 3
        #if DEBUG
        // UI tests: keep controls up long enough to inspect them on a slow, busy machine
        if ProcessInfo.processInfo.environment["TL_RESET_UI_STATE"] != nil { delay = 30 }
        #endif
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.player.timeControlStatus != .paused, !self.isScrubbing else { return }
            self.setControls(visible: false)
        }
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

    @objc private func scrubBegan() { isScrubbing = true; hideTimer?.invalidate() }
    @objc private func scrubChanged() {
        let t = Double(slider.value) * duration
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        syncProgress()
    }
    @objc private func scrubEnded() { isScrubbing = false; scheduleHide() }

    // MARK: Gestures

    private func buildGestures() {
        let double = UITapGestureRecognizer(target: self, action: #selector(togglePlay))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap))
        single.require(toFail: double)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        long.minimumPressDuration = 0.25
        [double, single, long].forEach { $0.delegate = self; view.addGestureRecognizer($0) }
        if dragGestures {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            // a finger or the Pencil: a trackpad's or a mouse's drag does not seek or set volume / brightness
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
        } else {
            // without the drags, dragging down closes the player (or the viewer it is a page of),
            // as in the photo viewer
            let down = UISwipeGestureRecognizer(target: self, action: #selector(close))
            down.direction = .down
            down.delegate = self
            view.addGestureRecognizer(down)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let v = touch.view, v === lockButton || v.isDescendant(of: lockButton) { return false }
        // Locked: nothing but a single tap, which only reveals the lock button.
        if locked { return g is UITapGestureRecognizer && (g as! UITapGestureRecognizer).numberOfTapsRequired == 1 }
        if g is UISwipeGestureRecognizer { return true }
        // Leave the bottom bar to its own controls.
        guard controls.alpha > 0.01, let v = touch.view else { return true }
        return !(v is UIControl) && !(v.superview is UIControl)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UILongPressGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UILongPressGestureRecognizer)
    }

    @objc private func singleTap() {
        if locked { flashLockButton(); return }
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
        let tr = g.translation(in: view)
        switch g.state {
        case .began:
            let v = g.velocity(in: view)
            if abs(v.x) > abs(v.y) {
                panMode = .seek
                panStartValue = player.currentTime().seconds
                isScrubbing = true
            } else if g.location(in: view).x < view.bounds.midX {
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
                let target = min(max(panStartValue + Double(tr.x / view.bounds.width) * span, 0), duration)
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if duration > 0 { slider.value = Float(target / duration) }
                let delta = target - panStartValue
                hud.show(symbol: delta >= 0 ? "goforward" : "gobackward", text: "\(Self.fmt(target)) / \(Self.fmt(duration))", sticky: true)
            case .brightness:
                let v = clamp(panStartValue - Double(tr.y / (view.bounds.height * 0.7)))
                (view.window?.windowScene?.screen ?? UIScreen.main).brightness = CGFloat(v)
                hud.show(symbol: "sun.max.fill", progress: v)
            case .volume:
                let v = clamp(panStartValue - Double(tr.y / (view.bounds.height * 0.7)))
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

/// A video's rotate button asks the scene for one orientation, and the scene keeps to that even after
/// the player has gone: the app stayed turned and no longer followed the device. When the player or
/// the viewer has gone: back to how the screen was, then the device decides again.
enum ViewerOrientation {
    static var turned = false

    static func settle(scene: UIWindowScene?, landscape: Bool) {
        guard turned, let scene else { return }
        turned = false
        func refresh() { scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() } }
        refresh()
        if scene.effectiveGeometry.interfaceOrientation.isLandscape != landscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .all)) { _ in }
            refresh()
        }
    }
}

/// Centered pill that reports gesture feedback (speed, seek target, brightness/volume level).
final class HUDView: UIView {
    private let icon = UIImageView()
    private let label = UILabel()
    private let bar = UIProgressView(progressViewStyle: .bar)
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        alpha = 0
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "hud"
        icon.tintColor = .white
        icon.preferredSymbolConfiguration = .init(pointSize: 15, weight: .semibold)
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        bar.progressTintColor = .white
        bar.trackTintColor = UIColor.white.withAlphaComponent(0.25)
        let stack = UIStackView(arrangedSubviews: [icon, label, bar])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bar.widthAnchor.constraint(equalToConstant: 120),
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

/// Fullscreen photo with pinch/double-tap zoom.
/// Full-screen viewer: swipe left / right through every photo and video of the list it was opened
/// from (on past the end of a post into the next one), pinch or double-tap to zoom, tap or swipe down to close; the share button sends the
/// current file to other apps, Files, AirDrop, or copies it.
final class PhotoViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private let items: [FeedItem]
    private var index: Int
    /// Where the first video starts (it was already playing in the feed).
    private var videoStart: CMTime
    private let bar = UIStackView()
    private let pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
    private let counter = UILabel()
    private let shareButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    /// The post of the media on screen, over the bottom (above the bar, or a video's controls).
    private let caption = UIHostingController(rootView: PostCaptionView(item: nil))
    private let captionHost = PassThroughView()
    private var captionAboveBar: NSLayoutConstraint!
    private var captionAboveVideo: NSLayoutConstraint!

    init(items: [FeedItem], index: Int, videoStart: CMTime = .zero) {
        self.items = items
        self.index = max(0, min(index, items.count - 1))
        self.videoStart = videoStart
        super.init(nibName: nil, bundle: nil)
    }
    convenience init(url: URL) {
        self.init(items: [FeedItem(mediaId: url.lastPathComponent, postId: "", ordinal: 0, kind: .photo, path: url.path, text: nil, authorName: nil, screenName: nil, url: nil, tags: [])], index: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var prefersStatusBarHidden: Bool { true }
    private var currentPlayer: PlayerViewController? { pages.viewControllers?.first as? PlayerViewController }
    override var prefersHomeIndicatorAutoHidden: Bool { currentPlayer != nil }
    /// A video on screen may have turned the screen (its rotate button, auto-landscape).
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { currentPlayer?.forcedMask ?? .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
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

        counter.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        counter.textColor = .white
        counter.accessibilityIdentifier = "photoCounter"
        func style(_ b: UIButton, _ sym: String, _ label: String, _ id: String, _ action: Selector) {
            b.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            b.layer.cornerRadius = 20
            b.accessibilityLabel = label
            b.accessibilityIdentifier = id
            b.addTarget(self, action: action, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        style(shareButton, "square.and.arrow.up", L("viewer.share"), "photoShare", #selector(share))
        style(closeButton, "xmark", L("viewer.close"), "photoClose", #selector(close))
        [counter, UIView(), shareButton, closeButton].forEach { bar.addArrangedSubview($0) }
        bar.spacing = 12
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            // bottom right, within reach of the thumb
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        // the caption's host fills the screen above the bar (the caption sits at its bottom and
        // may grow when opened); only the caption itself takes touches
        caption.view.backgroundColor = .clear
        addChild(caption)
        captionHost.addSubview(caption.view)
        view.insertSubview(captionHost, belowSubview: bar)
        caption.didMove(toParent: self)
        caption.view.frame = captionHost.bounds
        caption.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captionHost.translatesAutoresizingMaskIntoConstraints = false
        captionAboveBar = captionHost.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -2)
        captionAboveVideo = captionHost.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -120)
        NSLayoutConstraint.activate([
            captionHost.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            captionHost.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            captionHost.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            captionAboveBar,
        ])
        updateCounter()
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(close))
        swipe.direction = .down
        swipe.delegate = self
        view.addGestureRecognizer(swipe)
        pageChanged()
    }

    /// A photo is a zoomable page; a video is the player itself, so turning to it plays it.
    private func page(_ i: Int) -> UIViewController {
        guard items[i].kind == .video else {
            let p = ZoomPage(item: items[i], index: i)
            p.onClose = { [weak self] in self?.close() }
            p.onShown = { [weak self] in self?.shown(i) }
            return p
        }
        let start = videoStart
        videoStart = .zero      // only the video that was opened goes on from where the feed was
        let p = PlayerViewController(url: items[i].fileURL, startAt: i == index ? start : .zero)
        p.embedding = .init(index: i, hasPrevious: i > 0, hasNext: i < items.count - 1,
                            step: { [weak self] d in self?.step(d) }, close: { [weak self] in self?.close() },
                            shown: { [weak self] in self?.shown(i) },
                            controlsVisible: { [weak self, weak p] on in
                                guard let self, let p, self.currentPlayer === p else { return }
                                UIView.animate(withDuration: 0.2) { self.captionHost.alpha = on ? 1 : 0 }
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
    private func pageChanged() {
        let video = currentPlayer
        bar.isHidden = video != nil
        updateCaption()
        let scroll = pages.view.subviews.compactMap { $0 as? UIScrollView }.first
        scroll?.isScrollEnabled = items.count > 1 && (video?.dragGestures != true)
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

    /// The caption for the media on screen: above the bar for a photo, above a video's controls
    /// (and showing only while they do).
    private func updateCaption() {
        let it = items[index]
        let video = currentPlayer
        captionAboveBar.isActive = video == nil
        captionAboveVideo.isActive = video != nil
        if let video { captionAboveVideo.constant = -video.controlsClearance }
        // a photo's shade goes on under the bar past the bottom edge and out past the sides (the
        // screen cuts it); a fixed reach, not one measured from frames, which change while the
        // viewer opens and turns and made the shade jump. A video's shade is the controls' own,
        // grown to take the caption in.
        let below: CGFloat = video == nil ? 1200 : 0
        let sides: CGFloat = 600
        let shows = PostCaptionView.shows(it)
        caption.rootView = PostCaptionView(item: it, maxExpandedHeight: view.bounds.height * 0.45,
                                           onHeight: { [weak self, weak video] h in
                                               self?.captionHost.activeHeight = h
                                               video?.shadeCaption(height: shows ? h : 0)
                                           },
                                           shaded: video == nil, shadeBelow: below, shadeSides: sides)
        if !shows { video?.shadeCaption(height: 0) }
        captionHost.alpha = video.map { $0.controlsShown ? 1 : 0 } ?? 1
        captionHost.isHidden = !shows
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in self.updateCaption() }
    }

    /// Dragging down closes a photo; a video handles it itself (or not at all, when its vertical
    /// drags set volume and brightness).
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        !(g is UISwipeGestureRecognizer && currentPlayer != nil)
    }

    private func updateCounter() {
        // the position within the current post, as the list shows it
        let post = items[index].postId
        var lo = index, hi = index
        while lo > 0, items[lo - 1].postId == post, !post.isEmpty { lo -= 1 }
        while hi < items.count - 1, items[hi + 1].postId == post, !post.isEmpty { hi += 1 }
        counter.text = hi > lo ? "\(index - lo + 1) / \(hi - lo + 1)" : nil
        counter.accessibilityValue = counter.text
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

    /// Share the current file (other apps, Files, AirDrop, Copy, Save Image).
    @objc private func share() {
        let vc = UIActivityViewController(activityItems: [items[index].fileURL], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = shareButton
        present(vc, animated: true)
    }
    private var openedLandscape: Bool?
    private weak var openedScene: UIWindowScene?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if openedLandscape == nil { openedLandscape = view.bounds.width > view.bounds.height; openedScene = view.window?.windowScene }
    }

    /// However it closed, from whichever page (the video that turned the screen may be pages away).
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { ViewerOrientation.settle(scene: openedScene, landscape: openedLandscape ?? false) }
    }

    /// A video that turned the screen to landscape turns it back first.
    @objc private func close() {
        if let p = currentPlayer { p.restorePortrait { [weak self] in self?.dismiss(animated: true) } } else { dismiss(animated: true) }
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

    init(item: FeedItem, index: Int) { self.item = item; self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.maximumZoomScale = item.kind == .video ? 1 : 5
        scroll.contentInsetAdjustmentBehavior = .never
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

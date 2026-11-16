import AppKit

/// The little Clawd over the window, in wide windows while the mascot mode is on: at home in the
/// bottom-right corner. Its eyes follow the pointer while the window is in the foreground. Only
/// the crab itself takes clicks; everything else goes to what is below.
final class MascotPetView: NSView {
    private let engine = PetEngine()
    private var timer: Timer?
    private var lastTime: CFTimeInterval = 0
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        observers.append(NotificationCenter.default.addObserver(forName: Mascot.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.pointerGone() }
        })
        update()
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        engine.setBounds(s, margin: 18)
        update()
    }

    private func update() {
        let show = Mascot.isOn && Mascot.petFits(bounds.size) && window != nil
        isHidden = !show
        if show, timer == nil {
            lastTime = 0
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !show {
            timer?.invalidate()
            timer = nil
            engine.pointerGone()
            needsDisplay = true
        }
    }

    private func step() {
        guard window?.occlusionState.contains(.visible) == true else { lastTime = 0; return }
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 0 : now - lastTime
        lastTime = now
        let r = engine.tick(dt)
        if r.changed { setNeedsDisplay(r.dirty) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let c = NSGraphicsContext.current?.cgContext { engine.draw(in: c) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // only while the window is the key window: a window behind others is left alone
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with e: NSEvent) { engine.pointer(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { engine.pointerGone() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let host = superview else { return nil }
        return engine.hit(convert(point, from: host)) ? self : nil
    }

    override func mouseDown(with e: NSEvent) { engine.tap(convert(e.locationInWindow, from: nil)) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

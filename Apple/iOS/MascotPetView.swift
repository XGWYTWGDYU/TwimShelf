import UIKit

/// The little Clawd over the app, in wide windows while the mascot mode is on: at home in the
/// bottom-right corner. Only the crab itself takes touches; everything else goes to what is below.
final class MascotPetView: UIView {
    private let engine = PetEngine()
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var observer: NSObjectProtocol?
    private lazy var hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))

    static func install(in host: UIView) {
        let v = MascotPetView(frame: host.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(v)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
        observer = NotificationCenter.default.addObserver(forName: Mascot.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        superview?.addGestureRecognizer(hover)    // a mouse or trackpad on an iPad, over anything
        update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        engine.setBounds(bounds.size, margin: 18)
        update()
    }

    private func update() {
        let show = Mascot.isOn && Mascot.petFits(bounds.size) && superview != nil
        isHidden = !show
        if show, link == nil {
            let l = CADisplayLink(target: self, selector: #selector(step(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)   // pixel art
            l.add(to: .main, forMode: .common)
            link = l
            lastTime = 0
        } else if !show {
            link?.invalidate()
            link = nil
            engine.pointerGone()
        }
    }

    @objc private func step(_ l: CADisplayLink) {
        // above the pages, which may be added later; a presented screen still covers it
        if superview?.subviews.last !== self { superview?.bringSubviewToFront(self) }
        let dt = lastTime == 0 ? 0 : l.timestamp - lastTime
        lastTime = l.timestamp
        let r = engine.tick(dt)
        if r.changed { setNeedsDisplay(r.dirty) }
    }

    override func draw(_ rect: CGRect) {
        if let c = UIGraphicsGetCurrentContext() { engine.draw(in: c) }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { !isHidden && engine.hit(point) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { engine.tap(t.location(in: self)) }
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: engine.pointer(g.location(in: self))
        default: engine.pointerGone()
        }
    }
}

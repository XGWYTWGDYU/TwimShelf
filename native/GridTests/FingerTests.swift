import XCTest

/// Synthetic pinches over many start states, finger positions and gesture shapes.
///
/// The engine follows Photos, which does not always keep the photo under the fingers: a layer
/// puts the anchor in the column nearest the finger, and a layer whose first row would show is
/// top-aligned. These tests check the photo stays under the finger wherever Photos' rules keep
/// it there, that the layout never shows a partial first row at rest, and that a gesture that
/// comes back to where it started restores the original layout.
final class FingerTests: XCTestCase {

    // MARK: - Gesture driver

    struct Script {
        var name: String
        /// (duration in s, cumulative recognizer scale at the end), log-linear in between.
        var steps: [(Double, CGFloat)]
        var releaseVelocity: CGFloat = 0
        /// Finger drift per second while pinching (a pan during the pinch).
        var drift: CGPoint = .zero
    }

    static let scripts: [Script] = [
        Script(name: "in small", steps: [(0.4, 1.3)]),
        Script(name: "in one step", steps: [(0.5, 1.9)]),
        Script(name: "in two steps", steps: [(0.8, 6)]),
        Script(name: "in to cap", steps: [(0.8, 9)]),
        Script(name: "out small", steps: [(0.4, 0.8)]),
        Script(name: "out one step", steps: [(0.5, 0.55)]),
        Script(name: "out two steps", steps: [(0.8, 0.18)]),
        Script(name: "out into rubber", steps: [(0.8, 0.06)]),
        Script(name: "in-out", steps: [(0.4, 2.2), (0.4, 1)]),
        Script(name: "out-in", steps: [(0.4, 0.45), (0.4, 1)]),
        Script(name: "in-out-in", steps: [(0.3, 2.5), (0.3, 0.6), (0.3, 1.8)]),
        Script(name: "hold then in", steps: [(0.3, 1), (0.5, 2.4)]),
        Script(name: "fling in", steps: [(0.15, 1.25)], releaseVelocity: 6),
        Script(name: "fling out", steps: [(0.15, 0.85)], releaseVelocity: -6),
        Script(name: "slow in", steps: [(2.5, 3)]),
        Script(name: "in with pan", steps: [(0.6, 2.2)], drift: CGPoint(x: 0, y: 60)),
    ]

    struct Frame {
        var time: Double
        var side: CGFloat
        var finger: CGPoint
        var tiles: [Tile]
    }

    /// Runs one gesture to rest, handing every frame to `check`.
    @discardableResult
    static func run(_ engine: ZoomEngine, finger f0: CGPoint, _ script: Script, start: Double = 0,
                    check: (Frame) -> Void) -> RestState {
        let dt = 1.0 / 120
        var t = start
        var finger = f0
        engine.beginPinch(at: finger, time: t)
        var tiles: [Tile] = []
        func frame() {
            tiles.removeAll(keepingCapacity: true)
            engine.zoomTiles(into: &tiles)
            check(Frame(time: t, side: engine.info().side, finger: finger, tiles: tiles))
        }
        var scale: CGFloat = 1
        for (dur, target) in script.steps {
            let s0 = scale
            let n = max(1, Int(dur / dt))
            for k in 1...n {
                t += dt
                scale = s0 * pow(target / s0, CGFloat(k) / CGFloat(n))
                finger.x += script.drift.x * CGFloat(dt)
                finger.y += script.drift.y * CGFloat(dt)
                engine.pinchChanged(scale: scale, finger: finger)
                if let r = engine.tick(time: t) { return r }
                frame()
            }
        }
        engine.release(velocity: script.releaseVelocity, scale: scale)
        for _ in 0..<1200 {
            t += dt
            if let r = engine.tick(time: t) { return r }
            frame()
        }
        XCTFail("\(script.name): zoom did not come to rest")
        return engine.finishNow() ?? engine.rest
    }

    /// The photo whose colour dominates at the finger: the topmost tile there with alpha ≥ ½.
    static func photoUnder(_ p: CGPoint, _ tiles: [Tile]) -> Int? {
        var photo: Int?
        for t in tiles where t.alpha >= 0.5 && p.x >= t.x && p.x < t.x + t.side && p.y >= t.y && p.y < t.y + t.side {
            photo = t.photo
        }
        return photo
    }

    // MARK: - Start states

    static let count = 206

    static func engine(level: Int, offset: CGFloat, count: Int = count) -> ZoomEngine {
        let cfg = photosConfig(count: count)
        // Resting states as the app produces them: the first row is full when it can be seen.
        var phase = cfg.bottomPhase(level)
        var o = min(offset, cfg.maxOffset(level: level, phase: phase))
        if o < cfg.insetTop + cfg.side(level) { phase = 0; o = min(offset, cfg.maxOffset(level: level, phase: 0)) }
        let e = ZoomEngine(cfg: cfg, rest: RestState(level: level, phase: phase, offset: max(0, o)))
        e.items = (0..<count).map { $0 }
        return e
    }

    /// Offsets from the very top to the very bottom.
    static func offsets(level: Int) -> [CGFloat] {
        let cfg = photosConfig(count: count)
        let m = cfg.maxOffset(level: level, phase: 0)
        return [0, 40, cfg.insetTop + cfg.side(level) + 1, 300, m * 0.5, m - 300, m - 30, m]
    }

    static let fingers: [CGPoint] = stride(from: CGFloat(8), through: 394, by: 29).flatMap { x in
        stride(from: CGFloat(150), through: 770, by: 88).map { y in CGPoint(x: x, y: y) }
    }

    /// What the app does when a zoom ends with a partial first row on screen (possible only
    /// when the fingers panned the starting layout down): it re-aligns to a full first row.
    static func appRealign(_ r: RestState, _ cfg: GridConfig) -> RestState {
        guard r.phase != 0, r.offset < cfg.insetTop + cfg.side(r.level) else { return r }
        return RestState(level: r.level, phase: 0, offset: min(r.offset, cfg.maxOffset(level: r.level, phase: 0)))
    }

    // MARK: - Where Photos keeps the photo under the finger

    /// In the resting layout of a level, is the anchor photo still under the finger? Photos
    /// keeps it there between two such levels: the anchor moves linearly between them.
    /// `margin` allows for the rubber band shrinking the tile around a fixed point.
    static func anchorStays(_ e: ZoomEngine, _ z: ZoomEngine.Zoom, level l: Int, margin: CGFloat) -> Bool {
        let cfg = e.cfg
        guard z.anchors[l] == z.anchor else { return false }          // top-aligned layer
        let n = cfg.columns[l], side = cfg.side(l), pitch = cfg.pitch(l)
        let row = (z.anchor + z.phases[l]) / n
        let o = cfg.insetTop + CGFloat(row) * pitch + z.rel.y * side - z.finger.y
        guard o >= 0, o <= cfg.maxOffset(level: l, phase: z.phases[l]) else { return false }   // clamped
        let x0 = CGFloat(z.cols[l]) * pitch
        // A finger exactly on a tile edge is in neither tile.
        let inY = z.rel.y * side >= 0.01 && z.rel.y * side <= side - 0.01
        return inY && z.finger.x >= x0 + margin && z.finger.x <= x0 + side - margin
    }

    /// Bracketing rest levels of a displayed side.
    static func bracket(_ s: CGFloat, _ cfg: GridConfig) -> (Int, Int) {
        if s <= cfg.side(0) { return (0, 0) }
        for l in 0..<(cfg.levels - 1) where s <= cfg.side(l + 1) { return (l, l + 1) }
        return (cfg.levels - 1, cfg.levels - 1)
    }

    /// Every level, offset, finger and gesture: wherever Photos keeps the anchor under the
    /// finger, the photo seen under the finger never changes, in any frame.
    func testPhotoUnderFingerStaysWherePhotosKeepsIt() {
        var checkedFrames = 0, gestures = 0, keptGestures = 0
        var failures: [String] = []
        for level in 0..<3 {
            for offset in Self.offsets(level: level) {
                for finger in Self.fingers {
                    for script in Self.scripts where script.drift == .zero {
                        let e = Self.engine(level: level, offset: offset)
                        guard let start = e.restIndex(at: finger) else { continue }   // finger in a gap
                        let before = e.rest
                        gestures += 1
                        var keep: [Bool] = []
                        var kept = true
                        Self.run(e, finger: finger, script) { f in
                            guard let z = e.zoom else { return }
                            if keep.isEmpty {
                                keep = (0..<e.cfg.levels).map {
                                    Self.anchorStays(e, z, level: $0, margin: $0 == 0 ? 4.5 : 0.01)
                                }
                            }
                            let (lo, hi) = Self.bracket(f.side, e.cfg)
                            guard keep[lo] && keep[hi] else { kept = false; return }
                            checkedFrames += 1
                            let under = Self.photoUnder(f.finger, f.tiles)
                            if under != start, failures.count < 20 {
                                failures.append("level \(level) offset \(before.offset) finger \(finger) "
                                    + "\(script.name) t=\(f.time) side=\(f.side): under \(String(describing: under)), "
                                    + "anchor \(start)")
                            }
                        }
                        if kept { keptGestures += 1 }
                    }
                }
            }
        }
        print("photo under finger: \(gestures) gestures, \(keptGestures) entirely in Photos' keep region, "
              + "\(checkedFrames) frames checked")
        XCTAssertGreaterThan(checkedFrames, 100_000)
        XCTAssert(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// 3 ↔ 1 columns: the anchor's column is fixed at 3 columns and fills the width at 1, so the
    /// photo under the finger never changes, wherever the finger is (away from top/bottom clamps).
    func testThreeAndOneColumnsAlwaysKeepThePhoto() {
        let cfg = photosConfig(count: Self.count)
        var checked = 0
        for offset: CGFloat in [1500, 3000, 5000] {
            for finger in Self.fingers {
                for script in Self.scripts where ["in one step", "in-out", "fling in", "in to cap", "slow in"].contains(script.name) {
                    let e = Self.engine(level: 1, offset: offset)
                    guard let start = e.restIndex(at: finger) else { continue }
                    Self.run(e, finger: finger, script) { f in
                        guard f.side >= cfg.side(1) else { return }
                        checked += 1
                        XCTAssertEqual(Self.photoUnder(f.finger, f.tiles), start,
                                       "finger \(finger) offset \(offset) \(script.name) side \(f.side)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
    }

    /// The anchor point stays at the finger's height in every frame unless a level is clamped
    /// at the top or bottom of the content, including when the fingers pan during the pinch.
    func testAnchorFollowsFingerVertically() {
        var checked = 0
        for level in 0..<3 {
            for offset in Self.offsets(level: level) {
                for finger in Self.fingers where Int(finger.x) % 3 == 0 {
                    for script in Self.scripts {
                        let e = Self.engine(level: level, offset: offset)
                        guard e.restIndex(at: finger) != nil else { continue }
                        Self.run(e, finger: finger, script) { f in
                            guard let z = e.zoom else { return }
                            let (lo, hi) = Self.bracket(f.side, e.cfg)
                            func free(_ l: Int) -> Bool {
                                let n = e.cfg.columns[l]
                                let row = (z.anchors[l] + z.phases[l]) / n
                                let o = e.cfg.insetTop + CGFloat(row) * e.cfg.pitch(l) + z.rel.y * e.cfg.side(l) - z.finger.y
                                return o >= 0 && o <= e.cfg.maxOffset(level: l, phase: z.phases[l])
                            }
                            guard free(lo), free(hi), z.anchors[lo] == z.anchor, z.anchors[hi] == z.anchor else { return }
                            guard let t = f.tiles.first(where: { $0.index == z.anchor && abs($0.y + z.rel.y * $0.side - z.finger.y) < 200 })
                            else { return XCTFail("anchor tile missing: \(script.name)") }
                            checked += 1
                            XCTAssertEqual(t.y + z.rel.y * t.side, z.finger.y, accuracy: 0.01,
                                           "level \(level) offset \(offset) finger \(finger) \(script.name)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 50_000)
    }

    /// A gesture that ends at the column count it started from restores the exact layout.
    func testRoundTripRestoresLayout() {
        let roundTrips = Self.scripts.filter { ["in-out", "out-in", "in small", "out small"].contains($0.name) }
        for level in 0..<3 {
            for offset in Self.offsets(level: level) {
                for finger in Self.fingers {
                    for script in roundTrips {
                        let e = Self.engine(level: level, offset: offset)
                        guard e.restIndex(at: finger) != nil else { continue }
                        let before = e.rest
                        let after = Self.run(e, finger: finger, script) { _ in }
                        guard after.level == before.level else { continue }   // "small" may latch at 1 col
                        XCTAssertEqual(after.phase, before.phase, "\(script.name) level \(level) finger \(finger)")
                        XCTAssertEqual(after.offset, before.offset, accuracy: 0.01,
                                       "\(script.name) level \(level) offset \(offset) finger \(finger)")
                    }
                }
            }
        }
    }

    // MARK: - First row

    static func assertFullFirstRow(_ r: RestState, _ cfg: GridConfig, _ what: @autoclosure () -> String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssert(r.offset >= -0.001 && r.offset <= cfg.maxOffset(level: r.level, phase: r.phase) + 0.001,
                  "offset out of range: \(r) \(what())", file: file, line: line)
        if r.offset < cfg.insetTop + cfg.side(r.level) {
            XCTAssertEqual(r.phase, 0, "partial first row on screen: \(r) \(what())", file: file, line: line)
        }
    }

    /// After any gesture from any start, a visible first row is a full row.
    func testNoPartialFirstRowAfterAnyZoom() {
        for level in 0..<3 {
            for offset in Self.offsets(level: level) {
                for finger in Self.fingers {
                    for script in Self.scripts {
                        let e = Self.engine(level: level, offset: offset)
                        var r = Self.run(e, finger: finger, script) { _ in }
                        if script.drift != .zero { r = Self.appRealign(r, e.cfg) }
                        Self.assertFullFirstRow(r, e.cfg, "level \(level) offset \(offset) finger \(finger) \(script.name)")
                    }
                }
            }
        }
    }

    /// Long random sequences of zooms near the top (the reported "empty slots in the top row"),
    /// with occasional scrolls, small libraries included.
    func testRepeatedZoomsNearTop() {
        var rng = SplitMix(seed: 0x5EED)
        for count in [206, 7, 13, 26, 40, 61] {
            let e = Self.engine(level: 1, offset: 0, count: count)
            var t = 0.0
            for k in 0..<1500 {
                let finger = CGPoint(x: CGFloat(rng.next(in: 2...400)), y: CGFloat(rng.next(in: 140...780)))
                let script = Self.scripts[Int(rng.next(in: 0...Double(Self.scripts.count) - 0.001))]
                var r = Self.run(e, finger: finger, script, start: t) { _ in }
                if script.drift != .zero { r = Self.appRealign(r, e.cfg); e.rest = r }
                t += 10
                Self.assertFullFirstRow(r, e.cfg, "count \(count) step \(k) finger \(finger) \(script.name)")
                if k % 7 == 3 {
                    // A scroll somewhere near the top; the app realigns before the top shows.
                    let cfg = e.cfg
                    var s = e.rest
                    s.offset = clampf(CGFloat(rng.next(in: 0...900)), 0, cfg.maxOffset(level: s.level, phase: s.phase))
                    if s.offset < cfg.insetTop + 3 * cfg.pitch(s.level) && s.phase != 0 {
                        s.offset = min(s.offset, cfg.maxOffset(level: s.level, phase: 0)); s.phase = 0
                    }
                    e.rest = s
                }
            }
        }
    }

    /// Several pinches started while the previous one is still settling (regrab).
    func testRegrabDuringSettle() {
        for finger in Self.fingers where Int(finger.y) % 2 == 0 {
            let e = Self.engine(level: 0, offset: 2000)
            guard let start = e.restIndex(at: finger) else { continue }
            var t = 0.0
            // Release mid-transition and grab again before it settles, three times.
            for k in 0..<3 {
                e.beginPinch(at: finger, time: t)
                for i in 1...20 {
                    t += 1.0 / 120
                    e.pinchChanged(scale: pow(k % 2 == 0 ? 1.6 : 0.7, CGFloat(i) / 20), finger: finger)
                    _ = e.tick(time: t)
                }
                e.release(velocity: 0, scale: 1)
                for _ in 0..<6 { t += 1.0 / 120; _ = e.tick(time: t) }
                XCTAssert(e.isZooming)
            }
            var r: RestState?
            for _ in 0..<1200 where r == nil { t += 1.0 / 120; r = e.tick(time: t) }
            XCTAssertNotNil(r)
            if let r { Self.assertFullFirstRow(r, e.cfg, "regrab finger \(finger)") }
            // The regrabs keep the picture still at the moment of the grab, so the anchor is unchanged.
            var tiles: [Tile] = []
            e.restTiles(e.rest, into: &tiles)
            XCTAssertTrue(tiles.contains { $0.photo == start }, "anchor scrolled away: finger \(finger)")
        }
    }
}

/// Small deterministic generator for the randomized tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(in r: ClosedRange<Double>) -> Double {
        r.lowerBound + Double(next() >> 11) / Double(1 << 53) * (r.upperBound - r.lowerBound)
    }
}

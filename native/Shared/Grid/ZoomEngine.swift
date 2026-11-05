import CoreGraphics
import QuartzCore

/// One drawn tile, in screen points.
struct Tile {
    var x: CGFloat
    var y: CGFloat
    var side: CGFloat
    var alpha: CGFloat
    var index: Int                 // position in the item list (layout)
    var photo: Int = 0             // photo identity (appearance)
    /// top-left, top-right, bottom-right, bottom-left
    var radii: (CGFloat, CGFloat, CGFloat, CGFloat)
}

/// The pinch-zoom state machine reverse-engineered from Photos (FINDINGS.md §2–§7).
///
/// One lattice of cells (pitch = side + gap, gap fixed in screen space) anchored at the
/// photo that was under the fingers. Every column count is a *layer* that only decides which
/// photo sits in which cell; layers cross-fade over each other.
final class ZoomEngine {
    var cfg: GridConfig
    var rest: RestState
    private(set) var zoom: Zoom?
    /// Photo identities in display order; index i of the grid shows photo items[i].
    var items: [Int] { didSet { cfg.count = items.count } }
    /// A photo not drawn by the grid (it is lifted out by the context menu).
    var hiddenPhoto: Int?
    var isZooming: Bool { zoom != nil }

    struct Zoom {
        var anchor: Int
        var rel: CGPoint              // finger position inside the anchor cell (side units)
        var cols: [Int]               // column of the anchor cell in every layer
        var anchors: [Int]            // photo in the anchor cell of every layer
        var phases: [Int]             // resting phase of every layer
        var finger: CGPoint           // effective finger position (incl. regrab offset)
        var fingerOffset: CGPoint
        var lnBase: CGFloat           // ln(raw side) when the current pinch began
        var lnRaw: CGFloat            // ln(raw side) now
        var lnVel: CGFloat = 0        // settle spring velocity
        var level: CGFloat            // cross-fade progress L (0 = densest layer)
        var target: Int               // latched layer T
        var pinching = true
        var prevLnRaw: CGFloat
        var prevLnSide: CGFloat
        var sideRate: CGFloat = 0     // |d ln side / dt|
        var lastTime: CFTimeInterval = 0
    }

    init(cfg: GridConfig, rest: RestState) {
        self.cfg = cfg
        self.rest = rest
        self.items = Array(0..<cfg.count)
    }

    // MARK: - Gesture

    func beginPinch(at finger: CGPoint, time: CFTimeInterval) {
        if var z = zoom {
            // A pinch during the settle continues from the current state; keep the picture still.
            z.fingerOffset = CGPoint(x: z.finger.x - finger.x, y: z.finger.y - finger.y)
            z.lnBase = z.lnRaw
            z.lnVel = 0
            z.pinching = true
            z.lastTime = time
            zoom = z
            return
        }
        let lv = rest.level
        let n = cfg.columns[lv]
        let side = cfg.side(lv), pitch = cfg.pitch(lv)
        let cy = finger.y - cfg.insetTop + rest.offset
        let col = min(max(Int(floor(finger.x / pitch)), 0), n - 1)
        let row = max(0, Int(floor(cy / pitch)))
        let index = min(max(row * n + col - rest.phase, 0), max(cfg.count - 1, 0))
        let c = cfg.cell(of: index, level: lv, phase: rest.phase)
        let rel = CGPoint(x: (finger.x - CGFloat(c.col) * pitch) / side,
                          y: (cy - CGFloat(c.row) * pitch) / side)

        var cols = [Int](repeating: 0, count: cfg.levels)
        var phases = [Int](repeating: 0, count: cfg.levels)
        var anchors = [Int](repeating: index, count: cfg.levels)
        for l in 0..<cfg.levels where l != lv {
            (cols[l], phases[l], anchors[l]) = chooseColumn(level: l, anchor: index, rel: rel, finger: finger)
        }
        cols[lv] = c.col; phases[lv] = rest.phase
        let ln0 = log(side)
        zoom = Zoom(anchor: index, rel: rel, cols: cols, anchors: anchors, phases: phases,
                    finger: finger, fingerOffset: .zero,
                    lnBase: ln0, lnRaw: ln0, level: CGFloat(lv), target: lv,
                    prevLnRaw: ln0, prevLnSide: ln0, lastTime: time)
    }

    func pinchChanged(scale: CGFloat, finger: CGPoint) {
        guard var z = zoom, z.pinching else { return }
        z.finger = CGPoint(x: finger.x + z.fingerOffset.x, y: finger.y + z.fingerOffset.y)
        z.lnRaw = z.lnBase + log(max(scale, 1e-3))
        zoom = z
    }

    /// `velocity` is the recognizer's scale velocity (scale/s).
    func release(velocity: CGFloat, scale: CGFloat) {
        guard var z = zoom else { return }
        let v = clampf(velocity / max(scale, 1e-3), -8, 8)
        // Let a fling carry the latch one step further, using the same directional rule.
        let projected = cfg.displaySide(lnRaw: z.lnRaw + v * GridConfig.releaseProjection)
        z.target = latch(target: z.target, side: projected, direction: v)
        z.pinching = false
        z.lnVel = v
        zoom = z
    }

    // MARK: - Per frame

    /// Advances the zoom. Returns the new resting state when the zoom has finished.
    func tick(time: CFTimeInterval) -> RestState? {
        guard var z = zoom else { return nil }
        let dt = CGFloat(min(max(time - z.lastTime, 0), 1.0 / 30))
        z.lastTime = time

        if !z.pinching {
            let goal = log(cfg.side(z.target))
            let w = GridConfig.springOmega
            var t = dt
            while t > 1e-6 {
                let h = min(t, 1.0 / 480)
                let a = -w * w * (z.lnRaw - goal) - 2 * w * z.lnVel
                z.lnVel += a * h
                z.lnRaw += z.lnVel * h
                t -= h
            }
        }

        let s = cfg.displaySide(lnRaw: z.lnRaw)
        let lnS = log(s)
        if dt > 0 {
            let inst = abs(lnS - z.prevLnSide) / dt
            z.sideRate += (inst - z.sideRate) * min(1, dt * 30)
        }
        if z.pinching {
            z.target = latch(target: z.target, side: s, direction: z.lnRaw - z.prevLnRaw)
        }
        z.prevLnRaw = z.lnRaw
        z.prevLnSide = lnS

        // Cross-fade progress: time plus gesture motion, toward the latched layer.
        let rate = GridConfig.fadeBase + GridConfig.fadeGain * z.sideRate
        let diff = CGFloat(z.target) - z.level
        z.level += (diff > 0 ? 1 : -1) * min(abs(diff), rate * dt)
        zoom = z

        // Done once the remaining motion is below a third of a pixel and the fade has landed.
        let remaining = abs(z.lnRaw - log(cfg.side(z.target))) * cfg.side(z.target)
        if !z.pinching, remaining < 0.33 / cfg.scale, abs(z.lnVel) < 0.02,
           abs(z.level - CGFloat(z.target)) < 0.02 {
            return finish()
        }
        return nil
    }

    /// Jumps a settling zoom to its end state (used when the user starts scrolling mid-settle).
    func finishNow() -> RestState? {
        guard var z = zoom, !z.pinching else { return nil }
        z.lnRaw = log(cfg.side(z.target))
        z.lnVel = 0
        z.level = CGFloat(z.target)
        zoom = z
        return finish()
    }

    private func latch(target: Int, side s: CGFloat, direction: CGFloat) -> Int {
        var t = target
        if direction > 0 {
            while t < cfg.levels - 1 && s > cfg.up(t) { t += 1 }
        } else if direction < 0 {
            while t > 0 && s < cfg.down(t - 1) { t -= 1 }
        }
        return t
    }

    private func finish() -> RestState? {
        guard let z = zoom else { return nil }
        let l = z.target
        let r = restAnchorPoint(level: l, z: z)
        let n = cfg.columns[l]
        let row = (z.anchors[l] + z.phases[l]) / n
        let contentY = CGFloat(row) * cfg.pitch(l) + z.rel.y * cfg.side(l)
        let offset = clampf(cfg.insetTop + contentY - r.y, 0, cfg.maxOffset(level: l, phase: z.phases[l]))
        rest = RestState(level: l, phase: z.phases[l], offset: offset)
        zoom = nil
        return rest
    }

    // MARK: - Anchor geometry

    /// Anchor cell of a layer, as Photos does it: the column whose resting x is nearest the
    /// finger (experiment J), holding the anchor photo. If the first row would be on screen in
    /// that resting layout, the layer is top-aligned instead so the first row is full, and the
    /// anchor cell keeps its column but holds the photo that sits there in the top-aligned
    /// layout, on the anchor's row (experiment TOP).
    private func chooseColumn(level l: Int, anchor: Int, rel: CGPoint, finger: CGPoint) -> (col: Int, phase: Int, photo: Int) {
        let n = cfg.columns[l]
        let side = cfg.side(l), pitch = cfg.pitch(l)
        let col = min(max(Int(((finger.x - rel.x * side) / pitch).rounded()), 0), n - 1)
        let phase = posmod(col - anchor, n)
        let row = (anchor + phase) / n
        let o = clampf(cfg.insetTop + CGFloat(row) * pitch + rel.y * side - finger.y,
                       0, cfg.maxOffset(level: l, phase: phase))
        if o < cfg.insetTop + side {
            let photo = min((anchor / n) * n + col, max(cfg.count - 1, 0))
            return (photo % n, 0, photo)
        }
        return (col, phase, anchor)
    }

    /// Where the anchor point would be on screen if the grid came to rest in layer `l`.
    private func restAnchorPoint(level l: Int, z: Zoom) -> CGPoint {
        let n = cfg.columns[l]
        let side = cfg.side(l), pitch = cfg.pitch(l)
        let row = (z.anchors[l] + z.phases[l]) / n
        let x = CGFloat(z.cols[l]) * pitch + z.rel.x * side
        let contentY = CGFloat(row) * pitch + z.rel.y * side
        let o = clampf(cfg.insetTop + contentY - z.finger.y, 0, cfg.maxOffset(level: l, phase: z.phases[l]))
        return CGPoint(x: x, y: cfg.insetTop + contentY - o)
    }

    /// Anchor position: linear in side between the resting positions of the bracketing layers.
    private func anchorPoint(side s: CGFloat, z: Zoom) -> CGPoint {
        if s <= cfg.side(0) { return restAnchorPoint(level: 0, z: z) }
        for l in 0..<(cfg.levels - 1) where s <= cfg.side(l + 1) {
            let a = restAnchorPoint(level: l, z: z), b = restAnchorPoint(level: l + 1, z: z)
            let t = (s - cfg.side(l)) / (cfg.side(l + 1) - cfg.side(l))
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        return restAnchorPoint(level: cfg.levels - 1, z: z)
    }

    // MARK: - Frame

    struct FrameInfo {
        var side: CGFloat
        var level: CGFloat
        var target: Int
        var columns: Int
    }

    func info() -> FrameInfo {
        if let z = zoom {
            return FrameInfo(side: cfg.displaySide(lnRaw: z.lnRaw), level: z.level, target: z.target,
                             columns: cfg.columns[Int(z.level.rounded())])
        }
        return FrameInfo(side: cfg.side(rest.level), level: CGFloat(rest.level), target: rest.level,
                         columns: cfg.columns[rest.level])
    }

    /// Tiles for the current zoom frame, back to front.
    func zoomTiles(into out: inout [Tile]) {
        guard let z = zoom else { return }
        let s = cfg.displaySide(lnRaw: z.lnRaw)
        let p = s + cfg.gap
        let anchorPt = anchorPoint(side: s, z: z)
        let ax = anchorPt.x - z.rel.x * s, ay = anchorPt.y - z.rel.y * s

        var alpha = [CGFloat](repeating: 1, count: cfg.levels)
        for j in 1..<cfg.levels {
            let v = clampf(z.level - CGFloat(j - 1), 0, 1)
            alpha[j] = v * v
        }
        let drMin = Int(floor(-ay / p)), drMax = Int(floor((cfg.height - ay) / p))
        let dcScreenMin = Int(floor(-ax / p)), dcScreenMax = Int(floor((cfg.width - ax) / p))

        for l in 0..<cfg.levels {
            if l > 0 && alpha[l] <= 0.001 { continue }
            let n = cfg.columns[l]
            let c = z.cols[l]
            // Cells covered by an opaque sparser layer above need not be drawn.
            let opaqueAbove = ((l + 1)..<cfg.levels).filter { alpha[$0] >= 0.999 }
            let lo = max(-c, dcScreenMin), hi = min(n - 1 - c, dcScreenMax)
            if lo > hi { continue }
            for dr in drMin...drMax {
                for dc in lo...hi {
                    if opaqueAbove.contains(where: { m in
                        let cm = z.cols[m], nm = cfg.columns[m]
                        let im = z.anchors[m] + dr * nm + dc
                        return dc >= -cm && dc <= nm - 1 - cm && im >= 0 && im < cfg.count
                    }) { continue }
                    let idx = z.anchors[l] + dr * n + dc
                    if idx < 0 || idx >= cfg.count { continue }
                    let x = ax + CGFloat(dc) * p, y = ay + CGFloat(dr) * p
                    if items[idx] == hiddenPhoto { continue }
                    out.append(Tile(x: x, y: y, side: s, alpha: alpha[l], index: idx, photo: items[idx],
                                    radii: radii(x: x, side: s, leftEdge: dc == -c, rightEdge: dc == n - 1 - c)))
                }
            }
        }
    }

    /// Tiles of a resting layout (optionally offset in y).
    func restTiles(_ r: RestState, into out: inout [Tile], alpha: CGFloat = 1) {
        let l = r.level, n = cfg.columns[l]
        let s = cfg.side(l), p = cfg.pitch(l)
        let rowMin = max(0, Int(floor((r.offset - cfg.insetTop) / p)))
        let rowMax = Int(floor((r.offset - cfg.insetTop + cfg.height) / p))
        guard rowMin <= rowMax else { return }
        for row in rowMin...rowMax {
            for col in 0..<n {
                let idx = row * n + col - r.phase
                if idx < 0 || idx >= cfg.count { continue }
                let x = CGFloat(col) * p, y = cfg.insetTop + CGFloat(row) * p - r.offset
                if items[idx] == hiddenPhoto { continue }
                out.append(Tile(x: x, y: y, side: s, alpha: alpha, index: idx, photo: items[idx],
                                radii: radii(x: x, side: s, leftEdge: col == 0, rightEdge: col == n - 1)))
            }
        }
    }

    /// Screen frame of a photo in a resting layout.
    func restFrame(_ index: Int, _ r: RestState) -> CGRect {
        let c = cfg.cell(of: index, level: r.level, phase: r.phase)
        let p = cfg.pitch(r.level), s = cfg.side(r.level)
        return CGRect(x: CGFloat(c.col) * p, y: cfg.insetTop + CGFloat(c.row) * p - r.offset, width: s, height: s)
    }

    /// Index of the photo whose tile contains a screen point in the resting layout.
    func restIndex(at pt: CGPoint) -> Int? {
        let l = rest.level, n = cfg.columns[l], p = cfg.pitch(l), side = cfg.side(l)
        let cy = pt.y - cfg.insetTop + rest.offset
        guard pt.x >= 0, cy >= 0 else { return nil }
        let col = Int(pt.x / p), row = Int(cy / p)
        guard col < n, pt.x - CGFloat(col) * p <= side, cy - CGFloat(row) * p <= side else { return nil }
        let i = row * n + col - rest.phase
        return i >= 0 && i < cfg.count ? i : nil
    }

    /// Inner corners are rounded; a layer's outer corners square off as they reach the screen edge.
    func radii(x: CGFloat, side: CGFloat, leftEdge: Bool, rightEdge: Bool) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let r = GridConfig.cornerRadius
        let l = leftEdge ? r * clampf(x / r, 0, 1) : r
        let rr = rightEdge ? r * clampf((cfg.width - x - side) / r, 0, 1) : r
        return (l, rr, rr, l)
    }
}

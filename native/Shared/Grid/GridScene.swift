import CoreGraphics
import QuartzCore

/// What the grid shows in one tile.
struct ZoomGridTile {
    var item: FeedItem
    /// Media in the post (grouped mode); a badge shows it when more than one.
    var count: Int
}

/// The media of a folder or collection on the zoomable grid, shared by iOS (`MediaGridView`)
/// and macOS (`MacMediaGridView`). The zoom itself is `ZoomEngine` / `GridConfig`, measured
/// from Photos (research/FINDINGS.md) and used unchanged; this adds the media behind the tiles
/// and the two animations that change the layout without a zoom, both from the same research:
///  * re-aligning the first row (a conveyor shift, only near the top: the first row is never
///    partly empty), and
///  * a removal: later tiles slide straight to their new places and the removed ones fade out
///    in place (cubic-bezier(0.25, 0.9, 0.3, 1), 0.36 s).
/// The views own the scrolling and the gestures; they call `frame(at:)` once per drawn frame.
final class GridScene {
    let engine: ZoomEngine
    /// Tiles in display order (`engine.items[i]` is the key of `tiles[i]`).
    private(set) var tiles: [ZoomGridTile] = []
    /// Media id → stable key (the engine's photo identity), and back.
    private var keys: [String: Int] = [:]
    private var tileByKey: [Int: ZoomGridTile] = [:]
    private var nextKey = 0
    var selecting = false
    var selected: Set<String> = []

    private struct Reflow { var from: RestState; var to: RestState; var start: CFTimeInterval }
    private var reflow: Reflow?
    private struct Deletion { var oldItems: [Int]; var removed: Set<Int>; var rest: RestState; var start: CFTimeInterval }
    private var deletion: Deletion?
    /// A new list that arrived while a zoom or removal was running.
    private var pending: [ZoomGridTile]?

    /// The resting layout changed without a scroll (a zoom ended, a removal or a new list): the
    /// view sets its content size and offset from `engine.rest`.
    var onRestChanged: (() -> Void)?
    /// The content height changed while the offset stays (a re-align, the end of a removal).
    var onContentHeightChanged: (() -> Void)?

    init(cfg: GridConfig, level: Int) {
        engine = ZoomEngine(cfg: cfg, rest: RestState(level: min(max(level, 0), cfg.levels - 1), phase: 0, offset: 0))
        engine.items = []
    }

    var isAnimating: Bool { engine.isZooming || reflow != nil || deletion != nil }
    var isBusy: Bool { engine.isZooming || deletion != nil }

    func tile(key: Int) -> ZoomGridTile? { tileByKey[key] }
    func tile(at index: Int) -> ZoomGridTile? { index >= 0 && index < tiles.count ? tiles[index] : nil }
    func isSelected(key: Int) -> Bool { selecting && tileByKey[key].map { selected.contains($0.item.mediaId) } == true }

    private func key(for id: String) -> Int {
        if let k = keys[id] { return k }
        nextKey += 1
        keys[id] = nextKey
        return nextKey
    }

    // MARK: Content

    /// A new list of tiles. Only removals animate (the rest close the gap); anything else keeps
    /// the media in the middle of the screen where it is.
    func setTiles(_ t: [ZoomGridTile]) {
        if isBusy { pending = t; return }
        let newKeys = t.map { key(for: $0.item.mediaId) }
        let old = engine.items
        for (k, tile) in zip(newKeys, t) { tileByKey[k] = tile }
        let ids = Set(t.map(\.item.mediaId))
        selected = selected.intersection(ids)
        if newKeys == old { tiles = t; return }
        if !old.isEmpty, newKeys.count < old.count, let removed = Self.removal(from: old, to: newKeys) {
            tiles = t
            startDeletion(removed)
            return
        }
        replace(t, keys: newKeys)
    }

    /// Indices of `old` that are missing from `new`, when `new` is `old` with only removals.
    private static func removal(from old: [Int], to new: [Int]) -> Set<Int>? {
        var removed = Set<Int>(), j = 0
        for (i, k) in old.enumerated() {
            if j < new.count && new[j] == k { j += 1 } else { removed.insert(i) }
        }
        return j == new.count ? removed : nil
    }

    private func replace(_ t: [ZoomGridTile], keys newKeys: [Int]) {
        let cfg = engine.cfg, r = engine.rest
        // the media in the middle of the screen stays where it is (in its column, at its height)
        let mid = CGPoint(x: cfg.width / 2, y: cfg.insetTop + (cfg.height - cfg.insetTop - cfg.insetBottom) / 2)
        let anchor = (engine.restIndex(at: mid) ?? (engine.items.isEmpty ? nil : 0)).map { (engine.items[$0], engine.restFrame($0, r)) }
        tiles = t
        engine.items = newKeys
        reflow = nil
        var rest = RestState(level: r.level, phase: 0, offset: 0)
        if let (k, f) = anchor, let j = newKeys.firstIndex(of: k) {
            let n = cfg.columns[r.level]
            let col = Int((f.minX / cfg.pitch(r.level)).rounded())
            rest.phase = posmod(col - j, n)
            let row = (j + rest.phase) / n
            rest.offset = clampf(cfg.insetTop + CGFloat(row) * cfg.pitch(r.level) - f.minY, 0, engine.cfg.maxOffset(level: r.level, phase: rest.phase))
            // a first row on screen is always full
            if rest.offset < cfg.insetTop + cfg.side(r.level) + cfg.pitch(r.level) {
                let row0 = j / n
                rest.phase = 0
                rest.offset = clampf(cfg.insetTop + CGFloat(row0) * cfg.pitch(r.level) - f.minY, 0, engine.cfg.maxOffset(level: r.level, phase: 0))
            }
        }
        engine.rest = rest
        onRestChanged?()
    }

    /// The view's size or insets changed (rotation, a toolbar): same level, the media in the
    /// middle stays.
    func setConfig(_ cfg: GridConfig) {
        guard !isBusy else { return }
        var cfg = cfg
        cfg.count = engine.items.count
        // same width (a toolbar, a taller window): the layout stays, the offset stays in range
        if cfg.width == engine.cfg.width, cfg.scale == engine.cfg.scale, cfg.columns == engine.cfg.columns {
            engine.cfg = cfg
            let r = engine.rest
            engine.rest.offset = clampf(r.offset, 0, cfg.maxOffset(level: r.level, phase: r.phase))
            onRestChanged?()
            return
        }
        let level = engine.rest.level
        let midIndex = engine.items.isEmpty ? nil : (engine.restIndex(at: CGPoint(x: engine.cfg.width / 2, y: engine.cfg.insetTop + 1)) ?? 0)
        engine.cfg = cfg
        var rest = RestState(level: min(level, cfg.levels - 1), phase: 0, offset: 0)
        if let i = midIndex, engine.rest.offset > 0 {
            let row = i / cfg.columns[rest.level]
            rest.offset = clampf(cfg.insetTop + CGFloat(row) * cfg.pitch(rest.level) - cfg.insetTop, 0, cfg.maxOffset(level: rest.level, phase: 0))
        }
        engine.rest = rest
        reflow = nil
        onRestChanged?()
    }

    // MARK: Re-aligning the first row

    /// While scrolling near the top: the first row must never show empty places, so a grid
    /// left with a phase by a zoom re-aligns once the first row is within three rows of the screen.
    func realignBeforeTopShows() {
        let cfg = engine.cfg, r = engine.rest
        guard r.phase != 0, reflow == nil else { return }
        if r.offset < cfg.insetTop + 3 * cfg.pitch(r.level) { realignToTop() }
    }

    /// The grid re-aligns so its first row is full. The glide runs in content space with the
    /// live offset, so it never interrupts scrolling.
    func realignToTop() {
        guard !engine.isZooming, reflow == nil, deletion == nil else { return }
        let r = engine.rest
        guard r.phase != 0 else { return }
        reflow = Reflow(from: r, to: RestState(level: r.level, phase: 0, offset: r.offset), start: CACurrentMediaTime())
        engine.rest.phase = 0
        onContentHeightChanged?()
    }

    // MARK: Removal

    private func startDeletion(_ removed: Set<Int>) {
        let old = engine.items
        reflow = nil
        deletion = Deletion(oldItems: old, removed: removed, rest: engine.rest, start: CACurrentMediaTime())
        engine.items = old.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }

    private func finishDeletion() {
        deletion = nil
        onContentHeightChanged?()
        if let p = pending { pending = nil; setTiles(p) }
    }

    /// The zoom ended in a new resting layout.
    private func zoomEnded() {
        let r = engine.rest
        onRestChanged?()
        // a resting grid never shows a partial first row
        if r.phase != 0, r.offset < engine.cfg.insetTop + engine.cfg.side(r.level) { realignToTop() }
        if let p = pending { pending = nil; setTiles(p) }
    }

    /// A settling zoom jumps to its end (the user started scrolling).
    func finishZoomNow() {
        if engine.finishNow() != nil { zoomEnded() }
    }

    // MARK: Frames

    /// Tiles to draw at this time, back to front (advances the zoom and the animations).
    func frame(at now: CFTimeInterval, into out: inout [Tile]) {
        out.removeAll(keepingCapacity: true)
        if engine.isZooming, engine.tick(time: now) != nil { zoomEnded() }
        if engine.isZooming {
            engine.zoomTiles(into: &out)
        } else if let d = deletion {
            deletionTiles(d, now: now, into: &out)
        } else if let rf = reflow {
            reflowTiles(rf, now: now, into: &out)
        } else {
            engine.restTiles(engine.rest, into: &out)
        }
    }

    /// Re-alignment as a conveyor: the phase moves continuously, so every tile slides along the
    /// reading order; one leaving the end of a row slides out to the right while its copy slides
    /// in at the start of the next row — nothing crosses over other tiles.
    private func reflowTiles(_ rf: Reflow, now: CFTimeInterval, into out: inout [Tile]) {
        let t = CGFloat(min(1, (now - rf.start) / 0.3))
        let e = 1 - pow(1 - t, 3)
        let cfg = engine.cfg
        let l = rf.to.level, n = cfg.columns[l]
        let p = cfg.pitch(l), side = cfg.side(l)
        var delta = posmod(rf.to.phase - rf.from.phase, n)
        if delta * 2 > n { delta -= n }
        let phase = CGFloat(rf.from.phase) + CGFloat(delta) * e
        let offset = engine.rest.offset
        let rowMin = Int(floor((offset - cfg.insetTop) / p)) - 1
        let rowMax = Int(floor((offset - cfg.insetTop + cfg.height) / p)) + 1
        let iMin = max(0, rowMin * n - Int(ceil(phase)) - 1)
        let iMax = min(cfg.count - 1, (rowMax + 1) * n)
        if t >= 1 { reflow = nil }
        guard iMin <= iMax else { return }
        func add(_ col: CGFloat, _ row: Int, _ index: Int) {
            let x = col * p, y = cfg.insetTop + CGFloat(row) * p - offset
            if x + side <= 0 || x >= cfg.width || y + side <= 0 || y >= cfg.height { return }
            out.append(Tile(x: x, y: y, side: side, alpha: 1, index: index, photo: engine.items[index],
                            radii: engine.radii(x: x, side: side, leftEdge: true, rightEdge: true)))
        }
        for i in iMin...iMax {
            let k = CGFloat(i) + phase
            let row = Int(floor(k / CGFloat(n)))
            let col = k - CGFloat(row * n)
            add(col, row, i)
            if col > CGFloat(n - 1) { add(col - CGFloat(n), row + 1, i) }   // wrapping copy
        }
    }

    /// One shared progress drives everything: later tiles move in straight lines (one wrapping
    /// to the previous row crosses diagonally, drawn above the ones it passes), and the removed
    /// ones fade out in place underneath, without shrinking.
    private func deletionTiles(_ d: Deletion, now: CFTimeInterval, into out: inout [Tile]) {
        let t = CGFloat(min(1, (now - d.start) / 0.36))
        let e = cubicBezier(0.25, 0.9, 0.3, 1, t)
        let cfg = engine.cfg
        var r = d.rest
        r.offset = engine.rest.offset
        let n = cfg.columns[r.level], p = cfg.pitch(r.level), side = cfg.side(r.level)
        let rowMin = Int(floor((r.offset - cfg.insetTop) / p)) - 1
        let rowMax = Int(floor((r.offset - cfg.insetTop + cfg.height) / p)) + 1
        let lo = max(0, rowMin * n - r.phase), hi = min(d.oldItems.count - 1, (rowMax + 1) * n - r.phase)
        defer { if t >= 1 { finishDeletion() } }
        guard lo <= hi else { return }
        func frame(_ i: Int) -> CGRect {
            let c = cfg.cell(of: i, level: r.level, phase: r.phase)
            return CGRect(x: CGFloat(c.col) * p, y: cfg.insetTop + CGFloat(c.row) * p - r.offset, width: side, height: side)
        }
        func tile(_ f: CGRect, _ index: Int, _ key: Int, _ alpha: CGFloat) -> Tile {
            Tile(x: f.minX, y: f.minY, side: side, alpha: alpha, index: index, photo: key,
                 radii: engine.radii(x: f.minX, side: side, leftEdge: true, rightEdge: true))
        }
        for i in lo...hi where d.removed.contains(i) {
            out.append(tile(frame(i), i, d.oldItems[i], 1 - e))
        }
        var before = d.removed.filter { $0 < lo }.count
        for i in lo...hi {
            if d.removed.contains(i) { before += 1; continue }
            let j = i - before
            let f0 = frame(i), f1 = frame(j)
            let f = CGRect(x: f0.minX + (f1.minX - f0.minX) * e, y: f0.minY + (f1.minY - f0.minY) * e, width: side, height: side)
            if f.maxY < 0 || f.minY > cfg.height { continue }
            out.append(tile(f, j, d.oldItems[i], 1))
        }
    }

    /// Tiles a little beyond the screen (above and below) at rest, to decode ahead of a scroll.
    func nearbyKeys(screens: CGFloat) -> [Int] {
        var r = engine.rest
        var out: [Tile] = []
        let h = engine.cfg.height
        for k in stride(from: -screens, through: screens, by: 1) where k != 0 {
            r.offset = engine.rest.offset + k * h
            engine.restTiles(r, into: &out)
        }
        return out.map(\.photo)
    }
}

/// CSS-style cubic-bezier timing function, y for a given x = t.
func cubicBezier(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ t: CGFloat) -> CGFloat {
    if t <= 0 { return 0 }
    if t >= 1 { return 1 }
    func bx(_ s: CGFloat) -> CGFloat { 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s }
    func by(_ s: CGFloat) -> CGFloat { 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s }
    var lo: CGFloat = 0, hi: CGFloat = 1
    for _ in 0..<30 {
        let mid = (lo + hi) / 2
        if bx(mid) < t { lo = mid } else { hi = mid }
    }
    return by((lo + hi) / 2)
}

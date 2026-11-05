import CoreGraphics
import Foundation

/// A Photos recording reduced to what the engine needs (tools/make_fixture.py).
struct Fixture: Decodable {
    struct Start: Decodable { var level: Int; var phase: Int; var offset: CGFloat }
    struct Frame: Decodable {
        var t: Double
        var s: CGFloat
        /// [photo, x, y, side] of every fully visible, cleanly coloured tile, in points.
        var tiles: [[CGFloat]]
    }
    var name: String
    var items: [Int]
    var finger: [CGFloat]
    var start: Start
    var frames: [Frame]

    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURES_FILE"] ?? #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func load(_ name: String) throws -> Fixture {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    static var all: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
}

/// The screen the recordings were made on (iPhone 18 Pro simulator, Photos).
func photosConfig(count: Int) -> GridConfig {
    GridConfig(width: 402, height: 874, scale: 3, insetTop: 136, insetBottom: 93, count: count)
}

/// ln(raw side) whose displayed side is `s` (inverse of the rubber band below the 5-column side).
func lnRaw(displayed s: CGFloat, cfg: GridConfig) -> CGFloat {
    let m = cfg.minSide
    guard s < m else { return log(s) }
    let d = GridConfig.rubberDepth, c = GridConfig.rubberC
    let q = min(-log(s / m) / d, 0.999)   // a few frames go a hair past the model asymptote
    return log(m) - d / c * (1 / (1 - q) - 1)
}

struct ReplayReport {
    struct FrameError { var t: Double; var s: CGFloat; var n: Int; var median: CGFloat; var worst: CGFloat; var worstPhoto: Int; var dx: CGFloat = 0; var dy: CGFloat = 0 }
    var name: String
    var frames: [FrameError] = []
    var errors: [CGFloat] = []
    /// Recorded tiles whose photo the engine does not draw at all. A cross-fade blend can
    /// match another palette colour, so a few of these are expected.
    var unmatched = 0
    var gestures = 0
    var unmatchedFraction: Double { Double(unmatched) / Double(max(1, unmatched + errors.count)) }

    func percentile(_ p: Double) -> CGFloat {
        guard !errors.isEmpty else { return 0 }
        let e = errors.sorted()
        return e[min(e.count - 1, Int(Double(e.count - 1) * p))]
    }
    var summary: String {
        String(format: "%@: %d gestures, %d frames, %d tiles (%d unmatched), median %.2fpt, p95 %.2fpt, p99 %.2fpt, max %.2fpt",
               name, gestures, frames.count, errors.count, unmatched, percentile(0.5), percentile(0.95), percentile(0.99),
               errors.max() ?? 0)
    }
}

/// Feeds the displayed side of every recorded frame through the engine and compares every
/// recorded tile with the engine tile of the same photo.
///
/// The recordings contain several gestures (the fingers lift between them). A gesture is taken
/// to have ended once the side has rested on a column size for `restGap` seconds.
func replay(_ f: Fixture, restGap: Double = 0.35) -> ReplayReport {
    let cfg = photosConfig(count: f.items.count)
    let engine = ZoomEngine(cfg: cfg, rest: RestState(level: f.start.level, phase: f.start.phase, offset: f.start.offset))
    engine.items = f.items
    let finger = CGPoint(x: f.finger[0], y: f.finger[1])
    var report = ReplayReport(name: f.name)
    var tiles: [Tile] = []
    var restSince: Double?
    var side0: CGFloat = cfg.side(f.start.level)

    func isRestSide(_ s: CGFloat) -> Bool { (0..<cfg.levels).contains { abs(cfg.side($0) - s) < 0.4 } }

    for fr in f.frames {
        let atRestSide = isRestSide(fr.s)
        if engine.isZooming {
            if atRestSide {
                if restSince == nil { restSince = fr.t }
            } else {
                restSince = nil
            }
            if let r0 = restSince, fr.t - r0 >= restGap, let z = engine.zoom,
               abs(z.level - CGFloat(z.target)) < 0.02, abs(fr.s - cfg.side(z.target)) < 0.4 {
                // Fingers lifted: the zoom comes to rest.
                engine.release(velocity: 0, scale: 1)
                _ = engine.finishNow()
                restSince = nil
            }
        }
        if !engine.isZooming {
            if abs(fr.s - cfg.side(engine.rest.level)) < 0.4 {
                tiles.removeAll(keepingCapacity: true)
                engine.restTiles(engine.rest, into: &tiles)
                compare(fr, tiles, &report)
                continue
            }
            engine.beginPinch(at: finger, time: fr.t)
            side0 = cfg.side(engine.rest.level)
            report.gestures += 1
        }
        engine.pinchChanged(scale: exp(lnRaw(displayed: fr.s, cfg: cfg) - log(side0)), finger: finger)
        _ = engine.tick(time: fr.t)
        tiles.removeAll(keepingCapacity: true)
        engine.zoomTiles(into: &tiles)
        compare(fr, tiles, &report)
    }
    return report
}

/// The engine cross-fades two photos at this recorded tile: its colour is a mix of the two and
/// can match a third photo of the palette, so it is not a measurement of that photo.
private func isBlend(at o: [CGFloat], _ tiles: [Tile]) -> Bool {
    let here = tiles.filter { abs($0.x - o[1]) < 3 && abs($0.y - o[2]) < 3 }
    return here.count >= 2 && here.contains { $0.alpha > 0.005 && $0.alpha < 0.995 }
}

/// Debug hook: sees every replayed frame with the engine's tiles.
var replayTrace: ((Fixture.Frame, [Tile]) -> Void)?

private func compare(_ fr: Fixture.Frame, _ tiles: [Tile], _ report: inout ReplayReport) {
    replayTrace?(fr, tiles)
    var byPhoto: [Int: [Tile]] = [:]
    for t in tiles where t.alpha > 0.02 { byPhoto[t.photo, default: []].append(t) }
    var errs: [CGFloat] = []
    var worst: CGFloat = 0, worstPhoto = -1
    var dxs: [CGFloat] = [], dys: [CGFloat] = []
    for o in fr.tiles {
        let g = Int(o[0])
        guard let cands = byPhoto[g] else { report.unmatched += 1; continue }
        let best = cands.min { hypot($0.x - o[1], $0.y - o[2]) < hypot($1.x - o[1], $1.y - o[2]) }!
        let e = hypot(best.x - o[1], best.y - o[2])
        if e > 10 && isBlend(at: o, tiles) { report.unmatched += 1; continue }
        dxs.append(best.x - o[1]); dys.append(best.y - o[2])
        errs.append(e)
        if e > worst { worst = e; worstPhoto = g }
    }
    guard !errs.isEmpty else { return }
    let sorted = errs.sorted()
    report.frames.append(.init(t: fr.t, s: fr.s, n: errs.count, median: sorted[sorted.count / 2],
                               worst: worst, worstPhoto: worstPhoto,
                               dx: dxs.sorted()[dxs.count / 2], dy: dys.sorted()[dys.count / 2]))
    report.errors += errs
}

import CoreGraphics
import Foundation

/// Geometry and the constants measured from the Photos app (see FINDINGS.md).
struct GridConfig {
    var width: CGFloat
    var height: CGFloat
    var scale: CGFloat
    var insetTop: CGFloat
    var insetBottom: CGFloat
    var count: Int

    /// Column counts the zoom settles on, densest first. Level index = position here.
    /// Measured on a phone in portrait: 5 / 3 / 1. Wider views (landscape, iPad, Mac windows)
    /// keep the three levels at about the same tile sizes (`columns(forWidth:)`).
    var columns: [Int] = [5, 3, 1]

    /// The three levels for a width: 5 / 3 / 1 up to a large phone, then as many columns as keep
    /// the tiles about as big as the phone's (80 / 134 / 402 pt).
    static func columns(forWidth w: CGFloat) -> [Int] {
        guard w > 500 else { return [5, 3, 1] }
        let one = max(1, Int((w / 402).rounded()))
        let three = max(one + 1, Int((w / 134).rounded()))
        let five = max(three + 1, Int((w / 80.4).rounded()))
        return [five, three, one]
    }

    // MARK: measured constants

    static let gapPixelsAt3x: CGFloat = 5
    static let cornerRadius: CGFloat = 2.5
    /// Direction-latched layer switch thresholds, as log-fractions between adjacent rest sides.
    static let upFraction: [CGFloat] = [0.118, 0.423]     // 5→3, 3→1 (while zooming in)
    static let downFraction: [CGFloat] = [0.931, 0.893]   // 3→5, 1→3 (while zooming out)
    /// Cross-fade progress rate: base + gain·|d ln(side)/dt| per second; layer alpha = progress².
    static let fadeBase: CGFloat = 1.0
    static let fadeGain: CGFloat = 0.9
    /// Rubber band below the 5-column side (log space).
    static let rubberC: CGFloat = 0.467
    static let rubberDepth: CGFloat = 0.0566
    /// Hard limit above the 1-column side.
    static let maxSideFactor: CGFloat = 1.2214
    /// Critically damped settle spring on ln(raw side).
    static let springOmega: CGFloat = 12
    /// How far a release velocity is projected when deciding the final layer.
    static let releaseProjection: CGFloat = 0.08

    var gap: CGFloat { max(1, (Self.gapPixelsAt3x * scale / 3).rounded()) / scale }
    var levels: Int { columns.count }

    func side(_ level: Int) -> CGFloat {
        let n = CGFloat(columns[level])
        return floor((width - gap * (n - 1)) / n * scale) / scale
    }

    func pitch(_ level: Int) -> CGFloat { side(level) + gap }

    /// Side above which zooming in latches level+1.
    func up(_ level: Int) -> CGFloat {
        side(level) * pow(side(level + 1) / side(level), Self.upFraction[level])
    }

    /// Side below which zooming out latches `level` again (coming from level+1).
    func down(_ level: Int) -> CGFloat {
        side(level) * pow(side(level + 1) / side(level), Self.downFraction[level])
    }

    var minSide: CGFloat { side(0) }
    var maxSide: CGFloat { side(levels - 1) * Self.maxSideFactor }

    // MARK: resting layout

    func rows(level: Int, phase: Int) -> Int {
        let n = columns[level]
        return (count + phase + n - 1) / n
    }

    func contentHeight(level: Int, phase: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(rows(level: level, phase: phase)) * pitch(level) - gap
    }

    func maxOffset(level: Int, phase: Int) -> CGFloat {
        max(0, contentHeight(level: level, phase: phase) + insetTop + insetBottom - height)
    }

    /// Phase that makes the last row full.
    func bottomPhase(_ level: Int) -> Int {
        let n = columns[level]
        return (n - count % n) % n
    }

    func cell(of index: Int, level: Int, phase: Int) -> (col: Int, row: Int) {
        let n = columns[level]
        let k = index + phase
        return (k % n, k / n)
    }

    /// Displayed side for a raw (finger-driven) side: rubber band below, hard stop above.
    func displaySide(lnRaw: CGFloat) -> CGFloat {
        let raw = exp(lnRaw)
        if raw < minSide {
            let u = log(minSide / raw)
            let d = Self.rubberDepth
            return minSide * exp(-d * (1 - 1 / (Self.rubberC * u / d + 1)))
        }
        return min(raw, maxSide)
    }
}

struct RestState: Equatable {
    var level: Int
    var phase: Int
    /// Scroll offset: content y shown at the top inset line.
    var offset: CGFloat
}

@inline(__always) func clampf(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
@inline(__always) func posmod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }

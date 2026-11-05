import Foundation

enum ImageDecodeLimits {
    /// The intermediate image must fit a pixel budget, even for extremely long images.
    static func maximumPixel(width: Double, height: Double, shortSide: Double) -> Double {
        guard width > 0, height > 0, shortSide > 0 else { return 1 }
        let ratio = max(width, height) / min(width, height)
        return min(max(width, height), shortSide * ratio, 8192, sqrt(4_000_000 * ratio))
    }
}

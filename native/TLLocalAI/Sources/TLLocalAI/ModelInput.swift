import AVFoundation
import CoreImage
import Foundation
import ImageIO

/// Pictures for a vision model and its answers, the same for every app that runs one.
public enum ModelInput {
    /// Downsampled still for a photo, or a representative frame (a third in) for a video.
    public static func stillImage(path: String, kind: String) -> CIImage? {
        let url = URL(fileURLWithPath: path)
        if kind == "video" {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 896, height: 896)
            let dur = CMTimeGetSeconds(asset.duration)
            let t = CMTime(seconds: dur.isFinite && dur > 1 ? dur * 0.33 : 0, preferredTimescale: 600)
            return (try? gen.copyCGImage(at: t, actualTime: nil)).map { fitForModel(CIImage(cgImage: $0)) }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 896,
              ] as CFDictionary) else { return nil }
        return fitForModel(CIImage(cgImage: cg))
    }

    /// Vision models cut the picture into 28–32 px patches after scaling it into 448 × 448: a
    /// very thin strip (e.g. 22 × 900) or a tiny icon came out narrower than one patch and the
    /// model refused it ("Width: 22 must be larger than factor: 32"). Pads the short side with
    /// black up to a quarter of the long side and scales tiny images up, so every image fits.
    public static func fitForModel(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width >= 1, e.height >= 1, e.width.isFinite, e.height.isFinite else { return image }
        var img = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        var w = e.width, h = e.height
        let minSide: CGFloat = 112
        if min(w, h) < minSide {
            let k = min(minSide / min(w, h), 896 / max(w, h))
            if k > 1 { img = img.transformed(by: CGAffineTransform(scaleX: k, y: k)); w *= k; h *= k }
        }
        let W = max(w, (h / 4).rounded(.up)), H = max(h, (w / 4).rounded(.up))
        guard W > w || H > h else { return img }
        let canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        return img.transformed(by: CGAffineTransform(translationX: ((W - w) / 2).rounded(), y: ((H - h) / 2).rounded())).composited(over: canvas)
    }

    /// Accepts a JSON array or, failing that, a delimited list; normalizes and de-duplicates.
    public static func parseTags(_ raw: String) -> [String] {
        var text = raw
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        var items: [String] = []
        if let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b,
           let arr = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [Any] {
            items = arr.compactMap { $0 as? String }
        } else {
            items = text.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n#")).map { $0 }   // i18n-exempt: characters the parser recognizes, not text
        }
        var seen = Set<String>()
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”[]()（）。."))).lowercased() }   // i18n-exempt: characters the parser recognizes, not text
            .filter { !$0.isEmpty && $0.count <= 12 && seen.insert($0).inserted }
            .prefix(12).map { $0 }
    }
}

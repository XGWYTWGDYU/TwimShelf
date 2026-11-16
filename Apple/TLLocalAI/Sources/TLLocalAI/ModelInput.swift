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

    /// Why a reply gave no tags: not a list of tags (or pieces of its syntax as tags), or none.
    public enum TagsError: Error, Equatable { case notTags, noTags }

    /// A model's reply as tags, by the rules every app shares (scripts/checks/ai_tags/cases.json):
    /// a JSON array of strings (after a reasoning block or inside a code fence), or, from a reply
    /// with no JSON in it at all, a list split at commas and the like. Anything else, or a tag that
    /// is a piece of the reply's syntax (`}`, `harley }`), refuses the whole reply (`notTags`): a
    /// model saying that is not working, and its other words are no better. An empty list is
    /// `noTags`. Either way the analysis failed, and nothing is written.
    public static func parseTags(_ raw: String) throws -> [String] {
        var text = raw
        if let r = text.range(of: "</think>", options: .backwards) { text = String(text[r.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? ""
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("```") { text.removeLast(3) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var items: [String]
        let a = text.firstIndex(of: "["), b = text.lastIndex(of: "]")
        if a != nil || b != nil {
            guard let a, let b, a < b else { throw TagsError.notTags }
            let outside = String(text[..<a]) + String(text[text.index(after: b)...])
            if outside.contains(where: { "[]{}".contains($0) }) { throw TagsError.notTags }
            guard let list = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [Any] else { throw TagsError.notTags }
            let strings = list.compactMap { $0 as? String }
            if strings.count != list.count { throw TagsError.notTags }
            items = strings
        } else {
            if text.contains(where: { "{}:\"".contains($0) }) { throw TagsError.notTags }
            items = text.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n#"))   // i18n-exempt: characters the parser recognizes, not text
        }
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”[]()（）。."))   // i18n-exempt: characters the parser recognizes, not text
        var seen = Set<String>(), result: [String] = []
        for item in items {
            let clean = item.trimmingCharacters(in: edges).lowercased()
            if clean.isEmpty { continue }
            let fragment = clean.unicodeScalars.contains { "{}[]<>:\"\\`".unicodeScalars.contains($0) || $0.properties.generalCategory == .control }
            let punctuation = clean.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.punctuationCharacters.union(.symbols).contains($0)) || CharacterSet.whitespaces.contains($0) }
            if fragment || punctuation { throw TagsError.notTags }
            if clean.count <= 12 && seen.insert(clean).inserted { result.append(clean) }
            if result.count == 12 { break }
        }
        if result.isEmpty { throw TagsError.noTags }
        return result
    }
}

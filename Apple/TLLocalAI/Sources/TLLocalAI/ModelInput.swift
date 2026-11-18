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
    /// a list in brackets (after a reasoning block, inside a code fence or a `{"tags": …}`, cut off
    /// by the length limit, with single quotes), or, from a reply with no brackets at all, a list
    /// split at commas and the like. What is no tag in a good list (`}`, a number) is left out. A
    /// reply that is no list, or holds nothing but such pieces, is `notTags`; an empty list is
    /// `noTags`. Either way the analysis failed, and nothing is written.
    public static func parseTags(_ raw: String) throws -> [String] {
        var text = try withoutThinking(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? ""
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("```") { text.removeLast(3) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var items: [String]
        let a = text.firstIndex(of: "["), b = text.lastIndex(of: "]")
        if a != nil || b != nil {
            guard let a, b == nil || a < b! else { throw TagsError.notTags }
            let before = text[..<a].trimmingCharacters(in: .whitespacesAndNewlines)
            let after = b.map { text[text.index(after: $0)...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let wrapped = before.hasPrefix("{") && !before.dropFirst().contains { "[]{}".contains($0) } && (after == "}" || b == nil)
            if !wrapped && (before + after).contains(where: { "[]{}".contains($0) }) { throw TagsError.notTags }
            items = try listItems(Array(text[text.index(after: a)..<(b ?? text.endIndex)]), cutOff: b == nil)
        } else {
            if text.range(of: thinkingAloud, options: [.regularExpression, .caseInsensitive]) != nil { throw TagsError.notTags }
            if let r = text.range(of: #"^[^,，、;；\n:：{}"]{1,24}[:：]\s*"#, options: .regularExpression) { text.removeSubrange(r) }   // i18n-exempt: characters the parser recognizes
            if text.contains(where: { "{}:\"".contains($0) }) { throw TagsError.notTags }
            items = text.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n#"))   // i18n-exempt: characters the parser recognizes, not text
        }
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”[]()（）。."))   // i18n-exempt: characters the parser recognizes, not text
        var seen = Set<String>(), result: [String] = [], pieces = false
        for item in items {
            let clean = item.trimmingCharacters(in: edges).lowercased()
            if clean.isEmpty { continue }
            let fragment = clean.unicodeScalars.contains { "{}[]<>:\"\\`".unicodeScalars.contains($0) || $0.properties.generalCategory == .control }
            let punctuation = clean.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.punctuationCharacters.union(.symbols).contains($0)) || CharacterSet.whitespaces.contains($0) }
            if fragment || punctuation { pieces = true; continue }
            if clean.count <= 12 && seen.insert(clean).inserted { result.append(clean) }
            if result.count == 12 { break }
        }
        if result.isEmpty { throw pieces ? TagsError.notTags : TagsError.noTags }
        return result
    }

    /// How models mark their reasoning, and a plain reply that is reasoning without any mark.
    private static let thinkingEnds = ["</think>", "</thinking>", "</reasoning>", "</reason>", "[/think]", "◁/think▷", "</seed:think>", "<channel|>", "<|end_of_thought|>", "<|channel|>final<|message|>"]   // i18n-exempt: model syntax
    private static let thinkingStarts = ["<think>", "<thinking>", "<reasoning>", "<reason>", "[think]", "◁think▷", "<seed:think>", "<|channel>thought", "<|channel|>analysis", "<|begin_of_thought|>"]   // i18n-exempt: model syntax
    private static let thinkingAloud = #"^((thinking process|thinking|thoughts?|reasoning|analysis)\s*[:：]|let me|let's|okay,|ok,|hmm|the user|the image|this image|思考|嗯|好的|首先|用户)"#   // i18n-exempt: model syntax

    /// What follows the model's reasoning. Reasoning that never ended (the length limit) is no answer.
    private static func withoutThinking(_ raw: String) throws -> String {
        var text = raw
        for end in thinkingEnds {
            if let r = text.range(of: end, options: [.backwards, .caseInsensitive]) { text = String(text[r.upperBound...]) }
        }
        if thinkingStarts.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) { throw TagsError.notTags }
        return text
    }

    /// The entries between a list's brackets. `cutOff`: the reply stopped inside the list, and
    /// what it was still writing is left out.
    private static func listItems(_ c: [Character], cutOff: Bool) throws -> [String] {
        var items: [String] = [], i = 0
        scan: while i < c.count {
            if c[i] == "," || c[i].isWhitespace { i += 1; continue }
            let closers: [Character: Character] = ["\"": "\"", "'": "'", "“": "”", "‘": "’"]
            if let close = closers[c[i]] {
                var word = "", j = i + 1, closed = false
                while j < c.count {
                    if c[j] == "\\", j + 1 < c.count {
                        switch c[j + 1] {
                        case "n", "t", "r": word.append(" "); j += 2
                        case "u":
                            guard j + 5 < c.count, let v = UInt32(String(c[(j + 2)...(j + 5)]), radix: 16) else { throw TagsError.notTags }
                            if let u = Unicode.Scalar(v) { word.unicodeScalars.append(u) }
                            j += 6
                        default: word.append(c[j + 1]); j += 2
                        }
                        continue
                    }
                    if c[j] == close {
                        // an apostrophe inside a word in single quotes (dog's) is not the end
                        var k = j + 1
                        while k < c.count, c[k].isWhitespace { k += 1 }
                        if close != "'" || k >= c.count || c[k] == "," { closed = true; j += 1; break }
                    }
                    word.append(c[j]); j += 1
                }
                guard closed else { break scan }
                items.append(word); i = j
            } else {
                var j = i
                while j < c.count, c[j] != "," { j += 1 }
                let word = String(c[i..<j]).trimmingCharacters(in: .whitespacesAndNewlines)
                if word.contains(where: { "[]{}".contains($0) }) { throw TagsError.notTags }
                if !(cutOff && j == c.count), Double(word) == nil, !["null", "true", "false"].contains(word) { items.append(word) }
                i = j
            }
        }
        return items
    }
}

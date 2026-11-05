import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
typealias MascotImage = UIImage
#else
import AppKit
typealias MascotImage = NSImage
#endif

/// 使用 Claude Code 吉祥物: the mode's switch, its icons (drawn from `ClawdIconData`, see
/// scripts/gen_icons.py) and the little Clawd's engine (core/src/pet.rs).
enum Mascot {
    static let changed = Notification.Name("mascotChanged")
    static let key = "mascot.enabled"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// A window big enough to have room for the little Clawd: not a phone, not a narrowed window.
    static func petFits(_ s: CGSize) -> Bool { s.width >= 700 && s.height >= 500 }

    /// The mode's icon for a place, if it has one.
    static func name(for place: LibraryPlace) -> String? {
        switch place {
        case .browse: "home"
        case .photos: "image"
        case .videos: "video"
        case .allFolders, .folder: "folder"
        case .settings: "settings"
        default: nil
        }
    }

    /// The mode's icon for a kind of device, if it has one.
    static func name(forDevice symbol: String) -> String? {
        switch symbol {
        case "iphone": "mobile"
        case "laptopcomputer", "desktopcomputer": "laptop"
        default: nil
        }
    }

    private static var paths: [String: CGPath] = [:]
    private static func path(_ d: String) -> CGPath {
        if let p = paths[d] { return p }
        let t = d.split(separator: " ")
        let p = CGMutablePath()
        var i = 0
        func n(_ k: Int) -> CGFloat { CGFloat(Double(t[i + k]) ?? 0) }
        while i < t.count {
            switch t[i] {
            case "M": p.move(to: CGPoint(x: n(1), y: n(2))); i += 3
            case "L": p.addLine(to: CGPoint(x: n(1), y: n(2))); i += 3
            case "C": p.addCurve(to: CGPoint(x: n(5), y: n(6)), control1: CGPoint(x: n(1), y: n(2)), control2: CGPoint(x: n(3), y: n(4))); i += 7
            default: p.closeSubpath(); i += 1
            }
        }
        paths[d] = p
        return p
    }

    /// Draws an icon into a context whose origin is at the top left, in a square of `side`.
    private static func draw(_ name: String, side: CGFloat, foreground: CGColor, in c: CGContext) {
        c.scaleBy(x: side / 24, y: side / 24)
        c.setLineWidth(0.7)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        for op in ClawdIconData.icons[name] ?? [] {
            c.addPath(path(op.d))
            if op.stroke {
                c.setStrokeColor(foreground)
                c.strokePath()
            } else if let f = op.fill {
                c.setFillColor(rgba(0xFF00_0000 | f))
                c.fillPath()
            } else {
                c.setFillColor(foreground)
                c.fillPath()
            }
        }
    }

    static func rgba(_ argb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((argb >> 16) & 255) / 255, green: CGFloat((argb >> 8) & 255) / 255,
                blue: CGFloat(argb & 255) / 255, alpha: CGFloat(argb >> 24) / 255)
    }

    /// An icon as an image, redrawn for each appearance: the crab in its own colours, the object it
    /// holds in the label colour. Never a template: tints would flatten the crab.
    static func icon(_ name: String, side: CGFloat) -> MascotImage {
        #if canImport(UIKit)
        func render(_ traits: UITraitCollection) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { r in
                draw(name, side: side, foreground: UIColor.label.resolvedColor(with: traits).cgColor, in: r.cgContext)
            }
        }
        let light = UITraitCollection(userInterfaceStyle: .light), dark = UITraitCollection(userInterfaceStyle: .dark)
        let image = render(light).withRenderingMode(.alwaysOriginal)
        image.imageAsset?.register(render(dark).withRenderingMode(.alwaysOriginal), with: dark)
        return image
        #else
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            draw(name, side: side, foreground: NSColor.labelColor.cgColor, in: c)
            return true
        }
        image.isTemplate = false
        return image
        #endif
    }

    /// The license of the icons, quoted as written.
    static let license = """
    Clawd Icons
    https://github.com/TangfanOVO/clawd-icons

    MIT License

    Copyright (c) 2026 唐幡 (TangfanOVO)
    Copyright (c) 2026 Marcio Granzotto Rodrigues (Clawd base artwork)

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

/// The little Clawd of core/src/pet.rs: a view paints its rectangles and passes on the pointer and
/// the taps. Top-left coordinates.
final class PetEngine {
    struct Rect { let frame: CGRect; let color: CGColor }
    private let handle = tl_pet_new(UInt64.random(in: 1...UInt64.max))
    private let capacity = 400
    private let buffer: UnsafeMutablePointer<Double>
    private var last: [Double] = []

    init() { buffer = .allocate(capacity: capacity * 5) }
    deinit { tl_pet_free(handle); buffer.deallocate() }

    func setBounds(_ size: CGSize, margin: CGFloat) { tl_pet_set_bounds(handle, size.width, size.height, margin, margin) }
    func pointer(_ p: CGPoint) { tl_pet_pointer(handle, p.x, p.y) }
    func pointerGone() { tl_pet_pointer_gone(handle) }
    func hit(_ p: CGPoint) -> Bool { tl_pet_hit(handle, p.x, p.y) }
    func tap(_ p: CGPoint) { _ = tl_pet_tap(handle, p.x, p.y) }

    /// Advances; true when the picture changed. `dirty` is what a view has to redraw then.
    func tick(_ dt: Double) -> (changed: Bool, dirty: CGRect) {
        let n = min(Int(tl_pet_tick(handle, dt, buffer, UInt64(capacity))), capacity) * 5
        let now = Array(UnsafeBufferPointer(start: buffer, count: n))
        if now == last { return (false, .null) }
        let dirty = Self.bounds(last).union(Self.bounds(now)).insetBy(dx: -2, dy: -2)
        last = now
        return (true, dirty)
    }

    func draw(in c: CGContext) {
        var i = 0
        while i + 4 < last.count {
            c.setFillColor(Mascot.rgba(UInt32(last[i + 4])))
            c.fill(CGRect(x: last[i], y: last[i + 1], width: last[i + 2], height: last[i + 3]))
            i += 5
        }
    }

    private static func bounds(_ p: [Double]) -> CGRect {
        var r = CGRect.null
        var i = 0
        while i + 4 < p.count { r = r.union(CGRect(x: p[i], y: p[i + 1], width: p[i + 2], height: p[i + 3])); i += 5 }
        return r
    }
}

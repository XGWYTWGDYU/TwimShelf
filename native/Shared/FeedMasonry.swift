import CoreGraphics

/// Where the cards of the 浏览 grid go now that every card is as tall as its content: columns of
/// equal width, each card placed in the shortest column (the order reads left to right, top to
/// bottom, as before), with no gaps under short cards. Shared by the iOS and Mac
/// collection layouts; plain geometry, no UI.
struct FeedMasonry {
    struct Metrics: Equatable {
        var width: CGFloat
        var columns: Int
        var side: CGFloat
        var columnGap: CGFloat
        var rowGap: CGFloat
        var top: CGFloat = 0
        var footer: CGFloat
        var columnWidth: CGFloat { columns > 0 ? floor((width - side * 2 - CGFloat(columns - 1) * columnGap) / CGFloat(columns)) : 0 }
    }

    let metrics: Metrics
    /// Frames of one pass's cards, relative to the top of the pass.
    private(set) var frames: [CGRect] = []
    /// Indices of `frames` ordered by their top edge, for finding what a rectangle shows.
    private var byTop: [Int] = []
    private var tallest: CGFloat = 0
    /// The column of each card, and where each column ends.
    private var columnOf: [Int] = []
    private var bottoms: [CGFloat] = []
    /// One pass: its cards, then the footer under the tallest column.
    private(set) var passHeight: CGFloat = 0

    /// `height(i, columnWidth)`: how tall card `i` is at that width.
    init(count: Int, metrics m: Metrics, height: (Int, CGFloat) -> CGFloat) {
        metrics = m
        guard count > 0, m.columns > 0 else { return }
        let w = m.columnWidth
        bottoms = [CGFloat](repeating: 0, count: m.columns)
        frames.reserveCapacity(count)
        columnOf.reserveCapacity(count)
        for i in 0..<count {
            // the shortest column (the leftmost of equals)
            var c = 0
            for k in 1..<m.columns where bottoms[k] < bottoms[c] - 0.5 { c = k }
            let h = max(1, height(i, w).rounded(.up))
            let y = bottoms[c] == 0 ? 0 : bottoms[c] + m.rowGap
            frames.append(CGRect(x: m.side + CGFloat(c) * (w + m.columnGap), y: y, width: w, height: h))
            columnOf.append(c)
            bottoms[c] = y + h
            tallest = max(tallest, h)
        }
        byTop = frames.indices.sorted { frames[$0].minY < frames[$1].minY }
        passHeight = (bottoms.max() ?? 0) + m.footer
    }

    /// A card grows or shrinks while its pages are turned: everything stays in its column and the
    /// cards under it move along, so nothing jumps to another column under the finger. Called once
    /// per frame while that goes on. Returns how much the pass grew (what comes after it moves).
    @discardableResult
    mutating func resize(item i: Int, height: CGFloat) -> CGFloat {
        guard frames.indices.contains(i) else { return 0 }
        let d = max(1, height) - frames[i].height
        guard abs(d) > 0.01 else { return 0 }
        frames[i].size.height += d
        let c = columnOf[i]
        for k in (i + 1)..<max(i + 1, frames.count) where columnOf[k] == c { frames[k].origin.y += d }
        bottoms[c] += d
        tallest = max(tallest, frames[i].height)
        // nearly in order still: one insertion pass
        for a in byTop.indices.dropFirst() {
            var b = a
            let v = byTop[b]
            while b > 0, frames[byTop[b - 1]].minY > frames[v].minY { byTop[b] = byTop[b - 1]; b -= 1 }
            byTop[b] = v
        }
        let before = passHeight
        passHeight = (bottoms.max() ?? 0) + metrics.footer
        return passHeight - before
    }

    /// Where pass `s` starts.
    func passTop(_ s: Int) -> CGFloat { metrics.top + CGFloat(s) * passHeight }

    func frame(item: Int, pass: Int) -> CGRect { frames[item].offsetBy(dx: 0, dy: passTop(pass)) }

    func footerFrame(pass: Int) -> CGRect {
        CGRect(x: 0, y: passTop(pass) + passHeight - metrics.footer, width: metrics.width, height: metrics.footer)
    }

    func contentHeight(passes: Int) -> CGFloat { passes > 0 ? passTop(passes) : 0 }

    /// The cards (pass, item) and footers (pass) that a rectangle shows.
    func elements(in rect: CGRect, passes: Int) -> (items: [(pass: Int, item: Int)], footers: [Int]) {
        guard passHeight > 0, passes > 0 else { return ([], []) }
        var items: [(Int, Int)] = []
        var footers: [Int] = []
        let first = max(0, Int(((rect.minY - metrics.top) / passHeight).rounded(.down)))
        let last = min(passes - 1, Int(((rect.maxY - metrics.top) / passHeight).rounded(.down)))
        guard first <= last else { return ([], []) }
        for s in first...last {
            let top = passTop(s)
            let lo = rect.minY - top - tallest, hi = rect.maxY - top
            // the first card whose top could still reach into the rectangle
            var a = 0, b = byTop.count
            while a < b { let m = (a + b) / 2; if frames[byTop[m]].minY < lo { a = m + 1 } else { b = m } }
            var k = a
            while k < byTop.count, frames[byTop[k]].minY <= hi {
                let i = byTop[k]
                if frames[i].offsetBy(dx: 0, dy: top).intersects(rect) { items.append((s, i)) }
                k += 1
            }
            if footerFrame(pass: s).intersects(rect) { footers.append(s) }
        }
        return (items, footers)
    }
}

/// Card heights by entry, kept while the width and text size stay the same (measuring text is
/// the expensive part of laying out the grid).
final class CardHeightCache {
    private var heights: [String: CGFloat] = [:]
    private var width: CGFloat = -1
    private var sizeKey = ""

    /// Forgets everything when the column width or the text size changed.
    func prepare(width w: CGFloat, sizeKey k: String) {
        if abs(w - width) > 0.5 || k != sizeKey { heights.removeAll(keepingCapacity: true); width = w; sizeKey = k }
    }

    func height(_ key: String, _ make: () -> CGFloat) -> CGFloat {
        if let h = heights[key] { return h }
        let h = make()
        heights[key] = h
        return h
    }

    func removeAll() { heights.removeAll() }
}

extension FeedItem {
    /// What decides how tall a card is (author, text, link, loose), for `CardHeightCache` keys.
    var cardContentKey: Int {
        var h = Hasher()
        h.combine(text); h.combine(authorName); h.combine(screenName); h.combine(url); h.combine(isLoose)
        return h.finalize()
    }

    /// A card's media, height per unit of width: the media's own shape, so no bands around it (a
    /// card follows the page it shows). A very long or very wide one stays within reason and is
    /// fitted; 4:5 until its size is known.
    var cardMediaRatio: CGFloat {
        guard width > 0, height > 0 else { return 1.25 }
        return min(max(CGFloat(height) / CGFloat(width), 0.3), 1.8)
    }
}

/// The page each card of 浏览 was left on, by entry: a card that scrolled away comes back on it,
/// and its height follows.
struct CardPages {
    private var pages: [String: Int] = [:]
    mutating func set(_ page: Int, for key: String) { pages[key] = page == 0 ? nil : page }
    func page(of key: String, count: Int) -> Int { min(max(pages[key] ?? 0, 0), max(count - 1, 0)) }
}

/// A card's media height at a place between two pages (`position` 1.5: halfway from the second
/// page to the third).
func cardMediaHeight(_ items: [FeedItem], width: CGFloat, position: CGFloat) -> CGFloat {
    guard !items.isEmpty else { return width * 1.25 }
    let p = min(max(position, 0), CGFloat(items.count - 1))
    let a = Int(p.rounded(.down)), b = min(a + 1, items.count - 1)
    let ha = ceil(width * items[a].cardMediaRatio), hb = ceil(width * items[b].cardMediaRatio)
    return ha + (hb - ha) * (p - CGFloat(a))
}

/// A feed read while the core was still reading the media's sizes in the background shows them
/// once that has finished (first run after an update: until then the cards are 4:5).
@MainActor
final class MediaSizesWatcher {
    private var done = false

    func watch(_ items: [FeedItem], reload: @escaping @MainActor () -> Void) {
        guard !done, items.contains(where: { $0.width == 0 }) else { return }
        done = true
        Task { @MainActor in
            while Core.mediaSizesFilling { try? await Task.sleep(for: .seconds(2)) }
            reload()
        }
    }
}

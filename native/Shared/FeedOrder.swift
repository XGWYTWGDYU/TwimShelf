import Foundation

/// Random feed order drawn from the system's cryptographic random number generator
/// (`SystemRandomNumberGenerator`, i.e. arc4random). Each media gets a random rank the first
/// time it is seen and keeps it until the next reshuffle, so the order stays put while you tag,
/// delete or sync, and media that arrive later land at random positions.
struct FeedOrder {
    private var rank: [String: UInt64] = [:]
    private var rng = SystemRandomNumberGenerator()

    mutating func reshuffle() { rank.removeAll(keepingCapacity: true) }

    /// Posts in the order of `items` (which the core already put in order), each post's media in
    /// their order: the feed by when things were added.
    static func postsInPlace(_ items: [FeedItem]) -> [[FeedItem]] {
        var order: [String] = []
        var by: [String: [FeedItem]] = [:]
        for it in items {
            if by[it.postId] == nil { order.append(it.postId) }
            by[it.postId, default: []].append(it)
        }
        return order.map { by[$0]!.sorted { $0.ordinal < $1.ordinal } }
    }

    /// Posts, each with exactly one random rank (its own draw, never "the best of its media":
    /// that favoured posts with many media near the top), each post's media in their order.
    /// Nothing about the content (text, ids, hashes, dates) enters the order.
    mutating func posts(_ items: [FeedItem]) -> [[FeedItem]] {
        var by: [String: [FeedItem]] = [:]
        for it in items { by[it.postId, default: []].append(it) }
        var keyed: [(UInt64, [FeedItem])] = []
        keyed.reserveCapacity(by.count)
        for (post, media) in by {
            let k = "post:" + post
            let r: UInt64
            if let v = rank[k] { r = v } else { r = rng.next(); rank[k] = r }
            keyed.append((r, media.sorted { $0.ordinal < $1.ordinal }))
        }
        keyed.sort { $0.0 < $1.0 }
        return keyed.map(\.1)
    }

    mutating func apply(_ items: [FeedItem]) -> [FeedItem] {
        var keyed: [(UInt64, FeedItem)] = []
        keyed.reserveCapacity(items.count)
        for it in items {
            let r: UInt64
            if let v = rank[it.mediaId] { r = v } else { r = rng.next(); rank[it.mediaId] = r }
            keyed.append((r, it))
        }
        keyed.sort { $0.0 < $1.0 }
        return keyed.map(\.1)
    }
}

/// Library-wide view preferences shared by iOS and macOS.
enum LibraryPrefs {
    static let changed = Notification.Name("LibraryPrefsChanged")

    /// What ten taps on the icon in 关于 bring out stays out until ten more put it away: the
    /// maintenance rows there, and 损坏或丢失 wherever it is offered.
    static var aboutExtras: Bool {
        get { UserDefaults.standard.bool(forKey: "about.extras") }
        set {
            UserDefaults.standard.set(newValue, forKey: "about.extras")
            if !newValue { UserDefaults.standard.set(false, forKey: "filter.bad") }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// 浏览 by when things were added, newest first, instead of at random.
    static var feedByAdded: Bool {
        get { UserDefaults.standard.bool(forKey: "feed.sortByAdded") }
        set { UserDefaults.standard.set(newValue, forKey: "feed.sortByAdded") }
    }

    /// How many cards a row of 浏览 holds on a large screen, as a rough level for each
    /// orientation (0 fewer, 1 medium, 2 more): the exact count follows the width.
    static var cardDensityPortrait: Int {
        get { UserDefaults.standard.object(forKey: "feed.density.portrait") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "feed.density.portrait"); NotificationCenter.default.post(name: changed, object: nil) }
    }
    static var cardDensityLandscape: Int {
        get { UserDefaults.standard.object(forKey: "feed.density.landscape") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "feed.density.landscape"); NotificationCenter.default.post(name: changed, object: nil) }
    }
    static let densityNames = [L("cards.fewer"), L("cards.medium"), L("cards.more")]

    /// The columns of 浏览 for a width: one card per `base` points at 适中, wider cards at 少,
    /// narrower at 多 (the window's shape picks the portrait or the landscape level).
    static func feedColumns(width: CGFloat, height: CGFloat, base: CGFloat, maxColumns: Int) -> Int {
        let level = width > height ? cardDensityLandscape : cardDensityPortrait
        let per = base * [1.35, 1.0, 0.72][min(max(level, 0), 2)]
        return max(1, min(maxColumns + (level == 2 ? 2 : 0), Int(width / per)))
    }

    static var badOnly: Bool {
        get { aboutExtras && UserDefaults.standard.bool(forKey: "filter.bad") }
        set { UserDefaults.standard.set(newValue, forKey: "filter.bad"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Settings of features that are gone (整理 mode): removed from this device at every launch.
    /// The list only grows and costs one lookup per key, so a device that skips versions (or
    /// comes back years later) is cleaned the same way.
    static func removeRetired() {
        for k in ["triage.mode", "triage.filter", "triage.recentFolders", "home.backdrop"] { UserDefaults.standard.removeObject(forKey: k) }
    }

    /// 视频禁用手势: the player leaves out the drags for seeking, volume and brightness (long press for
    /// speed and double tap for pause stay). Swiping sideways then turns to the next photo or video
    /// of the list, and dragging down closes the player, as in the photo viewer.
    static var playerGesturesOff: Bool {
        get { UserDefaults.standard.bool(forKey: "player.noGestures") }
        set { UserDefaults.standard.set(newValue, forKey: "player.noGestures") }
    }

    static var autoLandscape: Bool {
        get { UserDefaults.standard.bool(forKey: "player.autoLandscape") }
        set { UserDefaults.standard.set(newValue, forKey: "player.autoLandscape") }
    }

    /// Semantic / substring matching for search terms (Settings → 搜索). On by default, but only
    /// in effect (and only switchable) once a semantic search model is installed and chosen.
    static var fuzzySearch: Bool {
        get { semanticSearchAvailable && (UserDefaults.standard.object(forKey: "search.fuzzy") as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: "search.fuzzy"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// A semantic search (embedding) model is installed and selected.
    static var semanticSearchAvailable: Bool { ModelStore.shared.activeEmbedder != nil }
    static let semanticSearchNeedsModel = L("search.fuzzy.needsModel")

    static let keepChoices: [(days: Int, title: String)] = [(7, L("trash.keep.7")), (30, L("trash.keep.30")), (90, L("trash.keep.90")), (365, L("trash.keep.365")), (0, L("trash.neverShort"))]
    static func keepTitle(_ d: Int) -> String { keepChoices.first { $0.days == d }?.title ?? L("trash.keep.days", d) }
}


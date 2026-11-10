import Foundation

/// Which tags a search looks at: mine, the AI's, either ("both"), or both at once ("common").
enum SearchScope: String, Codable, CaseIterable { case mine, ai, both, common }
enum MediaKind: String, Codable { case photo, video }

/// `PackedFeed` of the core (core/src/library.rs): posts and tag lists once, media referring to
/// them by position.
struct PackedFeed: Decodable {
    struct Post: Decodable {
        let id: String
        let text: String?
        let authorName: String?
        let screenName: String?
        let url: String?
        let createdAt: String?
        let recent: Bool
        var album: Bool? = nil
    }
    /// [label, origin, models]
    struct Tag: Decodable {
        let view: TagView
        init(from d: Decoder) throws {
            var c = try d.unkeyedContainer()
            view = TagView(label: try c.decode(String.self), origin: try c.decode(UInt8.self), models: try c.decode([String].self))
        }
    }
    /// [media id, post, ordinal, kind, path below root, tag list, damage, width, height]
    struct Media: Decodable {
        let id: String, post: Int, ordinal: Int, kind: String, path: String, tags: Int, bad: String, width: Int, height: Int
        init(from d: Decoder) throws {
            var c = try d.unkeyedContainer()
            id = try c.decode(String.self); post = try c.decode(Int.self); ordinal = try c.decode(Int.self)
            kind = try c.decode(String.self); path = try c.decode(String.self); tags = try c.decode(Int.self); bad = try c.decode(String.self)
            width = try c.decode(Int.self); height = try c.decode(Int.self)
        }
    }
    let root: String
    let posts: [Post]
    let tagLists: [[Tag]]
    let media: [Media]

    var items: [FeedItem] {
        let lists = tagLists.map { $0.map(\.view) }
        return media.map { m in
            let p = posts[m.post]
            return FeedItem(mediaId: m.id, postId: p.id, ordinal: m.ordinal, kind: m.kind == "v" ? .video : .photo,
                            path: m.path.hasPrefix("/") ? m.path : root + m.path,
                            text: p.text, authorName: p.authorName, screenName: p.screenName, url: p.url,
                            tags: lists[m.tags], createdAt: p.createdAt, bad: m.bad.isEmpty ? nil : m.bad, recent: p.recent, album: p.album, width: m.width, height: m.height)
        }
    }
}

struct TagView: Codable, Hashable {
    let label: String
    let origin: UInt8
    /// AI models (folder ids) that proposed this tag.
    var models: [String] = []
    var isUser: Bool { origin & 1 != 0 }
    var isAI: Bool { origin & 2 != 0 }
}

struct FeedItem: Codable, Hashable {
    let mediaId: String
    let postId: String
    let ordinal: Int
    let kind: MediaKind
    let path: String
    let text: String?
    let authorName: String?
    let screenName: String?
    let url: String?
    var tags: [TagView]
    /// When the post was published, as its source wrote it (`PostDate` reads it).
    var createdAt: String? = nil
    /// Why the file is damaged ("missing", "hash", "decode"), when verification failed.
    var bad: String? = nil
    /// The post is "最近添加": batch-downloaded from a bookmarks JSON in the last 5 days.
    var recent: Bool? = nil
    var isRecent: Bool { recent ?? false }
    /// Brought in through a share extension (从相册导入).
    var album: Bool? = nil
    var isAlbum: Bool { album ?? false }
    /// Size as displayed, 0 until read from the file.
    var width = 0
    var height = 0
    var fileURL: URL { URL(fileURLWithPath: path) }
    /// A loose media: imported on its own, without a post (no text, author or link).
    var isLoose: Bool { postId.hasPrefix("loose:") }
    /// There is a post to download this media from again: its link, or an id that makes one.
    var canRedownload: Bool { url != nil || (!postId.isEmpty && postId.allSatisfy(\.isASCII) && postId.allSatisfy(\.isNumber)) }
    /// Value for the "only this author" filter: the @handle, or the display name without one.
    var authorKey: String? { screenName ?? authorName }
    var authorDisplay: String { screenName.map { "@\($0)" } ?? authorName ?? L("common.unknownAuthor") }
    var isReviewed: Bool { tags.contains { $0.isUser } }
    /// Badge text for a media that failed verification.
    var badText: String? {
        switch bad {
        case nil: nil
        case "not_media": kind == .video ? L("bad.notVideo") : L("bad.notPhoto")
        case "decode": L("bad.decode")
        case "missing": L("bad.missing")
        default: L("bad.damaged")
        }
    }
}

struct FolderOverview: Decodable, Equatable {
    struct Folder: Decodable, Hashable {
        let name: String
        let count: Int
        let videos: Int
        let coverId: String?
        let coverPath: String?
        let coverVideo: Bool
    }
    let folders: [Folder]
    let photos: Int
    let videos: Int
}

/// Reviewed = carries a tag you added or endorsed.
enum ReviewFilter: String, Codable { case any, unreviewed, reviewed }

/// Extra feed filters, all of which must hold.
struct FeedFilter: Codable, Equatable {
    var author: String? = nil
    var labels: [String] = []
    var review: ReviewFilter = .any
    var badOnly = false
    var folder: String? = nil
    var looseOnly = false
    /// Only media brought in through a share extension (从相册导入).
    var albumOnly = false
    /// Only "最近添加" posts.
    var recentOnly = false
    /// Only photos or only videos.
    var kind: MediaKind? = nil
    /// Words written with a minus: media containing any of them in a searched field are left out.
    var excludeTerms: [String] = []
    /// Which tag origins count (1 = only mine, 2 = only AI, 3 = both), when a scope has a minus.
    var origins: [UInt8]? = nil
    var excludeFolders: [String] = []
    var excludeRecent = false
    var excludeLoose = false
    var isEmpty: Bool { self == FeedFilter() }
}

struct FeedRequest: Encodable {
    var terms: [String] = []
    var scope: SearchScope = .both
    /// nil: the core keeps a stable order and the app shuffles with the system RNG.
    var seed: UInt64? = nil
    var newestFirst = false
    var fuzzy = true
    var termVectors: [[Float]?] = []
    var embedModel: String? = nil
    var threshold: Float = 0.55
    var fields = SearchFields.saved
    var filter = FeedFilter()
    /// Post cards: a post found through any of its media comes with all of them.
    var wholePosts = false
}

/// Which parts of a post a search term may match (any enabled field counts).
struct SearchFields: Codable, Equatable {
    var tags = true
    var text = false
    var author = false

    static var saved: SearchFields {
        get { (UserDefaults.standard.data(forKey: "search.fields")).flatMap { try? JSONDecoder().decode(SearchFields.self, from: $0) } ?? SearchFields() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "search.fields") }
    }

}

struct ImportIssue: Codable, Hashable {
    let category: String
    let path: String
    let reason: String
    let sameAs: String?
    var isFile: Bool { !category.hasPrefix("post_") }
    static func title(_ c: String) -> String {
        switch c {
        case "not_media": L("import.cat.not_media"); case "unsupported": L("import.cat.unsupported"); case "unreadable": L("import.cat.unreadable")
        case "duplicate": L("import.cat.duplicate"); case "in_bin": L("import.cat.in_bin"); case "ignored_location": L("import.cat.ignored_location")
        case "unsafe_path": L("import.cat.unsafe_path"); case "post_not_imported": L("import.cat.post_not_imported"); case "post_hidden": L("import.cat.post_hidden")
        case "post_merged": L("import.cat.post_merged"); case "post_text_truncated": L("import.cat.post_text_truncated"); default: L("sidebar.other")
        }
    }
    /// Display order of categories.
    static let order = ["not_media", "unsupported", "unreadable", "ignored_location", "unsafe_path", "duplicate", "in_bin", "post_not_imported", "post_hidden", "post_merged", "post_text_truncated"]
}

struct ImportReport: Codable {
    let posts: Int; let media: Int; let skipped: [String]
    var deleted: Int? = 0; var duplicateMedia: Int? = 0; var mergedPosts: Int? = 0; var postsWithoutMedia: Int? = 0
    var entries: Int? = 0; var systemFiles: Int? = 0; var sidecars: Int? = 0; var newMedia: Int? = 0; var folders: Int? = 0
    var issues: [ImportIssue]? = []
    var reportFile: String? = nil
    var source: String? = nil
    var folder: String? = nil
    var folderAdded: Int? = 0
    /// Backup restore: media put back into the bin, rename rules and empty folders restored.
    var toBin: Int? = 0; var renamesRestored: Int? = 0; var foldersRestored: Int? = 0
    /// Why it stopped short with something it can still do later: keep the source, try again.
    var incomplete: String? = nil

    /// Issues grouped by category, in display order.
    var grouped: [(category: String, items: [ImportIssue])] {
        let all = issues ?? []
        return ImportIssue.order.compactMap { c in let v = all.filter { $0.category == c }; return v.isEmpty ? nil : (c, v) }
    }

    /// Summary for alerts: what was read, what the library gained, and every kind of problem.
    var summary: String {
        var t = L("import.summary.read", entries ?? 0, sidecars ?? 0, systemFiles ?? 0)
        t += L("import.summary.added", posts - (mergedPosts ?? 0) - (postsWithoutMedia ?? 0), newMedia ?? media)
        for (c, items) in grouped { t += L("import.summary.issue", ImportIssue.title(c), items.count) }
        if let f = folder { t += L("import.summary.folder", f, folderAdded ?? 0) }
        if (toBin ?? 0) > 0 { t += L("import.summary.toBin", toBin ?? 0) }
        if (renamesRestored ?? 0) + (foldersRestored ?? 0) > 0 { t += L("import.summary.restored", renamesRestored ?? 0, foldersRestored ?? 0) }
        if (issues ?? []).isEmpty { t += L("import.summary.allOK") } else { t += L("import.summary.canView") }
        return t
    }
}

struct ImportProgress: Codable { let outcome: String; let running: Bool; let kind: String; let foldersDone: Int; let foldersTotal: Int; let filesDone: Int; let issues: Int; let current: String?; var waiting: Bool? = false }

struct ExportReport: Codable {
    let posts: Int; let media: Int; let bytes: UInt64
    var trashed: Int? = 0
    /// Media left out (file missing on this device, or damaged), each with the reason.
    var skipped: [ExportSkip]? = []
}
struct ExportSkip: Codable, Hashable { let mediaId: String; let postId: String; let reason: String }

extension ExportReport {
    /// Every media left out, each with its post and reason (the first 15, then how many more);
    /// empty when nothing was left out.
    var skippedText: String {
        let skipped = self.skipped ?? []
        guard !skipped.isEmpty else { return "" }
        var t = L("export.skipped", skipped.count)
        for s in skipped.prefix(15) { t += L("export.skip.line", s.postId.hasPrefix("loose:") ? L("card.loose") : L("common.post", s.postId), s.mediaId.prefix(10), s.reason) }
        if skipped.count > 15 { t += L("export.skip.more", skipped.count - 15) }
        return t
    }
}
struct ExportProgress: Codable { let running: Bool; let done: Int; let total: Int; let bytes: UInt64 }
struct TagCount: Codable, Hashable { let label: String; let count: Int; let user: Int; let ai: Int }
struct LibraryStats: Codable, Equatable {
    let posts: Int; let photos: Int; let videos: Int; let tags: Int; let pendingJobs: Int; let failedJobs: Int; var trashed: Int? = 0; var bad: Int? = 0
    /// Sync records made by a newer app version on another device (kept and passed on; applied after updating this one).
    var newerOps: Int? = 0
    static let newerOpsText = L("sync.newerOps")
}

struct TrashItem: Codable, Hashable {
    let mediaId: String
    let postId: String
    let ordinal: Int
    let kind: MediaKind
    let path: String
    let text: String?
    let authorName: String?
    let screenName: String?
    let url: String?
    var tags: [TagView]
    let trashedAtMs: UInt64
    var fileURL: URL { URL(fileURLWithPath: path) }
    var trashedAt: Date { Date(timeIntervalSince1970: Double(trashedAtMs) / 1000) }
    var asFeedItem: FeedItem { FeedItem(mediaId: mediaId, postId: postId, ordinal: ordinal, kind: kind, path: path, text: text, authorName: authorName, screenName: screenName, url: url, tags: tags) }
}

enum TrashGroups {
    /// Bin entries grouped by post (media in post order), in the order the bin lists them (most
    /// recently deleted first). Loose media have their own post, so they stand alone.
    static func group(_ items: [TrashItem]) -> [[TrashItem]] {
        var order: [String] = []
        var byPost: [String: [TrashItem]] = [:]
        for it in items {
            if byPost[it.postId] == nil { order.append(it.postId) }
            byPost[it.postId, default: []].append(it)
        }
        return order.map { byPost[$0]!.sorted { $0.ordinal < $1.ordinal } }
    }
}

/// What an export carries besides media and post text.
struct ExportOptions: Encodable, Equatable {
    /// Tags (origins, AI models) and analysed-by records.
    var tags = true
    /// Folder memberships.
    var folders = true
    /// A plain zip of the media, all at its root and named after their post, readable without this app.
    var mediaOnly = false
}

struct VerifyStatus: Codable { let outcome: String; let completedAt: UInt64; let running: Bool; let checked: UInt64; let total: UInt64; let bytes: UInt64; let bad: UInt64; let fixed: UInt64; let finished: Bool; let current: String? }

struct IntegritySummary: Decodable {
    let total: Int; let unchecked: Int; let bad: Int; let last: VerifyStatus?
    var text: String {
        if let v = last, v.running { return L("verify.checking", v.checked, v.total) }
        guard let v = last else { return L("verify.never", total) + (bad > 0 ? L("verify.knownBad", bad) : "") }
        if !v.finished { return L("verify.stopped", v.outcome == "failed" ? L("verify.failed") : L("verify.interrupted"), v.checked, v.total) }
        if bad > 0 { return L("verify.foundBad", bad, unchecked) }
        if unchecked > 0 { return L("verify.newSince", unchecked) }
        if v.outcome != "succeeded" { return L("verify.lastBad", v.bad) }
        return L("verify.lastOK") + Date(timeIntervalSince1970: Double(v.completedAt) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}

enum DownloadRoute: String, Codable, CaseIterable { case auto, fx, cookie }

struct DownloadRequest: Encodable {
    var urls: [String]
    var concurrency = 3
    var intervalMs: UInt64 = 500
    var route: DownloadRoute = .auto
    /// Explicit links: media of these posts in the recycle bin or deleted come back.
    var revive = false
    /// Put the downloaded posts (also ones already in the library) into this folder.
    var folder: String? = nil
    /// Mark newly downloaded posts "最近添加" (batch download from a bookmarks JSON).
    var markRecent = false
}

struct DownloadStatus: Decodable {
    let outcome: String
    let paused: Int
    var outcomeText: String {
        switch outcome { case "succeeded": L("download.done"); case "partial": L("download.partial"); case "failed": L("models.downloadFailed"); case "cancelled": L("download.cancelled"); case "paused": L("download.paused"); case "running": L("settings.downloading"); default: paused > 0 ? L("download.paused") : L("download.notYet") }
    }
    let running: Bool
    let total: Int
    let done: Int
    let skipped: Int
    let failed: Int
    let active: [String]
    let errors: [[String]]
    let generation: UInt64
    /// Most recently stored media files (newest last).
    let recent: [String]
    var finished: Int { done + skipped + failed }
}

struct CoreError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

/// Thin Swift wrapper over the Rust core's C ABI. All calls are synchronous and thread-safe.
enum Core {
    // A fresh coder per call: Core is used from the main thread and many background threads at
    // once, and Foundation does not promise that one coder instance can be shared between them.
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }

    private struct Envelope<T: Decodable>: Decodable { let ok: T?; let error: String? }
    private struct Empty: Decodable {}

    private static func call<T: Decodable>(_ p: UnsafeMutablePointer<CChar>?, as: T.Type, caller: String = #function) throws -> T {
        guard let p else { AppLog.error("core", L("core.noResult", caller)); throw CoreError(message: "core returned nothing") }
        defer { tl_string_free(p) }
        let env: Envelope<T>
        do { env = try decoder.decode(Envelope<T>.self, from: Data(bytes: p, count: strlen(p))) }
        catch { AppLog.error("core", L("core.badResultDetail", caller, error)); throw error }
        if let v = env.ok { return v }
        guard let msg = env.error else {
            // `{"ok":null}` is a valid "nothing" for optional results (e.g. no model download)
            if let none = Optional<Any>.none as? T { return none }
            AppLog.error("core", L("core.emptyResult", caller))
            throw CoreError(message: "empty result")
        }
        AppLog.warn("core", L("format.labelValue", caller, msg))
        throw CoreError(message: msg)
    }

    /// Rows of mixed values (`[[name, count], …]`). An error from the core is logged like any
    /// other call (it used to read as an empty list: "no folders", "no records").
    private static func rows(_ p: UnsafeMutablePointer<CChar>?, caller: String = #function) -> [[Any]] {
        guard let p else { AppLog.error("core", L("core.noResult", caller)); return [] }
        defer { tl_string_free(p) }
        guard let o = try? JSONSerialization.jsonObject(with: Data(bytes: p, count: strlen(p))) as? [String: Any] else {
            AppLog.error("core", L("core.badResult", caller)); return []
        }
        if let e = o["error"] as? String { AppLog.warn("core", L("format.labelValue", caller, e)); return [] }
        return o["ok"] as? [[Any]] ?? []
    }

    /// Like `call`, but a `null` result is accepted when `T` is optional.
    static func decodeOk<T: Decodable>(_ p: UnsafeMutablePointer<CChar>?, as: T.Type) throws -> T {
        guard let p else { throw CoreError(message: "core returned nothing") }
        defer { tl_string_free(p) }
        let env = try decoder.decode(Envelope<T>.self, from: Data(bytes: p, count: strlen(p)))
        if let e = env.error { throw CoreError(message: e) }
        if let v = env.ok { return v }
        if let none = Optional<Any>.none as? T { return none }
        throw CoreError(message: "empty result")
    }

    private static func callUnit(_ p: UnsafeMutablePointer<CChar>?) throws {
        guard let p else { throw CoreError(message: "core returned nothing") }
        defer { tl_string_free(p) }
        let env = try decoder.decode(Envelope<Empty>.self, from: Data(bytes: p, count: strlen(p)))
        if let e = env.error { throw CoreError(message: e) }
    }

    // MARK: the browser extension's receiver (core/src/extension.rs)

    struct ExtensionClient: Decodable, Identifiable { let id: String; let name: String; let added: Int; let seen: Int }
    struct ExtensionPairing: Decodable { let code: String; let link: String; let expiresIn: Int }
    struct ExtensionState: Decodable { let clients: [ExtensionClient]; let pairing: ExtensionPairing?; let port: Int? }

    /// This device for the browser extension (name, platform, download settings); with `listen`
    /// the listener starts once. Its port.
    @discardableResult static func extensionServe(name: String, platform: String, route: String, concurrency: Int, intervalMs: Int, folder: String?, listen: Bool) throws -> Int? {
        struct O: Encodable { let name: String; let platform: String; let flavor: String; let route: String; let concurrency: Int; let intervalMs: Int; let folder: String?; let listen: Bool }
        let json = String(decoding: try encoder.encode(O(name: name, platform: platform, flavor: "native", route: route, concurrency: concurrency, intervalMs: intervalMs, folder: folder, listen: listen)), as: UTF8.self)
        return try decodeOk(tl_ext_serve(json), as: Int?.self)
    }
    /// A new binding code, with this device's own LAN addresses in its binding text.
    static func extensionPairBegin() throws -> ExtensionPairing {
        struct P: Decodable { let code: String; let link: String; let expiresIn: Int }
        let p = try call(tl_ext_pair_begin("null"), as: P.self)
        return ExtensionPairing(code: p.code, link: p.link, expiresIn: p.expiresIn)
    }
    static func extensionPairCancel() { tl_ext_pair_cancel() }
    static func extensionState() throws -> ExtensionState { try call(tl_ext_clients(), as: ExtensionState.self) }
    @discardableResult static func extensionRemove(_ id: String) throws -> Bool { try call(tl_ext_remove(id), as: Bool.self) }

    static var libraryDirectory: URL {
        #if DEBUG
        if let d = ProcessInfo.processInfo.environment["TL_LIBRARY_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG && os(macOS)
        // a debug build never opens the real library (it is a separate app with its own data)
        return base.appendingPathComponent("TwimShelf-Debug", isDirectory: true)
        #else
        return base.appendingPathComponent("TwimShelf", isDirectory: true)
        #endif
    }

    @discardableResult
    static func open() -> Bool {
        tl_set_language(L10n.coreLanguage)
        tl_set_app_name(L10n.appName)
        return tl_open(libraryDirectory.path)
    }

    static func thumbnailItems() -> [FeedItem] {
        struct Item: Decodable { let mediaId: String; let path: String; let kind: MediaKind }
        let items = (try? call(tl_thumbnail_items(), as: [Item].self)) ?? []
        return items.map { FeedItem(mediaId: $0.mediaId, postId: "", ordinal: 0, kind: $0.kind, path: $0.path, text: nil, authorName: nil, screenName: nil, url: nil, tags: []) }
    }

    /// The feed, read in the core's compact form (each post and tag list once, paths relative to
    /// the library): a large library is a quarter of the data, and every media of a post shares
    /// one copy of its text.
    static func feed(_ req: FeedRequest) throws -> [FeedItem] {
        let json = String(decoding: try encoder.encode(req), as: UTF8.self)
        return try call(tl_feed_packed(json), as: PackedFeed.self).items
    }

    static func importLegacyDirectory(_ url: URL) throws -> ImportReport {
        try call(tl_import_legacy_dir(url.path), as: ImportReport.self)
    }

    static func addTag(_ label: String, to mediaId: String, ai: Bool = false) throws {
        try callUnit(tl_tag(mediaId, label, ai ? 2 : 1))
    }

    static func removeTag(_ label: String, from mediaId: String) throws {
        try callUnit(tl_untag(mediaId, label))
    }

    static func importLegacyZip(_ url: URL, folder: String? = nil) throws -> ImportReport { try call(tl_import_legacy_zip(url.path, folder ?? ""), as: ImportReport.self) }
    /// A ZIP of loose media: every file becomes its own loose-media item.
    static func importLooseZip(_ url: URL, folder: String? = nil) throws -> ImportReport { try call(tl_import_loose_zip(url.path, folder ?? ""), as: ImportReport.self) }
    static func importPack(_ url: URL, folder: String? = nil) throws -> ImportReport { try call(tl_import_pack(url.path, folder ?? ""), as: ImportReport.self) }

    // MARK: Folders

    /// Live folders with their media counts.
    static func folders() -> [(name: String, count: Int)] {
        rows(tl_folders()).compactMap { r in guard r.count == 2, let n = r[0] as? String, let c = r[1] as? Int else { return nil }; return (n, c) }
    }
    /// The folders page: folders with counts and covers, plus the library's photo and video totals.
    static func folderOverview() -> FolderOverview? { try? call(tl_folder_overview(), as: FolderOverview.self) }
    static func mediaFolders(_ mediaId: String) -> [String] { (try? call(tl_media_folders(mediaId), as: [String].self)) ?? [] }
    @discardableResult static func createFolder(_ name: String) throws -> String { try call(tl_create_folder(name), as: String.self) }
    static func deleteFolder(_ name: String) throws { try callUnit(tl_delete_folder(name)) }
    /// Renames a folder; into an existing name it merges. Returns how many media moved.
    @discardableResult static func renameFolder(_ old: String, to new: String) throws -> Int {
        struct A: Encodable { let old: String; let new: String }
        return try call(tl_rename_folder(String(decoding: try encoder.encode(A(old: old, new: new)), as: UTF8.self)), as: Int.self)
    }
    private struct FolderArgs: Encodable { let name: String; var media: [String] = []; var posts: [String] = [] }
    /// Adds media (and every live media of the given posts) to a folder, created if needed.
    @discardableResult static func addToFolder(_ name: String, media: [String] = [], posts: [String] = []) throws -> Int {
        try call(tl_folder_add(json(FolderArgs(name: name, media: media, posts: posts))), as: Int.self)
    }
    @discardableResult static func removeFromFolder(_ name: String, media: [String] = [], posts: [String] = []) throws -> Int {
        try call(tl_folder_remove(json(FolderArgs(name: name, media: media, posts: posts))), as: Int.self)
    }

    /// Exports exactly these media (the result of a search) as a .tlpack, or with
    /// `options.mediaOnly` as a plain zip. There is no other way to choose what is exported.
    static func exportMedia(_ ids: [String], options: ExportOptions = ExportOptions(), to url: URL) throws -> ExportReport {
        struct A: Encodable { let mediaIds: [String]; let options: ExportOptions; let out: String }
        return try call(tl_export_media(json(A(mediaIds: ids, options: options, out: url.path))), as: ExportReport.self)
    }

    /// The live media of a folder, for its plain-zip export.
    static func mediaIds(inFolder name: String) -> [String] {
        var req = FeedRequest()
        req.filter.folder = name
        return ((try? feed(req)) ?? []).map(\.mediaId)
    }

    /// Diagnostics ZIP (logs, crash reports, numbers-only summary); returns the file count.
    static func exportDiagnostics(to url: URL, appInfo: String) throws -> Int { try call(tl_export_diagnostics(url.path, appInfo), as: Int.self) }

    /// Cold backup of the whole library (everything but AI models).
    static func exportBackup(to url: URL) throws -> ExportReport { try call(tl_export_backup(url.path), as: ExportReport.self) }
    static func exportStatus() -> ExportProgress? { try? call(tl_export_status(), as: ExportProgress.self) }
    static func cancelExport() { _ = try? callUnit(tl_export_cancel()) }

    /// Imports a folder of loose media (a share); with `consume`, imported files are removed from it.
    static func importLooseDir(_ dir: URL, folder: String? = nil, consume: Bool, keepTo: URL? = nil, album: Bool = true) throws -> ImportReport {
        struct A: Encodable { let dir: String; let folder: String?; let consume: Bool; let keepTo: String?; let album: Bool }
        return try call(tl_import_loose_dir(json(A(dir: dir.path, folder: folder, consume: consume, keepTo: keepTo?.path, album: album))), as: ImportReport.self)
    }

    struct DeletedReports: Codable { let reports: Int; let sources: Int; let bytes: UInt64 }
    /// Deletes import records; a record's source is deleted too when it is one of the app's own
    /// copies (inside `owned`), never a file of the user's elsewhere.
    static func deleteImportReports(_ files: [String], owned: [URL]) throws -> DeletedReports {
        struct A: Encodable { let reports: [String]; let owned: [String] }
        return try call(tl_delete_import_reports(json(A(reports: files, owned: owned.map(\.path)))), as: DeletedReports.self)
    }

    private static func json<T: Encodable>(_ v: T) -> String { String(decoding: (try? encoder.encode(v)) ?? Data("{}".utf8), as: UTF8.self) }

    // MARK: Import progress and reports

    /// Name of the newest saved import report (a directory listing; cheap enough for change checks).
    static var latestImportReportName: String? {
        let dir = libraryDirectory.appendingPathComponent("logs/import-reports", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("import-") }.max()
    }
    static func importStatus() -> ImportProgress? { try? call(tl_import_status(), as: ImportProgress.self) }
    static func importReport(_ path: String) throws -> ImportReport { try call(tl_import_report(path), as: ImportReport.self) }
    /// Saved reports, newest first.
    static func importReports() -> [(file: String, date: Date, source: String, issues: Int)] {
        rows(tl_import_reports()).compactMap { r in
            guard r.count == 4, let f = r[0] as? String, let ms = r[1] as? Double, let src = r[2] as? String, let n = r[3] as? Int else { return nil }
            return (f, Date(timeIntervalSince1970: ms / 1000), src, n)
        }
    }
    /// Writes the problem files (unchanged) and 说明.txt into a ZIP; returns how many files.
    @discardableResult static func exportImportIssues(report: String, to url: URL) throws -> Int { try call(tl_import_export_issues(report, url.path), as: Int.self) }

    // UI action receipts identify exactly what changed, including a clock for safe undo.
    enum ActionKind: String, Codable { case trash, restore, purge, folderAdd = "folder_add", folderRemove = "folder_remove", tag }
    struct ActionStamp: Codable { let id: String; let hlc: UInt64; let inc: UInt32; let state: UInt8 }
    struct ActionReceipt: Codable {
        let kind: ActionKind; let label: String?; let folder: String?; let folderHlc: UInt64?; let epoch: UInt64; let changes: [ActionStamp]
        var count: Int { changes.count }
    }
    struct BinSnapshot: Codable {
        var entries: [ActionStamp]; var pendingCount: Int; let epoch: UInt64
        var count: Int { entries.count }
        var description: String { L("scope.count", count) + (pendingCount > 0 ? L("scope.pending", pendingCount) : "") }
    }
    struct MediaScope: Decodable {
        let ids: [String]; let pendingCount: Int; var userTags: [String: [String]]
        func taggedCount(_ label: String, ids: [String]) -> Int { ids.filter { userTags[$0, default: []].contains(label) }.count }
        func commonTags(_ ids: [String]) -> Set<String> {
            guard let first = ids.first else { return [] }
            return ids.dropFirst().reduce(Set(userTags[first, default: []])) { $0.intersection(userTags[$1, default: []]) }
        }
    }
    static func postScope(_ post: String) throws -> MediaScope { try call(tl_post_scope(post), as: MediaScope.self) }
    static func binSnapshot(media: [String]? = nil) throws -> BinSnapshot {
        var snapshot = try call(tl_bin_snapshot(), as: BinSnapshot.self)
        if let media { let ids = Set(media); snapshot.entries.removeAll { !ids.contains($0.id) }; snapshot.pendingCount = 0 }
        return snapshot
    }
    @discardableResult static func action(_ kind: ActionKind, media: [String] = [], posts: [String] = [], folder: String? = nil, label: String? = nil, snapshot: BinSnapshot? = nil) throws -> ActionReceipt {
        struct A: Encodable { let kind: ActionKind; let media: [String]; let posts: [String]; let folder: String?; let label: String?; let expected: [ActionStamp]?; let epoch: UInt64? }
        return try call(tl_action(json(A(kind: kind, media: media, posts: posts, folder: folder, label: label, expected: snapshot?.entries, epoch: snapshot?.epoch))), as: ActionReceipt.self)
    }
    static func undo(_ receipt: ActionReceipt) throws -> String {
        let n = try call(tl_action_undo(json(receipt)), as: Int.self)
        return L("undo.done", n) + (n < receipt.count ? L("undo.skipped", receipt.count - n) : "")
    }

    // MARK: Recycle bin

    private struct Ids: Encodable { var media: [String] = []; var post: String? = nil }
    /// Moves media (and/or every live media of a post) to the recycle bin; returns how many.
    @discardableResult static func trash(media: [String] = [], post: String? = nil) throws -> Int { try call(tl_trash(json(Ids(media: media, post: post))), as: Int.self) }
    @discardableResult static func restore(_ media: [String]) throws -> Int { try call(tl_trash_restore(json(Ids(media: media))), as: Int.self) }
    /// Permanent deletion (on every device). Only media in the bin.
    @discardableResult static func purge(_ media: [String]) throws -> Int { try call(tl_trash_purge(json(Ids(media: media))), as: Int.self) }
    @discardableResult static func emptyTrash() throws -> Int { try call(tl_trash_empty(), as: Int.self) }
    static func trashList() -> [TrashItem] { (try? call(tl_trash_list(), as: [TrashItem].self)) ?? [] }
    static var trashKeepDays: Int {
        get { (try? call(tl_trash_keep_days(), as: Int.self)) ?? 30 }
        set { try? callUnit(tl_set_trash_keep_days(UInt32(max(0, newValue)))) }
    }
    @discardableResult static func expireTrash() -> Int { (try? call(tl_trash_expire(), as: Int.self)) ?? 0 }

    // MARK: Verification and repair

    @discardableResult static func startVerify() throws -> Int { try call(tl_verify_start(), as: Int.self) }
    static var mediaSizesFilling: Bool { tl_media_sizes_filling() }
    static func integritySummary() -> IntegritySummary? { try? call(tl_integrity_summary(), as: IntegritySummary.self) }
    static func verifyStatus() -> VerifyStatus? { try? call(tl_verify_status(), as: VerifyStatus.self) }
    static func cancelVerify() { tl_verify_cancel() }
    /// The app could not decode a media: the core checks the file and records why.
    @discardableResult static func reportBad(_ mediaId: String) -> String? { (try? decodeOk(tl_report_bad(mediaId), as: String?.self)) ?? nil }
    enum RepairResult: String, Codable { case replaced, replacedNew = "replaced_new", fromPeers = "from_peers" }
    /// Downloads a media again (blocking: call off the main thread).
    static func repair(_ mediaId: String) throws -> RepairResult { try call(tl_repair(mediaId), as: RepairResult.self) }

    static func bookmarkURLs(in file: URL) throws -> [String] { try call(tl_parse_bookmarks(file.path), as: [String].self) }

    @discardableResult
    static func startDownload(_ req: DownloadRequest) throws -> Int {
        let json = String(decoding: try encoder.encode(req), as: UTF8.self)
        return try call(tl_download_start(json), as: Int.self)
    }
    static func downloadStatus() -> DownloadStatus? { try? call(tl_download_status(), as: DownloadStatus.self) }
    @MainActor static func cancelDownload() {
        do { try stopDownload(pause: false) } catch { AppLog.error("download", error.localizedDescription) }
    }
    @MainActor static func stopDownload(pause: Bool) throws {
        _ = try call(tl_download_stop(pause), as: Int.self)
        ActivityCenter.shared.refreshNow(); ActivityCenter.shared.refreshStats()
    }
    @MainActor static func resumeDownload() throws {
        let d = UserDefaults.standard
        let req = DownloadRequest(urls: [], concurrency: d.object(forKey: "dl.concurrency") as? Int ?? 3, intervalMs: UInt64(d.object(forKey: "dl.interval") as? Int ?? 500))
        _ = try call(tl_download_resume(json(req)), as: Int.self)
        ActivityCenter.shared.refreshNow()
    }
    static func setCookies(authToken: String, ct0: String) { tl_set_cookies(authToken, ct0) }

    /// Renames (or merges) a tag everywhere; returns the new name.
    @discardableResult static func renameTag(_ from: String, to: String) throws -> String { try call(tl_rename_tag(from, to), as: String.self) }
    /// Removes a tag from every media (whoever added it, under every old name); syncs. Returns
    /// how many media lost it.
    @discardableResult static func deleteTag(_ label: String) throws -> Int { try call(tl_delete_tag(label), as: Int.self) }
    /// Removes every AI tag (ones I endorsed stay as mine) and the records of which model
    /// proposed them; syncs. Returns how many tags lost their AI part.
    @discardableResult static func removeAITags() throws -> Int { try call(tl_remove_ai_tags(), as: Int.self) }
    /// Active renames as (old name, current name).
    /// Current tags of a media (after renames), for the AI's context.
    static func mediaTags(_ mediaId: String) -> [String] {
        rows(tl_media_tags(mediaId)).compactMap { $0.first as? String }
    }

    /// Checks the saved cookies with X (Settings → 检查 Cookie).
    static func checkCookies() -> (title: String, detail: String) {
        struct R: Decodable { let screenName: String?; let error: String? }
        let auth = Keychain.get("auth_token") ?? "", ct0 = Keychain.get("ct0") ?? ""
        guard !auth.isEmpty, !ct0.isEmpty else { return (L("cookie.none.title"), L("cookie.none.message")) }
        guard let r = try? call(tl_check_cookies(auth, ct0), as: R.self) else { return (L("cookie.checkFailed"), "") }
        if let e = r.error { return (L("cookie.invalid"), e) }
        return (L("cookie.valid"), L("cookie.signedIn", r.screenName ?? ""))
    }

    /// Every live media with this tag into a folder (created if needed); returns how many were added.
    @discardableResult static func tagToFolder(_ label: String, folder: String) throws -> Int {
        struct A: Encodable { let label: String; let folder: String }
        return try call(tl_tag_to_folder(json(A(label: label, folder: folder))), as: Int.self)
    }
    static func allTags() -> [TagCount] { (try? call(tl_all_tags(), as: [TagCount].self)) ?? [] }
    static func stats() -> LibraryStats? { try? call(tl_stats(), as: LibraryStats.self) }

    /// The models offered for download (`mlx` on Apple devices).
    static func modelCatalog(format: String) -> [CatalogModel] { (try? call(tl_model_catalog(format), as: [CatalogModel].self)) ?? [] }

    /// 检查更新 (GitHub builds): the newer release, nil when this build is current. Network: off
    /// the main thread.
    struct UpdateInfo: Codable, Equatable { let version: String; let pageUrl: String; let notes: String; let assetName: String?; let assetUrl: String?; let assetSize: UInt64; let assetDigest: String? }
    static func checkUpdate(repo: String, current: String, suffixes: [String]) throws -> UpdateInfo? {
        struct Q: Encodable { let repo: String; let current: String; let suffixes: [String]; let flutter = false }
        return try call(tl_update_check(json(Q(repo: repo, current: current, suffixes: suffixes))), as: UpdateInfo?.self)
    }
    /// Downloads and checks the release's installer; its file.
    static func downloadUpdate(_ info: UpdateInfo, into dir: URL) throws -> URL {
        URL(fileURLWithPath: try call(tl_update_download(json(info), dir.path), as: String.self))
    }

    /// 存储空间 by group (`storage.group.<key>`). Walks folders: call it off the main thread.
    struct StorageGroup: Codable, Hashable { let key: String; let bytes: UInt64; let files: UInt64 }
    struct StorageUsage: Codable { let groups: [StorageGroup]; let total: UInt64 }
    static func storageUsage(extra: [(key: String, url: URL)]) throws -> StorageUsage {
        struct P: Encodable { let key: String; let path: String }
        return try call(tl_storage_usage(json(extra.map { P(key: $0.key, path: $0.url.path) })), as: StorageUsage.self)
    }
    /// Deletes posts, media, tags and sync state; AI models only when `includeModels`.
    static func wipe(includeModels: Bool) throws { try callUnit(tl_wipe(includeModels)) }

    /// Preferences that belong to the AI models (kept when models are kept).
    static let aiPreferenceKeys = ["ai.tagger.id", "ai.embedder.id", "ai.autotag"]

    // MARK: Models (standard Hugging Face / MLX folders)

    struct ModelInfo: Codable, Hashable {
        let id: String
        let repo: String?
        let modelType: String?
        let vision: Bool
        let bytes: UInt64
        let path: String
        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    }
    struct ModelDownloadStatus: Codable { let repo: String; let running: Bool; let totalBytes: UInt64; let doneBytes: UInt64; let file: String; let error: String?; let finished: Bool }
    struct MediaRef: Codable, Hashable { let mediaId: String; let path: String; let kind: String; var text: String? = nil }

    static func setModelsDirectory(_ url: URL) { try? callUnit(tl_set_models_dir(url.path)) }
    static func downloadModel(_ repo: String) throws { try callUnit(tl_model_download(repo)) }
    static func modelStatus() -> ModelDownloadStatus? { (try? call(tl_model_status(), as: ModelDownloadStatus?.self)) ?? nil }
    static func cancelModelDownload() { tl_model_cancel() }
    /// A model download left unfinished by a quit or crash; downloading it again continues.
    struct InterruptedModel: Decodable { let repo: String; let bytes: UInt64 }
    static func interruptedModels() -> [InterruptedModel] { (try? call(tl_models_interrupted(), as: [InterruptedModel].self)) ?? [] }
    static func installedModels() -> [ModelInfo] { (try? call(tl_models_installed(), as: [ModelInfo].self)) ?? [] }
    static func deleteModel(_ id: String) throws { try callUnit(tl_model_delete(id)) }
    static func exportModelZip(_ id: String, to url: URL) throws { _ = try call(tl_model_export_zip(id, url.path), as: UInt64.self) }
    static func importModel(_ url: URL) throws -> ModelInfo { try call(tl_model_import(url.path), as: ModelInfo.self) }

    // MARK: Model store (Hugging Face, through the core)

    struct HubDevice: Decodable, Hashable { let memoryBytes: UInt64?; let freeBytes: UInt64?; let mobile: Bool }
    struct HubRepo: Decodable, Hashable {
        let repo: String; let format: String; let architecture: String?; let params: UInt64?; let downloads: UInt64; let likes: UInt64
        let license: String?; let sha: String?; let claimsUncensored: Bool; let estimatedBytes: UInt64?; let tier: String
    }
    struct HubHidden: Decodable, Hashable { let repo: String; let reason: String }
    struct HubPage: Decodable { let device: HubDevice; let items: [HubRepo]; let hidden: [HubHidden]; let next: String? }
    struct HubVariant: Decodable, Hashable { let label: String; let weights: String?; let projector: String?; let bytes: UInt64; let tier: String; let suggested: Bool; let enoughSpace: Bool; let folder: String }
    struct HubSkipped: Decodable, Hashable { let name: String; let reason: String }
    struct HubDetail: Decodable { let repo: HubRepo; let revision: String; let variants: [HubVariant]; let skipped: [HubSkipped]; let problem: String? }
    struct HubInstall: Encodable { let format: String; let repo: String; let revision: String?; let weights: String?; let projector: String?; let bytes: UInt64; let folder: String }

    static func hubDevice() -> HubDevice? { try? call(tl_hub_device(), as: HubDevice.self) }
    /// Network: off the main thread.
    static func hubSearch(format: String, query: String, uncensored: Bool, next: String?) throws -> HubPage {
        struct Q: Encodable { let format: String; let query: String; let uncensored: Bool; let next: String? }
        return try call(tl_hub_search(json(Q(format: format, query: query, uncensored: uncensored, next: next))), as: HubPage.self)
    }
    /// Network: off the main thread.
    static func hubRepo(format: String, repo: String) throws -> HubDetail { try call(tl_hub_repo(format, repo), as: HubDetail.self) }
    static func hubInstall(_ r: HubInstall) throws { try callUnit(tl_hub_install(json(r))) }

    // MARK: AI tagging

    /// Media that no model has analysed yet.
    static func aiPending(limit: Int) -> [MediaRef] { (try? call(tl_ai_pending(Int64(limit)), as: [MediaRef].self)) ?? [] }
    /// The same for `model` on this device, leaving out media whose analysis failed here too
    /// often, or once since `since` (unix seconds, the start of the current run; 0 = none).
    static func aiPending(model: String, since: Int, limit: Int) -> [MediaRef] {
        (try? call(tl_ai_pending_for(model, Int64(since), Int64(limit)), as: [MediaRef].self)) ?? []
    }
    /// Analysis attempts on this device (local only, never synced; see `AutoTagger`).
    enum AiAttemptStep: String { case begin, failed, undo }
    static func aiAttempt(_ step: AiAttemptStep, mediaId: String, model: String, reason: String = "") {
        struct A: Encodable { let step: String; let mediaId: String; let model: String; let reason: String; let now: Int }
        guard let d = try? encoder.encode(A(step: step.rawValue, mediaId: mediaId, model: model, reason: reason, now: Int(Date().timeIntervalSince1970))) else { return }
        do { try callUnit(tl_ai_attempt(String(decoding: d, as: UTF8.self))) }
        catch { AppLog.error("ai", L("ai.attemptFailed", error.localizedDescription)) }
    }
    struct AiFailure: Decodable, Hashable { let mediaId: String; let model: String; let attempts: Int; let reason: String; let at: Int }
    /// Media this device gave up analysing (live, not analysed by any device), newest first.
    static func aiFailures() -> [AiFailure] { (try? call(tl_ai_failures(), as: [AiFailure].self)) ?? [] }
    static func aiFailuresClear() { _ = try? call(tl_ai_failures_clear(), as: Int.self) }
    /// A setting shared by every device of the sync account (nil = the default).
    static func setting(_ key: String) -> String? { (try? decodeOk(tl_setting(key), as: String?.self)) ?? nil }
    static func setSetting(_ key: String, _ value: String?) {
        let p = value.map { v in v.withCString { tl_set_setting(key, $0) } } ?? tl_set_setting(key, nil)
        _ = try? decodeOk(p, as: Optional<Int>.self)
    }

    /// Live media after `after` (a media id; "" = from the start), in id order.
    static func mediaPage(after: String, limit: Int) -> [MediaRef] { (try? call(tl_media_page(after, Int64(limit)), as: [MediaRef].self)) ?? [] }
    static func aiCounts() -> (done: Int, total: Int) {
        let v = (try? call(tl_ai_counts(), as: [Int].self)) ?? [0, 0]
        return (v.first ?? 0, v.last ?? 0)
    }
    /// Applies a model's labels. `replaceOld` removes unendorsed AI tags it did not propose again;
    /// tags you added or endorsed are never removed.
    static func epoch() throws -> UInt64 { try call(tl_epoch(), as: UInt64.self) }
    static func aiApply(mediaId: String, model: String, labels: [String], replaceOld: Bool = false, epoch: UInt64? = nil) throws {
        struct A: Encodable { let mediaId: String; let model: String; let labels: [String]; let replaceOld: Bool; let epoch: UInt64 }
        try callUnit(tl_ai_apply(String(decoding: try encoder.encode(A(mediaId: mediaId, model: model, labels: labels, replaceOld: replaceOld, epoch: try epoch ?? Core.epoch())), as: UTF8.self)))
    }
    static func labelsMissingVectors(model: String) -> [String] { (try? call(tl_labels_missing_vectors(model), as: [String].self)) ?? [] }
    static func setVectors(model: String, items: [(String, [Float])], epoch: UInt64? = nil) throws {
        let payload: [String: Any] = ["epoch": try epoch ?? Core.epoch(), "model": model, "items": items.map { [$0.0, $0.1] as [Any] }]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try callUnit(tl_set_vectors(String(decoding: data, as: UTF8.self)))
    }

    static func fxAPIURL(for link: String) -> URL? {
        guard let p = tl_fx_api_url(link) else { return nil }
        defer { tl_string_free(p) }
        return URL(string: String(cString: p))
    }
}

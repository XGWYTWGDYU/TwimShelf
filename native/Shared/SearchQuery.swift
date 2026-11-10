import Foundation
import SwiftUI

/// One part of a post a search term can match.
enum SearchField: String, CaseIterable { case tags, text, author }

/// A condition word of the token style.
enum SearchKeyword: Hashable {
    case field(SearchField)
    case scope(SearchScope)
    /// Only "最近添加" posts.
    case recent
    /// Only media imported from outside (散装: loose ZIPs and the share extension).
    case external
    /// "文件夹": the next word is a folder's name (until then a pending capsule).
    case folder
    /// "视频" / "照片": only that kind of media.
    case media(MediaKind)

    struct Info { let word: String; let aliases: [String]; let symbol: String; let hint: String; let excludeHint: String }

    static let all: [SearchKeyword] = [.field(.tags), .field(.text), .field(.author), .scope(.mine), .scope(.ai), .scope(.common), .scope(.both), .media(.video), .media(.photo), .folder, .recent, .external]

    /// The catalog name of the keyword ("search.kw.<id>.word", ".aliases", ".hint", ".exclude").
    var id: String {
        switch self {
        case .field(let f): f.rawValue
        case .scope(let s): s == .both ? "all" : s.rawValue
        case .recent: "recent"
        case .external: "external"
        case .folder: "folder"
        case .media(let k): k.rawValue
        }
    }

    var symbol: String {
        switch self {
        case .field(.tags): "tag"
        case .field(.text): "text.quote"
        case .field(.author): "person"
        case .scope(.mine): "person.crop.circle"
        case .scope(.ai): "sparkles"
        case .scope(.common): "checkmark.seal"
        case .scope(.both): "circle.grid.2x2"
        case .media(.video): "video"
        case .media(.photo): "photo"
        case .folder: "folder"
        case .recent: "clock.badge.checkmark"
        case .external: "square.and.arrow.down"
        }
    }

    // i18n-keys: search.kw.*
    var info: Info {
        let base = "search.kw." + id
        let aliases = L(base + ".aliases").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Info(word: L(base + ".word"), aliases: aliases, symbol: symbol, hint: L(base + ".hint"), excludeHint: L(base + ".exclude"))
    }

    /// "全部" means nothing with a minus (the other conditions do).
    var excludable: Bool { self != .scope(.both) }

    /// The keyword a typed word stands for (its word or an alias in the app's language, any case).
    static func from(_ word: String) -> SearchKeyword? {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard !w.isEmpty else { return nil }
        return all.first { kw in let i = kw.info; return ([i.word] + i.aliases).contains { $0.lowercased() == w } }
    }

    /// Stored in a token's representedObject.
    var key: String {
        switch self {
        case .field(let f): "f:" + f.rawValue
        case .scope(let s): "s:" + s.rawValue
        case .recent: "r:recent"
        case .external: "x:external"
        case .folder: TokenQuery.pendingFolder
        case .media(let k): "k:" + k.rawValue
        }
    }
}

/// What the capsules in a token search field ask for. Conditions apply to the whole search;
/// every text capsule must match (as with several search terms). A capsule written with a minus
/// ("-猫", "-用户", "-文件夹 旅行") takes something away: a word excludes the media containing
/// it, a condition excludes what it stands for (see `searchFields`, `origins`, `kind`).
struct TokenQuery: Equatable {
    var fields: Set<SearchField> = []
    var scopes: Set<SearchScope> = []
    var terms: [String] = []
    var folder: String?
    var recent = false
    var external = false
    /// 视频 / 照片 capsules: one of them narrows to that kind; both (or none) mean no limit.
    var kinds: Set<MediaKind> = []
    // written with a minus
    var excludedTerms: [String] = []
    var excludedFields: Set<SearchField> = []
    var excludedScopes: Set<SearchScope> = []
    var excludedKinds: Set<MediaKind> = []
    var excludedFolders: [String] = []
    var excludeRecent = false
    var excludeExternal = false

    static let pendingFolder = "p:folder"
    /// The prefix of a capsule written with a minus: "-t:猫", "-f:author", "-d:旅行".
    static let minus = "-"
    static func termKey(_ t: String) -> String { "t:" + t }
    static func folderKey(_ name: String) -> String { "d:" + name }
    /// The minus signs a word may start with (a full-width one from a Chinese keyboard too).
    static let minusSigns: Set<Character> = ["-", "－", "−", "–"]   // i18n-exempt: characters the parser recognizes, not text

    /// The kinds of media searched: one, or nil for both. (Empty `allowedKinds` = none.)
    var allowedKinds: Set<MediaKind> { (kinds.isEmpty ? [.photo, .video] : kinds).subtracting(excludedKinds) }
    var kind: MediaKind? { allowedKinds.count == 1 ? allowedKinds.first : nil }

    /// Where the words are looked for. No field capsule = everywhere (tags, post text, authors);
    /// a field capsule (标签 / 贴文 / 用户) limits it to those. 我的 / AI / 共同 are about who
    /// added a tag, so with only those it is tags. 文件夹 / 最近 / 外部导入 only narrow which
    /// posts are searched (as do 视频 / 照片, which narrow the kind of media) and keep the default.
    /// A field with a minus ("-用户") is taken away from whichever of these applies.
    var searchFields: SearchFields {
        var f: SearchFields
        if fields.isEmpty {
            f = scopes.subtracting([.both]).isEmpty ? SearchFields(tags: true, text: true, author: true) : SearchFields(tags: true, text: false, author: false)
        } else {
            f = SearchFields(tags: fields.contains(.tags), text: fields.contains(.text), author: fields.contains(.author))
        }
        if excludedFields.contains(.tags) { f.tags = false }
        if excludedFields.contains(.text) { f.text = false }
        if excludedFields.contains(.author) { f.author = false }
        return f
    }

    /// "共同" wins (the narrowest); "我的" with "AI" is either; none = either.
    var scope: SearchScope {
        if scopes.contains(.common) { return .common }
        if scopes.contains(.mine) && scopes.contains(.ai) { return .both }
        if scopes.contains(.mine) { return .mine }
        if scopes.contains(.ai) { return .ai }
        return .both
    }

    /// Which tag origins count when a scope has a minus (`rules::origins_for` in the core):
    /// 1 = only mine, 2 = only the AI's, 3 = both together. nil: the scope decides alone.
    var origins: [UInt8]? {
        guard !excludedScopes.isEmpty else { return nil }
        let mask: UInt8 = scope == .common ? 4 : scope == .mine ? 1 : scope == .ai ? 2 : 3
        return [UInt8(1), 2, 3].filter { o in
            let allowed = mask == 4 ? o == 3 : (o & mask & 3) != 0
            return allowed && !(excludedScopes.contains(.mine) && o & 1 != 0) && !(excludedScopes.contains(.ai) && o & 2 != 0) && !(excludedScopes.contains(.common) && o == 3)
        }
    }

    /// The search asks for something and its opposite (视频 -视频, 最近 -最近, a folder and the
    /// same folder with a minus, words to find with every field taken away): nothing can match.
    var isContradictory: Bool {
        let f = searchFields
        return allowedKinds.isEmpty || (recent && excludeRecent) || (external && excludeExternal)
            || (folder.map { excludedFolders.contains($0) } ?? false)
            || (!terms.isEmpty && !f.tags && !f.text && !f.author)
    }

    /// The conditions of the capsules on top of a page's own filter (its chips).
    func filter(over base: FeedFilter) -> FeedFilter {
        var f = base
        if let d = folder { f.folder = d }
        if recent { f.recentOnly = true }
        if external { f.looseOnly = true }
        if let k = kind { f.kind = k }
        let fl = searchFields
        // a minus-word with every field taken away has nowhere to be found: it excludes nothing
        if fl.tags || fl.text || fl.author { f.excludeTerms = excludedTerms }
        f.origins = origins
        f.excludeFolders = excludedFolders
        f.excludeRecent = excludeRecent
        f.excludeLoose = excludeExternal
        return f
    }

    /// What the cards highlight: the words, only in the fields searched.
    var marks: SearchMarks { SearchMarks(terms: terms, fields: searchFields) }

    /// Reads the capsules of a field.
    init(keys: [String]) {
        for k in keys {
            if k.hasPrefix(Self.minus) { exclude(String(k.dropFirst())); continue }
            if k.hasPrefix("f:"), let f = SearchField(rawValue: String(k.dropFirst(2))) { fields.insert(f) }
            else if k.hasPrefix("s:"), let s = SearchScope(rawValue: String(k.dropFirst(2))) { scopes.insert(s) }
            else if k.hasPrefix("t:") { let t = String(k.dropFirst(2)).lowercased(); if !terms.contains(t) { terms.append(t) } }
            else if k.hasPrefix("d:") { folder = String(k.dropFirst(2)) }
            else if k == "r:recent" { recent = true }
            else if k == "x:external" { external = true }
            else if k.hasPrefix("k:"), let m = MediaKind(rawValue: String(k.dropFirst(2))) { kinds.insert(m) }
        }
    }
    init() {}

    private mutating func exclude(_ k: String) {
        if k.hasPrefix("f:"), let f = SearchField(rawValue: String(k.dropFirst(2))) { excludedFields.insert(f) }
        else if k.hasPrefix("s:"), let s = SearchScope(rawValue: String(k.dropFirst(2))), s != .both { excludedScopes.insert(s) }
        else if k.hasPrefix("t:") { let t = String(k.dropFirst(2)).lowercased(); if !t.isEmpty, !excludedTerms.contains(t) { excludedTerms.append(t) } }
        else if k.hasPrefix("d:") { let n = String(k.dropFirst(2)); if !excludedFolders.contains(n) { excludedFolders.append(n) } }
        else if k == "r:recent" { excludeRecent = true }
        else if k == "x:external" { excludeExternal = true }
        else if k.hasPrefix("k:"), let m = MediaKind(rawValue: String(k.dropFirst(2))) { excludedKinds.insert(m) }
    }

    /// The word without its minus, when it is written with one ("-猫" → "猫"; a lone "-" is a word).
    static func negated(_ w: String) -> String? {
        guard let c = w.first, minusSigns.contains(c), w.count > 1 else { return nil }
        return String(w.dropFirst())
    }

    /// The capsule key of one finished word: a condition, a word to search for, either with a
    /// minus. `after` is the key before it (a word right after "文件夹" names the folder).
    static func key(for word: String, after previous: String?) -> String {
        if previous == pendingFolder { return folderKey(word) }
        if previous == minus + pendingFolder { return minus + folderKey(negated(word) ?? word) }
        if let rest = negated(word) {
            if let kw = SearchKeyword.from(rest), kw.excludable { return minus + kw.key }
            return minus + termKey(rest.lowercased())
        }
        return SearchKeyword.from(word)?.key ?? termKey(word)
    }

    /// Splits typed text at spaces (half or full width): every complete word becomes a capsule
    /// key; the unfinished rest stays as text. A word right after "文件夹" is the folder's name.
    static func split(_ text: String) -> (keys: [String], rest: String) {
        let seps: Set<Character> = [" ", "\u{3000}", "\n", "\t"]
        guard let last = text.lastIndex(where: { seps.contains($0) }) else { return ([], text) }
        let done = text[..<last].split(whereSeparator: { seps.contains($0) }).map(String.init)
        let rest = String(text[text.index(after: last)...])
        var keys: [String] = []
        for w in done {
            let k = key(for: w, after: keys.last)
            if keys.last == pendingFolder || keys.last == minus + pendingFolder { keys[keys.count - 1] = k } else { keys.append(k) }
        }
        return (keys, rest)
    }

    /// What a capsule reads ("猫", "用户", "文件夹：旅行"); a minus capsule reads the same with its
    /// minus shown by `isExcluded`.
    static func title(_ key: String) -> String {
        let k = isExcluded(key) ? String(key.dropFirst()) : key
        if k.hasPrefix("t:") { return String(k.dropFirst(2)) }
        if k.hasPrefix("d:") { return L("search.token.folder", String(k.dropFirst(2))) }
        if k == pendingFolder { return L("search.token.folderPending") }
        return SearchKeyword.all.first { $0.key == k }?.info.word ?? k
    }
    static func isExcluded(_ key: String) -> Bool { key.hasPrefix(minus) }
    /// The symbol of a capsule (nil: a plain word).
    static func symbol(_ key: String) -> String? {
        if isExcluded(key) { return "minus.circle" }
        if key.hasPrefix("d:") || key == pendingFolder { return "folder" }
        return SearchKeyword.all.first { $0.key == key }?.symbol
    }
    /// What VoiceOver says for a capsule.
    static func spoken(_ key: String) -> String { isExcluded(key) ? L("search.token.excluded", title(key)) : title(key) }
}

/// What the cards of a search highlight: the words, in the fields that were searched (a search
/// in 用户 never marks the same word in a post's text or tags).
struct SearchMarks: Equatable {
    var terms: [String] = []
    var fields = SearchFields(tags: true, text: true, author: true)
    static let none = SearchMarks()
    /// As the core reads them: with neither text nor authors, the tags are searched.
    var tags: [String] { fields.tags || (!fields.text && !fields.author) ? terms : [] }
    var text: [String] { fields.text ? terms : [] }
    var author: [String] { fields.author ? terms : [] }
}

/// Recent search terms (this device only; cleared with the library).
enum SearchHistory {
    private static let key = "search.history"
    static var items: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        UserDefaults.standard.set(Array(([t] + items.filter { $0 != t }).prefix(12)), forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Where the searched words occur in a shown text (case- and width-insensitive), so every match
/// can be highlighted in the results.
enum SearchHighlight {
    static func ranges(of terms: [String], in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        for t in Set(terms.map { $0.trimmingCharacters(in: .whitespaces) }) where !t.isEmpty {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: t, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                out.append(r)
                from = r.location + max(r.length, 1)
            }
        }
        return out
    }

    /// Marks every match in `s` with the given attributes.
    static func apply(_ terms: [String], to s: NSMutableAttributedString, _ attrs: [NSAttributedString.Key: Any]) {
        guard !terms.isEmpty else { return }
        for r in ranges(of: terms, in: s.string) { s.addAttributes(attrs, range: r) }
    }

    /// The guide under the suggestions: how capsules, conditions and minus-words work.
    static var guide: String {
        let words = SearchKeyword.all.map { L("search.guide.quoted", $0.info.word) }.joined(separator: L("search.guide.separator"))
        return L("search.guide", words)
    }
}

/// One row of the list under the search field (iOS and Mac draw the same rows).
struct SearchSuggestion {
    enum Action { case key(String), folder(String, excluded: Bool), clearHistory }
    enum Tint { case accent, folder, secondary, exclude }
    var id: String
    var title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Tint = .accent
    var destructive = false
    var action: Action? = nil
}
struct SearchSuggestionSection { var title: String?; var rows: [SearchSuggestion] }

/// The list under the search field: the conditions still available (completing what is typed),
/// what to search for, matching tags and folders, recent searches. Typed with a minus ("-", "-猫"),
/// the same as exclusions: conditions to take away, the word to leave out, folders to leave out.
enum SearchSuggestions {
    static func sections(typed raw: String, keys: [String], tags: [TagCount], folders: [(name: String, count: Int)]) -> [SearchSuggestionSection] {
        let typed = raw.trimmingCharacters(in: .whitespaces)
        let present = Set(keys)
        let terms = keys.filter { $0.hasPrefix("t:") }.map { String($0.dropFirst(2)).lowercased() }
        let lone = typed.count == 1 && typed.first.map { TokenQuery.minusSigns.contains($0) } == true
        let negative = lone || TokenQuery.negated(typed) != nil
        let q = (lone ? "" : TokenQuery.negated(typed) ?? typed).lowercased()
        func matches(_ kw: SearchKeyword) -> Bool { q.isEmpty || ([kw.info.word] + kw.info.aliases).contains { $0.lowercased().hasPrefix(q) } }
        // right after "文件夹" / "-文件夹": the folders (matching what is typed)
        if let last = keys.last, last == TokenQuery.pendingFolder || last == TokenQuery.minus + TokenQuery.pendingFolder {
            let excluded = last != TokenQuery.pendingFolder
            let shown = q.isEmpty ? folders : folders.filter { $0.name.lowercased().contains(q) }
            let rows = shown.isEmpty
                ? [SearchSuggestion(id: "noFolder", title: folders.isEmpty ? L("search.noFolders") : L("search.noMatchingFolders"), symbol: "folder")]
                : shown.map { f in SearchSuggestion(id: "folder-" + f.name, title: f.name, subtitle: L("search.row.mediaCount", f.count), symbol: excluded ? "minus.circle" : "folder", tint: excluded ? .exclude : .folder, action: .folder(f.name, excluded: excluded)) }
            return [SearchSuggestionSection(title: excluded ? L("search.section.pickExcludedFolder") : L("search.section.pickFolder"), rows: rows)]
        }
        var out: [SearchSuggestionSection] = []
        if negative {
            let kws = SearchKeyword.all.filter { $0.excludable && !present.contains(TokenQuery.minus + $0.key) && matches($0) }
            if !kws.isEmpty {
                out.append(.init(title: L("search.section.exclude"), rows: kws.map { kw in
                    SearchSuggestion(id: "kw-minus-" + kw.id, title: "−" + kw.info.word, subtitle: kw.info.excludeHint, symbol: "minus.circle", tint: .exclude, action: .key(TokenQuery.minus + kw.key))
                }))
            }
            if !q.isEmpty {
                var rows = [SearchSuggestion(id: "term-minus", title: L("search.row.exclude", q), symbol: "minus.circle", tint: .exclude, action: .key(TokenQuery.minus + TokenQuery.termKey(q)))]
                rows += tags.filter { $0.label.lowercased().contains(q) && $0.label != q }.sorted { $0.count > $1.count }.prefix(6).map { t in
                    SearchSuggestion(id: "tag-minus-" + t.label, title: L("search.row.excludeTag", t.label), subtitle: L("search.row.mediaCount", t.count), symbol: "tag", tint: .exclude, action: .key(TokenQuery.minus + TokenQuery.termKey(t.label.lowercased())))
                }
                out.append(.init(title: L("search.section.content"), rows: rows))
                let fs = folders.filter { $0.name.lowercased().contains(q) && !present.contains(TokenQuery.minus + TokenQuery.folderKey($0.name)) }
                if !fs.isEmpty {
                    out.append(.init(title: L("search.section.folders"), rows: fs.map { f in
                        SearchSuggestion(id: "folder-minus-" + f.name, title: f.name, subtitle: L("search.row.mediaCount", f.count), symbol: "minus.circle", tint: .exclude, action: .folder(f.name, excluded: true))
                    }))
                }
            }
            return out
        }
        let kws = SearchKeyword.all.filter { !present.contains($0.key) && matches($0) }
        if !kws.isEmpty {
            out.append(.init(title: L("search.section.conditions"), rows: kws.map { kw in
                SearchSuggestion(id: "kw-" + kw.id, title: kw.info.word, subtitle: kw.info.hint, symbol: kw.info.symbol, action: .key(kw.key))
            }))
        }
        if !typed.isEmpty {
            var rows = [SearchSuggestion(id: "term", title: L("search.row.searchFor", typed), symbol: "magnifyingglass", action: .key(TokenQuery.termKey(q)))]
            rows += tags.filter { $0.label.lowercased().contains(q) && !terms.contains($0.label) }.sorted { $0.count > $1.count }.prefix(8).map { t in
                SearchSuggestion(id: "tag-" + t.label, title: t.label, subtitle: L("search.row.mediaCount", t.count), symbol: "tag", action: .key(TokenQuery.termKey(t.label.lowercased())))
            }
            out.append(.init(title: L("search.section.content"), rows: rows))
            let fs = folders.filter { $0.name.lowercased().contains(q) }
            if !fs.isEmpty {
                out.append(.init(title: L("search.section.folders"), rows: fs.map { f in
                    SearchSuggestion(id: "folder-" + f.name, title: f.name, subtitle: L("search.row.onlyFolder", f.count), symbol: "folder", tint: .folder, action: .folder(f.name, excluded: false))
                }))
            }
        } else {
            let recent = SearchHistory.items.filter { !terms.contains($0) }.prefix(6)
            if !recent.isEmpty {
                out.append(.init(title: L("search.section.recent"), rows: recent.map { t in
                    SearchSuggestion(id: "recent-" + t, title: t, symbol: "clock.arrow.circlepath", tint: .secondary, action: .key(TokenQuery.termKey(t)))
                } + [SearchSuggestion(id: "clearHistory", title: L("search.clearHistory"), destructive: true, action: .clearHistory)]))
            }
        }
        return out
    }
}

extension Array where Element == TagCount {
    /// Tags someone added by hand first, then tags only AI gave; each group by popularity.
    var userFirst: [TagCount] {
        let mine = filter { $0.user > 0 }, ai = filter { $0.user == 0 }
        return mine.sorted { $0.count > $1.count } + ai.sorted { $0.count > $1.count }
    }
}


// MARK: - Exporting a search result

/// The two switches of the export popover, remembered between exports.
enum SearchExportPrefs {
    static var tags: Bool {
        get { UserDefaults.standard.object(forKey: "export.tags") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "export.tags") }
    }
    static var folders: Bool {
        get { UserDefaults.standard.object(forKey: "export.folders") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "export.folders") }
    }
    /// A plain zip of the media only: no tags, no folders (those switches are off and locked then).
    static var mediaOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "export.mediaOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "export.mediaOnly") }
    }
    static var options: ExportOptions {
        mediaOnly ? ExportOptions(tags: false, folders: false, mediaOnly: true) : ExportOptions(tags: tags, folders: folders, mediaOnly: false)
    }

    /// "<app> 猫咪搜索结果.zip": only the words searched for, not conditions or words left out; what
    /// no system accepts in a file name goes.
    static func fileName(terms: [String]) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        let words = terms.map { $0.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return (words.isEmpty ? L("export.search.fileNameAll") : L("export.search.fileName", words)) + "." + (mediaOnly ? "zip" : "tlpack")
    }
}

/// What the export button next to the search field opens (a small popover on Mac and iPhone):
/// the media of the current search result are exported, and the only choices are whether tags
/// and folder memberships come along.
/// A double click in the links field brings in the post links on the clipboard, without a word
/// about it. iOS may ask each time and be told no; it is simply asked again the next time.
private struct PasteOnDoubleClick: ViewModifier {
    @Binding var links: String
    #if os(macOS)
    @State private var monitor: Any?
    #endif

    private func paste() {
        #if os(macOS)
        let text = NSPasteboard.general.string(forType: .string)
        #else
        let text = UIPasteboard.general.string
        #endif
        guard let text else { return }
        let have = links.split(whereSeparator: \.isWhitespace).map(String.init)
        let fresh = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { Core.fxAPIURL(for: $0) != nil && !have.contains($0) }
        guard !fresh.isEmpty else { return }
        links = (have + fresh).joined(separator: "\n")
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        // the text view takes the clicks before a gesture would see them
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    if event.clickCount == 2, let text = event.window?.contentView?.hitTest(event.locationInWindow) as? NSTextView, text.isEditable, !text.isFieldEditor {
                        DispatchQueue.main.async { paste() }
                    }
                    return event
                }
            }
            .onDisappear { monitor.map(NSEvent.removeMonitor); monitor = nil }
        #else
        content.simultaneousGesture(TapGesture(count: 2).onEnded { paste() })
        #endif
    }
}

/// The quick download button's card: links, one per line, and the way to the full download page.
struct QuickDownloadCard: View {
    @Binding var links: String
    let width: CGFloat
    let openSettings: () -> Void
    let download: () -> Void

    /// The text box against the card behind it.
    private static var fieldFill: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("common.downloadPosts")).font(.headline)
                Text(L("mac.quick.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $links)
                .modifier(PasteOnDoubleClick(links: $links))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 140)
                .background(Self.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if links.isEmpty {
                        Text(L("mac.quick.placeholder"))
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            #if os(macOS)
                            .padding(.top, 6)
                            #else
                            .padding(.top, 14)
                            #endif
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(L("mac.quick.placeholder"))
                .accessibilityIdentifier("quickDownloadLinks")
            HStack {
                Button(L("mac.quick.settings"), action: openSettings)
                    .font(.subheadline)
                Spacer()
                Button(L("common.download"), action: download)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: width)
    }
}

struct SearchExportView: View {
    let count: Int
    let onExport: () -> Void
    @State private var tags = SearchExportPrefs.tags
    @State private var folders = SearchExportPrefs.folders
    @State private var mediaOnly = SearchExportPrefs.mediaOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("export.search.title")).font(.headline)
                Text(count == 0 ? L("export.search.none") : mediaOnly ? L("export.search.countMedia", count) : L("export.search.countWithPosts", count)).font(.footnote).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                // with 以纯媒体导出 on, these two show as off and cannot be changed; what they were
                // before comes back when it is turned off
                row(L("export.option.tags"), L("export.option.tags.detail"),
                    Binding(get: { tags && !mediaOnly }, set: { tags = $0; SearchExportPrefs.tags = $0 }), locked: mediaOnly)
                row(L("export.option.folders"), L("export.option.folders.detail"),
                    Binding(get: { folders && !mediaOnly }, set: { folders = $0; SearchExportPrefs.folders = $0 }), locked: mediaOnly)
                Divider()
                row(L("export.option.mediaOnly"), L("export.option.mediaOnly.detail"),
                    $mediaOnly, locked: false)
                    .onChange(of: mediaOnly) { _, v in SearchExportPrefs.mediaOnly = v }
            }
            Button(action: onExport) { Text(L("export.go")).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(count == 0)
                .accessibilityIdentifier("searchExportGo")
        }
        .padding(20)
        .frame(width: 340)
    }

    /// A title and a note on the left, the switch at the trailing edge.
    private func row(_ title: String, _ detail: String, _ on: Binding<Bool>, locked: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).disabled(locked)
                .accessibilityLabel(title)
        }
        .opacity(locked ? 0.55 : 1)
    }
}

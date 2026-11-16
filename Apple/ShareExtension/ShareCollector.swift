import Foundation
import UniformTypeIdentifiers

/// Brings what was shared into a share folder in the app group, for the share page to show and the
/// person to confirm. Files: copied one at a time into `Shares/Inbox/<id>.partial` (a clone on APFS;
/// nothing is decoded or read into memory, so memory stays flat for hundreds of photos and videos.
/// HEIC, MOV, ProRAW and anything else are copied as they are; the app decides what it can import and
/// lists the rest in the import record). Links: downloaded by the core into `Shares/Staging/<id>`, a
/// library of its own. `publish` renames the folder to `<id>`, with what the person chose in
/// `_share.json`, and the app imports it; `discard` removes all of it, and nothing was added anywhere.
final class ShareCollector: @unchecked Sendable {
    /// The App Group shared with the share extension (config.yaml → Info.plist `TLAppGroup`).
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "TLAppGroup") as? String ?? ""
    static let darwinName = groupID + ".share-inbox"
    #if DEBUG && os(macOS)
    /// Debug builds share into their own folder, so a test share never reaches the real app.
    static let sharesFolder = "Shares-Debug"
    #else
    static let sharesFolder = "Shares"
    #endif

    enum Failure: LocalizedError {
        case noContainer
        var errorDescription: String? { L("share.noGroup") }
    }

    /// What was brought here, for the page.
    struct Batch: Sendable {
        var count = 0
        var problems: [String] = []
        var previewFiles: [URL] = []
        /// How much was brought here.
        var bytes: Int64 = 0
        /// The shared post's text, when it was one post.
        var text: String?
        var failedLinks: [String] = []
        var staged = false
        var id = ""
    }

    /// How many are pictured on the page, at most.
    static let previewLimit = 9

    private var partial: URL?
    private var staging: URL?
    /// The shares folder; tests pass their own.
    private let sharesOverride: URL?
    init(shares: URL? = nil) { sharesOverride = shares }

    private var shares: URL? { sharesOverride ?? Self.groupShares }

    private static var groupShares: URL? {
        #if DEBUG
        // a test window with the page's own code, which has no app group of its own
        if let d = ProcessInfo.processInfo.environment["TL_SHARES_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        #endif
        guard !groupID.isEmpty else { return nil }   // this build has no share extension
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent(sharesFolder, isDirectory: true)
    }

    /// The library's folders, as the app last wrote them (the extension cannot open the library).
    static func folders() -> [String] {
        guard let url = groupShares?.appendingPathComponent("folders.json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func collect(_ providers: [NSItemProvider], progress: @escaping @Sendable (String) -> Void) async throws -> Batch {
        let fm = FileManager.default
        guard let shares else { throw Failure.noContainer }
        let id = "share-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let inbox = shares.appendingPathComponent("Inbox", isDirectory: true)
        let dir = inbox.appendingPathComponent(id + ".partial", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        partial = dir
        Self.removeOldStaging(in: shares)
        var batch = Batch(id: id)
        var text = ""
        for (i, provider) in providers.enumerated() {
            progress(L("share.progress", i + 1, providers.count) + (provider.suggestedName.map { "\n\($0)" } ?? ""))
            let name = provider.suggestedName ?? L("share.untitled")
            do {
                if let t = try await Self.sharedText(provider) { text += t + "\n"; continue }
                guard let copied = try await copy(provider, into: dir) else {
                    batch.problems.append(L("share.item.unsupported", i + 1, name))
                    continue
                }
                batch.count += copied.files
                batch.previewFiles += copied.previews.prefix(max(0, Self.previewLimit - batch.previewFiles.count))
            } catch {
                batch.problems.append(L("share.item.error", i + 1, name, error.localizedDescription))
            }
        }
        let links = SharedLinks.posts(in: text)
        if !text.isEmpty, links.isEmpty { batch.problems.append(L("share.noLink")) }
        if !links.isEmpty {
            progress(L("share.downloading", links.count))
            let stage = shares.appendingPathComponent("Staging/" + id, isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            staging = stage
            let staged = try await Self.stage(stage, links)
            batch.staged = !staged.items.isEmpty
            batch.count += staged.items.count
            batch.text = Set(staged.items.map(\.post_id)).count == 1 ? staged.items.first?.text : nil
            batch.previewFiles += staged.items.prefix(max(0, Self.previewLimit - batch.previewFiles.count)).map { URL(fileURLWithPath: $0.path) }
            batch.failedLinks = staged.failed.map { $0[0] }
            batch.problems += staged.failed.map { "\($0[0])\n\($0[1])" }
        }
        for root in [dir, staging].compactMap({ $0 }) {
            for case let f as URL in fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) ?? FileManager.DirectoryEnumerator() {
                batch.bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return batch
    }

    /// The person chose: hands it all to the app.
    func publish(_ batch: Batch, folder: String?, dropped: Bool = false) async throws {
        guard let partial, let shares else { return }
        let fm = FileManager.default
        if batch.staged, let staging { try await Self.pack(staging, to: partial.appendingPathComponent("post.tlpack")) }
        let choice: [String: Any] = ["version": 1, "folder": folder ?? "", "links": batch.failedLinks, "dropped": dropped]
        try JSONSerialization.data(withJSONObject: choice).write(to: partial.appendingPathComponent("_share.json"))
        try fm.moveItem(at: partial, to: shares.appendingPathComponent("Inbox/" + batch.id, isDirectory: true))
        self.partial = nil
        if let staging { try? fm.removeItem(at: staging) }
        staging = nil
        if sharesOverride == nil { CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(Self.darwinName as CFString), nil, nil, true) }
    }

    /// Removes what was brought here.
    func discard() {
        for u in [partial, staging].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
        partial = nil
        staging = nil
    }

    /// Staging folders of pages that were stopped half-way (the system ended the extension).
    private static func removeOldStaging(in shares: URL) {
        let fm = FileManager.default
        let folder = shares.appendingPathComponent("Staging", isDirectory: true)
        for u in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let d = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate, d < Date().addingTimeInterval(-86_400) { try? fm.removeItem(at: u) }
        }
    }

    // MARK: Links

    private struct Staged: Decodable {
        struct Item: Decodable { let media_id: String; let post_id: String; let path: String; let text: String? }
        let items: [Item]
        let failed: [[String]]
    }
    private struct Answer<T: Decodable>: Decodable { let ok: T?; let error: String? }
    private struct CoreFailure: LocalizedError { let errorDescription: String? }

    private static func answer<T: Decodable>(_ raw: UnsafeMutablePointer<CChar>?, as: T.Type) throws -> T {
        guard let raw else { throw CoreFailure(errorDescription: L("share.noResult")) }
        defer { tl_string_free(raw) }
        let a = try JSONDecoder().decode(Answer<T>.self, from: Data(String(cString: raw).utf8))
        if let error = a.error { throw CoreFailure(errorDescription: error) }
        guard let ok = a.ok else { throw CoreFailure(errorDescription: L("share.noResult")) }
        return ok
    }

    private static func stage(_ dir: URL, _ links: [String]) async throws -> Staged {
        try await Task.detached(priority: .userInitiated) {
            let urls = String(decoding: try JSONEncoder().encode(links), as: UTF8.self)
            return try answer(tl_share_stage(dir.path, urls, "auto"), as: Staged.self)
        }.value
    }

    private static func pack(_ dir: URL, to out: URL) async throws {
        struct Nothing: Decodable { init(from decoder: Decoder) throws {} }
        try await Task.detached(priority: .userInitiated) {
            let raw = tl_share_pack(dir.path, out.path)
            guard let raw else { throw CoreFailure(errorDescription: L("share.noResult")) }
            defer { tl_string_free(raw) }
            if let d = try JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any], let e = d["error"] as? String { throw CoreFailure(errorDescription: e) }
        }.value
    }

    /// A link or text is what the provider holds (a file's URL is a file).
    static func holdsText(_ p: NSItemProvider) -> Bool {
        let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
        if types.contains(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) || $0.conforms(to: .folder) || $0.conforms(to: .fileURL) }) { return false }
        return types.contains { $0.conforms(to: .url) || $0.conforms(to: .text) }
    }

    /// A shared link or text, when that is what the provider holds.
    private static func sharedText(_ p: NSItemProvider) async throws -> String? {
        guard holdsText(p) else { return nil }
        let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
        guard let t = types.first(where: { $0.conforms(to: .url) }) ?? types.first(where: { $0.conforms(to: .text) }) else { return nil }
        return try await withCheckedThrowingContinuation { c in
            _ = p.loadItem(forTypeIdentifier: t.identifier, options: nil) { item, error in
                if let u = item as? URL { c.resume(returning: u.absoluteString) }
                else if let s = item as? String { c.resume(returning: s) }
                else if let d = item as? Data { c.resume(returning: URL(dataRepresentation: d, relativeTo: nil)?.absoluteString ?? String(decoding: d, as: UTF8.self)) }
                else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    /// The most faithful file type a provider offers: the original movie, else the original
    /// still (never a Live Photo bundle or a preview), else a folder, else a file URL.
    private func pick(_ p: NSItemProvider) -> (String, UTType)? {
        let ids = p.registeredTypeIdentifiers
        let types = ids.compactMap { id in UTType(id).map { (id, $0) } }.filter { !$0.0.contains("live-photo") && !$0.0.contains("private") }
        if let m = types.first(where: { $0.1.conforms(to: .movie) }) { return m }
        // Photos also offers a converted JPEG: keep the original HEIC / HEIF / AVIF when there is one
        let originals: [UTType] = [.heic, .heif, UTType("public.avif")].compactMap { $0 }
        if let o = types.first(where: { t in originals.contains { t.1.conforms(to: $0) } }) { return o }
        if let i = types.first(where: { $0.1.conforms(to: .image) }) { return i }
        if let f = types.first(where: { $0.1.conforms(to: .folder) }) { return f }
        if let u = types.first(where: { $0.1.conforms(to: .fileURL) }) { return u }
        return nil
    }

    private struct Copied { var files: Int; var previews: [URL] }

    private func copy(_ provider: NSItemProvider, into dir: URL) async throws -> Copied? {
        guard let (id, type) = pick(provider) else { return nil }
        if type.conforms(to: .fileURL) {
            // Finder / Files hand over a file URL: copy that file (or folder) if it is media
            let url: URL = try await withCheckedThrowingContinuation { c in
                _ = provider.loadItem(forTypeIdentifier: id, options: nil) { item, error in
                    if let u = item as? URL { c.resume(returning: u) }
                    else if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { c.resume(returning: u) }
                    else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let t = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            guard let t, t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .folder) else { return nil }
            return try place(url, name: url.lastPathComponent, into: dir)
        }
        return try await withCheckedThrowingContinuation { c in
            _ = provider.loadFileRepresentation(forTypeIdentifier: id) { url, error in
                // the file exists only until this returns: copy it now
                guard let url else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += "." + ext }
                do { c.resume(returning: try self.place(url, name: name, into: dir)) } catch { c.resume(throwing: error) }
            }
        }
    }

    /// Copies a file or folder under a free name (clone on APFS; never read into memory).
    private func place(_ src: URL, name: String, into dir: URL) throws -> Copied {
        let fm = FileManager.default
        let clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        var dst = dir.appendingPathComponent(clean.isEmpty ? L("share.untitled") : clean)
        var k = 2
        while fm.fileExists(atPath: dst.path) {
            let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
            dst = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(k))" : "\(base) (\(k)).\(ext)")
            k += 1
        }
        try fm.copyItem(at: src, to: dst)
        var files = 0
        var previews: [URL] = []
        if let e = fm.enumerator(at: dst, includingPropertiesForKeys: [.isRegularFileKey]), (try? dst.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files += 1
                if previews.count < 3 { previews.append(u) }
            }
        } else {
            files = 1
            previews = [dst]
        }
        return Copied(files: files, previews: previews)
    }

    /// Attachments of every input item.
    static func providers(_ context: NSExtensionContext?) -> [NSItemProvider] {
        (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    }
}

/// The links of posts in shared text, normalized as `SharedLinks` in the Flutter app and in Android's
/// `ShareActivity`: x.com, twitter.com and the core's mirrors only; other sites, profile pages and
/// credentials are never sent to a download.
enum SharedLinks {
    static func posts(in text: String) -> [String] {
        let hosts: Set<String> = ["twitter.com", "x.com", "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com"]
        var seen: [String] = []
        let pattern = #"(?i)(?<![a-z0-9_.@/])(?:https?://)?(?:(?:www|mobile|m)\.)?(?:twitter\.com|x\.com|fxtwitter\.com|fixupx\.com|vxtwitter\.com|fixvx\.com)/[^\s<>()]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: whole) {
            guard let r = Range(match.range, in: text) else { continue }
            let value = String(text[r])
            guard let u = URLComponents(string: value.contains("://") ? value : "https://" + value), u.user == nil, u.password == nil, u.port == nil else { continue }
            var host = (u.host ?? "").lowercased()
            for prefix in ["www.", "mobile.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
            guard hosts.contains(host) else { continue }
            let parts = u.path.split(separator: "/").map(String.init)
            let pair: (String, String)?
            if parts.count >= 4, parts[0] == "i", parts[1] == "web", parts[2] == "status" { pair = ("i", parts[3]) }
            else if parts.count >= 3, parts[0] == "i", parts[1] == "status" { pair = ("i", parts[2]) }
            else if parts.count >= 3, ["status", "statuses"].contains(parts[1].lowercased()) { pair = (parts[0], parts[2]) }
            else { pair = nil }
            guard let (user, raw) = pair, user.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { continue }
            let id = String(raw.prefix { $0.isASCII && $0.isNumber })
            guard !id.isEmpty, id.count <= 20 else { continue }
            let link = "https://x.com/\(user)/status/\(id)"
            if !seen.contains(link) { seen.append(link) }
        }
        return seen
    }
}

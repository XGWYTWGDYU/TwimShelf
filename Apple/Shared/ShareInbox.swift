import Foundation

/// Files shared into TwimShelf (from Photos, Files or Finder) wait in the app group's
/// container. The share extension only copies files — it never decodes an image, so its memory
/// stays flat however many photos and videos are shared — into `Shares/Inbox/<id>.partial`, and
/// renames the folder to `<id>` once every file is in. The app imports complete folders as loose
/// media (one import at a time, like every other import) and removes what it imported; problem
/// files move to `Shares/Kept/<id>`, listed in that import's record and deleted with it.
/// An interrupted import leaves the folder in the inbox: the next run imports it again, and what
/// was already imported counts as a duplicate.
/// 下载帖子 from the app's icon: asked at any time, answered by the feed when it is there.
enum QuickDownloadRequest {
    static let changed = Notification.Name("QuickDownloadRequest.changed")
    nonisolated(unsafe) private static var pending = false
    static func ask() {
        pending = true
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func take() -> Bool {
        defer { pending = false }
        return pending
    }
}

enum ShareInbox {
    /// The App Group shared with the share extension (config.yaml → Info.plist `TLAppGroup`).
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "TLAppGroup") as? String ?? ""
    /// Posted (Darwin notification) by the extension when a share is complete.
    static let darwinName = groupID + ".share-inbox"
    /// Posted (NotificationCenter) after the app imported shares; object = [ImportReport].
    static let imported = Notification.Name("ShareInbox.imported")
    /// Posted when a share could not be imported; object = message. The share stays in the
    /// inbox and is tried again the next time the app becomes active.
    static let failed = Notification.Name("ShareInbox.failed")

    static var shares: URL? {
        #if DEBUG
        // test runs against a synthetic library never touch real shares
        if let d = ProcessInfo.processInfo.environment["TL_LIBRARY_DIR"] { return URL(fileURLWithPath: d).appendingPathComponent(".shares", isDirectory: true) }
        #endif
        #if DEBUG && os(macOS)
        let folder = "Shares-Debug"   // matches the debug extension
        #else
        let folder = "Shares"
        #endif
        guard !groupID.isEmpty else { return nil }   // this build has no share extension
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent(folder, isDirectory: true)
    }
    static var inbox: URL? { shares?.appendingPathComponent("Inbox", isDirectory: true) }
    static var kept: URL? { shares?.appendingPathComponent("Kept", isDirectory: true) }

    /// Folders holding the app's own copies of import sources (deleted together with a record).
    static var ownedRoots: [URL] {
        var v: [URL] = []
        if let s = shares { v.append(s) }
        #if os(iOS)
        v.append(FileManager.default.temporaryDirectory)   // files picked in Files are copied here
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { v.append(docs.appendingPathComponent("Inbox")) }
        #endif
        return v
    }

    /// Complete shares, oldest first. Partial ones older than a day (an extension that was
    /// stopped half-way) are removed.
    static func pending() -> [URL] {
        guard let inbox else { return [] }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        var ready: [(URL, Date)] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            guard v?.isDirectory == true else { continue }
            let created = v?.creationDate ?? .distantPast
            if u.pathExtension == "partial" {
                if created < Date().addingTimeInterval(-86_400) { try? fm.removeItem(at: u) }
                continue
            }
            ready.append((u, created))
        }
        return ready.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// What the person chose on the share page, in `_share.json`.
    private struct Choice: Decodable { var folder: String?; var links: [String]?; var dropped: Bool? }

    /// One confirmed share: its downloaded post (a pack), its files, into the folder chosen. Links
    /// the page could not download go to the download queue, with the same folder.
    private static func importShare(_ dir: URL, keepTo: URL?) throws -> [ImportReport] {
        let fm = FileManager.default
        let file = dir.appendingPathComponent("_share.json")
        let choice = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Choice.self, from: $0) }
        let folder = choice?.folder.flatMap { $0.isEmpty ? nil : $0 }
        if let folder { _ = try? Core.createFolder(folder) }
        var reports: [ImportReport] = []
        let pack = dir.appendingPathComponent("post.tlpack")
        if fm.fileExists(atPath: pack.path) {
            let report = try Core.importPack(pack, folder: folder)
            // what did not come in yet stays possible: the share stays in the inbox and the reason is shown
            if let why = report.incomplete { throw CoreError(message: why) }
            reports.append(report)
            try fm.removeItem(at: pack)
        }
        if let links = choice?.links, !links.isEmpty {
            _ = try Core.startDownload(DownloadRequest(urls: links, revive: true, folder: folder))
        }
        try? fm.removeItem(at: file)
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try fm.removeItem(at: dir)
            return reports
        }
        reports.append(try Core.importLooseDir(dir, folder: folder, consume: true, keepTo: keepTo, album: choice?.dropped != true))
        return reports
    }

    /// The library's folders for the share extension, which cannot open the library.
    static func publishFolders() {
        guard let shares else { return }
        let names = Core.folders().map(\.name)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: shares, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(names) { try? data.write(to: shares.appendingPathComponent("folders.json"), options: .atomic) }
        }
    }

    private static var running = false

    /// Imports every complete share off the main thread, then posts `imported` with the reports.
    static func importPending() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running, !pending().isEmpty else { return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            var reports: [ImportReport] = []
            var failure: String?
            // repeat: a share completing while we import is picked up in the same run
            while let next = pending().first {
                let keep = kept?.appendingPathComponent(next.lastPathComponent, isDirectory: true)
                do { reports += try importShare(next, keepTo: keep) }
                catch {
                    // never set a share aside without a record: it stays in the inbox, the reason
                    // is shown, and it is tried again next time (no retry loop within this run)
                    failure = L("shareInbox.failed", pending().count, error.localizedDescription)
                    break
                }
            }
            DispatchQueue.main.async {
                running = false
                if let failure { NotificationCenter.default.post(name: ShareInbox.failed, object: failure) }
                guard !reports.isEmpty else { return }
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                NotificationCenter.default.post(name: imported, object: reports)
            }
        }
    }

    /// "清除所有数据": shares waiting to be imported and files kept from earlier shares.
    static func wipe() {
        guard let shares else { return }
        let fm = FileManager.default
        for sub in ["Inbox", "Kept"] { try? fm.removeItem(at: shares.appendingPathComponent(sub, isDirectory: true)) }
    }

    /// One-line summary for a toast.
    static func summary(_ reports: [ImportReport]) -> String {
        let added = reports.reduce(0) { $0 + ($1.newMedia ?? $1.media) }
        let dup = reports.reduce(0) { $0 + ($1.duplicateMedia ?? 0) }
        let problems = reports.reduce(0) { $0 + $1.skipped.count }
        var t = L("shareInbox.imported", added)
        if dup > 0 { t += L("shareInbox.dup", dup) }
        if problems > 0 { t += L("shareInbox.problems", problems) }
        return t
    }

    /// Calls `handler` on the main queue whenever the extension finishes a share.
    static func observe(_ handler: @escaping () -> Void) {
        observer = handler
        publishFolders()
        NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { _ in publishFolders() }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { ShareInbox.observer?() }
        }, darwinName as CFString, nil, .deliverImmediately)
    }
    nonisolated(unsafe) private static var observer: (() -> Void)?
}

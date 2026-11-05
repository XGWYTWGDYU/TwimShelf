import Foundation

/// 存储空间: the places only the app knows (itself, its caches) for `Core.storageUsage`, and how
/// every group is shown (iOS, iPadOS and the Mac share this).
enum StorageReport {
    /// Groups in the order the core reports them; the colour is a palette index.
    static let palette = ["app": 0, "photos": 1, "videos": 2, "bin": 3, "database": 4, "libraryOther": 5, "models": 6, "thumbnails": 7, "cache": 8]

    static var extraPlaces: [(key: String, url: URL)] {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let thumbs = caches.appendingPathComponent("GridThumbnails", isDirectory: true)
        var v: [(key: String, url: URL)] = [("app", Bundle.main.bundleURL), ("thumbnails", thumbs)]
        #if os(iOS)
        // the app's own caches folder, without the thumbnails (a group of their own)
        for u in (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent != "GridThumbnails" { v.append(("cache", u)) }
        v.append(("cache", fm.temporaryDirectory))
        #else
        // outside a sandbox the caches folder is shared: only this app's part of it
        // (its temporary folder too is shared with every other app of this user: neither counted nor cleared)
        if let id = Bundle.main.bundleIdentifier { v.append(("cache", caches.appendingPathComponent(id, isDirectory: true))) }
        #endif
        return v
    }

    /// Measures off the main thread; `done` on the main thread.
    static func measure(_ done: @escaping @MainActor (Result<Core.StorageUsage, Error>) -> Void) {
        let places = extraPlaces
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Core.storageUsage(extra: places) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(r) } }
        }
    }

    static func title(_ key: String) -> String { L("storage.group." + key) }            // i18n-keys: storage.group.*
    static func detail(_ key: String) -> String { L("storage.group." + key + ".detail") } // i18n-keys: storage.group.*.detail
    static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// The groups this page may clear; everything else is the library or the app itself. The bin
    /// is permanent, so it starts unticked.
    static let clearable: Set<String> = ["thumbnails", "cache", "bin"]
    static let selectedAtFirst: Set<String> = ["thumbnails", "cache"]

    /// A share of the whole, as a person reads it: `38%`, `2.4%`, `<0.1%`.
    static func percent(_ share: Double) -> String {
        let p = share * 100
        if p < 0.1 { return "<0.1%" }
        return p >= 10 ? String(format: "%.0f%%", p) : String(format: "%.1f%%", p)
    }

    /// Free space on the volume the app is on.
    static func freeSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Clears [keys] off the main thread. `done` on the main thread gets what could not be cleared
    /// and why. Files of the "cache" group touched in the last hour stay: a share or an export may
    /// be using them.
    static func clear(_ keys: Set<String>, done: @escaping @MainActor ([(path: String, reason: String)]) -> Void) {
        let places = extraPlaces
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let recent = Date().addingTimeInterval(-3600)
            var skipped: [(path: String, reason: String)] = []
            for (key, folder) in places where keys.contains(key) && clearable.contains(key) {
                // iOS lists the caches folder's entries one by one: an entry may be a file
                var isFolder: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder) else { continue }
                // thumbnails: the files only, the running grid keeps writing into its folders
                let items: [URL] = !isFolder.boolValue ? [folder]
                    : key == "thumbnails" ? (fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
                    : (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for item in items {
                    if key == "cache", let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > recent {
                        skipped.append((item.path, L("storage.clear.recent")))
                        continue
                    }
                    do { try fm.removeItem(at: item) } catch { skipped.append((item.path, error.localizedDescription)) }
                }
            }
            if keys.contains("bin") {
                do { try Core.emptyTrash() } catch { skipped.append((title("bin"), error.localizedDescription)) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(skipped) } }
        }
    }
}

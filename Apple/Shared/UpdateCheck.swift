import Foundation

/// 检查更新, in GitHub builds only (they carry `TLUpdateRepository` in Info.plist; every other
/// build has it empty and never looks). At most once a day when the app opens, or when asked.
enum UpdateCheck {
    static var repo: String? {
        guard let r = Bundle.main.object(forInfoDictionaryKey: "TLUpdateRepository") as? String, r.contains("/"), !r.hasPrefix("$(") else { return nil }
        return r
    }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    private static let lastKey = "update.lastCheck", skippedKey = "update.skipped"
    static func skip(_ version: String) { UserDefaults.standard.set(version, forKey: skippedKey) }

    /// Off the main thread; `done` on it with the newer release (nil: current, or not due).
    /// `manual` checks now and also offers a skipped version.
    static func run(manual: Bool = false, done: @escaping @MainActor (Result<Core.UpdateInfo?, Error>) -> Void) {
        guard let repo else { return }
        let ud = UserDefaults.standard
        if !manual, Date().timeIntervalSince1970 - ud.double(forKey: lastKey) < 86_400 { return }
        #if os(iOS)
        let suffixes: [String] = []      // iOS: the release page
        #else
        let suffixes = [".dmg"]
        #endif
        let current = current
        DispatchQueue.global(qos: .utility).async {
            let r = Result { try Core.checkUpdate(repo: repo, current: current, suffixes: suffixes) }
            DispatchQueue.main.async {
                if case .success = r { ud.set(Date().timeIntervalSince1970, forKey: lastKey) }
                let shown = r.map { info in info.flatMap { !manual && ud.string(forKey: skippedKey) == $0.version ? nil : $0 } }
                // a check nobody asked for stays quiet when it fails (offline, rate limited)
                if !manual, case .failure = shown { return }
                MainActor.assumeIsolated { done(shown) }
            }
        }
    }
}

import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Items are device-only (not iCloud-synced).
enum Keychain {
    private static let service: String = {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["TL_KEYCHAIN_SUFFIX"] { return "org.twimshelf.\(s)" }
        #endif
        return "org.twimshelf"
    }()

    #if DEBUG && os(macOS)
    /// Debug Mac builds are re-signed on every build, which makes the login keychain prompt for
    /// access each time. They keep secrets in a 0600 file inside the library folder instead.
    private static var debugFile: URL { Core.libraryDirectory.appendingPathComponent(".debug-secrets.json") }
    private static func debugLoad() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: debugFile))) ?? [:]
    }
    static func get(_ key: String) -> String? { debugLoad()[key] }
    @discardableResult
    static func set(_ key: String, _ value: String?) -> Bool {
        var d = debugLoad()
        d[key] = (value?.isEmpty ?? true) ? nil : value
        do {
            try FileManager.default.createDirectory(at: debugFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(d).write(to: debugFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: debugFile.path)
            return true
        } catch { return false }
    }
    static func wipeAll() { try? FileManager.default.removeItem(at: debugFile) }
    #else
    static func get(_ key: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Saves (or, with nil/empty, removes) a secret; true on success. An existing item is
    /// updated in place, so a failed save never loses the value that was there.
    @discardableResult
    static func set(_ key: String, _ value: String?) -> Bool {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        guard let value, !value.isEmpty else {
            let s = SecItemDelete(base as CFDictionary)
            return s == errSecSuccess || s == errSecItemNotFound
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { AppLog.error("keychain", L("keychain.err.save", status)) }
        return status == errSecSuccess
    }

    static func wipeAll() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
    #endif
}

enum Session {
    /// No-op: X account cookies are now synced directly inside the library store (no Keychain encryption).
    static func applyStoredCookies() {}
}

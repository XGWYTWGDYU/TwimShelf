import AppKit
import Security

/// 检查更新 on the Mac (GitHub builds), as mature apps update themselves: the release's disk
/// image is downloaded in the background and checked against the release (size, SHA-256); the
/// app in it is checked (same bundle id, the release's version, a valid signature from the same
/// team as this one) and staged beside this app. Then it is put in place — now, reopening the
/// app, or when the app quits. Where this app cannot be replaced (a folder it may not write, or
/// run from a translocated copy) the disk image is opened to drag the app over, as on install.
@MainActor
enum MacUpdate {
    static func show(_ r: Result<Core.UpdateInfo?, Error>, window: NSWindow?, manual: Bool = false) {
        switch r {
        case .failure(let e): macAlert(window, L("update.failed", e.localizedDescription))
        case .success(nil): if manual { macAlert(window, L("update.current", UpdateCheck.current)) }
        case .success(let info?):
            let hasInstaller = info.assetUrl != nil
            macChoose(window, title: L("update.available.title", info.version), message: L("update.available.message", UpdateCheck.current),
                      options: [hasInstaller ? L("update.install") : L("update.openPage"), L("update.later"), L("update.skip")]) { i in
                if i == 2 { UpdateCheck.skip(info.version); return }
                guard i == 0 else { return }
                if hasInstaller { install(info, window: window) } else if let u = URL(string: info.pageUrl), u.scheme == "https" { NSWorkspace.shared.open(u) }
            }
        }
    }

    /// The new version waiting beside this app (put in place when the app quits).
    private static var staged: URL?

    private static func install(_ info: Core.UpdateInfo, window: NSWindow?) {
        let progress = ProgressSheet(on: window, text: L("update.downloading"))
        let target = replaceableBundle()
        let downloads = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TwimShelf-updates", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { () -> URL in
                let dmg = try Core.downloadUpdate(info, into: downloads)
                guard let target else { return dmg }      // cannot replace: the image is opened
                defer { try? FileManager.default.removeItem(at: dmg) }
                return try stage(dmg: dmg, version: info.version, beside: target)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    progress.close()
                    switch r {
                    case .success(let file) where target == nil:
                        NSWorkspace.shared.open(file)
                        macAlert(window, L("update.opened.mac"))
                    case .success(let app):
                        staged = app
                        macChoose(window, title: L("update.ready.title"), message: L("update.ready.message", info.version),
                                  options: [L("update.relaunch"), L("update.later")]) { i in
                            if i == 0 { apply(relaunch: true); NSApp.terminate(nil) }
                        }
                    case .failure(let e):
                        AppLog.error("update", "\(e)")
                        macAlert(window, L("update.failed", e.localizedDescription))
                    }
                }
            }
        }
    }

    /// This app, when it can be replaced where it is.
    private static func replaceableBundle() -> URL? {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/") else { return nil }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path), fm.isWritableFile(atPath: app.path) else { return nil }
        return app
    }

    enum UpdateError: LocalizedError {
        case image, noApp, wrongApp, signature
        var errorDescription: String? {
            switch self {
            case .image: "hdiutil"
            case .noApp, .wrongApp: L("update.wrongApp")
            case .signature: L("update.badSignature")
            }
        }
    }

    /// Mounts the image, checks the app in it and copies it beside `target` (the same volume:
    /// putting it in place is then a rename). Off the main thread.
    nonisolated private static func stage(dmg: URL, version: String, beside target: URL) throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("TwimShelf-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]) else { throw UpdateError.image }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
        }
        guard let name = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else { throw UpdateError.noApp }
        let app = mount.appendingPathComponent(name)
        try check(app, version: version)
        let out = target.deletingLastPathComponent().appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-update-\(UUID().uuidString).app")
        guard run("/usr/bin/ditto", [app.path, out.path]) else { throw UpdateError.image }
        do { try check(out, version: version) } catch { try? fm.removeItem(at: out); throw error }
        return out
    }

    /// The same app (bundle id), the release's version, a valid signature, and when this app is
    /// signed by a team, by the same team.
    nonisolated private static func check(_ app: URL, version: String) throws {
        guard let b = Bundle(url: app), b.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp }
        let v = (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        guard v == version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) else { throw UpdateError.wrongApp }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), nil) == errSecSuccess
        else { throw UpdateError.signature }
        if let mine = teamID(Bundle.main.bundleURL), teamID(app) != mine { throw UpdateError.signature }
    }

    nonisolated private static func teamID(_ app: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Puts the staged version in place once this process has quit (a small script outlives it:
    /// a running app cannot replace itself), and with `relaunch`, opens it. Once per staging.
    static func apply(relaunch: Bool) {
        guard let new = staged else { return }
        staged = nil
        let old = Bundle.main.bundleURL
        // (the reopened app must not inherit a debug run's fake update and start over)
        let script = """
        unset TL_FAKE_UPDATE_DMG TL_FAKE_UPDATE_AUTO
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        bak="$2.old-$$"
        if mv "$2" "$bak"; then
          if mv "$3" "$2"; then rm -rf "$bak"; else mv "$bak" "$2"; rm -rf "$3"; fi
        fi
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        [ "$4" = 1 ] && open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "twimshelf-update", String(ProcessInfo.processInfo.processIdentifier), old.path, new.path, relaunch ? "1" : "0"]
        try? p.run()
    }

    /// The app quits with a version staged: it is put in place (not reopened).
    static func applyOnQuit() { apply(relaunch: false) }

    /// At launch: staged copies a run left behind (it crashed before quitting) go.
    static func removeLeftovers() {
        let app = Bundle.main.bundleURL, dir = app.deletingLastPathComponent()
        let prefix = ".\(app.deletingPathExtension().lastPathComponent)-update-"
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) && name.hasSuffix(".app") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    #if DEBUG
    /// TL_FAKE_UPDATE_DMG=<disk image> (with TL_FAKE_UPDATE_AUTO, no questions): stages the app in
    /// that image as if a release had been downloaded, and reopens into it.
    static func debugFakeUpdate(dmg: String, auto: Bool, window: NSWindow?) {
        guard let target = replaceableBundle() else { NSLog("fake update: not replaceable %@", Bundle.main.bundleURL.path); return }
        let version = UpdateCheck.current
        DispatchQueue.global().async {
            let r = Result { try stage(dmg: URL(fileURLWithPath: dmg), version: version, beside: target) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch r {
                    case .success(let app):
                        NSLog("fake update staged at %@", app.path)
                        staged = app
                        if auto { apply(relaunch: true); NSApp.terminate(nil); return }
                        macChoose(window, title: L("update.ready.title"), message: L("update.ready.message", version), options: [L("update.relaunch"), L("update.later")]) { i in
                            if i == 0 { apply(relaunch: true); NSApp.terminate(nil) }
                        }
                    case .failure(let e): NSLog("fake update failed: %@", "\(e)")
                    }
                }
            }
        }
    }
    #endif
}

/// A small sheet while the update downloads.
@MainActor
private final class ProgressSheet {
    private weak var parent: NSWindow?
    private var sheet: NSWindow?

    init(on parent: NSWindow?, text: String) {
        self.parent = parent
        guard let parent else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 76), styleMask: [.titled], backing: .buffered, defer: false)
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        let label = NSTextField(labelWithString: text)
        let row = NSStackView(views: [spin, label])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(row)
        if let c = w.contentView {
            NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: c.centerXAnchor), row.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
        }
        parent.beginSheet(w)
        sheet = w
    }

    func close() {
        if let sheet { parent?.endSheet(sheet) }
        sheet = nil
    }
}

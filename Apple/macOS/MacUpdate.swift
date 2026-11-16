import AppKit

/// 检查更新 on the Mac (GitHub builds): the release's disk image is downloaded, checked against
/// the release and opened; the app is then dragged over the old one, as when it was installed.
@MainActor
enum MacUpdate {
    static func show(_ r: Result<Core.UpdateInfo?, Error>, window: NSWindow?, manual: Bool = false) {
        switch r {
        case .failure(let e): macAlert(window, L("update.failed", e.localizedDescription))
        case .success(nil): if manual { macAlert(window, L("update.current", UpdateCheck.current)) }
        case .success(let info?):
            let hasInstaller = info.assetUrl != nil
            macChoose(window, title: L("update.available.title", info.version), message: L("update.available.message", UpdateCheck.current),
                      options: [hasInstaller ? L("update.install") : L("update.openPage"), L("update.skip")]) { i in
                if i == 1 { UpdateCheck.skip(info.version); return }
                if hasInstaller { install(info, window: window) } else if let u = URL(string: info.pageUrl), u.scheme == "https" { NSWorkspace.shared.open(u) }
            }
        }
    }

    private static func install(_ info: Core.UpdateInfo, window: NSWindow?) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        AppLog.info("update", L("update.downloading"))
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Core.downloadUpdate(info, into: dir) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch r {
                    case .success(let dmg):
                        NSWorkspace.shared.open(dmg)
                        macAlert(window, L("update.opened.mac"))
                    case .failure(let e):
                        macAlert(window, L("update.failed", e.localizedDescription))
                    }
                }
            }
        }
    }
}

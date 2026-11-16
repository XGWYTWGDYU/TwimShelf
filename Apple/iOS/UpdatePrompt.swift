import UIKit

/// 检查更新 on iOS and iPadOS: a newer release opens its GitHub page, where it is downloaded
/// (an app from outside the App Store cannot install itself).
@MainActor
enum UpdatePrompt {
    static func show(_ r: Result<Core.UpdateInfo?, Error>, on vc: UIViewController?, manual: Bool = false) {
        guard let vc else { return }
        let a: UIAlertController
        switch r {
        case .failure(let e):
            a = UIAlertController(title: L("update.failed", e.localizedDescription), message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
        case .success(nil):
            guard manual else { return }
            a = UIAlertController(title: L("update.current", UpdateCheck.current), message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
        case .success(let info?):
            a = UIAlertController(title: L("update.available.title", info.version), message: L("update.available.message", UpdateCheck.current), preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L("update.openPage"), style: .default) { _ in
                if let u = URL(string: info.pageUrl), u.scheme == "https" { UIApplication.shared.open(u) }
            })
            a.addAction(UIAlertAction(title: L("update.skip"), style: .destructive) { _ in UpdateCheck.skip(info.version) })
            a.addAction(UIAlertAction(title: L("update.later"), style: .cancel))
        }
        var top = vc
        while let p = top.presentedViewController { top = p }
        top.present(a, animated: true)
    }
}

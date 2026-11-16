import SwiftUI
import UIKit

/// "导入 TwimShelf" in the share sheet (Photos, Files, X…): the shared page (`ShareSheetView`).
/// The app imports what was confirmed the next time it is active (right away when it is already
/// running) and records every file's result. The system's sheet around an extension keeps its own
/// height: the sheet controller seen here belongs to the extension's own process, and detents,
/// `preferredContentSize`, `modalPresentationStyle`, the full-screen Info.plist key and a
/// compose-service base class all leave the real one as it is. The page fills it instead.
final class ShareViewController: UIViewController {
    private let model = ShareSheetModel()
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        model.large = true
        let host = UIHostingController(rootView: ShareSheetView(model: model, close: { [weak self] in self?.closePage() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.onFinish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // viewDidAppear can run again (a sheet over it, rotation): start only once
        guard !started else { return }
        started = true
        model.start(ShareCollector.providers(extensionContext))
    }

    /// Swiped away too: the system calls this when the page goes, and nothing stays behind.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || view.window == nil { model.close() }
    }

    private func closePage() {
        model.close()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

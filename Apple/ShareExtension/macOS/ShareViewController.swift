import AppKit
import SwiftUI

/// "导入 TwimShelf" in the Share menu (Photos, Finder, Safari…): the share page
/// (`ShareSheetView`). When it is confirmed the app opens, imports it and records every file's result.
final class ShareViewController: NSViewController {
    private let model = ShareSheetModel()
    private var started = false

    override func loadView() {
        view = NSHostingView(rootView: ShareSheetView(model: model, close: { [weak self] in self?.closePage() }, onHeight: { [weak self] h in
            if h > 0 { self?.preferredContentSize = NSSize(width: 420, height: h) }
        }).frame(width: 420))
        preferredContentSize = NSSize(width: 420, height: 320)
        model.onFinish = { [weak self] in
            // the app's own scheme (debug builds have a separate one, so a test build is never launched instead)
            let scheme = Bundle.main.object(forInfoDictionaryKey: "TLAppURLScheme") as? String ?? "twimshelf"
            if let u = URL(string: "\(scheme)://share") { NSWorkspace.shared.open(u) }
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        model.start(ShareCollector.providers(extensionContext))
    }

    private func closePage() {
        model.close()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

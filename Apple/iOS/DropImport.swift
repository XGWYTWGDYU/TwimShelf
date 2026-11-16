import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Media dragged onto the window, from Files, Photos or another app beside it: the share page
/// offers them, and they go in as loose media.
@MainActor
final class DropImport: NSObject, UIDropInteractionDelegate, UIAdaptivePresentationControllerDelegate {
    private weak var host: UIViewController?
    private var model: ShareSheetModel?

    init(host: UIViewController) {
        self.host = host
        super.init()
        host.view.addInteraction(UIDropInteraction(delegate: self))
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.movie.identifier, UTType.folder.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        offer(session.items.map(\.itemProvider))
    }

    func offer(_ providers: [NSItemProvider]) {
        guard var top = host, model == nil else { return }
        while let p = top.presentedViewController { top = p }
        let model = ShareSheetModel()
        model.dropped = true
        #if DEBUG
        // the extension's page, in a test without a post to download
        model.large = ProcessInfo.processInfo.environment["TL_TEST_LARGE"] != nil
        #endif
        self.model = model
        let page = UIHostingController(rootView: AnyView(EmptyView()))
        page.rootView = AnyView(ShareSheetView(model: model, close: { [weak self, weak page] in
            self?.model?.close()
            self?.model = nil
            page?.dismiss(animated: true)
        }, onHeight: { [weak page] h in
            guard let sheet = page?.sheetPresentationController, h > 0 else { return }
            sheet.animateChanges { sheet.detents = [.custom { _ in h }, .large()] }
        }))
        model.onFinish = { [weak self, weak page] in
            self?.model = nil
            page?.dismiss(animated: true)
            ShareInbox.importPending()
        }
        page.presentationController?.delegate = self
        page.sheetPresentationController?.prefersGrabberVisible = true
        top.present(page, animated: true)
        model.start(providers)
    }

    /// Swiped away: nothing stays behind.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        model?.close()
        model = nil
    }
}

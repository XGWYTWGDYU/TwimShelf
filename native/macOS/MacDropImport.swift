import AppKit
import SwiftUI

/// Files dragged onto the main window: the share page offers them as a sheet, and they go in as
/// loose media. (The window's delegate receives what no view under the pointer takes, such as the
/// drop area of 下载帖子.)
@MainActor
extension AppDelegate: NSWindowDelegate {
    private static var dropModel: ShareSheetModel?

    func installDropImport() {
        window.delegate = self
        window.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["TL_TEST_DROP"] {
            let urls = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.offerDropped(urls) }
        }
        #endif
    }

    private func dropped(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropped(sender).isEmpty ? [] : .copy }
    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropped(sender).isEmpty ? [] : .copy }
    @objc func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !dropped(sender).isEmpty }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = dropped(sender)
        offerDropped(urls)
        return !urls.isEmpty
    }

    func offerDropped(_ urls: [URL]) {
        guard Self.dropModel == nil, !urls.isEmpty else { return }
        let model = ShareSheetModel()
        model.dropped = true
        Self.dropModel = model
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(ShareSheetView(model: model, close: { [weak host] in
            Self.dropModel?.close()
            Self.dropModel = nil
            host?.dismiss(nil)
        }, onHeight: { [weak host] h in
            if h > 0 { host?.preferredContentSize = NSSize(width: 420, height: h) }
        }).frame(width: 420))
        host.sizingOptions = []
        host.preferredContentSize = NSSize(width: 420, height: 320)
        model.onFinish = { [weak host] in
            Self.dropModel = nil
            host?.dismiss(nil)
            ShareInbox.importPending()
        }
        window.contentViewController?.presentAsSheet(host)
        model.start(urls.compactMap { url in
            let p = NSItemProvider(contentsOf: url)
            p?.suggestedName = url.lastPathComponent
            return p
        })
    }
}

import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 下载帖子 in the Dock's menu. The title comes from the app's catalog when it has started.
  static var quickAction: FlutterMethodChannel?
  static var dockTitle: String?

  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    guard let title = Self.dockTitle else { return nil }
    let menu = NSMenu()
    menu.addItem(withTitle: title, action: #selector(downloadPosts), keyEquivalent: "").target = self
    return menu
  }

  @objc private func downloadPosts() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { $0 is MainFlutterWindow }?.makeKeyAndOrderFront(nil)
    Self.quickAction?.invokeMethod("downloadPosts", arguments: nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

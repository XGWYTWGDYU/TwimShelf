import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // a library window: room for the sidebar and several columns; any size works (the layout
    // follows the window), it can be made as small as a phone's
    let screen = self.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1200, screen.width * 0.9), height: min(800, screen.height * 0.9))
    self.setFrame(NSRect(origin: NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2), size: size), display: true)
    self.minSize = NSSize(width: 320, height: 480)
    self.setFrameAutosaveName("Library")

    RegisterGeneratedPlugins(registry: flutterViewController)
    let quickAction = FlutterMethodChannel(name: "org.twimshelf/quick_action", binaryMessenger: flutterViewController.engine.binaryMessenger)
    quickAction.setMethodCallHandler { call, result in
      if call.method == "setTitle" { AppDelegate.dockTitle = call.arguments as? String }
      result(nil)
    }
    AppDelegate.quickAction = quickAction
    super.awakeFromNib()
  }
}

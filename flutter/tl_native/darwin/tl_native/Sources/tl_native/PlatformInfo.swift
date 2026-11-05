#if os(iOS)
import UIKit
import Flutter
#else
import FlutterMacOS
import AppKit
#endif

/// What only the platform knows: the device's name as the native apps show it, its kind, the
/// iPad's window-control box, and the share sheet (centred on iPad, no arrow). Formerly in the
/// runners' own channel (`tl/platform`).
enum PlatformInfo {
  static func handle(_ method: String, _ arguments: Any?, _ result: @escaping FlutterResult) -> Bool {
    switch method {
    #if os(iOS)
    case "deviceName": result(deviceName)
    case "deviceKind": result(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
    case "windowControls": result(windowControls())
    case "share":
      share(((arguments as? [String]) ?? []).map { URL(fileURLWithPath: $0) })
      result(nil)
    #else
    // the name other devices show, as the native app's `SyncService.deviceName`
    case "deviceName": result(Host.current().localizedName ?? "Mac")
    #endif
    default: return false
    }
    return true
  }

  #if os(iOS)
  /// The system share sheet for files. On iPad it is a popover in the middle of the window with
  /// no arrow: it belongs to the screen, not to a button.
  static func share(_ urls: [URL]) {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
          var top = scene.keyWindow?.rootViewController else { return }
    while let p = top.presentedViewController { top = p }
    let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
    if let pop = vc.popoverPresentationController {
      pop.sourceView = top.view
      pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
      pop.permittedArrowDirections = []
    }
    top.present(vc, animated: true)
  }

  /// The name other devices show for this one, as the native app's `SyncService.deviceName`.
  static var deviceName: String {
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : UIDevice.current.name
  }

  /// The room the iPad's window controls (close / minimise / full screen) take in a windowed
  /// scene, in points: the safe area adapted to the controls' corner minus the plain safe area.
  /// Zero in full screen, on iPhone and before iPadOS 26.
  static func windowControls() -> [String: Double] {
    guard UIDevice.current.userInterfaceIdiom == .pad, #available(iOS 26.0, *),
          let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
          let view = scene.keyWindow?.rootViewController?.view ?? scene.windows.first?.rootViewController?.view
    else { return ["leading": 0, "top": 0, "width": 0, "height": 0] }
    let plain = view.safeAreaInsets
    let horizontal = view.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
    let vertical = view.edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
    // horizontal adaptation moves the leading edge past the controls; vertical moves the top
    // below them: together, the controls' box
    return [
      "leading": Double(max(0, horizontal.left - plain.left)),
      "top": Double(plain.top),
      "width": Double(max(0, horizontal.left - plain.left)),
      "height": Double(max(0, vertical.top - plain.top)),
    ]
  }
  #endif
}

import CoreImage
import Foundation
import TLLocalAI
#if os(iOS)
import Flutter
import os
#else
import FlutterMacOS
#endif

/// The Flutter app's on-device AI on Apple devices: the same MLX engine as the native apps
/// (`TLLocalAI`), handed to the Rust core, which Dart asks for tags (core/src/ai).
enum LocalAIBridge {
  /// The core's `tl_ai_set_mlx`, from the app it is linked into (a C function: looked up rather
  /// than declared, which would give it Swift's calling convention).
  private static let registered: Bool = {
    typealias SetMLX = @convention(c) (CoreBridge.Describe, CoreBridge.Free, UInt64) -> Void
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "tl_ai_set_mlx") else { return false }
    unsafeBitCast(symbol, to: SetMLX.self)(CoreBridge.describe, CoreBridge.free, CoreBridge.memory)
    return true
  }()

  static func handle(_ call: FlutterMethodCall, _ args: [String: Any], _ result: @escaping FlutterResult) -> Bool {
    switch call.method {
    case "aiSupported":
      result(MLXRuntime.isSupported && registered)
    case "aiUnload":
      Task { await MLXRuntime.shared.unloadAll(); await MainActor.run { result(nil) } }
    default:
      return false
    }
    return true
  }
}

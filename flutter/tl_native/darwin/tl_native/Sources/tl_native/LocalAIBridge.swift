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
/// (`TLLocalAI`). Dart chooses the model and writes the prompt; this only runs it.
enum LocalAIBridge {
  static func handle(_ call: FlutterMethodCall, _ args: [String: Any], _ result: @escaping FlutterResult) -> Bool {
    switch call.method {
    case "aiSupported":
      result(MLXRuntime.isSupported)
    case "aiAvailableMemory":
      // iOS ends an app over its limit without a warning that arrives in time: Dart checks a
      // model's size against this before loading it. Nil on the Mac (no such limit).
      #if os(iOS)
      result(Int(os_proc_available_memory()))
      #else
      result(nil)
      #endif
    case "aiTags":
      guard let dir = args["modelDir"] as? String, let path = args["path"] as? String, let kind = args["kind"] as? String,
            let system = args["system"] as? String, let question = args["question"] as? String else {
        result(FlutterError(code: "arguments", message: nil, details: nil)); return true
      }
      Task.detached(priority: .utility) {
        guard let image = ModelInput.stillImage(path: path, kind: kind) else {
          await MainActor.run { result(FlutterError(code: "ai.noImage", message: nil, details: nil)) }; return
        }
        do {
          let raw = try await MLXRuntime.shared.respond(modelDir: URL(fileURLWithPath: dir, isDirectory: true), system: system, question: question, image: image)
          let tags = ModelInput.parseTags(raw)
          await MainActor.run { result(tags) }
        } catch {
          await MainActor.run { result(FlutterError(code: "ai.failed", message: "\(error)", details: nil)) }
        }
      }
    case "aiUnload":
      Task { await MLXRuntime.shared.unloadAll(); await MainActor.run { result(nil) } }
    default:
      return false
    }
    return true
  }
}

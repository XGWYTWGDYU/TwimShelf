import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
#endif

/// `tl/native`: what Dart would do slowly or cannot do at all (video posters, the MLX engine).
public final class TlNativePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "tl/native", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(TlNativePlugin(), channel: channel)
    #if os(iOS)
    // the window is there once the app has started
    drop = TlNativeDrop(channel: channel)
    DispatchQueue.main.async {
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      if let window = scene?.windows.first, let drop { window.addInteraction(UIDropInteraction(delegate: drop)) }
    }
    #endif
  }

  #if os(iOS)
  private static var drop: TlNativeDrop?
  #endif

  /// Poster frames decode in parallel, a few at a time (hardware decoders are few).
  private let posters = OperationQueue()

  override init() {
    posters.maxConcurrentOperationCount = 3
    posters.qualityOfService = .userInitiated
    super.init()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if PlatformInfo.handle(call.method, call.arguments, result) { return }
    if LocalAIBridge.handle(call, args, result) { return }
    switch call.method {
    case "posterFrame":
      guard let path = args["path"] as? String, let out = args["out"] as? String,
            let sides = args["sides"] as? [Int], !sides.isEmpty else {
        return result(FlutterError(code: "arguments", message: nil, details: nil))
      }
      let at = (args["atMs"] as? Int) ?? 500
      posters.addOperation {
        let ok = (args["whole"] as? Bool) == true
          ? Self.wholeFrame(path: path, atMs: at, longSide: sides[0], out: out)
          : Self.posterFrame(path: path, atMs: at, sides: sides, out: out)
        DispatchQueue.main.async { result(ok) }
      }
    case "sharesRoot":
      // as ShareCollector in the extension: a debug Mac build shares into its own folder
      #if DEBUG && os(macOS)
      let folder = "Shares-Debug"
      #else
      let folder = "Shares"
      #endif
      let group = Bundle.main.object(forInfoDictionaryKey: "TLAppGroup") as? String ?? ""
      // this build has no share extension
      result(group.isEmpty ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent(folder, isDirectory: true).path)
    case "appPaths":
      // the app itself (存储空间)
      result([Bundle.main.bundlePath])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// One frame of the video, decoded once by the system's (hardware) decoder at the size the
  /// largest poster needs, then cropped to a square and written as a JPEG for every size asked
  /// for: `out` with `{side}` replaced. The same as the native apps' grid posters.
  static func posterFrame(path: String, atMs: Int, sides: [Int], out: String) -> Bool {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    let largest = CGFloat(sides.max() ?? 512)
    // the short side must reach the poster's side after the square crop
    gen.maximumSize = CGSize(width: largest * 4, height: largest * 4)
    gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    let seconds = CMTimeGetSeconds(asset.duration)
    let at = Double(atMs) / 1000
    let time = CMTime(seconds: seconds.isFinite && seconds > 0 ? min(at, seconds * 0.5) : 0, preferredTimescale: 600)
    guard let frame = try? gen.copyCGImage(at: time, actualTime: nil) else { return false }
    let short = min(frame.width, frame.height)
    guard short > 0, let square = frame.cropping(to: CGRect(x: (frame.width - short) / 2, y: (frame.height - short) / 2, width: short, height: short)) else { return false }
    for side in sides {
      guard let scaled = scale(square, to: min(side, short)) ?? (side >= short ? square : nil) else { return false }
      let target = URL(fileURLWithPath: out.replacingOccurrences(of: "{side}", with: String(side)))
      try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      let partial = target.appendingPathExtension("partial")
      guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
      CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
      guard CGImageDestinationFinalize(dest) else { return false }
      _ = try? FileManager.default.removeItem(at: target)
      guard (try? FileManager.default.moveItem(at: partial, to: target)) != nil else { return false }
    }
    return true
  }

  /// One frame in the video's own shape (a card of 浏览 shows it until the video plays), its long
  /// side no longer than asked: `out` with `{side}` replaced.
  static func wholeFrame(path: String, atMs: Int, longSide: Int, out: String) -> Bool {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: longSide, height: longSide)
    gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    let seconds = CMTimeGetSeconds(asset.duration)
    let at = Double(atMs) / 1000
    let time = CMTime(seconds: seconds.isFinite && seconds > 0 ? min(at, seconds * 0.5) : 0, preferredTimescale: 600)
    guard let frame = try? gen.copyCGImage(at: time, actualTime: nil) else { return false }
    let target = URL(fileURLWithPath: out.replacingOccurrences(of: "{side}", with: String(longSide)))
    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let partial = target.appendingPathExtension("partial")
    guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, frame, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return false }
    _ = try? FileManager.default.removeItem(at: target)
    return (try? FileManager.default.moveItem(at: partial, to: target)) != nil
  }

  /// Draws on an opaque white canvas (JPEG has no alpha), at exactly side × side.
  private static func scale(_ image: CGImage, to side: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage()
  }
}

#if os(iOS)
/// Media dragged onto the window: copied to the temporary folder and handed to Dart (`DropImport`).
final class TlNativeDrop: NSObject, UIDropInteractionDelegate {
  private let channel: FlutterMethodChannel
  init(channel: FlutterMethodChannel) { self.channel = channel }

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.movie.identifier, UTType.folder.identifier])
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let group = DispatchGroup()
    let lock = NSLock()
    var paths: [String] = []
    for (i, item) in session.items.enumerated() {
      let p = item.itemProvider
      let type = [UTType.movie, .image, .folder].first { t in p.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: t) == true } }
      guard let type else { continue }
      group.enter()
      p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        defer { group.leave() }
        guard let url else { return }
        let to = dir.appendingPathComponent("\(i)_" + url.lastPathComponent)
        if (try? FileManager.default.copyItem(at: url, to: to)) != nil {
          lock.lock(); paths.append(to.path); lock.unlock()
        }
      }
    }
    group.notify(queue: .main) { [channel] in channel.invokeMethod("dropped", arguments: paths.sorted()) }
  }
}
#endif

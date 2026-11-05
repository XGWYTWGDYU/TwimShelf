#if DEBUG && canImport(UIKit)
import UIKit

/// Debug-only frame monitor: logs every frame that took longer than 1.5× the display interval
/// (wall-clock time, duration in ms) to tmp/hitches.log. Enabled with TL_HITCH_LOG=1.
final class HitchMonitor: NSObject {
    static let shared = HitchMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var handle: FileHandle?

    static var logURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("hitches.log") }

    func startIfRequested() {
        guard ProcessInfo.processInfo.environment["TL_HITCH_LOG"] != nil else { return }
        try? FileManager.default.removeItem(at: Self.logURL)
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: Self.logURL)
        link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ l: CADisplayLink) {
        defer { last = l.timestamp }
        guard last > 0 else { return }
        let interval = l.targetTimestamp - l.timestamp
        let dt = l.timestamp - last
        if dt > max(interval, 1.0 / 120) * 1.5 {
            let line = String(format: "%.3f %.1f\n", Date().timeIntervalSince1970, (dt - interval) * 1000)
            handle?.write(Data(line.utf8))
        }
    }
}

#endif

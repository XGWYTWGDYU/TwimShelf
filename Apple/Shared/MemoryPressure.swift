import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// App-owned caches must release resources too; NSCache cannot evict Metal textures.
enum MemoryPressure {
    static let changed = Notification.Name("ReleaseMediaCaches")
    private static var source: DispatchSourceMemoryPressure?
    private static var observer: NSObjectProtocol?
    static func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { NotificationCenter.default.post(name: changed, object: nil) }
        source = s
        s.resume()
        #if canImport(UIKit)
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            NotificationCenter.default.post(name: changed, object: nil)
        }
        #endif
    }
}

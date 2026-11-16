import UIKit
import ImageIO
import AVFoundation

/// Off-main thumbnail decoding with an in-memory cache. Videos use their first frame as a poster.
final class MediaLoader {
    static let shared = MediaLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "media.decode", qos: .userInitiated, attributes: .concurrent)

    init() {
        cache.totalCostLimit = 128 * 1024 * 1024
        pressureObserver = NotificationCenter.default.addObserver(forName: MemoryPressure.changed, object: nil, queue: .main) { [weak self] _ in self?.clearMemory() }
    }
    deinit { if let pressureObserver { NotificationCenter.default.removeObserver(pressureObserver) } }

    func cached(_ item: FeedItem, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(item, maxPixel))
    }

    typealias Token = UInt64
    private struct Job { let key: String; let path: String; let video: Bool; let pixels: CGFloat }
    private var waiting: [String: [(Token, (UIImage?) -> Void)]] = [:]
    private var jobs: [Job] = []
    private var ahead: [Job] = []
    private var running = Set<String>()
    private var nextToken: Token = 0
    private var generation = 0
    private let workers = 3
    private var pressureObserver: NSObjectProtocol?

    func anyCached(_ item: FeedItem, near maxPixel: CGFloat) -> UIImage? {
        // No unbounded index of evicted entries: try the small, fixed set of UI sizes.
        for size in [maxPixel, MediaPageView.pixelSize, 600, 1200, 1600, 2048].sorted(by: { abs($0 - maxPixel) < abs($1 - maxPixel) }) {
            if let img = cached(item, maxPixel: size) { return img }
        }
        return nil
    }

    @discardableResult
    func load(_ item: FeedItem, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) -> Token? {
        load(path: item.path, isVideo: item.kind == .video, maxPixel: maxPixel, completion: completion)
    }

    @discardableResult
    func load(path: String, isVideo: Bool, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) -> Token? {
        dispatchPrecondition(condition: .onQueue(.main))
        let k = "\(path)@\(Int(maxPixel))"
        if let img = cache.object(forKey: k as NSString) { completion(img); return nil }
        nextToken &+= 1
        let token = nextToken
        waiting[k, default: []].append((token, completion))
        if !running.contains(k) {
            jobs.removeAll { $0.key == k }; ahead.removeAll { $0.key == k }
            jobs.append(Job(key: k, path: path, video: isVideo, pixels: maxPixel))
        }
        pump()
        return token
    }

    func cancel(_ token: Token?) {
        guard let token else { return }
        for key in Array(waiting.keys) {
            waiting[key]?.removeAll { $0.0 == token }
            if waiting[key]?.isEmpty == true { waiting[key] = nil; jobs.removeAll { $0.key == key } }
        }
    }

    func prefetch(_ items: [FeedItem], maxPixel: CGFloat) {
        for it in items {
            let k = key(it, maxPixel) as String
            guard cache.object(forKey: k as NSString) == nil, !running.contains(k), waiting[k] == nil else { continue }
            ahead.removeAll { $0.key == k }
            ahead.append(Job(key: k, path: it.path, video: it.kind == .video, pixels: maxPixel))
        }
        ahead = Array(ahead.suffix(12))
        pump()
    }

    func cancelPrefetch(_ items: [FeedItem], maxPixel: CGFloat) {
        let keys = Set(items.map { key($0, maxPixel) as String })
        ahead.removeAll { keys.contains($0.key) }
    }

    private func pump() {
        while running.count < workers, let job = jobs.popLast() ?? ahead.popLast() {
            guard running.insert(job.key).inserted else { continue }
            let version = generation
            queue.async { [weak self] in
                let img = autoreleasepool { job.video ? Self.poster(URL(fileURLWithPath: job.path), job.pixels) : Self.thumbnail(URL(fileURLWithPath: job.path), job.pixels) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running.remove(job.key)
                    if version == self.generation {
                        if let img, let cg = img.cgImage { self.cache.setObject(img, forKey: job.key as NSString, cost: cg.bytesPerRow * cg.height) }
                        let callbacks = self.waiting.removeValue(forKey: job.key) ?? []
                        for (_, done) in callbacks { done(img) }
                    }
                    if version != self.generation, self.waiting[job.key] != nil { self.jobs.append(job) }
                    self.pump()
                }
            }
        }
    }

    private func key(_ item: FeedItem, _ px: CGFloat) -> NSString { "\(item.path)@\(Int(px))" as NSString }

    func clearMemory() {
        cache.removeAllObjects()
        ahead.removeAll()
        // Keep visible requests, but don't let old workers repopulate the cache.
        generation &+= 1
    }

    func forget(_ item: FeedItem) { clearMemory(); reported.remove(item.mediaId) }

    /// A media that failed to decode is reported to the core once per launch, which verifies the
    /// file and records the damage (the card then shows a badge and offers a re-download).
    private var reported = Set<String>()
    func reportIfBroken(_ item: FeedItem) {
        guard !reported.contains(item.mediaId) else { return }
        reported.insert(item.mediaId)
        // async all the way (a thread blocked on a semaphore while Swift concurrency loads the
        // asset could starve the shared thread pool)
        Task.detached(priority: .utility) {
            // A video whose poster frame failed may still play fine: only an unplayable one counts.
            if item.kind == .video, (try? await AVURLAsset(url: item.fileURL).load(.isPlayable)) == true { return }
            let reason = Core.reportBad(item.mediaId)
            if reason != item.bad { await MainActor.run { NotificationCenter.default.post(name: .libraryChanged, object: nil) } }
        }
    }

    private static func thumbnail(_ url: URL, _ maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
    }

    private static func poster(_ url: URL, _ maxPixel: CGFloat) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        return (try? gen.copyCGImage(at: .zero, actualTime: nil)).map { UIImage(cgImage: $0) }
    }
}

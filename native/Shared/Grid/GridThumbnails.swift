import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Square, center-cropped thumbnails of media as Metal textures, for the grid.
///
/// Two sizes only, as Photos does it: one **small** thumbnail serves every tile up to about the
/// middle zoom level — whatever the column count, a scroll or a zoom never asks for a new
/// decode — and a **large** one is decoded only for tiles that get big (one column, zoomed past
/// it), shown over the small one once ready. The small ones are also kept on disk (JPEG, in the
/// caches folder), so a picture is decoded from its original file once; after that it comes
/// back in a millisecond or two. Opening a grid warms that disk cache for all of it in the
/// background.
///
/// `texture(for:pixels:)` always answers at once with what is at hand — a frame never waits for
/// a picture. What a frame is missing is decoded first, in reading order, and a list wanted by
/// an earlier frame is dropped when the next frame starts (`beginFrame`), so a fast scroll
/// decodes what is on screen now instead of a backlog. Main thread only, O(1) per tile.
final class GridThumbnails {
    private let device: MTLDevice
    private let decodeQueue = DispatchQueue(label: "grid.thumbnails", qos: .userInitiated, attributes: .concurrent)

    /// The small thumbnail covers a middle-level tile (the levels keep about 134 pt at any window
    /// width), so its size depends only on the screen scale and the disk cache stays valid.
    static let smallPoints: CGFloat = 134
    static func smallPixels(scale: CGFloat) -> Int { min(max(Int((smallPoints * scale / 64).rounded(.up)) * 64, 128), 512) }

    /// Pixels of the small thumbnail and of the large one.
    private(set) var smallSide = 384
    private(set) var largeSide = 1280
    private var cacheDir: URL

    private struct Entry { var small: MTLTexture?; var large: MTLTexture?; var used: UInt64 }
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private var budget: Int
    private var generation = 0
    private var pressureObserver: NSObjectProtocol?

    private struct Job { let item: FeedItem; let large: Bool }
    /// Missing in the current frame, in drawing order (rebuilt every frame).
    private var wanted: [Job] = []
    private var wantedKeys = Set<String>()
    /// Ahead of the scroll (rebuilt when the grid moves on).
    private var ahead: [Job] = []
    private var running = Set<String>()
    private var failed = Set<String>()
    private let workers = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    /// A picture arrived: draw again.
    var onLoaded: (() -> Void)?
    /// A media could not be decoded (the app checks the file and marks it damaged).
    var onFailed: ((FeedItem) -> Void)?

    init(device: MTLDevice, budgetMB: Int) {
        self.device = device
        budget = budgetMB * 1024 * 1024
        cacheDir = Self.cacheDirectory(small: 384)
        pressureObserver = NotificationCenter.default.addObserver(forName: MemoryPressure.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.budget = min(self.budget, 64 * 1024 * 1024)
            self.forgetAll()
            self.onLoaded?()
        }
    }

    deinit { if let pressureObserver { NotificationCenter.default.removeObserver(pressureObserver) } }

    /// Sizes for a grid: the small one covers its middle level's tiles, the large one its
    /// biggest (with room for zooming past it). Changing them drops what is in memory.
    @discardableResult
    func setSizes(small: CGFloat, large: CGFloat) -> Bool {
        let s = min(max(Int((small / 64).rounded(.up)) * 64, 128), 512)
        let l = min(max(Int((large / 128).rounded(.up)) * 128, s * 2), 2048)
        guard s != smallSide || l != largeSide else { return false }
        smallSide = s
        largeSide = l
        cacheDir = Self.cacheDirectory(small: s)
        forgetAll()
        return true
    }

    private static func cacheDirectory(small: Int) -> URL {
        // per library (a test library never shares thumbnails with the real one), per size
        let lib = Core.libraryDirectory.standardizedFileURL.path
        let tag = SHA256.hash(data: Data(lib.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("GridThumbnails/\(tag)/\(small)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Frames

    /// A new frame begins: what the last one was missing no longer counts.
    func beginFrame() {
        wanted.removeAll(keepingCapacity: true)
        wantedKeys.removeAll(keepingCapacity: true)
    }

    /// The best texture at hand for a tile `pixels` wide; asks for what is missing.
    func texture(for item: FeedItem, pixels: CGFloat) -> MTLTexture? {
        let id = item.mediaId
        clock &+= 1
        var e = entries[id]
        e?.used = clock
        if let e { entries[id] = e }
        let wantsLarge = pixels > CGFloat(smallSide) * 1.3
        if wantsLarge, let l = e?.large { return l }
        if e?.small == nil { want(item, large: false) }
        if wantsLarge { want(item, large: true) }
        return e?.small ?? e?.large
    }

    private func want(_ item: FeedItem, large: Bool) {
        let key = (large ? "L" : "S") + item.mediaId
        guard !failed.contains(item.mediaId), !running.contains(key), wantedKeys.insert(key).inserted else { return }
        wanted.append(Job(item: item, large: large))
        pump()
    }

    /// Small thumbnails to have ready next (rows above and below, ahead of the scroll).
    func prefetch(_ items: [FeedItem]) {
        ahead = items.reversed().filter { entries[$0.mediaId]?.small == nil && !failed.contains($0.mediaId) }.map { Job(item: $0, large: false) }
        pump()
    }

    /// Opening a grid only queues its first screen; the library warmer handles disk coverage.
    func warm(_ items: [FeedItem]) {
        prefetch(Array(items.prefix(24)))
    }

    private static let libraryCounter = AtomicCounter()
    private static let libraryQueue = DispatchQueue(label: "grid.thumbnails.library", qos: .background)
    /// Makes the small thumbnail of every media in the library ahead of time, at background
    /// priority, so a grid opened for the first time is not blank while scrolled.
    /// Later notifications enqueue only newly discovered media IDs.
    /// Warms the library now and again a few seconds after each library change (imports, syncs).
    static func keepLibraryWarm(scale: @escaping () -> CGFloat) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TL_NO_THUMB_WARM"] != nil { return }   // cold measurements
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { warmLibrary(scale: scale()) }
        NotificationCenter.default.addObserver(forName: MemoryPressure.changed, object: nil, queue: .main) { _ in
            libraryCounter.add()
            pauseWarmUntil = Date().addingTimeInterval(60)
        }
        var pending: DispatchWorkItem?
        NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { _ in
            pending?.cancel()
            let w = DispatchWorkItem { warmLibrary(scale: scale()) }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
        }
    }

    // Only the serial library queue accesses this inventory. Tag edits do not re-stat
    // every original. Content-addressed media keep the same image for the same ID.
    private static var known: [String: Set<String>] = [:]
    private static var pauseWarmUntil = Date.distantPast
    static func warmLibrary(scale: CGFloat) {
        guard Date() >= pauseWarmUntil,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return }
        let side = smallPixels(scale: scale)
        let dir = cacheDirectory(small: side)
        let gen = libraryCounter.value
        libraryQueue.async {
            guard libraryCounter.value == gen else { return }
            let items = Core.thumbnailItems()
            guard libraryCounter.value == gen else { return }
            let ids = Set(items.map(\.mediaId))
            let old = known[dir.path] ?? []
            let added = items.filter { !old.contains($0.mediaId) }
            known[dir.path] = ids
            guard !added.isEmpty || old != ids else { return }
            for it in added {
                guard libraryCounter.value == gen else { known[dir.path] = nil; return }
                let url = cacheURL(it, in: dir)
                if fresh(url, for: it) { continue }
                autoreleasepool {
                    if let img = decodeOriginal(it, minSide: side), let sq = square(img, side: side) { write(sq, to: url) }
                }
            }
            pruneDiskCache(dir: dir, live: ids)
        }
    }

    private static func pruneDiskCache(dir: URL, live: Set<String>?) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        let validNames = live.map { Set($0.map { String($0.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }) }) }
        var keep: [(URL, Int, Date)] = []
        for file in files {
            // A decoder can be writing a temporary file concurrently; never remove it here.
            guard file.pathExtension == "jpg" else { continue }
            guard validNames?.contains(file.deletingPathExtension().lastPathComponent) != false else { try? FileManager.default.removeItem(at: file); continue }
            let v = try? file.resourceValues(forKeys: keys)
            keep.append((file, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast))
        }
        var bytes = keep.reduce(0) { $0 + $1.1 }
        for (file, size, _) in keep.sorted(by: { $0.2 < $1.2 }) where bytes > 512 * 1024 * 1024 {
            if (try? FileManager.default.removeItem(at: file)) != nil { bytes -= size }
        }
    }

    func forgetAll() {
        generation &+= 1
        entries = [:]; bytes = 0; failed = []
        wanted = []; wantedKeys = []; ahead = []
    }

    // MARK: Decoding

    private func pump() {
        while running.count < workers {
            let job: Job
            if !wanted.isEmpty { job = wanted.removeFirst() }
            else if let a = ahead.popLast() { job = a }
            else { return }
            let key = (job.large ? "L" : "S") + job.item.mediaId
            if running.contains(key) { continue }
            if !job.large, entries[job.item.mediaId]?.small != nil { continue }
            running.insert(key)
            let version = generation
            let device = device, side = job.large ? largeSide : smallSide, dir = cacheDir, small = smallSide
            decodeQueue.async { [weak self] in
                let tex: MTLTexture? = autoreleasepool {
                    if job.large { return Self.largeTexture(job.item, side: side, device: device) }
                    return Self.smallTexture(job.item, side: small, dir: dir, device: device)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running.remove(key)
                    if version == self.generation, side == (job.large ? self.largeSide : self.smallSide) {
                        if let tex { self.store(tex, id: job.item.mediaId, large: job.large); self.onLoaded?() }
                        else if !job.large, self.failed.insert(job.item.mediaId).inserted { self.onFailed?(job.item) }
                    }
                    self.pump()
                }
            }
        }
    }

    private func store(_ t: MTLTexture, id: String, large: Bool) {
        var e = entries[id] ?? Entry(used: clock)
        if large { if e.large != nil { return }; e.large = t } else { if e.small != nil { return }; e.small = t }
        e.used = clock
        entries[id] = e
        bytes += t.width * t.height * 4
        guard bytes > budget else { return }
        // over budget: drop the least recently drawn quarter (rare, so a sort is fine)
        let old = entries.sorted { $0.value.used < $1.value.used }
        for (k, v) in old {
            if bytes <= budget * 3 / 4 { break }
            for t in [v.small, v.large].compactMap({ $0 }) { bytes -= t.width * t.height * 4 }
            entries[k] = nil
        }
    }

    private static func cacheURL(_ item: FeedItem, in dir: URL) -> URL {
        let safe = item.mediaId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".jpg")
    }

    /// A cached thumbnail newer than its original (a re-downloaded file makes it stale).
    private static func fresh(_ url: URL, for item: FeedItem) -> Bool {
        let fm = FileManager.default
        guard let c = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        let o = (try? fm.attributesOfItem(atPath: item.fileURL.path))?[.modificationDate] as? Date ?? .distantPast
        return c >= o
    }

    private static func smallTexture(_ item: FeedItem, side: Int, dir: URL, device: MTLDevice) -> MTLTexture? {
        let url = cacheURL(item, in: dir)
        if fresh(url, for: item), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
           let px = square(img, side: side) {
            return texture(px, side: side, device: device)
        }
        guard let img = decodeOriginal(item, minSide: side), let px = square(img, side: side) else { return nil }
        write(px, to: url)
        return texture(px, side: side, device: device)
    }

    private static func largeTexture(_ item: FeedItem, side: Int, device: MTLDevice) -> MTLTexture? {
        guard let img = decodeOriginal(item, minSide: side), let px = square(img, side: side) else { return nil }
        return texture(px, side: side, device: device)
    }

    /// The picture (a video's first frame) with its short side at least `minSide` pixels.
    private static func decodeOriginal(_ item: FeedItem, minSide side: Int) -> CGImage? {
        let url = item.fileURL
        if item.kind == .video {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: side * 2, height: side * 2)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
            return try? gen.copyCGImage(at: .zero, actualTime: nil)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var maxPixel = CGFloat(side)
        if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
            maxPixel = ImageDecodeLimits.maximumPixel(width: w, height: h, shortSide: CGFloat(side))
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Aspect-filled, centered, `side`×`side` BGRA in the sRGB-encoded space the grid blends in.
    private static func square(_ image: CGImage, side: Int) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        if image.width == side && image.height == side {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return ctx.makeImage()
        }
        ctx.interpolationQuality = .high
        let w = CGFloat(image.width), h = CGFloat(image.height), s = CGFloat(side)
        let k = max(s / w, s / h)
        ctx.draw(image, in: CGRect(x: (s - w * k) / 2, y: (s - h * k) / 2, width: w * k, height: h * k))
        return ctx.makeImage()
    }

    private static let pruneLock = NSLock()
    private static var lastPrune: [String: Date] = [:]
    private static let pruneQueue = DispatchQueue(label: "grid.cache.cleanup", qos: .background)
    private static func schedulePrune(_ directory: URL) {
        pruneLock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastPrune[directory.path] ?? .distantPast) > 60
        if due { lastPrune[directory.path] = now }
        pruneLock.unlock()
        if due { pruneQueue.async { pruneDiskCache(dir: directory, live: nil) } }
    }

    private static func write(_ image: CGImage, to url: URL) {
        let tmp = url.appendingPathExtension("tmp-" + UUID().uuidString)
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if CGImageDestinationFinalize(dst) {
            do { try FileManager.default.moveItem(at: tmp, to: url) }
            catch { _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp) }
            schedulePrune(url.deletingLastPathComponent())
        }
    }

    private static func texture(_ image: CGImage, side: Int, device: MTLDevice) -> MTLTexture? {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data), image.bitsPerPixel == 32 else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: ptr, bytesPerRow: image.bytesPerRow)
        return tex
    }

    /// The best decoded picture of a media as an image (the stand-in a long press lifts out).
    func image(for item: FeedItem) -> CGImage? {
        guard let e = entries[item.mediaId], let t = e.large ?? e.small else { return nil }
        let side = t.width
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        t.getBytes(&bytes, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A counter read from the warming thread while the main thread moves it on.
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func add() { lock.lock(); n += 1; lock.unlock() }
}

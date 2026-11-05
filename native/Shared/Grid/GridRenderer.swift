import CoreText
import Metal
import MetalKit
import simd

/// Must match `GridTileInstance` in GridShaders.metal.
struct GridTileInstance {
    var origin: SIMD2<Float>
    var side: Float
    var alpha: Float
    var flags: UInt32
    var count: UInt32
    var pad: SIMD2<Float> = .zero
    var radii: SIMD4<Float>
    var placeholder: SIMD4<Float>
}

private struct GridUniforms {
    var viewSize: SIMD2<Float>
    var scale: Float
    var pad: Float = 0
}

/// Draws the grid's tiles: rounded quads with antialiased edges (research/MetalGridZoom), each
/// showing its thumbnail. Tiles come back to front from `GridScene`; each one is an instance of
/// one quad, drawn with its own picture bound.
final class GridRenderer {
    let device: MTLDevice
    let thumbnails: GridThumbnails
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let digits: MTLTexture
    private let blank: MTLTexture
    private var buffers: [MTLBuffer] = []
    private var capacity = 0
    private var frameIndex = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var textures: [MTLTexture?] = []
    /// Tiles on screen drawn without a picture in the last frame, and all tiles drawn (measuring).
    private(set) var lastBlank = 0
    private(set) var lastTileCount = 0
    /// Placeholder colour while a picture is decoding (sRGB-encoded).
    var placeholder = SIMD4<Float>(0.9, 0.9, 0.92, 1)

    init?(view: MTKView, budgetMB: Int) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "gridTileVertex")
        desc.fragmentFunction = library.makeFunction(name: "gridTileFragment")
        let att = desc.colorAttachments[0]!
        att.pixelFormat = view.colorPixelFormat
        att.isBlendingEnabled = true
        att.sourceRGBBlendFactor = .one
        att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let p = try? device.makeRenderPipelineState(descriptor: desc),
              let d = Self.makeDigitAtlas(device: device, queue: queue) else { return nil }
        pipeline = p
        digits = d
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let b = device.makeTexture(descriptor: bd) else { return nil }
        blank = b
        thumbnails = GridThumbnails(device: device, budgetMB: budgetMB)
        precondition(MemoryLayout<GridTileInstance>.stride == 64)
    }

    /// The thumbnail sizes for a grid configuration: the small one covers the middle level's
    /// tiles, the large one the biggest level zoomed to its limit. True when they changed.
    @discardableResult
    func setThumbnailSizes(_ cfg: GridConfig) -> Bool {
        thumbnails.setSizes(small: GridThumbnails.smallPoints * cfg.scale, large: cfg.side(cfg.levels - 1) * cfg.scale * GridConfig.maxSideFactor)
    }

    /// One frame. `info` gives a tile's media, its post's count and whether it is selected.
    func draw(_ tiles: [Tile], in view: MTKView, scale: CGFloat, background: MTLClearColor,
              info: (Int) -> (item: FeedItem, count: Int, selected: Bool)?) {
        // a bounded wait: the main thread drives scrolling, never stall it for long
        guard inflight.wait(timeout: .now() + .milliseconds(4)) == .success else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            inflight.signal(); return
        }
        ensureCapacity(tiles.count)
        let buffer = buffers[frameIndex]
        frameIndex = (frameIndex + 1) % buffers.count
        let ptr = buffer.contents().bindMemory(to: GridTileInstance.self, capacity: max(tiles.count, 1))
        textures.removeAll(keepingCapacity: true)
        // Encoders retain resources until GPU completion; do not also retain the last
        // frame in this CPU scratch array after cache eviction or memory pressure.
        defer { textures.removeAll(keepingCapacity: true) }
        thumbnails.beginFrame()
        var blankCount = 0
        defer { lastBlank = blankCount; lastTileCount = tiles.count }
        for (k, t) in tiles.enumerated() {
            var flags: UInt32 = 0
            var count: UInt32 = 0
            var tex: MTLTexture?
            if let i = info(t.photo) {
                tex = thumbnails.texture(for: i.item, pixels: t.side * scale)
                if tex != nil { flags |= 1 }
                if i.item.kind == .video { flags |= 2 }
                if i.selected { flags |= 4 }
                count = UInt32(max(0, i.count))
            }
            textures.append(tex)
            if tex == nil && t.alpha > 0.5 && t.y + t.side > 0 && t.y < view.bounds.height { blankCount += 1 }
            ptr[k] = GridTileInstance(origin: SIMD2(Float(t.x), Float(t.y)), side: Float(t.side), alpha: Float(t.alpha),
                                      flags: flags, count: count,
                                      radii: SIMD4(Float(t.radii.0), Float(t.radii.1), Float(t.radii.2), Float(t.radii.3)),
                                      placeholder: placeholder)
        }
        pass.colorAttachments[0].clearColor = background
        pass.colorAttachments[0].loadAction = .clear
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal(); return
        }
        var u = GridUniforms(viewSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)), scale: Float(scale))
        if !tiles.isEmpty {
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 1)
            enc.setFragmentTexture(digits, index: 1)
            // runs of tiles sharing a picture (or none) go in one draw
            var start = 0
            while start < tiles.count {
                let tex = textures[start]
                var end = start + 1
                while end < tiles.count && textures[end] === tex { end += 1 }
                enc.setFragmentTexture(tex ?? blank, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: end - start, baseInstance: start)
                start = end
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.commit()
    }

    #if DEBUG
    /// The same frame drawn offscreen and read back (tour pictures: window snapshots do not
    /// contain Metal content).
    func snapshot(_ tiles: [Tile], size: CGSize, scale: CGFloat, background: MTLClearColor,
                  info: (Int) -> (item: FeedItem, count: Int, selected: Bool)?) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard w > 0, h > 0, let target = device.makeTexture(descriptor: td),
              let buffer = device.makeBuffer(length: max(1, tiles.count) * MemoryLayout<GridTileInstance>.stride, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer() else { return nil }
        let ptr = buffer.contents().bindMemory(to: GridTileInstance.self, capacity: max(tiles.count, 1))
        var texs: [MTLTexture?] = []
        for (k, t) in tiles.enumerated() {
            var flags: UInt32 = 0, count: UInt32 = 0
            var tex: MTLTexture?
            if let i = info(t.photo) {
                tex = thumbnails.texture(for: i.item, pixels: t.side * scale)
                if tex != nil { flags |= 1 }
                if i.item.kind == .video { flags |= 2 }
                if i.selected { flags |= 4 }
                count = UInt32(max(0, i.count))
            }
            texs.append(tex)
            ptr[k] = GridTileInstance(origin: SIMD2(Float(t.x), Float(t.y)), side: Float(t.side), alpha: Float(t.alpha), flags: flags, count: count,
                                      radii: SIMD4(Float(t.radii.0), Float(t.radii.1), Float(t.radii.2), Float(t.radii.3)), placeholder: placeholder)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = background
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var u = GridUniforms(viewSize: SIMD2(Float(size.width), Float(size.height)), scale: Float(scale))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 1)
        enc.setFragmentTexture(digits, index: 1)
        for (k, tex) in texs.enumerated() {
            enc.setFragmentTexture(tex ?? blank, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1, baseInstance: k)
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    #endif

    private func ensureCapacity(_ n: Int) {
        guard n > capacity || buffers.isEmpty else { return }
        capacity = max(1024, Int(Double(n) * 1.5))
        buffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: capacity * MemoryLayout<GridTileInstance>.stride, options: .storageModeShared)
        }
        frameIndex = 0
    }

    /// Ten white digits in a row (one channel, mipmapped), for the count badges.
    private static func makeDigitAtlas(device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        let cw = 144, ch = 256, w = cw * 10
        var pixels = [UInt8](repeating: 0, count: w * ch)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: ch, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            let font = CTFontCreateWithName("SFProText-Bold" as CFString, CGFloat(ch) * 0.86, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
            for d in 0..<10 {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(d)", attributes: attrs))
                let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                ctx.textPosition = CGPoint(x: CGFloat(d * cw) + (CGFloat(cw) - b.width) / 2 - b.minX, y: (CGFloat(ch) - b.height) / 2 - b.minY)
                CTLineDraw(line, ctx)
            }
            return true
        }
        guard ok else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: ch, mipmapped: true)
        td.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, ch), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w)
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return tex
    }
}

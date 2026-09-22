import Flutter
import MetalKit
import ObjectiveC.runtime
import UIKit

/// Publishes an `MTKView`'s frames as a flutter texture.
///
/// The map draws into its own drawable as usual. Each finished frame is
/// blitted into an IOSurface-backed `CVPixelBuffer` and handed to
/// `FlutterTextureRegistry`, so flutter can composite the map like any other
/// widget rather than as a platform view.
///
/// Two details are load-bearing:
///
/// `framebufferOnly = false` on the view, or the drawable's texture cannot be
/// used as a blit source and every copy fails.
///
/// The frame that is copied is the PREVIOUS one, not the one just handed over.
/// There is no completion callback for a drawable on this sdk, and the current
/// frame has not finished rendering when the draw call returns, while the one
/// before it provably has. The cost is one frame of latency.
final class MapTexturePublisher: NSObject, FlutterTexture {
    private struct Entry {
        let buffer: CVPixelBuffer
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
    }

    private static var swizzled = Set<ObjectIdentifier>()
    private static let registry = NSMapTable<CAMetalLayer, MapTexturePublisher>
        .weakToWeakObjects()
    private static var presentHooked = false

    private let textures: FlutterTextureRegistry
    private weak var mapView: UIView?
    private weak var mtkView: MTKView?

    private var textureId: Int64 = -1
    private var queue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var ring: [Entry] = []
    private var ringIndex = 0
    private var ringWidth = 0
    private var ringHeight = 0
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    // MARK: - Overlay state
    //
    // See "UIKit content" below.

    private var overlayLink: CADisplayLink?
    /// What the last raster was of, so an overlay that has not moved is not
    /// rasterised again.
    private var overlaySignature: [CGRect] = []
    private var overlayTexture: MTLTexture?
    private var overlayRect: CGRect = .zero
    private var overlayPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let overlayLock = NSLock()

    init(mapView: UIView, textures: FlutterTextureRegistry) {
        self.mapView = mapView
        self.textures = textures
        super.init()
    }

    func start() -> Int64 {
        if textureId >= 0 { return textureId }
        guard let mapView, let mtk = Self.findMTKView(in: mapView) else { return -1 }
        mtkView = mtk
        mtk.framebufferOnly = false
        queue = mtk.device?.makeCommandQueue()
        guard let layer = mtk.layer as? CAMetalLayer else { return -1 }
        Self.registry.setObject(self, forKey: layer)
        Self.hookPresentIfNeeded(device: mtk.device)
        startOverlayLink()
        textureId = textures.register(self)
        return textureId
    }

    func stop() {
        overlayLink?.invalidate()
        overlayLink = nil
        overlayTexture = nil
        if let layer = mtkView?.layer as? CAMetalLayer {
            Self.registry.removeObject(forKey: layer)
        }
        if textureId >= 0 { textures.unregisterTexture(textureId) }
        textureId = -1
        ring.removeAll()
        latest = nil
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        return Unmanaged.passRetained(latest)
    }

    // MARK: - Frame capture

    /// Frames are caught at `-[MTLCommandBuffer presentDrawable:]`.
    ///
    /// `UIView.draw(_:)` is the obvious hook and it never runs: an MTKView
    /// renders through Metal, not Core Graphics, so the method is simply not
    /// called. Every frame does pass through presentDrawable, and hooking
    /// there also means the copy can be encoded onto the SAME command buffer
    /// that presents it, so the blit is ordered after the render with no
    /// waiting and no guessing.
    private static func hookPresentIfNeeded(device: MTLDevice?) {
        guard !presentHooked, let device,
              let queue = device.makeCommandQueue(),
              let probe = queue.makeCommandBuffer() else { return }
        presentHooked = true
        let cls: AnyClass = type(of: probe)
        let sel = NSSelectorFromString("presentDrawable:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias PresentIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: PresentIMP.self)
        let block: @convention(block) (AnyObject, AnyObject) -> Void = { buffer, drawable in
            if let metalDrawable = drawable as? CAMetalDrawable,
               let publisher = MapTexturePublisher.registry.object(forKey: metalDrawable.layer),
               let commandBuffer = buffer as? MTLCommandBuffer {
                publisher.encodeCopy(of: metalDrawable.texture, on: commandBuffer)
            }
            original(buffer, sel, drawable)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private func encodeCopy(of source: MTLTexture, on commandBuffer: MTLCommandBuffer) {
        guard textureId >= 0, !source.isFramebufferOnly else { return }
        guard source.pixelFormat == .bgra8Unorm
                || source.pixelFormat == .bgra8Unorm_srgb else { return }
        guard let device = mtkView?.device,
              let entry = nextEntry(width: source.width, height: source.height,
                                    format: source.pixelFormat, device: device),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width,
                                      height: source.height, depth: 1),
                  to: entry.texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        compositeOverlay(onto: entry.texture, commandBuffer: commandBuffer)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self, self.textureId >= 0 else { return }
            self.lock.lock()
            self.latest = entry.buffer
            self.lock.unlock()
            self.textures.textureFrameAvailable(self.textureId)
        }
    }

    // MARK: - Buffers

    /// Three buffers, so the one flutter is reading is never the one being
    /// written. Fewer and the texture tears under a fast camera.
    private func nextEntry(width: Int, height: Int, format: MTLPixelFormat,
                           device: MTLDevice) -> Entry? {
        if width != ringWidth || height != ringHeight {
            ring.removeAll()
            ringWidth = width
            ringHeight = height
        }
        if ring.count < 3 {
            guard let entry = makeEntry(width: width, height: height,
                                        format: format, device: device) else { return nil }
            ring.append(entry)
            return entry
        }
        ringIndex = (ringIndex + 1) % ring.count
        let candidate = ring[ringIndex]
        lock.lock()
        let inUse = candidate.buffer === latest
        lock.unlock()
        if inUse {
            ringIndex = (ringIndex + 1) % ring.count
            return ring[ringIndex]
        }
        return candidate
    }

    private func makeEntry(width: Int, height: Int, format: MTLPixelFormat,
                           device: MTLDevice) -> Entry? {
        if textureCache == nil {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        guard let cache = textureCache else { return nil }
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary,
                                  &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }
        var metalTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format,
            width, height, 0, &metalTexture) == kCVReturnSuccess,
              let cvTexture = metalTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return Entry(buffer: buffer, cvTexture: cvTexture, texture: texture)
    }

    // MARK: - UIKit content
    //
    // Everything the map shows that UIKit draws rather than Metal — a view
    // annotation, the logo, the attribution — is a subview of the map view and
    // so is NOT in the frame the blit above copies. On the platform view UIKit
    // composites those over the map; here nothing does, and a selected pin
    // would simply never appear.
    //
    // So they are rasterised on the main thread and drawn over the texture on
    // the gpu. Two things keep that cheap:
    //
    // The raster covers only the union of their frames, which is one small
    // view plus a strip at the bottom, not the screen.
    //
    // It is redone only when something has actually moved or is mid-animation.
    // The logo and attribution never move, so they are rasterised once and
    // then cost nothing; an annotation opening is redrawn per frame, which is
    // the one case where a cached bitmap would visibly freeze.

    private func startOverlayLink() {
        let link = CADisplayLink(target: self, selector: #selector(updateOverlay))
        link.add(to: .main, forMode: .common)
        overlayLink = link
    }

    /// Everything the map view draws with UIKit rather than Metal.
    private var overlayViews: [UIView] {
        guard let mapView else { return [] }
        return mapView.subviews.filter {
            !($0 is MTKView)
                && !$0.isHidden
                && $0.alpha > 0.01
                && $0.bounds.width > 0
                && $0.bounds.height > 0
        }
    }

    /// True while any of these is running an animation, at which point its
    /// pixels differ from frame to frame even if its frame does not.
    private func isAnimating(_ views: [UIView]) -> Bool {
        for view in views {
            if view.layer.animationKeys()?.isEmpty == false { return true }
            for sublayer in view.layer.sublayers ?? [] where sublayer.animationKeys()?.isEmpty == false {
                return true
            }
        }
        return false
    }

    @objc private func updateOverlay() {
        let views = overlayViews
        guard !views.isEmpty, let mapView, let device = mtkView?.device else {
            overlayLock.lock()
            overlayTexture = nil
            overlayRect = .zero
            overlayLock.unlock()
            overlaySignature = []
            return
        }

        let signature = views.map(\.frame)
        guard signature != overlaySignature || isAnimating(views) else { return }
        overlaySignature = signature

        let scale = mapView.contentScaleFactor
        var union = CGRect.null
        for view in views { union = union.union(view.frame) }
        union = union.intersection(mapView.bounds)
        guard !union.isNull, union.width > 0, union.height > 0 else { return }

        let width = Int((union.width * scale).rounded())
        let height = Int((union.height * scale).rounded())
        guard width > 0, height > 0 else { return }

        // BGRA premultiplied, which is what the destination texture is, so
        // the bytes go straight over with no conversion.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let hasContent: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }

            // A bitmap context draws y-up and UIKit lays out y-down, so the
            // vertical axis is flipped before anything is drawn into it.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -union.origin.x, y: -union.origin.y)
            UIGraphicsPushContext(context)
            for view in views {
                context.saveGState()
                context.translateBy(x: view.frame.origin.x, y: view.frame.origin.y)
                // The model layer, not the view: `drawHierarchy` needs the
                // view to be on screen, and this one never is.
                (view.layer.presentation() ?? view.layer).render(in: context)
                context.restoreGState()
            }
            UIGraphicsPopContext()
            return true
        }
        guard hasContent else { return }

        let texture = overlayDestination(width: width, height: height, device: device)
        guard let texture else { return }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: bytesPerRow)
        }

        overlayLock.lock()
        overlayTexture = texture
        overlayRect = CGRect(x: union.origin.x * scale, y: union.origin.y * scale,
                             width: CGFloat(width), height: CGFloat(height))
        overlayLock.unlock()
    }

    private func overlayDestination(width: Int, height: Int, device: MTLDevice) -> MTLTexture? {
        overlayLock.lock()
        let existing = overlayTexture
        overlayLock.unlock()
        if let existing, existing.width == width, existing.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }

    /// Draw the overlay over the copied map frame, on the same command buffer,
    /// so it lands in the same texture flutter is handed.
    private func compositeOverlay(onto destination: MTLTexture, commandBuffer: MTLCommandBuffer) {
        overlayLock.lock()
        let source = overlayTexture
        let rect = overlayRect
        overlayLock.unlock()
        guard let source, rect.width > 0, rect.height > 0,
              let device = mtkView?.device,
              let pipeline = overlayPipeline(for: destination.pixelFormat, device: device)
        else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Pixels to clip space. Metal's y runs up the screen and UIKit's runs
        // down it, so the vertical span is flipped here rather than in the
        // shader.
        let w = CGFloat(destination.width)
        let h = CGFloat(destination.height)
        var quad = SIMD4<Float>(
            Float(rect.minX / w * 2 - 1),
            Float(1 - rect.minY / h * 2),
            Float(rect.maxX / w * 2 - 1),
            Float(1 - rect.maxY / h * 2)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Compiled from source at runtime so the plugin needs no `.metal` file in
    /// its build, which a pod would have to declare and ship separately.
    private func overlayPipeline(for format: MTLPixelFormat, device: MTLDevice) -> MTLRenderPipelineState? {
        if let existing = overlayPipelines[format] { return existing }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 position [[position]]; float2 uv; };
        vertex VOut albo_overlay_vertex(uint id [[vertex_id]],
                                        constant float4 &rect [[buffer(0)]]) {
            float2 corners[4] = { float2(rect.x, rect.y), float2(rect.z, rect.y),
                                  float2(rect.x, rect.w), float2(rect.z, rect.w) };
            float2 uvs[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
            VOut out;
            out.position = float4(corners[id], 0, 1);
            out.uv = uvs[id];
            return out;
        }
        fragment float4 albo_overlay_fragment(VOut in [[stage_in]],
                                              texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return tex.sample(s, in.uv);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vertexFunction = library.makeFunction(name: "albo_overlay_vertex"),
              let fragmentFunction = library.makeFunction(name: "albo_overlay_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = format
        attachment?.isBlendingEnabled = true
        // The raster is premultiplied, so the source is added whole rather
        // than scaled by its own alpha a second time.
        attachment?.sourceRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        overlayPipelines[format] = pipeline
        return pipeline
    }

    private static func findMTKView(in view: UIView) -> MTKView? {
        if let mtk = view as? MTKView { return mtk }
        for subview in view.subviews {
            if let found = findMTKView(in: subview) { return found }
        }
        return nil
    }
}

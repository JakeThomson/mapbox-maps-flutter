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

    private final class OverlayItem {
        var texture: MTLTexture?
        var pixelWidth = 0
        var pixelHeight = 0
    }

    private var overlayLink: CADisplayLink?
    /// One raster per UIKit view, kept until that view's content changes.
    private var overlayItems: [ObjectIdentifier: OverlayItem] = [:]
    /// What the next frame draws: each raster and where, in pixels.
    private var overlayDraws: [(texture: MTLTexture, rect: CGRect)] = []
    private var overlayPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let overlayLock = NSLock()
    /// Until when every view is rasterised each frame regardless.
    private var overlayLiveUntil: CFTimeInterval = 0
    private var overlayObserver: NSObjectProtocol?

    /// Asks the map for a frame. The overlay only reaches flutter on the back
    /// of one, and the map renders on demand, so a pin animating over a map
    /// that is standing still would otherwise never be seen.
    var requestFrame: (() -> Void)?

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
        overlayObserver = NotificationCenter.default.addObserver(
            forName: Self.overlayDidChange, object: mapView, queue: .main
        ) { [weak self] _ in
            self?.overlayLiveUntil = CACurrentMediaTime() + Self.overlayLiveWindow
        }
        textureId = textures.register(self)
        return textureId
    }

    func stop() {
        overlayLink?.invalidate()
        overlayLink = nil
        if let overlayObserver { NotificationCenter.default.removeObserver(overlayObserver) }
        overlayObserver = nil
        overlayItems.removeAll()
        overlayLock.lock()
        overlayDraws.removeAll()
        overlayLock.unlock()
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
    // So each one is rasterised on the main thread, on its own, and drawn over
    // the texture on the gpu. What keeps that cheap is that a raster is redone
    // only when the view's CONTENT changes:
    //
    // A view that has only moved — every annotation, every frame of a pan —
    // keeps its raster and is drawn somewhere else.
    //
    // A view mid-animation is rasterised each frame. A Core Animation one says
    // so through its layers. A SwiftUI one does not: it restyles its layers
    // itself with nothing to observe, so whoever changes one posts
    // [overlayDidChange] and everything is rasterised for [overlayLiveWindow].
    //
    // Per view rather than one raster of all of them, because the sdk parks
    // its annotations in a transparent container the size of the map. One
    // raster of that is a full-screen bitmap on the main thread every frame an
    // annotation animates, which stalled the app for a second at a time.

    /// Posted with a map view as the object when UIKit content inside it
    /// changes in a way its layers cannot show.
    static let overlayDidChange = Notification.Name("MapTexturePublisherOverlayDidChange")

    /// Long enough to cover a SwiftUI spring settling after the change.
    private static let overlayLiveWindow: CFTimeInterval = 0.8

    static func setNeedsOverlay(in mapView: UIView) {
        NotificationCenter.default.post(name: overlayDidChange, object: mapView)
    }

    private func startOverlayLink() {
        let link = CADisplayLink(target: self, selector: #selector(updateOverlay))
        link.add(to: .main, forMode: .common)
        overlayLink = link
    }

    private static func isDrawn(_ view: UIView) -> Bool {
        !view.isHidden && view.alpha > 0.01 && view.bounds.width > 0 && view.bounds.height > 0
    }

    /// A transparent view covering the map, whose children are what is drawn.
    private static func isContainer(_ view: UIView, in mapView: UIView) -> Bool {
        view.layer.contents == nil
            && (view.backgroundColor ?? .clear).cgColor.alpha == 0
            && view.frame.width >= mapView.bounds.width
            && view.frame.height >= mapView.bounds.height
    }

    /// Everything the map view draws with UIKit rather than Metal, with the
    /// view that draws it: the view itself, or for an annotation the
    /// container it sits in (see [raster]).
    private var overlayViews: [(view: UIView, drawer: UIView)] {
        guard let mapView else { return [] }
        var views: [(view: UIView, drawer: UIView)] = []
        for view in mapView.subviews where !(view is MTKView) && Self.isDrawn(view) {
            if Self.isContainer(view, in: mapView) {
                views += view.subviews.filter(Self.isDrawn).map { ($0, view) }
            } else {
                views.append((view, view))
            }
        }
        return views
    }

    /// The part of [layer]'s own space its content actually covers.
    ///
    /// Not its bounds: a selected place pin keeps a small frame and draws its
    /// outline, lift and arrow outside it, which UIKit shows because nothing
    /// clips it. Rasterising the bounds alone cropped the whole selection
    /// away. Capped, so one runaway sublayer cannot make a pin screen-sized.
    private static func drawnBounds(of root: CALayer) -> CGRect {
        var drawn = root.bounds
        func visit(_ layer: CALayer, depth: Int) {
            guard !layer.masksToBounds, depth > 0 else { return }
            for sublayer in layer.sublayers ?? [] where !sublayer.isHidden && sublayer.opacity > 0.01 {
                drawn = drawn.union(sublayer.convert(sublayer.bounds, to: root))
                visit(sublayer, depth: depth - 1)
            }
        }
        visit(root, depth: 8)
        return drawn.intersection(root.bounds.insetBy(dx: -maximumOverflow, dy: -maximumOverflow))
    }

    private static let maximumOverflow: CGFloat = 240

    private static func isAnimating(_ layer: CALayer, depth: Int) -> Bool {
        if layer.animationKeys()?.isEmpty == false { return true }
        guard depth > 0 else { return false }
        return (layer.sublayers ?? []).contains { isAnimating($0, depth: depth - 1) }
    }

    @objc private func updateOverlay() {
        guard let mapView, let mtkView, let device = mtkView.device,
              mtkView.bounds.width > 0 else { return }
        // Pixels per point of the frames this is drawn onto. Not the map
        // view's `contentScaleFactor`, which is 1 on a view that draws nothing
        // itself: that put every overlay at a third of its size and position.
        let scale = mtkView.drawableSize.width / mtkView.bounds.width
        let live = CACurrentMediaTime() < overlayLiveUntil
        var seen = Set<ObjectIdentifier>()
        var draws: [(texture: MTLTexture, rect: CGRect)] = []
        var redrawn = false

        for (view, drawer) in overlayViews {
            // The presentation layer, so a view mid-animation is drawn where
            // it is on screen now rather than where it is going.
            let layer = view.layer.presentation() ?? view.layer
            let local = Self.drawnBounds(of: layer)
            let inDrawer = layer.convert(local, to: drawer.layer.presentation() ?? drawer.layer)
            let frame = drawer.convert(inDrawer, to: mapView)
            guard frame.intersects(mapView.bounds) else { continue }

            let key = ObjectIdentifier(view)
            seen.insert(key)
            let item = overlayItems[key] ?? OverlayItem()
            overlayItems[key] = item

            let width = Int((local.width * scale).rounded())
            let height = Int((local.height * scale).rounded())
            guard width > 0, height > 0 else { continue }
            if item.texture == nil || item.pixelWidth != width || item.pixelHeight != height
                || live || Self.isAnimating(view.layer, depth: 4) {
                item.texture = raster(drawer, region: drawer === view ? local : inDrawer,
                                      width: width, height: height, scale: scale, device: device)
                item.pixelWidth = width
                item.pixelHeight = height
                redrawn = true
            }
            guard let texture = item.texture else { continue }
            draws.append((texture, CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                          width: frame.width * scale, height: frame.height * scale)))
        }
        let removed = overlayItems.count > seen.count
        overlayItems = overlayItems.filter { seen.contains($0.key) }
        overlayLock.lock()
        overlayDraws = draws
        overlayLock.unlock()
        if redrawn || removed { requestFrame?() }
    }

    /// [region] of [drawer], in [drawer]'s own space, as a texture.
    ///
    /// An annotation is drawn from its CONTAINER, cropped to the annotation,
    /// rather than from itself: `drawHierarchy` clips a view to its bounds,
    /// and a selected pin is almost all overflow. Anything else draws itself.
    ///
    /// `drawHierarchy`, because the pins are SwiftUI and `render(in:)` draws a
    /// SwiftUI view blank. It needs the view in a window, which is why the host
    /// sits under the flutter view rather than off to the side.
    ///
    /// A fresh texture every time rather than one rewritten in place, so a
    /// frame the gpu is still compositing never has its pixels changed under it.
    private func raster(_ drawer: UIView, region: CGRect, width: Int, height: Int,
                        scale: CGFloat, device: MTLDevice) -> MTLTexture? {
        // BGRA premultiplied, which is what the destination texture is, so
        // the bytes go straight over with no conversion.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
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
            context.translateBy(x: -region.minX, y: -region.minY)
            UIGraphicsPushContext(context)
            if !drawer.drawHierarchy(in: drawer.bounds, afterScreenUpdates: false) {
                (drawer.layer.presentation() ?? drawer.layer).render(in: context)
            }
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
        }
        return texture
    }

    /// Draw the overlay over the copied map frame, on the same command buffer,
    /// so it lands in the same texture flutter is handed.
    private func compositeOverlay(onto destination: MTLTexture, commandBuffer: MTLCommandBuffer) {
        overlayLock.lock()
        let draws = overlayDraws
        overlayLock.unlock()
        guard !draws.isEmpty,
              let device = mtkView?.device,
              let pipeline = overlayPipeline(for: destination.pixelFormat, device: device)
        else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)

        // Pixels to clip space. Metal's y runs up the screen and UIKit's runs
        // down it, so the vertical span is flipped here rather than in the
        // shader.
        let w = CGFloat(destination.width)
        let h = CGFloat(destination.height)
        for draw in draws {
            var quad = SIMD4<Float>(
                Float(draw.rect.minX / w * 2 - 1),
                Float(1 - draw.rect.minY / h * 2),
                Float(draw.rect.maxX / w * 2 - 1),
                Float(1 - draw.rect.maxY / h * 2)
            )
            encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(draw.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
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

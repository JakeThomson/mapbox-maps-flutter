import Flutter
import MapboxMaps
import MetalKit
import UIKit

/// A map that is not a platform view.
///
/// The plugin's only way to show a map on ios is `MapboxMapController`, a
/// `FlutterPlatformView`. UIKit composites that view, not flutter, so nothing
/// drawn above it can read it: backdrop filters, shaders and captures all come
/// back empty. Android does not have this problem because it can render the
/// map into a `TextureView`.
///
/// This is that mode for ios. The same `MapboxMapController` is built, so every
/// pigeon api the normal map exposes is available on the same channel suffix,
/// but its view is parked offscreen and its frames go to
/// `FlutterTextureRegistry`. The widget tree gets a `Texture` and no platform
/// view at all.
final class HeadlessMapTexture: NSObject {
    private static var instances: [Int64: HeadlessMapTexture] = [:]

    private let host: UIView
    private let controller: MapboxMapController
    private let publisher: MapTexturePublisher
    private let textureId: Int64

    private init?(size: CGSize,
                  channelSuffix: Int,
                  options: MapInitOptions,
                  eventTypes: [Int],
                  registrar: FlutterPluginRegistrar) {
        let frame = CGRect(origin: .zero, size: size)

        // The real controller, so style, camera, annotations, gestures and
        // every other pigeon api work exactly as they do for the platform
        // view. Only where its view lives is different.
        controller = MapboxMapController(
            withFrame: frame,
            mapInitOptions: options,
            channelSuffix: channelSuffix,
            registrar: registrar,
            pluginVersion: "",
            eventTypes: eventTypes
        )

        // Parked in the app's OWN key window, UNDER the flutter view, rather
        // than in a window of our own. A second UIWindow steals the scene and
        // the flutter view goes to the background.
        //
        // Under it, not off to the side. The map draws into drawables that
        // CoreAnimation hands back only once it has composited them, and a
        // layer outside the window's bounds is not composited, so they came
        // back late or not at all: every frame then waited out the one second
        // `nextDrawable` allows, and the whole app stalled, not just the map.
        // Inside the bounds and covered by the opaque flutter view, the layer
        // is composited and never seen.
        guard let key = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return nil }
        host = UIView(frame: CGRect(origin: .zero, size: size))
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
        host.addSubview(controller.view())
        key.insertSubview(host, at: 0)

        // `.automatic` switches to presenting inside a Core Animation
        // transaction whenever a view annotation is on the map, to keep UIKit
        // and the map in step. That path never calls
        // `-[MTLCommandBuffer presentDrawable:]`, which is where the publisher
        // catches frames, so the texture froze the moment a pin was selected.
        // The step it keeps is moot here: the publisher composites the
        // annotations into the same frame itself.
        controller.mapboxMapView.presentationTransactionMode = .async

        publisher = MapTexturePublisher(mapView: controller.view(),
                                        textures: registrar.textures())
        let id = publisher.start()
        guard id >= 0 else { return nil }
        textureId = id
        super.init()
        publisher.requestFrame = { [weak controller = self.controller] in controller?.map.triggerRepaint() }
    }

    static func create(size: CGSize,
                       channelSuffix: Int,
                       options: MapInitOptions,
                       eventTypes: [Int],
                       registrar: FlutterPluginRegistrar) -> Int64 {
        guard let instance = HeadlessMapTexture(size: size,
                                                channelSuffix: channelSuffix,
                                                options: options,
                                                eventTypes: eventTypes,
                                                registrar: registrar) else {
            return -1
        }
        instances[instance.textureId] = instance
        return instance.textureId
    }

    static func dispose(textureId: Int64) {
        instances[textureId]?.stopFling()
        instances[textureId]?.publisher.stop()
        instances[textureId]?.host.removeFromSuperview()
        instances[textureId] = nil
    }

    /// Draw one frame.
    ///
    /// The map renders on demand, so after a change that flutter cannot
    /// observe — a resize, a style swap — the texture would otherwise keep
    /// showing the frame before it. This is NOT a loop: it used to be driven
    /// by a 30fps timer, which under glass meant every surface on the map
    /// redrew thirty times a second with the map standing still. Every
    /// ordinary camera change already renders on its own.
    static func pump(textureId: Int64) {
        instances[textureId]?.controller.map.triggerRepaint()
    }

    // MARK: - Interactions

    /// Fire what this tap would have fired, and say whether a view annotation
    /// took it.
    ///
    /// Both halves come from UIKit tap recognisers on the map view, and they
    /// never fire here. A view annotation is asked first because on the
    /// platform view its recogniser makes the map's own taps wait for it to
    /// fail: a hit there is not also a tap on the map. Otherwise the
    /// interactions `addInteraction` registered are dispatched by hand — see
    /// [InteractionsController.dispatch].
    static func tap(textureId: Int64, at point: CGPoint) -> Bool {
        guard let instance = instances[textureId] else { return false }
        if instance.controller.handleViewAnnotationTap(at: point) { return true }
        instance.controller.interactions?.dispatch(.tAP, at: point)
        return false
    }

    static func longPress(textureId: Int64, at point: CGPoint) {
        instances[textureId]?.controller.interactions?.dispatch(.lONGTAP, at: point)
    }

    // MARK: - Fling
    //
    // The sdk decelerates a pan through `CameraAnimationsManager.decelerate`,
    // which is internal to it, so the same physics is run here: displace from
    // the release point by velocity × elapsed each frame, and decay the
    // velocity once per millisecond by the platform's own scroll deceleration
    // rate. Stops under 35pt/s, the sdk's own floor.

    private var flingLink: CADisplayLink?
    private var flingVelocity: CGPoint = .zero
    private var flingOrigin: CGPoint = .zero
    private var flingPrevious: CFTimeInterval = 0

    /// Below this a flick is indistinguishable from letting go, and a fling
    /// there reads as the map sliding on its own.
    private static let minimumFlingSpeed: CGFloat = 50

    static func fling(textureId: Int64, velocity: CGPoint, at point: CGPoint) {
        guard let instance = instances[textureId] else { return }
        instance.stopFling()
        guard abs(velocity.x) > minimumFlingSpeed || abs(velocity.y) > minimumFlingSpeed else { return }
        instance.flingVelocity = velocity
        // Match PanGestureHandler: keep deceleration away from the horizon,
        // where a small screen displacement can translate into a huge pan.
        instance.flingOrigin = CGPoint(
            x: point.x,
            y: max(point.y, 3 * instance.host.bounds.height / 4))
        instance.flingPrevious = CACurrentMediaTime()
        let link = CADisplayLink(target: instance, selector: #selector(stepFling))
        link.add(to: .main, forMode: .common)
        instance.flingLink = link
    }

    static func touchDown(textureId: Int64) {
        guard let instance = instances[textureId] else { return }
        instance.stopFling()
        instance.controller.mapboxMapView.camera.cancelAnimations()
    }

    static func stopFling(textureId: Int64) {
        instances[textureId]?.stopFling()
    }

    private func stopFling() {
        flingLink?.invalidate()
        flingLink = nil
        flingVelocity = .zero
    }

    @objc private func stepFling() {
        let now = CACurrentMediaTime()
        let elapsed = CGFloat(now - flingPrevious)
        flingPrevious = now

        // Always relative to the release point, the way the sdk's animator
        // does it: the displacement shrinks with the velocity rather than the
        // cursor running away across the map.
        let to = CGPoint(x: flingOrigin.x + flingVelocity.x * elapsed,
                         y: flingOrigin.y + flingVelocity.y * elapsed)
        let map = controller.map
        map.setCamera(to: map.dragCameraOptions(from: flingOrigin, to: to))

        let decay = pow(UIScrollView.DecelerationRate.normal.rawValue, elapsed * 1000)
        flingVelocity.x *= decay
        flingVelocity.y *= decay
        if abs(flingVelocity.x) < 35 && abs(flingVelocity.y) < 35 {
            stopFling()
        }
    }

    /// Double tap to zoom in, two-finger tap to zoom out — animated, because
    /// an instant jump of a whole zoom level reads as the map teleporting.
    static func zoomStep(textureId: Int64, delta: Double, at point: CGPoint) {
        guard let instance = instances[textureId] else { return }
        instance.stopFling()
        let map = instance.controller.map
        let zoom = max(0, min(22, map.cameraState.zoom + CGFloat(delta)))
        instance.controller.mapboxMapView.camera.ease(
            to: camera(map, anchor: point, zoom: zoom),
            duration: 0.3,
            curve: .easeOut
        )
    }

    /// Rotation, split view, a keyboard appearing: the texture has to follow
    /// the widget or the map renders at one size and is sampled at another.
    static func resize(textureId: Int64, size: CGSize) {
        guard let instance = instances[textureId] else { return }
        guard size.width > 0, size.height > 0 else { return }
        instance.host.frame = CGRect(origin: .zero, size: size)
        instance.controller.view().frame = CGRect(origin: .zero, size: size)
        instance.controller.view().layoutIfNeeded()
        instance.controller.map.triggerRepaint()
    }

    // MARK: - Gestures
    //
    // The map's view is offscreen, so UIKit will never deliver touches to it
    // and its own recognisers can never fire. Flutter owns the hit test now,
    // so it forwards the points and the camera is driven directly. Same maths
    // the sdk's own pan recogniser uses, via dragCameraOptions.

    private var lastDrag: CGPoint?

    static func panBegin(textureId: Int64, at point: CGPoint) {
        instances[textureId]?.stopFling()
        instances[textureId]?.lastDrag = point
    }

    static func panUpdate(textureId: Int64, to point: CGPoint) {
        guard let instance = instances[textureId],
              let from = instance.lastDrag else { return }
        let map = instance.controller.map
        map.setCamera(to: map.dragCameraOptions(from: from, to: point))
        instance.lastDrag = point
    }

    static func panEnd(textureId: Int64) {
        instances[textureId]?.lastDrag = nil
    }

    /// Two finger twist. Bearing is degrees clockwise from north, the gesture
    /// gives radians, and a clockwise twist should turn the map the other way,
    /// hence the negation.
    static func rotateBy(textureId: Int64, radians: Double, at point: CGPoint) {
        guard let instance = instances[textureId] else { return }
        let map = instance.controller.map
        map.setCamera(to: camera(map,
                                 anchor: point,
                                 bearing: map.cameraState.bearing - radians * 180 / .pi))
    }

    /// Two finger drag up tilts the camera over. Clamped to the sdk's own
    /// ceiling; past it the horizon enters the frame and the map is unusable.
    static func pitchBy(textureId: Int64, delta: Double) {
        guard let instance = instances[textureId] else { return }
        let map = instance.controller.map
        let pitch = max(0, min(85, map.cameraState.pitch + delta))
        map.setCamera(to: camera(map, pitch: pitch))
    }

    /// Every field, every time.
    ///
    /// `CameraOptions` is not a patch: a nil field is not "leave this alone",
    /// it is "no value", and the camera resolves it to a default. Setting only
    /// bearing therefore threw away the centre and the zoom and left a black
    /// map. Read the current state and change the one thing.
    ///
    /// MapboxMaps.CameraOptions, not the pigeon type of the same name that
    /// this module also declares. Unqualified it resolves to ours.
    private static func camera(_ map: MapboxMap,
                               anchor: CGPoint? = nil,
                               zoom: CGFloat? = nil,
                               bearing: CLLocationDirection? = nil,
                               pitch: CGFloat? = nil) -> MapboxMaps.CameraOptions {
        let state = map.cameraState
        return MapboxMaps.CameraOptions(
            center: state.center,
            padding: state.padding,
            anchor: anchor,
            zoom: zoom ?? state.zoom,
            bearing: bearing ?? state.bearing,
            pitch: pitch ?? state.pitch
        )
    }

    static func zoomBy(textureId: Int64, delta: Double, at point: CGPoint) {
        guard let instance = instances[textureId] else { return }
        let map = instance.controller.map
        let zoom = max(0, min(22, map.cameraState.zoom + delta))
        map.setCamera(to: camera(map, anchor: point, zoom: zoom))
    }
}

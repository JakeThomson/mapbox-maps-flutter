import Flutter
@_spi(Experimental) import MapboxMaps
import UIKit

struct SuffixBinaryMessenger {
    let messenger: FlutterBinaryMessenger
    let suffix: String
}

final class MapboxMapController: NSObject, FlutterPlatformView {
    private let mapView: MapView
    private let mapboxMap: MapboxMap
    private let channel: FlutterMethodChannel
    private let annotationController: AnnotationController?
    private let gesturesController: GesturesController?
    private let interactionsController: InteractionsController?
    private let viewAnnotationController: ViewAnnotationController
    private var viewLayerController: ViewLayerController?
    private let eventHandler: MapboxEventHandler
    private let binaryMessenger: SuffixBinaryMessenger

    func view() -> UIView {
        return mapView
    }

    init(
        withFrame frame: CGRect,
        mapInitOptions: MapInitOptions,
        channelSuffix: Int,
        registrar: FlutterPluginRegistrar,
        pluginVersion: String,
        eventTypes: [Int]
    ) {
        binaryMessenger = SuffixBinaryMessenger(messenger: registrar.messenger(), suffix: String(channelSuffix))
        _ = SettingsServiceFactory.getInstanceFor(.nonPersistent)
            .set(key: "com.mapbox.common.telemetry.internal.custom_user_agent_fragment", value: "FlutterPlugin/\(pluginVersion)")

        mapView = MapView(frame: frame, mapInitOptions: mapInitOptions)
        mapboxMap = mapView.mapboxMap

        channel = FlutterMethodChannel(
            name: "plugins.flutter.io.\(channelSuffix)",
            binaryMessenger: binaryMessenger.messenger
        )
        self.eventHandler = MapboxEventHandler(
            eventProvider: mapboxMap,
            binaryMessenger: binaryMessenger.messenger,
            eventTypes: eventTypes,
            channelSuffix: String(channelSuffix)
        )

        let styleController = StyleController(styleManager: mapboxMap)
        StyleManagerSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: styleController, messageChannelSuffix: binaryMessenger.suffix)

        let cameraController = CameraController(withMapboxMap: mapboxMap)
        _CameraManagerSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: cameraController, messageChannelSuffix: binaryMessenger.suffix)

        let mapInterfaceController = MapInterfaceController(withMapboxMap: mapboxMap, mapView: mapView)
        _MapInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: mapInterfaceController, messageChannelSuffix: binaryMessenger.suffix)

        let mapProjectionController = MapProjectionController()
        ProjectionSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: mapProjectionController, messageChannelSuffix: binaryMessenger.suffix)

        let animationController = AnimationController(withMapView: mapView)
        _AnimationManagerSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: animationController, messageChannelSuffix: binaryMessenger.suffix)

        let locationController = LocationController(withMapView: mapView)
        _LocationComponentSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: locationController, messageChannelSuffix: binaryMessenger.suffix)

        gesturesController = GesturesController(withMapView: mapView)
        GesturesSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: gesturesController, messageChannelSuffix: binaryMessenger.suffix)

        interactionsController = InteractionsController(withMapView: mapView)
        
        viewAnnotationController = ViewAnnotationController(
            mapView: mapView,
            messenger: binaryMessenger.messenger,
            channelSuffix: binaryMessenger.suffix
        )

        viewLayerController = ViewLayerController(
            mapView: mapView,
            viewAnnotationController: viewAnnotationController,
            messenger: binaryMessenger.messenger,
            channelSuffix: binaryMessenger.suffix
        )

        let logoController = LogoController(withMapView: mapView)
        LogoSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: logoController, messageChannelSuffix: binaryMessenger.suffix)

        let attributionController = AttributionController(withMapView: mapView)
        AttributionSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: attributionController, messageChannelSuffix: binaryMessenger.suffix)

        let compassController = CompassController(withMapView: mapView)
        CompassSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: compassController, messageChannelSuffix: binaryMessenger.suffix)

        let scaleBarController = ScaleBarController(withMapView: mapView)
        ScaleBarSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: scaleBarController, messageChannelSuffix: binaryMessenger.suffix)

        annotationController = AnnotationController(withMapView: mapView, messenger: binaryMessenger)
        annotationController!.setup()

        let viewportController = ViewportController(
            viewportManager: mapView.viewport,
            cameraManager: mapView.camera,
            mapboxMap: mapboxMap
        )
        _ViewportMessengerSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: viewportController, messageChannelSuffix: binaryMessenger.suffix)

        let performanceStatisticsController = PerformanceStatisticsController(
            mapboxMap: mapView.mapboxMap,
            messenger: binaryMessenger
        )
        _PerformanceStatisticsApiSetup.setUp(
            binaryMessenger: binaryMessenger.messenger,
            api: performanceStatisticsController,
            messageChannelSuffix: binaryMessenger.suffix
        )

        let mapRecorderController = MapRecorderController(mapboxMap: mapView.mapboxMap)
        _MapRecorderMessengerSetup.setUp(
            binaryMessenger: binaryMessenger.messenger,
            api: mapRecorderController,
            messageChannelSuffix: binaryMessenger.suffix
        )

        super.init()

        channel.setMethodCallHandler { [weak self] in self?.onMethodCall(methodCall: $0, result: $1) }
    }

    deinit {
        viewLayerController?.dispose()
    }

    func onMethodCall(methodCall: FlutterMethodCall, result: @escaping FlutterResult) {
        switch methodCall.method {
        case "annotation#create_manager":
            annotationController!.handleCreateManager(methodCall: methodCall, result: result)
        case "annotation#remove_manager":
            annotationController!.handleRemoveManager(methodCall: methodCall, result: result)
        case "gesture#add_listeners":
            gesturesController!.addListeners(messenger: binaryMessenger)
            result(nil)
        case "gesture#remove_listeners":
            gesturesController!.removeListeners()
            result(nil)
        case "interactions#add_interaction":
            interactionsController!.addInteraction(messenger: binaryMessenger, methodCall: methodCall)
            result(nil)
        case "interactions#remove_interaction":
            interactionsController!.removeInteraction(methodCall: methodCall)
            result(nil)
        case "platform#releaseMethodChannels":
            releaseMethodChannels()
            result(nil)
        case "map#snapshot":
            do {
                let snapshot = try mapView.snapshot()
                result(snapshot.pngData())
            } catch {
                result(FlutterError(code: "2342345", message: error.localizedDescription, details: nil))
            }
        case "mapView#submitViewSizeHint":
            if let arguments = methodCall.arguments as? [String: Double],
               let width = arguments["width"], let height = arguments["height"] {
                let size = CGSize(width: width, height: height)
                guard size != .zero else { return }

                // This is a bit of a hack to size the map view as early as possible,
                // Flutter is quite slow with it
                mapView.superview?.frame = CGRect(origin: .zero, size: size)
            }
            result(nil)
        case "map#setCustomHeaders":
            guard let arguments = methodCall.arguments as? [String: Any],
              let headers = arguments["headers"] as? [String: String]
        else {
            result(FlutterError(
                code: "setCustomHeaders",
                message: "could not decode arguments",
                details: nil
            ))
            return
        }
        let customInterceptor = CustomHttpServiceInterceptor()
        HttpServiceFactory.setHttpServiceInterceptorForInterceptor(customInterceptor)
            customInterceptor.customHeaders = headers
        result(nil)

        case "viewAnnotation#add":
            guard let args = methodCall.arguments as? [String: Any],
                  let id = args["id"] as? String,
                  let layoutName = args["layoutName"] as? String,
                  let latitude = args["latitude"] as? Double,
                  let longitude = args["longitude"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing required arguments", details: nil))
                return
            }
            let data = args["data"] as? [String: Any]
            let anchor = args["anchor"] as? String
            let allowOverlap = args["allowOverlap"] as? Bool ?? true
            
            switch viewAnnotationController.add(
                id: id,
                layoutName: layoutName,
                latitude: latitude,
                longitude: longitude,
                data: data,
                anchor: anchor,
                allowOverlap: allowOverlap
            ) {
            case .success:
                result(nil)
            case .failure(let error):
                result(FlutterError(code: "VIEW_ANNOTATION_ERROR", message: error.localizedDescription, details: nil))
            }

        case "viewAnnotation#update":
            guard let args = methodCall.arguments as? [String: Any],
                  let id = args["id"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing required arguments", details: nil))
                return
            }
            let latitude = args["latitude"] as? Double
            let longitude = args["longitude"] as? Double
            let data = args["data"] as? [String: Any]
            
            switch viewAnnotationController.update(id: id, latitude: latitude, longitude: longitude, data: data) {
            case .success:
                result(nil)
            case .failure(let error):
                result(FlutterError(code: "VIEW_ANNOTATION_ERROR", message: error.localizedDescription, details: nil))
            }

        case "viewAnnotation#remove":
            guard let args = methodCall.arguments as? [String: Any],
                  let id = args["id"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing required arguments", details: nil))
                return
            }
            
            switch viewAnnotationController.remove(id: id) {
            case .success:
                result(nil)
            case .failure(let error):
                result(FlutterError(code: "VIEW_ANNOTATION_ERROR", message: error.localizedDescription, details: nil))
            }

        case "viewAnnotation#removeAll":
            viewAnnotationController.removeAll()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func releaseMethodChannels() {
        channel.setMethodCallHandler(nil)

        StyleManagerSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        _CameraManagerSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        _MapInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        ProjectionSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        _AnimationManagerSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        _LocationComponentSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        GesturesSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        LogoSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        AttributionSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        CompassSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        ScaleBarSettingsInterfaceSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        annotationController?.tearDown()
        _ViewportMessengerSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
        _PerformanceStatisticsApiSetup.setUp(binaryMessenger: binaryMessenger.messenger, api: nil, messageChannelSuffix: binaryMessenger.suffix)
    }
}

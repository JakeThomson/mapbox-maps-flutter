import UIKit
import Flutter
@_spi(Experimental) import MapboxMaps

struct ViewLayerConfig {
    let id: String
    let sourceId: String
    let sourceLayer: String?
    let layoutName: String
    let propertyMapping: [String: PropertyMappingConfig]
    let anchor: String?
    let allowOverlap: Bool
    let filter: [Any]?
    let minZoom: Double?
    let maxZoom: Double?
    let associatedSymbolLayerId: String?
}

struct PropertyMappingConfig {
    let type: String  // "feature" or "constant"
    let propertyKey: String?  // For feature type
    let value: Any?  // For constant type
}

class ViewLayerController {
    private let mapView: MapView
    private let viewAnnotationController: ViewAnnotationController
    private let messenger: FlutterBinaryMessenger
    private let channelSuffix: String

    private var viewLayers: [String: ViewLayerConfig] = [:]
    private var featureAnnotations: [String: Set<String>] = [:]  // layerId -> Set of annotation IDs
    private var visibleFeatureIds: [String: Set<String>] = [:]  // layerId -> Set of feature IDs

    private var updatePending = false
    private let debounceDelay: TimeInterval = 0.15
    private var cameraObserver: Cancelable?

    init(mapView: MapView, viewAnnotationController: ViewAnnotationController, messenger: FlutterBinaryMessenger, channelSuffix: String) {
        self.mapView = mapView
        self.viewAnnotationController = viewAnnotationController
        self.messenger = messenger
        self.channelSuffix = channelSuffix

        setupMethodChannels()
        setupCameraObserver()
    }

    private func setupMethodChannels() {
        let addChannel = FlutterBasicMessageChannel(
            name: "dev.flutter.pigeon.mapbox_maps_flutter.ViewLayerManager.addViewLayer.\(channelSuffix)",
            binaryMessenger: messenger,
            codec: FlutterStandardMessageCodec.sharedInstance()
        )

        addChannel.setMessageHandler { [weak self] (message, reply) in
            guard let self = self else { return }

            guard let args = message as? [Any],
                  let propertiesJson = args.first as? String else {
                reply(["error": ["code": "invalid_argument", "message": "Missing properties argument"]])
                return
            }

            do {
                let config = try self.parseViewLayerConfig(json: propertiesJson)
                self.viewLayers[config.id] = config
                self.featureAnnotations[config.id] = []
                self.visibleFeatureIds[config.id] = []
                self.scheduleUpdate()

                reply([:])
            } catch {
                reply(["error": ["code": "view_layer_error", "message": error.localizedDescription]])
            }
        }

        let updateChannel = FlutterBasicMessageChannel(
            name: "dev.flutter.pigeon.mapbox_maps_flutter.ViewLayerManager.updateViewLayer.\(channelSuffix)",
            binaryMessenger: messenger,
            codec: FlutterStandardMessageCodec.sharedInstance()
        )

        updateChannel.setMessageHandler { [weak self] (message, reply) in
            guard let self = self else { return }

            guard let args = message as? [Any],
                  let propertiesJson = args.first as? String else {
                reply(["error": ["code": "invalid_argument", "message": "Missing properties argument"]])
                return
            }

            do {
                let config = try self.parseViewLayerConfig(json: propertiesJson)

                guard self.viewLayers[config.id] != nil else {
                    throw NSError(domain: "ViewLayerController", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "ViewLayer '\(config.id)' not found"])
                }

                self.viewLayers[config.id] = config
                self.scheduleUpdate()

                reply([:])
            } catch {
                reply(["error": ["code": "view_layer_error", "message": error.localizedDescription]])
            }
        }
    }

    private func setupCameraObserver() {
        cameraObserver = mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
            self?.scheduleUpdate()
        }
    }

    private func parseViewLayerConfig(json: String) throws -> ViewLayerConfig {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ViewLayerController", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        }

        let propertyMappingObj = obj["propertyMapping"] as? [String: [String: Any]] ?? [:]
        var propertyMapping: [String: PropertyMappingConfig] = [:]

        for (key, mappingObj) in propertyMappingObj {
            let type = mappingObj["type"] as? String ?? "constant"
            let propertyKey = mappingObj["propertyKey"] as? String
            let value = mappingObj["value"]

            propertyMapping[key] = PropertyMappingConfig(
                type: type,
                propertyKey: propertyKey,
                value: value
            )
        }

        return ViewLayerConfig(
            id: obj["id"] as? String ?? "",
            sourceId: obj["source"] as? String ?? "",
            sourceLayer: obj["source-layer"] as? String,
            layoutName: obj["layoutName"] as? String ?? "",
            propertyMapping: propertyMapping,
            anchor: obj["anchor"] as? String,
            allowOverlap: obj["allowOverlap"] as? Bool ?? true,
            filter: obj["filter"] as? [Any],
            minZoom: obj["minzoom"] as? Double,
            maxZoom: obj["maxzoom"] as? Double,
            associatedSymbolLayerId: obj["associatedSymbolLayerId"] as? String
        )
    }

    private func scheduleUpdate() {
        guard !updatePending else { return }

        updatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay) { [weak self] in
            self?.updatePending = false
            self?.updateVisibleFeatures()
        }
    }

    private func updateVisibleFeatures() {
        let currentZoom = mapView.mapboxMap.cameraState.zoom

        for config in viewLayers.values {
            // Check zoom level
            if let minZoom = config.minZoom, currentZoom < minZoom {
                removeAllAnnotations(forLayer: config.id)
                continue
            }
            if let maxZoom = config.maxZoom, currentZoom >= maxZoom {
                removeAllAnnotations(forLayer: config.id)
                continue
            }

            // Query features for this layer
            queryFeatures(for: config)
        }
    }

    private func queryFeatures(for config: ViewLayerConfig) {
        // Get the viewport bounds to query features
        let screenBounds = mapView.bounds

        // Query rendered features using screen bounds
        var filterString: String? = nil
        if let filter = config.filter {
            if let jsonData = try? JSONSerialization.data(withJSONObject: filter),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                filterString = jsonString
            }
        }

        let pigeonOptions = RenderedQueryOptions(
            layerIds: config.associatedSymbolLayerId != nil ? [config.associatedSymbolLayerId!] : nil,
            filter: filterString
        )

        guard let options = try? pigeonOptions.toRenderedQueryOptions() else {
            return
        }

        mapView.mapboxMap.queryRenderedFeatures(
            with: screenBounds,
            options: options
        ) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let queriedFeatures):
                var currentFeatureIds = Set<String>()
                let previousFeatureIds = self.visibleFeatureIds[config.id] ?? []

                let useLayerFeatureBinding = config.associatedSymbolLayerId != nil

                for queriedFeature in queriedFeatures {
                    // Filter by source and sourceLayer
                    guard queriedFeature.queriedFeature.source == config.sourceId else { continue }
                    if let sourceLayer = config.sourceLayer {
                        guard queriedFeature.queriedFeature.sourceLayer == sourceLayer else { continue }
                    }

                    let feature = queriedFeature.queriedFeature.feature

                    // Get the namespaced feature ID for tracking
                    guard let featureId = self.getFeatureId(
                        feature: feature,
                        sourceLayer: config.sourceLayer,
                        requireExplicit: useLayerFeatureBinding
                    ) else {
                        continue
                    }

                    currentFeatureIds.insert(featureId)

                    // If this is a new feature, create annotation
                    if !previousFeatureIds.contains(featureId) {
                        // Get raw feature ID for layer feature binding
                        let rawFeatureId: String? = useLayerFeatureBinding ?
                            self.getFeatureId(feature: feature, sourceLayer: config.sourceLayer, requireExplicit: true, rawId: true) : nil

                        self.createAnnotation(for: config, feature: feature, featureId: featureId, rawFeatureId: rawFeatureId)
                    }
                }

                // Remove annotations for features no longer visible
                let removedFeatures = previousFeatureIds.subtracting(currentFeatureIds)
                for featureId in removedFeatures {
                    self.removeAnnotation(forLayer: config.id, featureId: featureId)
                }

                self.visibleFeatureIds[config.id] = currentFeatureIds

            case .failure:
                break
            }
        }
    }

    /// Gets the feature ID for annotation tracking.
    /// - Parameters:
    ///   - feature: The map feature
    ///   - sourceLayer: The source layer name for namespacing
    ///   - requireExplicit: If true, returns nil when no explicit ID is found (no coordinate fallback)
    ///   - rawId: If true, returns just the raw ID without sourceLayer prefix (for layer feature binding)
    ///
    /// IMPORTANT: When using `associatedSymbolLayerId` for layer feature binding, do NOT use
    /// `promoteId` on the source. The Mapbox SDK's `.layerFeature()` binding mechanism is
    /// incompatible with promoteId - it cannot find features when promoteId is set.
    private func getFeatureId(feature: Feature, sourceLayer: String?, requireExplicit: Bool = false, rawId: Bool = false) -> String? {
        // Try to get feature ID
        if let id = feature.identifier {
            let idString: String
            switch id {
            case .string(let str):
                idString = str
            case .number(let num):
                // IMPORTANT: Use Int64 conversion to avoid scientific notation for large numbers
                // MVT feature IDs are 64-bit integers, and annotatedLayerFeature needs exact match
                if num.truncatingRemainder(dividingBy: 1) == 0 {
                    idString = String(Int64(num))
                } else {
                    idString = String(num)
                }
            }
            return rawId ? idString : "\(sourceLayer ?? "default")_\(idString)"
        }

        // Try to get ID from properties
        if let properties = feature.properties,
           case .string(let idStr) = properties["id"] {
            return rawId ? idStr : "\(sourceLayer ?? "default")_\(idStr)"
        }

        if let properties = feature.properties,
           case .number(let idNum) = properties["id"] {
            let idStr = String(describing: idNum)
            return rawId ? idStr : "\(sourceLayer ?? "default")_\(idStr)"
        }

        // Only use coordinate fallback if not requiring explicit IDs
        if !requireExplicit, case .point(let point) = feature.geometry {
            return "\(sourceLayer ?? "default")_\(point.coordinates.longitude)_\(point.coordinates.latitude)"
        }

        return nil
    }

    /// Creates an annotation for a feature.
    /// - Parameters:
    ///   - config: The ViewLayer configuration
    ///   - feature: The map feature
    ///   - featureId: The namespaced feature ID for tracking (e.g., "sourceLayer_123")
    ///   - rawFeatureId: The raw feature ID for layer feature binding (e.g., "123"). Only needed when using associatedSymbolLayerId.
    private func createAnnotation(for config: ViewLayerConfig, feature: Feature, featureId: String, rawFeatureId: String? = nil) {
        guard case .point(let point) = feature.geometry else {
            return
        }

        // Map feature properties to view data using property mapping
        var viewData: [String: Any] = [:]

        for (dataKey, mapping) in config.propertyMapping {
            switch mapping.type {
            case "feature":
                if let propertyKey = mapping.propertyKey,
                   let properties = feature.properties {
                    // Get property from feature
                    if let value = properties[propertyKey] {
                        switch value {
                        case .string(let str):
                            viewData[dataKey] = str
                        case .number(let num):
                            viewData[dataKey] = num
                        case .boolean(let bool):
                            viewData[dataKey] = bool
                        default:
                            break
                        }
                    }
                }
            case "constant":
                if let value = mapping.value {
                    viewData[dataKey] = value
                }
            default:
                break
            }
        }

        let annotationId = "\(config.id)_\(featureId)"

        let result: Result<Void, Error>

        // Use layer feature binding if associatedSymbolLayerId is set
        if let symbolLayerId = config.associatedSymbolLayerId, let rawId = rawFeatureId {
            result = viewAnnotationController.addWithLayerFeature(
                id: annotationId,
                layoutName: config.layoutName,
                associatedLayerId: symbolLayerId,
                featureId: rawId,
                data: viewData,
                anchor: config.anchor,
                allowOverlap: config.allowOverlap,
                viewLayerId: config.id,
                feature: feature
            )
        } else {
            // Fallback to coordinate-based (legacy behavior)
            result = viewAnnotationController.add(
                id: annotationId,
                layoutName: config.layoutName,
                latitude: point.coordinates.latitude,
                longitude: point.coordinates.longitude,
                data: viewData,
                anchor: config.anchor,
                allowOverlap: config.allowOverlap
            )
        }

        switch result {
        case .success:
            if featureAnnotations[config.id] == nil {
                featureAnnotations[config.id] = []
            }
            featureAnnotations[config.id]?.insert(annotationId)
        case .failure:
            break
        }
    }

    private func removeAnnotation(forLayer layerId: String, featureId: String) {
        let annotationId = "\(layerId)_\(featureId)"
        _ = viewAnnotationController.remove(id: annotationId)
        featureAnnotations[layerId]?.remove(annotationId)
    }

    private func removeAllAnnotations(forLayer layerId: String) {
        guard let annotations = featureAnnotations[layerId] else { return }

        for annotationId in annotations {
            _ = viewAnnotationController.remove(id: annotationId)
        }

        featureAnnotations[layerId]?.removeAll()
        visibleFeatureIds[layerId]?.removeAll()
    }

    func dispose() {
        cameraObserver?.cancel()

        for layerId in viewLayers.keys {
            removeAllAnnotations(forLayer: layerId)
        }

        viewLayers.removeAll()
        featureAnnotations.removeAll()
        visibleFeatureIds.removeAll()
    }
}

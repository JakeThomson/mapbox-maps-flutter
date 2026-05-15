import UIKit
import Flutter
import QuartzCore
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
    let maxVisibleAnnotations: Int?
    let imageCacheKeys: [String]?
    let imageCachePadding: Double?
    let useImageMode: Bool
}

struct PropertyMappingConfig {
    let type: String  // "feature" or "constant"
    let propertyKey: String?  // For feature type
    let value: Any?  // For constant type
}

struct PromotedFeatureInfo {
    let configId: String
    let sourceId: String
    let sourceLayer: String?
    let rawFeatureId: String
}

class ViewLayerController {
    private let mapView: MapView
    private let viewAnnotationController: ViewAnnotationController
    private let messenger: FlutterBinaryMessenger
    private let channelSuffix: String

    private var viewLayers: [String: ViewLayerConfig] = [:]
    private var featureAnnotations: [String: Set<String>] = [:]  // layerId -> Set of annotation IDs
    private var visibleFeatureIds: [String: Set<String>] = [:]  // layerId -> Set of feature IDs

    // Time-based grace period (replaces cycle-based pendingRemovals)
    private var hiddenTimestamps: [String: [String: CFTimeInterval]] = [:]  // layerId -> featureId -> hide time
    private var hiddenAnnotations: [String: Set<String>] = [:]  // layerId -> Set of featureIds currently hidden
    private let maxHiddenPerLayer = 200
    private let graceDuration: TimeInterval = 5.0

    // Image mode: style image tracking
    private var registeredStyleImages: [String: Set<String>] = [:]  // layerId -> set of registered style image IDs
    private var imageModeExpressionSet: Set<String> = []  // layers where iconImage expression has been set
    private var imageModeFeatureMapping: [String: [String: String]] = [:]  // layerId → (featureId → imageName)

    // Promote/demote: tracking promoted features (image-mode → live ViewAnnotation)
    private var promotedFeatures: [String: PromotedFeatureInfo] = [:]  // annotationId -> info
    private var opacityExpressionSet: Set<String> = []  // layers where opacity expressions have been set
    private var pendingDemotions: [String: DispatchWorkItem] = [:]  // annotationId -> delayed cleanup work item

    // Image mode: initial batch tracking (hide symbol layer until first images render)
    private var imageModeInitialBatchDone: Set<String> = []
    private var needsImmediateUpdate = false

    // Staggered batch creation
    private struct PendingCreate {
        let config: ViewLayerConfig
        let feature: Feature
        let featureId: String
        let rawFeatureId: String?
    }
    private var pendingCreations: [PendingCreate] = []
    private let maxCreatesPerFrame = 15
    private var isDrainingCreationQueue = false

    // Staggered image-mode rendering
    private struct PendingImageRender {
        let config: ViewLayerConfig
        let cacheKey: String
        let viewData: [String: Any]
        let padding: CGFloat
    }
    private var pendingImageRenders: [PendingImageRender] = []
    private var pendingImageResults: [(cacheKey: String, image: UIImage)] = []
    private var isImageRenderBatchActive = false
    private let maxImageRendersPerFrame = 5
    private var activeImageBatchConfig: ViewLayerConfig? = nil
    private var activeImageBatchSymbolLayerId: String? = nil
    // Monotonic token incremented on every batch start. Background renders carry the token they started
    // with; main-thread continuations check it against this value and drop stale results, so a superseded
    // batch can't contaminate the new batch's pendingImageResults or registeredStyleImages.
    private var imageBatchToken: UInt64 = 0
    private var activeImageBatchToken: UInt64 = 0

    // Churn detection
    private var recentlyRemoved: [String: [String: CFTimeInterval]] = [:]  // layerId -> featureId -> remove time

    private var updatePending = false
    private let debounceDelay: TimeInterval = 0.15
    private var cameraObserver: Cancelable?
    private var sourceDataObserver: Cancelable?
    private var mapIdleObserver: Cancelable?
    private var styleImageMissingObserver: Cancelable?
    private var styleImageRemoveUnusedObserver: Cancelable?
    private var lastUpdateTrigger: String = "initial"
    private var currentCycleId: UInt64 = 0

    init(mapView: MapView, viewAnnotationController: ViewAnnotationController, messenger: FlutterBinaryMessenger, channelSuffix: String) {
        self.mapView = mapView
        self.viewAnnotationController = viewAnnotationController
        self.messenger = messenger
        self.channelSuffix = channelSuffix

        setupMethodChannels()
        setupCameraObserver()
        setupSourceDataObserver()
        setupMapIdleObserver()
        setupStyleImageMissingObserver()
        setupStyleImageRemoveUnusedObserver()
        ViewLayerPerfMonitor.shared.startMonitoring()
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

                // Register image-mode layer for tap fallback
                if self.isImageMode(config), let symbolLayerId = config.associatedSymbolLayerId {
                    self.viewAnnotationController.registerImageModeLayer(ImageModeLayerConfig(
                        symbolLayerId: symbolLayerId,
                        viewLayerId: config.id,
                        sourceId: config.sourceId,
                        sourceLayer: config.sourceLayer,
                        propertyMapping: config.propertyMapping
                    ))

                    // Hide symbol layer until first image batch completes
                    try? self.mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-opacity", value: 0)
                    try? self.mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "text-opacity", value: 0)

                    // Eagerly set icon-image expression so features participate in queries
                    if let keys = self.getEffectiveKeys(config) {
                        var expression: [Any] = ["concat", "\(config.layoutName)_"]
                        for (i, key) in keys.expressionKeys.enumerated() {
                            if i > 0 { expression.append("_") }
                            expression.append(["get", key])
                        }
                        try? self.mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-image", value: expression)
                        self.imageModeExpressionSet.insert(config.id)
                    }

                    self.needsImmediateUpdate = true
                }

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

        let removeChannel = FlutterBasicMessageChannel(
            name: "dev.flutter.pigeon.mapbox_maps_flutter.ViewLayerManager.removeViewLayer.\(channelSuffix)",
            binaryMessenger: messenger,
            codec: FlutterStandardMessageCodec.sharedInstance()
        )

        removeChannel.setMessageHandler { [weak self] (message, reply) in
            guard let self = self else { return }

            guard let args = message as? [Any],
                  let layerId = args.first as? String else {
                reply(["error": ["code": "invalid_argument", "message": "Missing layerId argument"]])
                return
            }

            guard let config = self.viewLayers[layerId] else {
                reply(["error": ["code": "not_found", "message": "ViewLayer '\(layerId)' not found"]])
                return
            }

            // Clean up all annotations for this layer
            self.removeAllAnnotations(forLayer: layerId)

            // Cancel any in-progress image render batch for this layer
            if self.activeImageBatchConfig?.id == layerId {
                self.imageBatchToken &+= 1  // invalidate any in-flight background dispatch
                self.activeImageBatchToken = self.imageBatchToken
                self.pendingImageRenders.removeAll()
                self.pendingImageResults.removeAll()
                self.isImageRenderBatchActive = false
                self.activeImageBatchConfig = nil
                self.activeImageBatchSymbolLayerId = nil
            }

            // Unregister image-mode layer from ViewAnnotationController
            if self.isImageMode(config), let symbolLayerId = config.associatedSymbolLayerId {
                self.viewAnnotationController.unregisterImageModeLayer(symbolLayerId: symbolLayerId)
            }

            // Remove the layer config
            self.viewLayers.removeValue(forKey: layerId)
            self.featureAnnotations.removeValue(forKey: layerId)
            self.visibleFeatureIds.removeValue(forKey: layerId)
            self.hiddenTimestamps.removeValue(forKey: layerId)
            self.hiddenAnnotations.removeValue(forKey: layerId)

            reply([:])
        }
    }

    private func setupCameraObserver() {
        cameraObserver = mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
            self?.lastUpdateTrigger = "cameraChanged"
            self?.scheduleUpdate()
        }
    }

    private func setupSourceDataObserver() {
        sourceDataObserver = mapView.mapboxMap.onSourceDataLoaded.observe { [weak self] event in
            guard let self = self else { return }
            let sourceId = event.sourceId
            let hasAffectedLayers = self.viewLayers.values.contains { $0.sourceId == sourceId }
            if hasAffectedLayers {
                NSLog("[ViewLayerPerf] ViewLayerController: sourceDataLoaded | source=%@, type=%@, scheduling debounced update", sourceId, String(describing: event.type))
                self.lastUpdateTrigger = "sourceDataLoaded"
                self.scheduleUpdate()
            }
        }
    }

    private func setupMapIdleObserver() {
        mapIdleObserver = mapView.mapboxMap.onMapIdle.observe { [weak self] _ in
            guard let self = self else { return }
            let hasClusterLayers = self.viewLayers.values.contains { $0.id.contains("cluster") }
            if hasClusterLayers {
                NSLog("[ViewLayerPerf] ViewLayerController: mapIdle | scheduling debounced update")
                self.lastUpdateTrigger = "mapIdle"
                self.scheduleUpdate()
            }
        }
    }

    private func setupStyleImageMissingObserver() {
        styleImageMissingObserver = mapView.mapboxMap.onStyleImageMissing.observe { [weak self] event in
            guard let self = self else { return }
            let imageId = event.imageId
            // Check if this is one of our registered style images
            for (layerId, imageIds) in self.registeredStyleImages {
                if imageIds.contains(imageId) {
                    NSLog("[ViewLayerDebug] STYLE_IMAGE_MISSING imageId=%@ layer=%@ — removing from tracking to force re-registration", imageId, layerId)
                    self.registeredStyleImages[layerId]?.remove(imageId)
                    self.lastUpdateTrigger = "styleImageMissing"
                    self.scheduleUpdate()
                    return
                }
            }
        }
    }

    private func setupStyleImageRemoveUnusedObserver() {
        styleImageRemoveUnusedObserver = mapView.mapboxMap.onStyleImageRemoveUnused.observe { [weak self] event in
            guard let self = self else { return }
            let imageId = event.imageId
            // Check if this is one of our registered style images
            for (layerId, imageIds) in self.registeredStyleImages {
                if imageIds.contains(imageId) {
                    NSLog("[ViewLayerDebug] STYLE_IMAGE_REMOVE_UNUSED imageId=%@ layer=%@ — removing from tracking to force re-registration", imageId, layerId)
                    self.registeredStyleImages[layerId]?.remove(imageId)
                    self.lastUpdateTrigger = "styleImageRemoveUnused"
                    self.scheduleUpdate()
                    return
                }
            }
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
            sourceLayer: (obj["source-layer"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            layoutName: obj["layoutName"] as? String ?? "",
            propertyMapping: propertyMapping,
            anchor: obj["anchor"] as? String,
            allowOverlap: obj["allowOverlap"] as? Bool ?? true,
            filter: obj["filter"] as? [Any],
            minZoom: obj["minzoom"] as? Double,
            maxZoom: obj["maxzoom"] as? Double,
            associatedSymbolLayerId: obj["associatedSymbolLayerId"] as? String,
            maxVisibleAnnotations: obj["maxVisibleAnnotations"] as? Int,
            imageCacheKeys: obj["imageCacheKeys"] as? [String],
            imageCachePadding: obj["imageCachePadding"] as? Double,
            useImageMode: obj["useImageMode"] as? Bool ?? false
        )
    }

    private func isImageMode(_ config: ViewLayerConfig) -> Bool {
        return config.useImageMode || config.imageCacheKeys != nil
    }

    /// Returns (dataKeys, expressionKeys) for property-based image cache keys.
    /// Only used when imageCacheKeys is explicitly provided.
    /// When nil, the hash-based match expression path is used instead.
    private func getEffectiveKeys(_ config: ViewLayerConfig) -> (dataKeys: [String], expressionKeys: [String])? {
        if let cacheKeys = config.imageCacheKeys {
            return (cacheKeys, cacheKeys)
        }
        return nil
    }

    /// Computes a hex hash of the view data dictionary for use as a stable image cache key.
    /// Sorts keys and normalizes numeric values (whole-number doubles drop ".0").
    private func computeViewDataHash(_ data: [String: Any]) -> String {
        var combined = ""
        for key in data.keys.sorted() {
            let normalized: String
            if let num = data[key] as? Double,
               num.truncatingRemainder(dividingBy: 1) == 0,
               !num.isInfinite, !num.isNaN {
                normalized = String(Int64(num))
            } else {
                normalized = "\(data[key] ?? "nil")"
            }
            combined += "\(key)=\(normalized);"
        }
        return String(format: "%lx", abs(combined.hashValue))
    }

    private func scheduleUpdate() {
        guard !updatePending else {
            NSLog("[ViewLayerPerf] ViewLayerController: scheduleUpdate SKIPPED | already pending")
            return
        }

        updatePending = true

        if needsImmediateUpdate {
            needsImmediateUpdate = false
            NSLog("[ViewLayerPerf] ViewLayerController: scheduleUpdate IMMEDIATE | bypassing debounce for initial image-mode load")
            DispatchQueue.main.async { [weak self] in
                self?.updatePending = false
                self?.updateVisibleFeatures()
            }
        } else {
            NSLog("[ViewLayerPerf] ViewLayerController: scheduleUpdate SCHEDULED | delay=%.0fms", debounceDelay * 1000)
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay) { [weak self] in
                self?.updatePending = false
                self?.updateVisibleFeatures()
            }
        }
    }

    private func updateVisibleFeatures() {
        let currentZoom = mapView.mapboxMap.cameraState.zoom
        let perfMonitor = ViewLayerPerfMonitor.shared

        let cycleId = perfMonitor.beginUpdateCycle(
            trigger: lastUpdateTrigger,
            zoom: currentZoom,
            layerCount: viewLayers.count
        )
        currentCycleId = cycleId

        perfMonitor.beginOperation("updateVisibleFeatures")

        for config in viewLayers.values {
            if let minZoom = config.minZoom, currentZoom < minZoom {
                removeAllAnnotations(forLayer: config.id)
                continue
            }
            if let maxZoom = config.maxZoom, currentZoom >= maxZoom {
                removeAllAnnotations(forLayer: config.id)
                continue
            }

            queryFeatures(for: config, cycleId: cycleId)
        }

        perfMonitor.endOperation("updateVisibleFeatures")
    }

    private func queryFeatures(for config: ViewLayerConfig, cycleId: UInt64) {
        let queryStartTime = CACurrentMediaTime()
        let perfMonitor = ViewLayerPerfMonitor.shared

        perfMonitor.beginOperation("queryRenderedFeatures:\(config.id)")

        let screenBounds = mapView.bounds

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
            perfMonitor.endOperation("queryRenderedFeatures:\(config.id)")
            return
        }

        mapView.mapboxMap.queryRenderedFeatures(
            with: screenBounds,
            options: options
        ) { [weak self] result in
            guard let self = self else { return }
            let queryMs = (CACurrentMediaTime() - queryStartTime) * 1000
            perfMonitor.endOperation("queryRenderedFeatures:\(config.id)")
            perfMonitor.recordQueryTime(queryMs)

            switch result {
            case .success(let queriedFeatures):
                // --- Image mode short-circuit: render to style images, skip ViewAnnotations ---
                if self.isImageMode(config) {
                    self.handleImageModeFeatures(config: config, queriedFeatures: queriedFeatures, cycleId: cycleId)
                    return
                }

                let batchStart = CACurrentMediaTime()
                perfMonitor.beginOperation("diffAndCreate:\(config.id)")

                let now = CACurrentMediaTime()
                var currentFeatureIds = Set<String>()
                let previousFeatureIds = self.visibleFeatureIds[config.id] ?? []
                let currentHidden = self.hiddenAnnotations[config.id] ?? []

                let useLayerFeatureBinding = config.associatedSymbolLayerId != nil
                var queuedCount = 0
                var unhiddenCount = 0

                // Collect all valid feature IDs + features from the query
                var queriedFeatureMap: [(featureId: String, feature: Feature)] = []

                for queriedFeature in queriedFeatures {
                    guard queriedFeature.queriedFeature.source == config.sourceId else {
                        continue
                    }
                    if let sourceLayer = config.sourceLayer {
                        guard queriedFeature.queriedFeature.sourceLayer == sourceLayer else { continue }
                    }

                    let feature = queriedFeature.queriedFeature.feature

                    guard let featureId = self.getFeatureId(
                        feature: feature,
                        sourceLayer: config.sourceLayer,
                        requireExplicit: useLayerFeatureBinding
                    ) else {
                        continue
                    }

                    queriedFeatureMap.append((featureId: featureId, feature: feature))
                }

                // Cap max visible annotations — truncate to first N from query (render/z-order)
                if let maxVisible = config.maxVisibleAnnotations, queriedFeatureMap.count > maxVisible {
                    queriedFeatureMap = Array(queriedFeatureMap.prefix(maxVisible))
                }

                for (featureId, feature) in queriedFeatureMap {
                    currentFeatureIds.insert(featureId)

                    // Feature reappeared from hidden state — unhide and clear timestamp
                    if currentHidden.contains(featureId) {
                        let annotationId = "\(config.id)_\(featureId)"
                        self.viewAnnotationController.setVisible(id: annotationId, visible: true)
                        self.hiddenAnnotations[config.id]?.remove(featureId)
                        self.hiddenTimestamps[config.id]?.removeValue(forKey: featureId)
                        unhiddenCount += 1
                        continue
                    }

                    if !previousFeatureIds.contains(featureId) {
                        queuedCount += 1
                        let rawFeatureId: String? = useLayerFeatureBinding ?
                            self.getFeatureId(feature: feature, sourceLayer: config.sourceLayer, requireExplicit: true, rawId: true) : nil

                        // Staggered creation — enqueue instead of creating inline
                        self.pendingCreations.append(PendingCreate(
                            config: config,
                            feature: feature,
                            featureId: featureId,
                            rawFeatureId: rawFeatureId
                        ))
                    }
                }

                // Process removals with time-based grace period
                let removedFeatures = previousFeatureIds.subtracting(currentFeatureIds)
                var hiddenCount = 0
                var actualRemovedCount = 0

                for featureId in removedFeatures {
                    if currentHidden.contains(featureId) {
                        // Already hidden — check if grace period expired
                        if let hideTime = self.hiddenTimestamps[config.id]?[featureId],
                           now - hideTime >= self.graceDuration {
                            // Grace period expired — actually remove
                            self.removeAnnotation(forLayer: config.id, featureId: featureId)
                            self.hiddenAnnotations[config.id]?.remove(featureId)
                            self.hiddenTimestamps[config.id]?.removeValue(forKey: featureId)
                            actualRemovedCount += 1
                        }
                        // Otherwise keep hidden, still within grace period
                        continue
                    }

                    // First time absent — immediately hide and record timestamp
                    let annotationId = "\(config.id)_\(featureId)"
                    self.viewAnnotationController.setVisible(id: annotationId, visible: false)
                    if self.hiddenAnnotations[config.id] == nil {
                        self.hiddenAnnotations[config.id] = []
                    }
                    self.hiddenAnnotations[config.id]?.insert(featureId)
                    if self.hiddenTimestamps[config.id] == nil {
                        self.hiddenTimestamps[config.id] = [:]
                    }
                    self.hiddenTimestamps[config.id]?[featureId] = now
                    hiddenCount += 1
                }

                // Enforce max hidden per layer — remove oldest hidden if over limit
                if let timestamps = self.hiddenTimestamps[config.id], timestamps.count > self.maxHiddenPerLayer {
                    let sorted = timestamps.sorted { $0.value < $1.value }
                    let excess = sorted.count - self.maxHiddenPerLayer
                    for i in 0..<excess {
                        let featureId = sorted[i].key
                        self.removeAnnotation(forLayer: config.id, featureId: featureId)
                        self.hiddenAnnotations[config.id]?.remove(featureId)
                        self.hiddenTimestamps[config.id]?.removeValue(forKey: featureId)
                        actualRemovedCount += 1
                    }
                }

                // Keep hidden features in visibleFeatureIds so they aren't re-created
                let hiddenFeatureIds = self.hiddenAnnotations[config.id] ?? []
                self.visibleFeatureIds[config.id] = currentFeatureIds.union(hiddenFeatureIds)

                // Also add pending creation featureIds to prevent duplicate creation
                for pending in self.pendingCreations where pending.config.id == config.id {
                    self.visibleFeatureIds[config.id]?.insert(pending.featureId)
                }

                if unhiddenCount > 0 {
                    NSLog("[ViewLayerPerf] VISIBILITY_RESTORE layer=%@ restored=%d", config.id, unhiddenCount)
                }
                if hiddenCount > 0 {
                    NSLog("[ViewLayerPerf] GRACE_HIDE layer=%@ hidden=%d", config.id, hiddenCount)
                }

                let batchMs = (CACurrentMediaTime() - batchStart) * 1000
                perfMonitor.endOperation("diffAndCreate:\(config.id)")

                // Update annotation count
                let totalAnnotations = self.featureAnnotations.values.reduce(0) { $0 + $1.count }
                perfMonitor.currentAnnotationCount = totalAnnotations

                NSLog("[ViewLayerPerf] BATCH layer=%@ batchMs=%.1f queued=%d hidden=%d restored=%d removed=%d",
                      config.id, batchMs, queuedCount, hiddenCount, unhiddenCount, actualRemovedCount)

                perfMonitor.endUpdateCycle(
                    cycleId: cycleId,
                    layer: config.id,
                    queryMs: queryMs,
                    created: queuedCount,
                    removed: actualRemovedCount
                )

                // Start draining the creation queue
                self.drainCreationQueue()

            case .failure(let error):
                perfMonitor.endOperation("diffAndCreate:\(config.id)")
                NSLog("[ViewLayerPerf] QUERY_ERROR layer=%@ queryMs=%.1f error=%@",
                      config.id, queryMs, error.localizedDescription)
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
            @unknown default:
                return nil
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

    // MARK: - Image mode (style image rendering)

    /// Extracts the raw GeoJSON feature ID as a string, matching the behavior of
    /// the Mapbox expression ["to-string", ["id"]]. Only uses feature.identifier,
    /// NOT properties["id"], since the expression ["id"] only accesses the GeoJSON-level ID.
    private func getFeatureIdString(_ feature: Feature) -> String? {
        guard let id = feature.identifier else { return nil }
        switch id {
        case .string(let str):
            return str
        case .number(let num):
            if num.truncatingRemainder(dividingBy: 1) == 0 {
                return String(Int64(num))
            }
            return String(num)
        @unknown default:
            return nil
        }
    }

    // MARK: - Phase 1: Data extraction (cheap, synchronous)
    private func handleImageModeFeatures(config: ViewLayerConfig, queriedFeatures: [MapboxMaps.QueriedRenderedFeature], cycleId: UInt64) {
        guard let symbolLayerId = config.associatedSymbolLayerId else { return }
        let effectiveKeys = getEffectiveKeys(config)
        let useFeatureIds = effectiveKeys == nil

        // If a batch is already active for this layer, supersede it. The token bump below (when we re-arm
        // the batch) will cause the in-flight background dispatch to drop its results on the main thread.
        // Clearing pendingImageRenders is fine because the dispatch already took a local snapshot.
        if isImageRenderBatchActive && activeImageBatchConfig?.id == config.id {
            pendingImageRenders.removeAll()
            NSLog("[ViewLayerPerf] IMAGE_BATCH_SUPERSEDED layer=%@ oldToken=%llu", config.id, activeImageBatchToken)
        }

        var existingImages = registeredStyleImages[config.id] ?? []
        var pendingItems: [PendingImageRender] = []
        var currentCycleMapping: [String: String] = [:]  // featureId → imageName (for hash-based match expression)

        for queriedFeature in queriedFeatures {
            guard queriedFeature.queriedFeature.source == config.sourceId else { continue }
            if let sourceLayer = config.sourceLayer {
                guard queriedFeature.queriedFeature.sourceLayer == sourceLayer else { continue }
            }

            let feature = queriedFeature.queriedFeature.feature

            // Build data from property mapping
            var viewData: [String: Any] = [:]
            for (dataKey, mapping) in config.propertyMapping {
                switch mapping.type {
                case "feature":
                    if let propertyKey = mapping.propertyKey,
                       let properties = feature.properties {
                        if let value = properties[propertyKey] {
                            switch value {
                            case .string(let str): viewData[dataKey] = str
                            case .number(let num): viewData[dataKey] = num
                            case .boolean(let bool): viewData[dataKey] = bool
                            default: break
                            }
                        }
                    }
                case "constant":
                    if let value = mapping.value { viewData[dataKey] = value }
                default: break
                }
            }

            let cacheKey: String
            if useFeatureIds {
                guard let featureId = getFeatureIdString(feature) else { continue }
                let hash = computeViewDataHash(viewData)
                cacheKey = "\(config.layoutName)_\(hash)"
                currentCycleMapping[featureId] = cacheKey
            } else {
                cacheKey = viewAnnotationController.computeImageCacheKey(layoutName: config.layoutName, data: viewData, keys: effectiveKeys!.dataKeys)
            }

            if existingImages.contains(cacheKey) {
                if mapView.mapboxMap.imageExists(withId: cacheKey) {
                    continue
                }
                existingImages.remove(cacheKey)
                NSLog("[ViewLayerDebug] STYLE_IMAGE_STALE cacheKey=%@ — tracked but missing from style, will re-register", cacheKey)
            }

            // Check for duplicates within this batch
            if pendingItems.contains(where: { $0.cacheKey == cacheKey }) { continue }

            let padding = CGFloat(config.imageCachePadding ?? 0)
            pendingItems.append(PendingImageRender(config: config, cacheKey: cacheKey, viewData: viewData, padding: padding))
        }

        registeredStyleImages[config.id] = existingImages

        // For hash-based path: update mapping and set match expression every cycle
        if useFeatureIds {
            setHashBasedMatchExpression(config: config, symbolLayerId: symbolLayerId, currentCycleMapping: currentCycleMapping)
        }

        if pendingItems.isEmpty {
            // No new images needed — set expression and reveal immediately
            if !useFeatureIds {
                setIconImageExpressionIfNeeded(config: config, symbolLayerId: symbolLayerId, effectiveKeys: effectiveKeys, useFeatureIds: useFeatureIds)
            }
            revealImageModeLayerIfNeeded(config: config, symbolLayerId: symbolLayerId)
            NSLog("[ViewLayerPerf] IMAGE_MODE_BATCH layer=%@ newImages=0 totalImages=%d", config.id, existingImages.count)
            return
        }

        // Queue for staggered rendering. Bump the batch token so any in-flight background dispatch from a
        // superseded batch will be rejected when it tries to commit.
        imageBatchToken &+= 1
        activeImageBatchToken = imageBatchToken
        pendingImageRenders = pendingItems
        pendingImageResults = []
        isImageRenderBatchActive = true
        activeImageBatchConfig = config
        activeImageBatchSymbolLayerId = symbolLayerId
        NSLog("[ViewLayerPerf] IMAGE_BATCH_QUEUED layer=%@ count=%d token=%llu", config.id, pendingItems.count, activeImageBatchToken)
        drainImageRenderQueue()
    }

    // MARK: - Phase 2: Staggered rendering (main thread, batched across frames)
    private func drainImageRenderQueue() {
        guard isImageRenderBatchActive else { return }

        // Fast path: if an image factory is registered, render ALL pending items on a background thread
        if let config = activeImageBatchConfig,
           ViewAnnotationRegistry.shared.hasImageFactory(for: config.layoutName) {
            let allPending = pendingImageRenders
            pendingImageRenders.removeAll()
            let scale = UIScreen.main.scale  // Capture on main thread before background dispatch
            let dispatchToken = activeImageBatchToken

            NSLog("[ViewLayerPerf] IMAGE_FACTORY_DISPATCH layer=%@ count=%d token=%llu", config.layoutName, allPending.count, dispatchToken)

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                var results: [(cacheKey: String, image: UIImage)] = []

                for pending in allPending {
                    if let image = self.viewAnnotationController.renderFromImageFactory(
                        layoutName: pending.config.layoutName,
                        data: pending.viewData,
                        cacheKey: pending.cacheKey,
                        padding: pending.padding,
                        scale: scale
                    ) {
                        results.append((cacheKey: pending.cacheKey, image: image))
                    } else {
                        NSLog("[ViewLayerPerf] IMAGE_FACTORY_RENDER_FAIL cacheKey=%@ token=%llu", pending.cacheKey, dispatchToken)
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Reject results from a superseded batch — they'd otherwise be registered under the
                    // current batch's config, and the current batch's own results would then be dropped
                    // when its mainHandler.post finds isImageRenderBatchActive == false.
                    if dispatchToken != self.activeImageBatchToken {
                        NSLog("[ViewLayerPerf] IMAGE_BATCH_STALE_RESULTS dispatched=%llu current=%llu dropped=%d", dispatchToken, self.activeImageBatchToken, results.count)
                        return
                    }
                    guard self.isImageRenderBatchActive else { return }
                    self.pendingImageResults.append(contentsOf: results)
                    self.commitImageBatch()
                }
            }
            return
        }

        // Slow path: staggered main-thread rendering (existing behavior)
        let batch = Array(pendingImageRenders.prefix(maxImageRendersPerFrame))
        pendingImageRenders.removeFirst(min(maxImageRendersPerFrame, pendingImageRenders.count))

        for pending in batch {
            if let image = viewAnnotationController.renderViewToImage(layoutName: pending.config.layoutName, data: pending.viewData, cacheKeys: [], padding: pending.padding, overrideCacheKey: pending.cacheKey) {
                pendingImageResults.append((cacheKey: pending.cacheKey, image: image))
            } else {
                NSLog("[ViewLayerPerf] IMAGE_MODE_RENDER_FAIL cacheKey=%@", pending.cacheKey)
            }
        }

        if !pendingImageRenders.isEmpty {
            // More to render — yield to run loop and continue next frame
            DispatchQueue.main.async { [weak self] in
                self?.drainImageRenderQueue()
            }
        } else {
            // All renders complete — commit the batch
            commitImageBatch()
        }
    }

    // MARK: - Phase 3: Batch style registration
    private func commitImageBatch() {
        guard isImageRenderBatchActive,
              let config = activeImageBatchConfig,
              let symbolLayerId = activeImageBatchSymbolLayerId else {
            return
        }

        let effectiveKeys = getEffectiveKeys(config)
        let useFeatureIds = effectiveKeys == nil
        var existingImages = registeredStyleImages[config.id] ?? []
        var newImagesCount = 0

        for result in pendingImageResults {
            do {
                try mapView.mapboxMap.addImage(result.image, id: result.cacheKey, sdf: false, stretchX: [], stretchY: [], content: nil)
                existingImages.insert(result.cacheKey)
                newImagesCount += 1
                NSLog("[ViewLayerPerf] STYLE_IMAGE_REGISTERED cacheKey=%@ size=%.0fx%.0f", result.cacheKey, result.image.size.width, result.image.size.height)
            } catch {
                NSLog("[ViewLayerPerf] STYLE_IMAGE_REGISTER_FAIL cacheKey=%@ error=%@", result.cacheKey, error.localizedDescription)
            }
        }

        registeredStyleImages[config.id] = existingImages

        if useFeatureIds {
            // Re-set match expression to force renderer to pick up newly registered images
            if let layerMapping = imageModeFeatureMapping[config.id] {
                var matchExpr: [Any] = ["match", ["to-string", ["id"]]]
                for (fid, imgName) in layerMapping {
                    matchExpr.append(fid)
                    matchExpr.append(imgName)
                }
                matchExpr.append("")  // fallback
                try? mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-image", value: matchExpr)
                NSLog("[ViewLayerPerf] HASH_EXPRESSION_REFRESH layer=%@ mappingCount=%d", config.id, layerMapping.count)
            }
        } else {
            setIconImageExpressionIfNeeded(config: config, symbolLayerId: symbolLayerId, effectiveKeys: effectiveKeys, useFeatureIds: useFeatureIds)
        }
        revealImageModeLayerIfNeeded(config: config, symbolLayerId: symbolLayerId)

        NSLog("[ViewLayerPerf] IMAGE_MODE_BATCH layer=%@ newImages=%d totalImages=%d", config.id, newImagesCount, existingImages.count)

        // Clear batch state
        pendingImageResults.removeAll()
        isImageRenderBatchActive = false
        activeImageBatchConfig = nil
        activeImageBatchSymbolLayerId = nil
    }

    // MARK: - Image mode helpers

    private func setIconImageExpressionIfNeeded(config: ViewLayerConfig, symbolLayerId: String, effectiveKeys: (dataKeys: [String], expressionKeys: [String])?, useFeatureIds: Bool) {
        guard !imageModeExpressionSet.contains(config.id) else { return }

        let expression: [Any]
        if let exprKeys = effectiveKeys?.expressionKeys {
            var parts: [Any] = ["concat", "\(config.layoutName)_"]
            for (i, key) in exprKeys.enumerated() {
                if i > 0 {
                    parts.append("_")
                }
                parts.append(["get", key])
            }
            expression = parts
        } else {
            expression = ["concat", "\(config.layoutName)_", ["to-string", ["id"]]]
        }

        do {
            try mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-image", value: expression)
            imageModeExpressionSet.insert(config.id)
            NSLog("[ViewLayerPerf] ICON_IMAGE_EXPRESSION_SET layer=%@ symbolLayer=%@ useFeatureIds=%d", config.id, symbolLayerId, useFeatureIds ? 1 : 0)
        } catch {
            NSLog("[ViewLayerPerf] ICON_IMAGE_EXPRESSION_FAIL layer=%@ error=%@", config.id, error.localizedDescription)
        }

        let opacityExpr: [Any] = ["case", ["boolean", ["feature-state", "promoted"], false], 0, 1]
        do {
            try mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-opacity", value: opacityExpr)
            opacityExpressionSet.insert(config.id)
            NSLog("[ViewLayerPerf] OPACITY_EXPRESSION_SET layer=%@ symbolLayer=%@", config.id, symbolLayerId)
        } catch {
            NSLog("[ViewLayerPerf] OPACITY_EXPRESSION_FAIL layer=%@ error=%@", config.id, error.localizedDescription)
        }
    }

    /// Builds and sets a match expression that maps feature IDs to hash-based image names.
    /// Called every cycle for the hash-based path (when imageCacheKeys is nil).
    private func setHashBasedMatchExpression(config: ViewLayerConfig, symbolLayerId: String, currentCycleMapping: [String: String]) {
        // Merge current cycle mapping into persistent mapping
        var layerMapping = imageModeFeatureMapping[config.id] ?? [:]
        for (fid, imgName) in currentCycleMapping {
            layerMapping[fid] = imgName
        }
        // Trim if too large — keep only currently visible features
        if layerMapping.count > 500 {
            layerMapping = currentCycleMapping
        }
        imageModeFeatureMapping[config.id] = layerMapping

        // Build match expression: ["match", ["to-string", ["id"]], "fid1", "img1", ..., ""]
        var matchExpr: [Any] = ["match", ["to-string", ["id"]]]
        for (fid, imgName) in layerMapping {
            matchExpr.append(fid)
            matchExpr.append(imgName)
        }
        matchExpr.append("")  // fallback

        do {
            try mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-image", value: matchExpr)
            imageModeExpressionSet.insert(config.id)
            NSLog("[ViewLayerPerf] HASH_EXPRESSION layer=%@ symbolLayer=%@ mappingCount=%d", config.id, symbolLayerId, layerMapping.count)
        } catch {
            NSLog("[ViewLayerPerf] HASH_EXPRESSION_FAIL layer=%@ error=%@", config.id, error.localizedDescription)
        }

        // Set opacity expression for promote/demote (only once)
        if !opacityExpressionSet.contains(config.id) {
            let opacityExpr: [Any] = ["case", ["boolean", ["feature-state", "promoted"], false], 0, 1]
            do {
                try mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-opacity", value: opacityExpr)
                opacityExpressionSet.insert(config.id)
                NSLog("[ViewLayerPerf] OPACITY_EXPRESSION_SET layer=%@ symbolLayer=%@", config.id, symbolLayerId)
            } catch {
                NSLog("[ViewLayerPerf] OPACITY_EXPRESSION_FAIL layer=%@ error=%@", config.id, error.localizedDescription)
            }
        }
    }

    private func revealImageModeLayerIfNeeded(config: ViewLayerConfig, symbolLayerId: String) {
        guard !imageModeInitialBatchDone.contains(config.id) else { return }
        imageModeInitialBatchDone.insert(config.id)

        let transition: [String: Any] = ["duration": 200, "delay": 0]
        try? mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-opacity-transition", value: transition)
        try? mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "text-opacity-transition", value: transition)

        let opacityExpr: [Any] = ["case", ["boolean", ["feature-state", "promoted"], false], 0, 1]
        try? mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-opacity", value: opacityExpr)
        opacityExpressionSet.insert(config.id)

        try? mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "text-opacity", value: 1)

        NSLog("[ViewLayerPerf] IMAGE_MODE_REVEALED layer=%@ symbolLayer=%@", config.id, symbolLayerId)
    }

    // MARK: - Staggered batch creation

    private func drainCreationQueue() {
        guard !isDrainingCreationQueue, !pendingCreations.isEmpty else { return }
        isDrainingCreationQueue = true

        let batch = Array(pendingCreations.prefix(maxCreatesPerFrame))
        pendingCreations.removeFirst(min(maxCreatesPerFrame, pendingCreations.count))

        for pending in batch {
            createAnnotation(for: pending.config, feature: pending.feature, featureId: pending.featureId, rawFeatureId: pending.rawFeatureId)
        }

        isDrainingCreationQueue = false

        // If more remain, schedule next batch on the next frame
        if !pendingCreations.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.drainCreationQueue()
            }
        }
    }

    // MARK: - Annotation creation with churn detection

    /// Creates an annotation for a feature.
    /// - Parameters:
    ///   - config: The ViewLayer configuration
    ///   - feature: The map feature
    ///   - featureId: The namespaced feature ID for tracking (e.g., "sourceLayer_123")
    ///   - rawFeatureId: The raw feature ID for layer feature binding (e.g., "123"). Only needed when using associatedSymbolLayerId.
    private func createAnnotation(for config: ViewLayerConfig, feature: Feature, featureId: String, rawFeatureId: String? = nil) {
        let createStartTime = CACurrentMediaTime()
        guard case .point(let point) = feature.geometry else {
            return
        }

        // Churn detection — check if this feature was recently removed
        if let removeTime = recentlyRemoved[config.id]?[featureId] {
            let removedAgo = createStartTime - removeTime
            if removedAgo < 5.0 {
                NSLog("[ViewLayerPerf] CHURN_DETECTED id=%@ removedAgo=%.1fs", featureId, removedAgo)
                ViewLayerPerfMonitor.shared.periodChurnCount += 1
            }
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

        let createDuration = (CACurrentMediaTime() - createStartTime) * 1000

        switch result {
        case .success:
            if featureAnnotations[config.id] == nil {
                featureAnnotations[config.id] = []
            }
            featureAnnotations[config.id]?.insert(annotationId)
            NSLog("[ViewLayerPerf] ViewLayerController: createAnnotation | id=%@, duration=%.0fms", annotationId, createDuration)
        case .failure(let error):
            NSLog("[ViewLayerPerf] ViewLayerController: createAnnotation FAILED | id=%@, duration=%.0fms, error=%@", annotationId, createDuration, error.localizedDescription)
        }
    }

    // MARK: - Removal with churn tracking

    private func removeAnnotation(forLayer layerId: String, featureId: String) {
        let annotationId = "\(layerId)_\(featureId)"
        _ = viewAnnotationController.remove(id: annotationId)
        featureAnnotations[layerId]?.remove(annotationId)

        // Record removal time for churn detection
        let now = CACurrentMediaTime()
        if recentlyRemoved[layerId] == nil {
            recentlyRemoved[layerId] = [:]
        }
        recentlyRemoved[layerId]?[featureId] = now

        // Clean stale entries older than 10s
        recentlyRemoved[layerId] = recentlyRemoved[layerId]?.filter { now - $0.value < 10.0 }
    }

    // MARK: - Promote / Demote (image-mode → live ViewAnnotation)

    func promoteFeature(annotationId: String, data: [String: Any]?) -> Result<Void, Error> {
        // 1. Find matching image-mode config by prefix
        guard let config = findImageModeConfig(for: annotationId) else {
            return .failure(NSError(domain: "ViewLayerController", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No image-mode config matches annotation '\(annotationId)'"]))
        }

        // 2. Parse rawFeatureId from annotationId
        let prefix = "\(config.id)_\(config.sourceLayer ?? "")_"
        guard annotationId.hasPrefix(prefix) else {
            return .failure(NSError(domain: "ViewLayerController", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Cannot parse feature ID from '\(annotationId)'"]))
        }
        let rawFeatureId = String(annotationId.dropFirst(prefix.count))

        // 3. Check if annotation is being animated out — cancel and re-promote
        if pendingDemotions[annotationId] != nil {
            cancelPendingDemotion(annotationId: annotationId)
            // View still exists, just update it back to selected
            var mergedData = viewAnnotationController.imageModeFeatureData[annotationId] ?? [:]
            if let data = data {
                for (key, value) in data { mergedData[key] = value }
            }
            mergedData["selected"] = true
            _ = viewAnnotationController.update(id: annotationId, latitude: nil, longitude: nil, data: mergedData)
            return .success(())
        }

        // 4. Look up cached feature data from original tap
        var mergedData = viewAnnotationController.imageModeFeatureData[annotationId] ?? [:]

        // 5. Merge with provided data
        if let data = data {
            for (key, value) in data {
                mergedData[key] = value
            }
        }

        // 6. Set feature state to hide icon
        mapView.mapboxMap.setFeatureState(
            sourceId: config.sourceId,
            sourceLayerId: config.sourceLayer,
            featureId: rawFeatureId,
            state: ["promoted": true]
        ) { _ in }

        // 7. Set opacity expression if not already set (safety fallback)
        if let symbolLayerId = config.associatedSymbolLayerId, !opacityExpressionSet.contains(config.id) {
            let opacityExpr: [Any] = ["case", ["boolean", ["feature-state", "promoted"], false], 0, 1]
            try? mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-opacity", value: opacityExpr)
            opacityExpressionSet.insert(config.id)
        }

        // 8. Create live ViewAnnotation with selected=false (for opening animation)
        guard let symbolLayerId = config.associatedSymbolLayerId else {
            return .failure(NSError(domain: "ViewLayerController", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "No associated symbol layer for config '\(config.id)'"]))
        }

        let savedSelected = mergedData["selected"]
        mergedData["selected"] = false

        let result = viewAnnotationController.addWithLayerFeature(
            id: annotationId,
            layoutName: config.layoutName,
            associatedLayerId: symbolLayerId,
            featureId: rawFeatureId,
            data: mergedData,
            anchor: config.anchor,
            allowOverlap: config.allowOverlap,
            viewLayerId: config.id
        )

        switch result {
        case .success:
            // 9. Track in promotedFeatures
            promotedFeatures[annotationId] = PromotedFeatureInfo(
                configId: config.id,
                sourceId: config.sourceId,
                sourceLayer: config.sourceLayer,
                rawFeatureId: rawFeatureId
            )

            // 10. After short delay, update to selected=true to trigger opening animation
            let selectedValue = savedSelected ?? true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self, self.promotedFeatures[annotationId] != nil else { return }
                var openData = mergedData
                openData["selected"] = selectedValue
                _ = self.viewAnnotationController.update(id: annotationId, latitude: nil, longitude: nil, data: openData)
            }

            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    @discardableResult
    func demoteFeatureIfNeeded(annotationId: String) -> Bool {
        guard let info = promotedFeatures[annotationId] else {
            return false
        }

        // Already pending demotion — skip
        if pendingDemotions[annotationId] != nil { return true }

        // 1. Update view to selected=false (triggers closing animation)
        _ = viewAnnotationController.update(id: annotationId, latitude: nil, longitude: nil, data: ["selected": false])

        // 2. Schedule delayed cleanup after animation completes
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingDemotions.removeValue(forKey: annotationId)
            self.promotedFeatures.removeValue(forKey: annotationId)

            // Remove feature state (restore icon)
            self.mapView.mapboxMap.removeFeatureState(
                sourceId: info.sourceId,
                sourceLayerId: info.sourceLayer,
                featureId: info.rawFeatureId,
                stateKey: "promoted"
            ) { _ in }

            // Remove the ViewAnnotation
            _ = self.viewAnnotationController.remove(id: annotationId)
        }

        pendingDemotions[annotationId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)

        return true
    }

    func cancelPendingDemotion(annotationId: String) {
        if let workItem = pendingDemotions.removeValue(forKey: annotationId) {
            workItem.cancel()
        }
    }

    func demoteAllFeatures() {
        // Cancel and immediately execute all pending demotions
        for (annotationId, workItem) in pendingDemotions {
            workItem.cancel()
            pendingDemotions.removeValue(forKey: annotationId)
        }

        for (annotationId, info) in promotedFeatures {
            mapView.mapboxMap.removeFeatureState(
                sourceId: info.sourceId,
                sourceLayerId: info.sourceLayer,
                featureId: info.rawFeatureId,
                stateKey: "promoted"
            ) { _ in }
            _ = viewAnnotationController.remove(id: annotationId)
        }
        promotedFeatures.removeAll()
    }

    private func findImageModeConfig(for annotationId: String) -> ViewLayerConfig? {
        for config in viewLayers.values {
            guard isImageMode(config) else { continue }
            let prefix = "\(config.id)_\(config.sourceLayer ?? "")_"
            if annotationId.hasPrefix(prefix) {
                return config
            }
        }
        return nil
    }

    private func removeAllAnnotations(forLayer layerId: String) {
        // Cancel any pending demotions for this layer
        let pendingForLayer = pendingDemotions.filter { (key, _) in key.hasPrefix(layerId) }
        for (annotationId, workItem) in pendingForLayer {
            workItem.cancel()
            pendingDemotions.removeValue(forKey: annotationId)
        }

        // Demote all promoted features for this layer
        let promotedForLayer = promotedFeatures.filter { $0.value.configId == layerId }
        for (annotationId, info) in promotedForLayer {
            mapView.mapboxMap.removeFeatureState(
                sourceId: info.sourceId,
                sourceLayerId: info.sourceLayer,
                featureId: info.rawFeatureId,
                stateKey: "promoted"
            ) { _ in }
            _ = viewAnnotationController.remove(id: annotationId)
            promotedFeatures.removeValue(forKey: annotationId)
        }

        // Clean up image-mode style images
        if let imageIds = registeredStyleImages[layerId] {
            for imageId in imageIds {
                try? mapView.mapboxMap.removeImage(withId: imageId)
            }
            registeredStyleImages.removeValue(forKey: layerId)
        }

        // Clean up feature-to-image mapping
        imageModeFeatureMapping.removeValue(forKey: layerId)

        // Reset iconImage expression if it was set
        if imageModeExpressionSet.contains(layerId) {
            if let config = viewLayers[layerId], let symbolLayerId = config.associatedSymbolLayerId {
                try? mapView.mapboxMap.setLayerProperty(for: symbolLayerId, property: "icon-image", value: "")
            }
            imageModeExpressionSet.remove(layerId)
        }

        // Reset opacity expressions if they were set
        if opacityExpressionSet.contains(layerId) {
            opacityExpressionSet.remove(layerId)
        }

        // Reset initial batch tracking so reveal can re-trigger if layer is re-added
        imageModeInitialBatchDone.remove(layerId)

        guard let annotations = featureAnnotations[layerId] else { return }

        for annotationId in annotations {
            _ = viewAnnotationController.remove(id: annotationId)
        }

        featureAnnotations[layerId]?.removeAll()
        visibleFeatureIds[layerId]?.removeAll()
        hiddenTimestamps[layerId]?.removeAll()
        hiddenAnnotations[layerId]?.removeAll()

        // Remove pending creations for this layer
        pendingCreations.removeAll { $0.config.id == layerId }
    }

    func dispose() {
        ViewLayerPerfMonitor.shared.stopMonitoring()
        cameraObserver?.cancel()
        sourceDataObserver?.cancel()
        mapIdleObserver?.cancel()
        styleImageMissingObserver?.cancel()
        styleImageRemoveUnusedObserver?.cancel()

        // Cancel all pending demotions
        for (_, workItem) in pendingDemotions {
            workItem.cancel()
        }
        pendingDemotions.removeAll()

        for layerId in viewLayers.keys {
            removeAllAnnotations(forLayer: layerId)
        }

        // Unregister image-mode layers from ViewAnnotationController
        for config in viewLayers.values {
            if let symbolLayerId = config.associatedSymbolLayerId, isImageMode(config) {
                viewAnnotationController.unregisterImageModeLayer(symbolLayerId: symbolLayerId)
            }
        }

        viewLayers.removeAll()
        featureAnnotations.removeAll()
        visibleFeatureIds.removeAll()
        hiddenTimestamps.removeAll()
        hiddenAnnotations.removeAll()
        pendingCreations.removeAll()
        recentlyRemoved.removeAll()
        registeredStyleImages.removeAll()
        imageModeExpressionSet.removeAll()
        imageModeInitialBatchDone.removeAll()
        promotedFeatures.removeAll()
        opacityExpressionSet.removeAll()
    }
}

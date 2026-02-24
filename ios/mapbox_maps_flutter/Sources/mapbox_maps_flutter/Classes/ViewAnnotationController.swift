import UIKit
import Flutter
import QuartzCore
import SwiftUI
@_spi(Experimental) import MapboxMaps

struct ImageModeLayerConfig {
    let symbolLayerId: String
    let viewLayerId: String
    let sourceId: String
    let sourceLayer: String?
    let propertyMapping: [String: PropertyMappingConfig]
}

class ViewAnnotationController: NSObject, UIGestureRecognizerDelegate {
    private let mapView: MapView
    private var annotations: [String: UIView] = [:]
    private var layoutNames: [String: String] = [:]
    private var annotationOptions: [String: ViewAnnotationOptions] = [:]
    private var annotationData: [String: [String: Any]] = [:]
    private var viewAnnotationObjects: [String: ViewAnnotation] = [:]  // For layer feature binding
    private var visibilityObjects: [String: ViewAnnotationVisibility] = [:]  // Track visibility state per annotation
    private var annotationFeatures: [String: FeaturesetFeature?] = [:]  // Store FeaturesetFeature for tap callback
    private var sizeCache: [String: CGSize] = [:]  // layoutName -> cached size to skip expensive sizeView()
    private var imageCache: [String: UIImage] = [:]  // cacheKey -> rendered snapshot image
    private var imageModeLayerConfigs: [String: ImageModeLayerConfig] = [:]  // symbolLayerId -> config for tap fallback
    var imageModeFeatureData: [String: [String: Any]] = [:]  // annotationId -> cached feature data from image-mode tap
    private let tapEventChannel: FlutterMethodChannel
    private let mapTapGesture: UITapGestureRecognizer

    init(mapView: MapView, messenger: FlutterBinaryMessenger, channelSuffix: String) {
        self.mapView = mapView
        self.tapEventChannel = FlutterMethodChannel(
            name: "plugins.flutter.io.\(channelSuffix)/viewAnnotationTap",
            binaryMessenger: messenger
        )
        self.mapTapGesture = UITapGestureRecognizer()
        super.init()

        mapTapGesture.addTarget(self, action: #selector(handleMapTap(_:)))
        mapTapGesture.cancelsTouchesInView = false
        mapTapGesture.delegate = self
        mapView.addGestureRecognizer(mapTapGesture)

        // Make the map's own tap gesture recognizers require our tap to fail first.
        // When our gesture succeeds (annotation hit), the SDK's tap gestures never fire,
        // preventing the SDK from cancelling programmatic camera animations (e.g. flyTo).
        for recognizer in mapView.gestureRecognizers ?? [] {
            if let tap = recognizer as? UITapGestureRecognizer, tap != mapTapGesture {
                tap.require(toFail: mapTapGesture)
            }
        }

        // Pre-warm UIHostingController to move ~248ms cold start off the annotation creation path
        DispatchQueue.main.async {
            let warmup = UIHostingController(rootView: EmptyView())
            warmup.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            warmup.view.layoutIfNeeded()
            _ = warmup  // ensure not optimized away
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer == mapTapGesture else { return true }
        let tapPoint = gestureRecognizer.location(in: mapView)
        for (annotationId, view) in annotations {
            if view.isHidden || view.alpha == 0 { continue }
            if let visibility = visibilityObjects[annotationId], !visibility.isVisible { continue }
            let pointInView = view.convert(tapPoint, from: mapView)
            if view.bounds.contains(pointInView) { return true }
        }
        return false  // No annotation hit → fail immediately, SDK gestures proceed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Prevent the SDK's tap gesture from firing simultaneously with ours.
        // Pan/pinch/rotation should still work simultaneously.
        if otherGestureRecognizer is UITapGestureRecognizer { return false }
        return true
    }
    
    func add(
        id: String,
        layoutName: String,
        latitude: Double,
        longitude: Double,
        data: [String: Any]?,
        anchor: String?,
        allowOverlap: Bool
    ) -> Result<Void, Error> {
        if annotations[id] != nil {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Annotation with id '\(id)' already exists"]
            ))
        }

        guard let view = ViewAnnotationRegistry.shared.createView(viewIdentifier: layoutName, args: data) else {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No view registered for '\(layoutName)'"]
            ))
        }
        
        // Size the view (use cache if available)
        if let cachedSize = sizeCache[layoutName] {
            view.frame = CGRect(origin: .zero, size: cachedSize)
            NSLog("[ViewLayerPerf] SIZE_CACHE_HIT layoutName=%@ size=%.0fx%.0f", layoutName, cachedSize.width, cachedSize.height)
        } else {
            let sizingResult = sizeView(view, id: id, layoutName: layoutName)
            switch sizingResult {
            case .failure:
                return sizingResult
            case .success:
                break
            }
        }

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        
        let options = ViewAnnotationOptions(
            geometry: Point(coordinate),
            allowOverlap: allowOverlap,
            allowOverlapWithPuck: true,
            anchor: parseAnchor(anchor)
        )

        view.isUserInteractionEnabled = false

        do {
            try mapView.viewAnnotations.add(view, options: options)
            annotations[id] = view
            layoutNames[id] = layoutName
            annotationOptions[id] = options
            annotationData[id] = data ?? [:]
            annotationFeatures[id] = nil  // Manual annotations have no feature
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Add a view annotation bound to a symbol layer feature.
    /// This enables shared collision detection between the view annotation and symbol layer.
    func addWithLayerFeature(
        id: String,
        layoutName: String,
        associatedLayerId: String,
        featureId: String,
        data: [String: Any]?,
        anchor: String?,
        allowOverlap: Bool,
        viewLayerId: String? = nil,
        feature: Feature? = nil
    ) -> Result<Void, Error> {
        let perfMonitor = ViewLayerPerfMonitor.shared

        if annotations[id] != nil {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Annotation with id '\(id)' already exists"]
            ))
        }

        // --- Live view mode ---

        // --- Phase 1: Factory ---
        let factoryStart = CACurrentMediaTime()
        perfMonitor.beginOperation("factory:\(id)")

        let visibility = ViewAnnotationVisibility()
        visibilityObjects[id] = visibility

        guard let view = ViewAnnotationRegistry.shared.createView(viewIdentifier: layoutName, args: data, visibility: visibility) else {
            perfMonitor.endOperation("factory:\(id)")
            visibilityObjects.removeValue(forKey: id)
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No view registered for '\(layoutName)'"]
            ))
        }
        let factoryMs = (CACurrentMediaTime() - factoryStart) * 1000
        perfMonitor.endOperation("factory:\(id)")

        // --- Phase 2: Size (use cache if available) ---
        let sizeStart = CACurrentMediaTime()
        perfMonitor.beginOperation("size:\(id)")

        if let cachedSize = sizeCache[layoutName] {
            view.frame = CGRect(origin: .zero, size: cachedSize)
            NSLog("[ViewLayerPerf] SIZE_CACHE_HIT layoutName=%@ size=%.0fx%.0f", layoutName, cachedSize.width, cachedSize.height)
        } else {
            let sizingResult = sizeView(view, id: id, layoutName: layoutName)
            switch sizingResult {
            case .failure:
                _ = (CACurrentMediaTime() - sizeStart) * 1000
                perfMonitor.endOperation("size:\(id)")
                visibilityObjects.removeValue(forKey: id)
                return sizingResult
            case .success:
                break
            }
        }

        let sizeMs = (CACurrentMediaTime() - sizeStart) * 1000
        perfMonitor.endOperation("size:\(id)")

        // --- Phase 3: AddToMap ---
        let addToMapStart = CACurrentMediaTime()
        perfMonitor.beginOperation("addToMap:\(id)")

        let annotation = ViewAnnotation(
            annotatedFeature: .layerFeature(layerId: associatedLayerId, featureId: featureId),
            view: view
        )

        annotation.variableAnchors = [ViewAnnotationAnchorConfig(anchor: parseAnchor(anchor))]
        annotation.allowOverlap = allowOverlap
        annotation.allowOverlapWithPuck = true

        annotation.onVisibilityChanged = { [weak self] isVisible in
            self?.visibilityObjects[id]?.isVisible = isVisible
        }

        view.isUserInteractionEnabled = false

        mapView.viewAnnotations.add(annotation)

        annotations[id] = view
        layoutNames[id] = layoutName
        annotationData[id] = data ?? [:]
        viewAnnotationObjects[id] = annotation

        if let feature = feature {
            let featuresetFeature = FeaturesetFeature(
                id: FeaturesetFeatureId(id: featureId, namespace: nil),
                featureset: FeaturesetDescriptor(featuresetId: nil, importId: nil, layerId: viewLayerId),
                geometry: feature.geometry?.toMap() ?? [:],
                properties: feature.properties?.turfRawValue ?? [:],
                state: [:]
            )
            annotationFeatures[id] = featuresetFeature
        } else {
            annotationFeatures[id] = nil
        }

        let addToMapMs = (CACurrentMediaTime() - addToMapStart) * 1000
        perfMonitor.endOperation("addToMap:\(id)")

        // Report breakdown to perf monitor
        let breakdown = AnnotationTimingBreakdown(
            id: id,
            factoryMs: factoryMs,
            sizeMs: sizeMs,
            addToMapMs: addToMapMs
        )
        perfMonitor.recordAnnotationCreation(breakdown)

        return .success(())
    }

    func update(
        id: String,
        latitude: Double?,
        longitude: Double?,
        data: [String: Any]?
    ) -> Result<Void, Error> {
        guard let oldView = annotations[id],
              let layoutName = layoutNames[id] else {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Annotation with id '\(id)' not found"]
            ))
        }

        // Check if this is a ViewLayer annotation (uses ViewAnnotation object)
        let isViewLayerAnnotation = viewAnnotationObjects[id] != nil

        // Get options if available (may be nil for ViewLayer-created annotations)
        var options = annotationOptions[id]

        // Update options if new coordinate provided (only for non-ViewLayer annotations)
        if let lat = latitude, let lng = longitude, !isViewLayerAnnotation {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            options = ViewAnnotationOptions(geometry: Point(coordinate))
        }

        // If data is provided, try to update the existing view in place
        // This preserves SwiftUI animation state (like Compose does on Android)
        if let data = data {
            // Try to update existing view properties using Key-Value Coding
            // This works for views that expose properties like 'emoji', 'selected', etc.
            var viewUpdated = false

            // Update common properties if they exist
            if let emoji = data["callout_emoji"] as? String {
                if oldView.responds(to: NSSelectorFromString("setEmoji:")) {
                    oldView.setValue(emoji, forKey: "emoji")
                    viewUpdated = true
                }
            }

            if let selected = data["selected"] as? Bool {
                if oldView.responds(to: NSSelectorFromString("setSelected:")) {
                    oldView.setValue(selected, forKey: "selected")
                    viewUpdated = true
                }
            }

            if let label = data["callout_label"] as? String {
                if oldView.responds(to: NSSelectorFromString("setLabel:")) {
                    oldView.setValue(label, forKey: "label")
                    viewUpdated = true
                }
            }

            // If we successfully updated the view, just update the stored data and options
            if viewUpdated {
                annotationData[id] = data
                // Update position if needed (only for non-ViewLayer annotations with valid options)
                if let options = options, latitude != nil || longitude != nil, !isViewLayerAnnotation {
                    do {
                        try mapView.viewAnnotations.update(oldView, options: options)
                        annotationOptions[id] = options
                    } catch {
                        return .failure(error)
                    }
                }
                return .success(())
            }

            // For ViewLayer annotations, if in-place update failed, we can't easily recreate
            // because they're bound to features. Just return success.
            if isViewLayerAnnotation {
                annotationData[id] = data
                return .success(())
            }

            // Fallback: If view doesn't support property updates, recreate it
            // Remove old view
            mapView.viewAnnotations.remove(oldView)

            // Create new view with updated data
            guard let newView = ViewAnnotationRegistry.shared.createView(viewIdentifier: layoutName, args: data) else {
                return .failure(NSError(
                    domain: "ViewAnnotationController",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create view for '\(layoutName)'"]
                ))
            }

            // Size the new view (use cache if available)
            if let cachedSize = sizeCache[layoutName] {
                newView.frame = CGRect(origin: .zero, size: cachedSize)
            } else {
                let sizingResult = sizeView(newView, id: id, layoutName: layoutName)
                switch sizingResult {
                case .failure:
                    return sizingResult
                case .success:
                    break
                }
            }

            newView.isUserInteractionEnabled = false

            // Add new view with updated options (should always have options for non-ViewLayer annotations)
            guard let opts = options else {
                return .failure(NSError(
                    domain: "ViewAnnotationController",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "No options available for annotation '\(id)'"]
                ))
            }

            do {
                try mapView.viewAnnotations.add(newView, options: opts)
                annotations[id] = newView
                annotationOptions[id] = opts
                annotationData[id] = data
            } catch {
                return .failure(error)
            }
        } else if latitude != nil || longitude != nil, !isViewLayerAnnotation {
            // Only update position without recreating view (only for non-ViewLayer annotations)
            guard let opts = options else {
                return .failure(NSError(
                    domain: "ViewAnnotationController",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "No options available for annotation '\(id)'"]
                ))
            }
            do {
                try mapView.viewAnnotations.update(oldView, options: opts)
                annotationOptions[id] = opts
            } catch {
                return .failure(error)
            }
        }
        
        return .success(())
    }
    
    private func sizeView(_ view: UIView, id: String, layoutName: String? = nil) -> Result<Void, Error> {
        let sizeStartTime = CACurrentMediaTime()

        // --- Sub-step: windowAttach ---
        let windowAttachStart = CACurrentMediaTime()

        let containerView = UIView(frame: CGRect(x: -10000, y: -10000, width: 1000, height: 1000))
        containerView.isHidden = true
        containerView.addSubview(view)

        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(greaterThanOrEqualTo: containerView.topAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor),
        ])

        var window: UIWindow?
        if #available(iOS 15.0, *) {
            window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
        } else {
            window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first
        }

        guard let window = window ?? mapView.window else {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not find window to temporarily attach view"]
            ))
        }

        window.addSubview(containerView)
        let windowAttachMs = (CACurrentMediaTime() - windowAttachStart) * 1000

        // --- Sub-step: layout ---
        let layoutStart = CACurrentMediaTime()

        view.setNeedsLayout()
        view.layoutIfNeeded()
        containerView.layoutIfNeeded()

        let layoutMs = (CACurrentMediaTime() - layoutStart) * 1000

        // --- Sub-step: measure ---
        let measureStart = CACurrentMediaTime()

        var finalSize = view.intrinsicContentSize

        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }

        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = view.frame.size
        }

        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = CGSize(width: 100, height: 50)
        }

        view.frame = CGRect(origin: .zero, size: finalSize)
        view.removeFromSuperview()
        containerView.removeFromSuperview()

        let measureMs = (CACurrentMediaTime() - measureStart) * 1000

        if view.frame.width <= 0 || view.frame.height <= 0 {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "View has invalid dimensions: width=\(view.frame.width), height=\(view.frame.height)"]
            ))
        }

        let totalMs = (CACurrentMediaTime() - sizeStartTime) * 1000
        NSLog("[ViewLayerPerf] SIZE_BREAKDOWN id=%@ total=%.1f windowAttach=%.1f layout=%.1f measure=%.1f size=%.0fx%.0f",
              id, totalMs, windowAttachMs, layoutMs, measureMs, view.frame.width, view.frame.height)

        // Cache the size for this layoutName
        if let layoutName = layoutName {
            sizeCache[layoutName] = view.frame.size
            NSLog("[ViewLayerPerf] SIZE_CACHE_STORE layoutName=%@ size=%.0fx%.0f", layoutName, view.frame.width, view.frame.height)
        }

        return .success(())
    }

    /// Renders a UIView to a UIImage snapshot.
    /// Attaches the view to an offscreen window container, forces layout, then captures via drawHierarchy.
    /// - Parameter padding: Extra padding (in points) added around the view to prevent clipping of shadows/glows.
    private func renderToImage(_ view: UIView, padding: CGFloat = 0) -> UIImage? {
        let containerView = UIView(frame: CGRect(x: -10000, y: -10000, width: 1000, height: 1000))
        // NOT hidden — drawHierarchy requires the view to be "visible" in the window
        containerView.clipsToBounds = false
        containerView.addSubview(view)

        view.clipsToBounds = false
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(greaterThanOrEqualTo: containerView.topAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor),
        ])

        var window: UIWindow?
        if #available(iOS 15.0, *) {
            window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
        } else {
            window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first
        }

        guard let window = window ?? mapView.window else {
            return nil
        }

        window.addSubview(containerView)

        view.setNeedsLayout()
        view.layoutIfNeeded()
        containerView.layoutIfNeeded()

        var finalSize = view.intrinsicContentSize
        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }
        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = view.frame.size
        }
        if finalSize.width <= 0 || finalSize.height <= 0 {
            view.removeFromSuperview()
            containerView.removeFromSuperview()
            return nil
        }

        let paddedSize = CGSize(
            width: finalSize.width + padding * 2,
            height: finalSize.height + padding * 2
        )
        view.frame = CGRect(x: padding, y: padding, width: finalSize.width, height: finalSize.height)

        let renderer = UIGraphicsImageRenderer(size: paddedSize)
        let image = renderer.image { _ in
            view.drawHierarchy(in: CGRect(x: padding, y: padding, width: finalSize.width, height: finalSize.height), afterScreenUpdates: true)
        }

        view.removeFromSuperview()
        containerView.removeFromSuperview()

        return image
    }

    /// Computes a cache key from layoutName and the values of the specified data keys.
    /// Numeric values are normalized to match Mapbox expression `concat` stringification
    /// (ECMAScript Number.toString): whole-number doubles omit the ".0" suffix.
    func computeImageCacheKey(layoutName: String, data: [String: Any]?, keys: [String]) -> String {
        var parts = [layoutName]
        for key in keys {
            let value = data?[key]
            parts.append(normalizeValueForCacheKey(value))
        }
        return parts.joined(separator: "_")
    }

    private func normalizeValueForCacheKey(_ value: Any?) -> String {
        guard let value = value else { return "nil" }
        if let num = value as? Double,
           num.truncatingRemainder(dividingBy: 1) == 0,
           !num.isInfinite, !num.isNaN {
            return String(Int64(num))
        }
        return "\(value)"
    }

    /// Renders a native view to a UIImage for use as a Mapbox style image.
    /// Creates view via factory, renders to image, caches it, and returns the UIImage.
    /// Does NOT create any ViewAnnotation.
    func renderViewToImage(layoutName: String, data: [String: Any]?, cacheKeys: [String], padding: CGFloat = 0, overrideCacheKey: String? = nil) -> UIImage? {
        let cacheKey = overrideCacheKey ?? computeImageCacheKey(layoutName: layoutName, data: data, keys: cacheKeys)

        if let cachedImage = imageCache[cacheKey] {
            return cachedImage
        }

        let dummyVisibility = ViewAnnotationVisibility()
        guard let view = ViewAnnotationRegistry.shared.createView(viewIdentifier: layoutName, args: data, visibility: dummyVisibility) else {
            NSLog("[ViewLayerPerf] renderViewToImage FAILED — no factory for '%@'", layoutName)
            return nil
        }

        guard let image = renderToImage(view, padding: padding) else {
            NSLog("[ViewLayerPerf] renderViewToImage FAILED — renderToImage returned nil for '%@'", layoutName)
            return nil
        }

        imageCache[cacheKey] = image
        NSLog("[ViewLayerPerf] STYLE_IMAGE_RENDERED cacheKey=%@ size=%.0fx%.0f", cacheKey, image.size.width, image.size.height)
        return image
    }

    // MARK: - Image mode layer registration (for tap fallback)

    func registerImageModeLayer(_ config: ImageModeLayerConfig) {
        imageModeLayerConfigs[config.symbolLayerId] = config
    }

    func unregisterImageModeLayer(symbolLayerId: String) {
        imageModeLayerConfigs.removeValue(forKey: symbolLayerId)
    }

    func setVisible(id: String, visible: Bool) {
        if let annotation = viewAnnotationObjects[id] {
            annotation.visible = visible
        } else if let view = annotations[id] {
            view.isHidden = !visible
        }
    }

    func isVisible(id: String) -> Bool {
        if let annotation = viewAnnotationObjects[id] {
            return annotation.visible
        } else if let view = annotations[id] {
            return !view.isHidden
        }
        return false
    }

    func remove(id: String) -> Result<Void, Error> {
        let removeStart = CACurrentMediaTime()

        // Check if using new ViewAnnotation API (layer feature binding)
        if let annotation = viewAnnotationObjects.removeValue(forKey: id) {
            annotation.remove()
            annotations.removeValue(forKey: id)
            layoutNames.removeValue(forKey: id)
            annotationOptions.removeValue(forKey: id)
            annotationData.removeValue(forKey: id)
            visibilityObjects.removeValue(forKey: id)
            annotationFeatures.removeValue(forKey: id)

            let durationMs = (CACurrentMediaTime() - removeStart) * 1000
            ViewLayerPerfMonitor.shared.recordAnnotationRemoval(id: id, durationMs: durationMs, remaining: annotations.count)
            return .success(())
        }

        // Fallback to legacy coordinate-based removal
        guard let view = annotations.removeValue(forKey: id) else {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Annotation with id '\(id)' not found"]
            ))
        }

        mapView.viewAnnotations.remove(view)
        layoutNames.removeValue(forKey: id)
        annotationOptions.removeValue(forKey: id)
        annotationData.removeValue(forKey: id)
        visibilityObjects.removeValue(forKey: id)
        annotationFeatures.removeValue(forKey: id)

        let durationMs = (CACurrentMediaTime() - removeStart) * 1000
        ViewLayerPerfMonitor.shared.recordAnnotationRemoval(id: id, durationMs: durationMs, remaining: annotations.count)
        return .success(())
    }

    func removeAll() {
        // Remove new-style annotations (layer feature binding)
        for annotation in viewAnnotationObjects.values {
            annotation.remove()
        }
        viewAnnotationObjects.removeAll()

        // Remove legacy coordinate-based annotations
        for view in annotations.values {
            mapView.viewAnnotations.remove(view)
        }
        annotations.removeAll()
        layoutNames.removeAll()
        annotationOptions.removeAll()
        annotationData.removeAll()
        visibilityObjects.removeAll()
        annotationFeatures.removeAll()
        imageModeFeatureData.removeAll()
    }
    
    private func parseAnchor(_ anchor: String?) -> MapboxMaps.ViewAnnotationAnchor {
        guard let anchor = anchor?.uppercased() else {
            return .center
        }
        
        switch anchor {
        case "TOP":
            return .top
        case "LEFT":
            return .left
        case "BOTTOM":
            return .bottom
        case "RIGHT":
            return .right
        case "TOP_LEFT":
            return .topLeft
        case "TOP_RIGHT":
            return .topRight
        case "BOTTOM_LEFT":
            return .bottomLeft
        case "BOTTOM_RIGHT":
            return .bottomRight
        case "CENTER":
            return .center
        default:
            return .center
        }
    }
    
    @objc private func handleMapTap(_ gesture: UITapGestureRecognizer) {
        let tapPoint = gesture.location(in: mapView)
        NSLog("[ViewAnnotationTap] handleMapTap at (%.1f, %.1f) timestamp=%.3f", tapPoint.x, tapPoint.y, CACurrentMediaTime())

        // Phase 1: Check ViewAnnotation views (existing behavior)
        for (annotationId, view) in annotations {
            if view.isHidden || view.alpha == 0 {
                continue
            }
            if let visibility = visibilityObjects[annotationId], !visibility.isVisible {
                continue
            }

            let pointInView = view.convert(tapPoint, from: mapView)
            if view.bounds.contains(pointInView) {
                NSLog("[ViewAnnotationTap] HIT annotationId=%@ timestamp=%.3f", annotationId, CACurrentMediaTime())
                let data = annotationData[annotationId] ?? [:]
                let feature = annotationFeatures[annotationId] ?? nil

                var featureList: [Any?]? = nil
                if let feature = feature {
                    let idList: [Any?]? = feature.id != nil ? [feature.id!.id, feature.id!.namespace] : nil
                    let featuresetList: [Any?] = [feature.featureset.featuresetId, feature.featureset.importId, feature.featureset.layerId]
                    featureList = [idList, featuresetList, feature.geometry, feature.properties, feature.state]
                }

                tapEventChannel.invokeMethod("onTap", arguments: [
                    "annotationId": annotationId,
                    "feature": featureList as Any,
                    "data": data
                ])
                return
            }
        }

        // Phase 2: Check image-mode symbol layers via queryRenderedFeatures
        guard !imageModeLayerConfigs.isEmpty else { return }

        let tapRect = CGRect(x: tapPoint.x - 22, y: tapPoint.y - 22, width: 44, height: 44)
        let layerIds = Array(imageModeLayerConfigs.keys)

        let options = MapboxMaps.RenderedQueryOptions(layerIds: layerIds, filter: nil)
        mapView.mapboxMap.queryRenderedFeatures(with: tapRect, options: options) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let queriedFeatures):
                guard let first = queriedFeatures.first else { return }
                let feature = first.queriedFeature.feature
                let sourceLayerId = first.queriedFeature.sourceLayer ?? ""

                // Find which image-mode config matched
                for layerId in first.layers {
                    guard let config = self.imageModeLayerConfigs[layerId] else { continue }

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

                    // Build feature ID
                    let featureId: String?
                    if let id = feature.identifier {
                        switch id {
                        case .string(let str): featureId = str
                        case .number(let num):
                            featureId = num.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(num)) : String(num)
                        @unknown default: featureId = nil
                        }
                    } else {
                        featureId = nil
                    }

                    let annotationId = "\(config.viewLayerId)_\(sourceLayerId)_\(featureId ?? "unknown")"

                    // Cache feature data for promote/demote
                    if self.imageModeFeatureData.count > 100 {
                        self.imageModeFeatureData.removeAll()
                    }
                    self.imageModeFeatureData[annotationId] = viewData
                    return
                }
            case .failure(let error):
                NSLog("[ViewLayerPerf] IMAGE_MODE_TAP_QUERY_ERROR: %@", error.localizedDescription)
            }
        }
    }
}


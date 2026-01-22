import UIKit
import os.log
import Flutter
import ObjectiveC
@_spi(Experimental) import MapboxMaps

private struct AssociatedKeys {
    static var annotationId = "annotationId"
}

class ViewAnnotationController {
    private let mapView: MapView
    private var annotations: [String: UIView] = [:]
    private var layoutNames: [String: String] = [:]
    private var annotationOptions: [String: ViewAnnotationOptions] = [:]
    private var annotationData: [String: [String: Any]] = [:]
    private var viewAnnotationObjects: [String: ViewAnnotation] = [:]  // For layer feature binding
    private let logger = OSLog(subsystem: "com.mapbox.maps.mapbox_maps", category: "ViewAnnotationController")
    private let tapEventChannel: FlutterMethodChannel
    
    init(mapView: MapView, messenger: FlutterBinaryMessenger, channelSuffix: String) {
        self.mapView = mapView
        self.tapEventChannel = FlutterMethodChannel(
            name: "plugins.flutter.io.\(channelSuffix)/viewAnnotationTap",
            binaryMessenger: messenger
        )
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
        os_log("[%{public}@] Starting add view annotation", log: logger, type: .info, id)
        
        if annotations[id] != nil {
            os_log("[%{public}@] ERROR: Annotation already exists", log: logger, type: .error, id)
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Annotation with id '\(id)' already exists"]
            ))
        }
        
        guard let view = ViewAnnotationRegistry.shared.createView(viewIdentifier: layoutName, args: data) else {
            os_log("[%{public}@] ERROR: No view registered for '%{public}@'", log: logger, type: .error, id, layoutName)
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No view registered for '\(layoutName)'"]
            ))
        }
        
        os_log("[%{public}@] View created: %{public}@", log: logger, type: .info, id, String(describing: type(of: view)))
        
        // Size the view
        let sizingResult = sizeView(view, id: id)
        switch sizingResult {
        case .failure:
            return sizingResult
        case .success:
            break
        }
        
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        
        let options = ViewAnnotationOptions(
            geometry: Point(coordinate),
            allowOverlap: allowOverlap,
            anchor: parseAnchor(anchor)
        )
        
        os_log("[%{public}@] Adding view annotation to map with coordinate: (%f, %f)", log: logger, type: .info, id, latitude, longitude)
        
        // Add tap gesture recognizer
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
        view.isUserInteractionEnabled = true
        
        // Store the annotation ID with the gesture recognizer for lookup
        objc_setAssociatedObject(tapGesture, &AssociatedKeys.annotationId, id, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        do {
            try mapView.viewAnnotations.add(view, options: options)
            annotations[id] = view
            layoutNames[id] = layoutName
            annotationOptions[id] = options
            annotationData[id] = data ?? [:]
            os_log("[%{public}@] Successfully added view annotation", log: logger, type: .info, id)
            return .success(())
        } catch {
            os_log("[%{public}@] ERROR: Failed to add view annotation: %{public}@", log: logger, type: .error, id, error.localizedDescription)
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
        allowOverlap: Bool
    ) -> Result<Void, Error> {
        os_log("[%{public}@] Starting add view annotation with layer feature binding to layer %{public}@, feature %{public}@", log: logger, type: .info, id, associatedLayerId, featureId)

        if annotations[id] != nil {
            os_log("[%{public}@] ERROR: Annotation already exists", log: logger, type: .error, id)
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Annotation with id '\(id)' already exists"]
            ))
        }

        guard let view = ViewAnnotationRegistry.shared.createView(viewIdentifier: layoutName, args: data) else {
            os_log("[%{public}@] ERROR: No view registered for '%{public}@'", log: logger, type: .error, id, layoutName)
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No view registered for '\(layoutName)'"]
            ))
        }

        os_log("[%{public}@] View created: %{public}@", log: logger, type: .info, id, String(describing: type(of: view)))

        // Size the view
        let sizingResult = sizeView(view, id: id)
        switch sizingResult {
        case .failure:
            return sizingResult
        case .success:
            break
        }

        // Create ViewAnnotation with layer feature binding
        let annotation = ViewAnnotation(
            annotatedFeature: .layerFeature(layerId: associatedLayerId, featureId: featureId),
            view: view
        )

        // Configure anchor
        annotation.variableAnchors = [ViewAnnotationAnchorConfig(anchor: parseAnchor(anchor))]
        annotation.allowOverlap = allowOverlap

        // Add tap gesture recognizer
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
        view.isUserInteractionEnabled = true
        objc_setAssociatedObject(tapGesture, &AssociatedKeys.annotationId, id, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        mapView.viewAnnotations.add(annotation)

        annotations[id] = view
        layoutNames[id] = layoutName
        annotationData[id] = data ?? [:]
        viewAnnotationObjects[id] = annotation

        // Debug: Check annotation state after adding
        os_log("[%{public}@] ViewAnnotation state - allowOverlap: %{public}@, view.frame: %{public}@, view.isHidden: %{public}@, view.alpha: %{public}f",
               log: logger, type: .info, id,
               String(describing: annotation.allowOverlap),
               String(describing: view.frame),
               String(describing: view.isHidden),
               view.alpha)

        os_log("[%{public}@] Successfully added view annotation with layer feature binding", log: logger, type: .info, id)
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
            // because they're bound to features. Just return success with a warning.
            if isViewLayerAnnotation {
                os_log("[%{public}@] ViewLayer annotation view doesn't support in-place property updates", log: logger, type: .default, id)
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

            // Size the new view
            let sizingResult = sizeView(newView, id: id)
            switch sizingResult {
            case .failure:
                return sizingResult
            case .success:
                break
            }

            // Add tap gesture recognizer
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            newView.addGestureRecognizer(tapGesture)
            newView.isUserInteractionEnabled = true
            objc_setAssociatedObject(tapGesture, &AssociatedKeys.annotationId, id, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

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
    
    private func sizeView(_ view: UIView, id: String) -> Result<Void, Error> {
        // Temporarily add to a container view to force layout calculation
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
        
        // Force layout
        view.setNeedsLayout()
        view.layoutIfNeeded()
        containerView.layoutIfNeeded()
        
        // Try to get size from intrinsic content size first
        var finalSize = view.intrinsicContentSize
        
        // If intrinsic size is invalid, try systemLayoutSizeFitting
        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }
        
        // If still invalid, use frame size
        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = view.frame.size
        }
        
        // If still zero, set a default size
        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = CGSize(width: 100, height: 50)
        }
        
        // Set the final frame
        view.frame = CGRect(origin: .zero, size: finalSize)
        view.removeFromSuperview()
        containerView.removeFromSuperview()
        
        if view.frame.width <= 0 || view.frame.height <= 0 {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "View has invalid dimensions: width=\(view.frame.width), height=\(view.frame.height)"]
            ))
        }
        
        return .success(())
    }
    
    func remove(id: String) -> Result<Void, Error> {
        // Check if using new ViewAnnotation API (layer feature binding)
        if let annotation = viewAnnotationObjects.removeValue(forKey: id) {
            annotation.remove()
            annotations.removeValue(forKey: id)
            layoutNames.removeValue(forKey: id)
            annotationOptions.removeValue(forKey: id)
            annotationData.removeValue(forKey: id)
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
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let annotationId = objc_getAssociatedObject(gesture, &AssociatedKeys.annotationId) as? String else {
            os_log("🔴 TAP GESTURE FIRED but no annotation ID found!", log: logger, type: .error)
            return
        }
        let data = annotationData[annotationId] ?? [:]
        os_log("🎯 IOS TAP DETECTED! ID: %{public}@, Data: %{public}@", log: logger, type: .info, annotationId, String(describing: data))
        os_log("🎯 Invoking Flutter method channel...", log: logger, type: .info)
        tapEventChannel.invokeMethod("onTap", arguments: ["id": annotationId, "data": data])
    }
}


import UIKit
import os.log
@_spi(Experimental) import MapboxMaps

class ViewAnnotationController {
    private let mapView: MapView
    private var annotations: [String: UIView] = [:]
    private let logger = OSLog(subsystem: "com.mapbox.maps.mapbox_maps", category: "ViewAnnotationController")
    
    init(mapView: MapView) {
        self.mapView = mapView
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
        os_log("[%{public}@] Initial frame: %{public}@", log: logger, type: .info, id, String(describing: view.frame))
        os_log("[%{public}@] Initial bounds: %{public}@", log: logger, type: .info, id, String(describing: view.bounds))
        os_log("[%{public}@] Initial intrinsic content size: %{public}@", log: logger, type: .info, id, String(describing: view.intrinsicContentSize))
        
        // Temporarily add to a container view to force layout calculation
        // Similar to Android approach - views need to be laid out before being added to map
        let containerView = UIView(frame: CGRect(x: -10000, y: -10000, width: 1000, height: 1000))
        containerView.isHidden = true
        containerView.addSubview(view)
        
        // Set up constraints to let the view size itself
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(greaterThanOrEqualTo: containerView.topAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor),
        ])
        
        // Get the window to temporarily attach the container
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
            os_log("[%{public}@] ERROR: Could not find window to temporarily attach view", log: logger, type: .error, id)
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not find window to temporarily attach view"]
            ))
        }
        
        window.addSubview(containerView)
        os_log("[%{public}@] Temporarily attached to window for layout", log: logger, type: .info, id)
        
        // Force layout
        view.setNeedsLayout()
        view.layoutIfNeeded()
        containerView.layoutIfNeeded()
        
        // Try to get size from intrinsic content size first
        var finalSize = view.intrinsicContentSize
        os_log("[%{public}@] After layout - intrinsic content size: %{public}@", log: logger, type: .info, id, String(describing: finalSize))
        os_log("[%{public}@] After layout - frame: %{public}@", log: logger, type: .info, id, String(describing: view.frame))
        os_log("[%{public}@] After layout - bounds: %{public}@", log: logger, type: .info, id, String(describing: view.bounds))
        
        // If intrinsic size is invalid, try systemLayoutSizeFitting
        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            os_log("[%{public}@] Using systemLayoutSizeFitting: %{public}@", log: logger, type: .info, id, String(describing: finalSize))
        }
        
        // If still invalid, use frame size
        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = view.frame.size
            os_log("[%{public}@] Using frame size: %{public}@", log: logger, type: .info, id, String(describing: finalSize))
        }
        
        // If still zero, set a default size
        if finalSize.width <= 0 || finalSize.height <= 0 {
            finalSize = CGSize(width: 100, height: 50)
            os_log("[%{public}@] WARNING: View had zero size, using default: %{public}@", log: logger, type: .error, id, String(describing: finalSize))
        }
        
        // Set the final frame
        view.frame = CGRect(origin: .zero, size: finalSize)
        view.removeFromSuperview()
        containerView.removeFromSuperview()
        
        // Verify final dimensions
        os_log("[%{public}@] Final frame before adding: %{public}@", log: logger, type: .info, id, String(describing: view.frame))
        os_log("[%{public}@] Final bounds: %{public}@", log: logger, type: .info, id, String(describing: view.bounds))
        os_log("[%{public}@] Final width: %f, height: %f", log: logger, type: .info, id, view.frame.width, view.frame.height)
        
        if view.frame.width <= 0 || view.frame.height <= 0 {
            os_log("[%{public}@] ERROR: Invalid dimensions after all attempts - width: %f, height: %f", log: logger, type: .error, id, view.frame.width, view.frame.height)
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "View has invalid dimensions: width=\(view.frame.width), height=\(view.frame.height)"]
            ))
        }
        
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        
        let options = ViewAnnotationOptions(
            geometry: Point(coordinate),
            allowOverlap: allowOverlap,
            anchor: parseAnchor(anchor)
        )
        
        os_log("[%{public}@] Adding view annotation to map with coordinate: (%f, %f)", log: logger, type: .info, id, latitude, longitude)
        
        do {
            try mapView.viewAnnotations.add(view, options: options)
            annotations[id] = view
            os_log("[%{public}@] Successfully added view annotation", log: logger, type: .info, id)
            return .success(())
        } catch {
            os_log("[%{public}@] ERROR: Failed to add view annotation: %{public}@", log: logger, type: .error, id, error.localizedDescription)
            return .failure(error)
        }
    }
    
    func update(
        id: String,
        latitude: Double?,
        longitude: Double?,
        data: [String: Any]?
    ) -> Result<Void, Error> {
        guard let view = annotations[id] else {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Annotation with id '\(id)' not found"]
            ))
        }
        
        if let lat = latitude, let lng = longitude {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let options = ViewAnnotationOptions(geometry: Point(coordinate))
            do {
                try mapView.viewAnnotations.update(view, options: options)
            } catch {
                return .failure(error)
            }
        }
        
        return .success(())
    }
    
    func remove(id: String) -> Result<Void, Error> {
        guard let view = annotations.removeValue(forKey: id) else {
            return .failure(NSError(
                domain: "ViewAnnotationController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Annotation with id '\(id)' not found"]
            ))
        }
        
        mapView.viewAnnotations.remove(view)
        return .success(())
    }
    
    func removeAll() {
        for view in annotations.values {
            mapView.viewAnnotations.remove(view)
        }
        annotations.removeAll()
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
}


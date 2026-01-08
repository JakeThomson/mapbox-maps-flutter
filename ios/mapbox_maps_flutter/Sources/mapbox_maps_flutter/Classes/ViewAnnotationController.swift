import UIKit
@_spi(Experimental) import MapboxMaps

class ViewAnnotationController {
    private let mapView: MapView
    private var annotations: [String: UIView] = [:]
    
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
        
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        
        let options = ViewAnnotationOptions(
            geometry: Point(coordinate),
            allowOverlap: allowOverlap,
            anchor: parseAnchor(anchor)
        )
        
        do {
            try mapView.viewAnnotations.add(view, options: options)
            annotations[id] = view
            return .success(())
        } catch {
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
    
    private func parseAnchor(_ anchor: String?) -> ViewAnnotationAnchor {
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


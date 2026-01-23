import UIKit

public typealias ViewAnnotationFactory = ([String: Any]?) -> UIView

/// Protocol for view annotations that want to handle their own visibility animations.
/// Implement this protocol in your UIView subclass to customize appear/disappear animations.
///
/// Example:
/// ```swift
/// class MyCalloutView: UIView, AnimatedViewAnnotation {
///     func animateVisibilityChange(visible: Bool, completion: (() -> Void)?) {
///         UIView.animate(withDuration: visible ? 0.2 : 0.15,
///                        delay: 0,
///                        options: visible ? .curveEaseOut : .curveEaseIn) {
///             self.transform = visible ? .identity : CGAffineTransform(scaleX: 0.1, y: 0.1)
///             self.alpha = visible ? 1 : 0
///         } completion: { _ in
///             completion?()
///         }
///     }
/// }
/// ```
@objc public protocol AnimatedViewAnnotation {
    /// Called when the view annotation's visibility changes due to collision detection.
    /// - Parameters:
    ///   - visible: Whether the annotation should be visible
    ///   - completion: Optional completion handler to call when animation finishes
    func animateVisibilityChange(visible: Bool, completion: (() -> Void)?)
}

public class ViewAnnotationRegistry {
    public static let shared = ViewAnnotationRegistry()
    
    private var factories: [String: ViewAnnotationFactory] = [:]
    
    private init() {}
    
    public func register(viewIdentifier: String, factory: @escaping ViewAnnotationFactory) {
        factories[viewIdentifier] = factory
    }
    
    public func unregister(viewIdentifier: String) {
        factories.removeValue(forKey: viewIdentifier)
    }
    
    func createView(viewIdentifier: String, args: [String: Any]?) -> UIView? {
        return factories[viewIdentifier]?(args)
    }
    
    func hasFactory(for viewIdentifier: String) -> Bool {
        return factories[viewIdentifier] != nil
    }
}





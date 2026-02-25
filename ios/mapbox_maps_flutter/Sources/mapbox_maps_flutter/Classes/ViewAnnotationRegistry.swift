import UIKit
import Combine

/// Observable object that provides visibility state for view annotations.
///
/// Use this in your SwiftUI views to animate entrance/exit based on
/// Mapbox collision detection and visibility changes.
///
/// Example usage:
/// ```swift
/// struct MyAnnotationView: View {
///     @ObservedObject var visibility: ViewAnnotationVisibility
///
///     var body: some View {
///         Circle()
///             .scaleEffect(visibility.isVisible ? 1 : 0)
///             .opacity(visibility.isVisible ? 1 : 0)
///             .animation(.spring(response: 0.3, dampingFraction: 0.6), value: visibility.isVisible)
///     }
/// }
/// ```
public class ViewAnnotationVisibility: ObservableObject {
    @Published public var isVisible: Bool = true

    public init() {}
}

public typealias ViewAnnotationFactory = ([String: Any]?) -> UIView

/// Factory that also receives a visibility object for animations.
public typealias ViewAnnotationFactoryWithVisibility = ([String: Any]?, ViewAnnotationVisibility) -> UIView

/// Factory that renders directly to a UIImage using CoreGraphics (thread-safe, no UIKit views).
/// - Parameters:
///   - data: The annotation data dictionary.
///   - scale: The screen scale factor (e.g. 2.0, 3.0).
/// - Returns: A rendered UIImage, or nil on failure.
public typealias ViewAnnotationImageFactory = (_ data: [String: Any]?, _ scale: CGFloat) -> UIImage?

public class ViewAnnotationRegistry {
    public static let shared = ViewAnnotationRegistry()

    private var factories: [String: ViewAnnotationFactory] = [:]
    private var factoriesWithVisibility: [String: ViewAnnotationFactoryWithVisibility] = [:]
    private var imageFactories: [String: ViewAnnotationImageFactory] = [:]

    private init() {}

    /// Register a factory that creates views without visibility support.
    public func register(viewIdentifier: String, factory: @escaping ViewAnnotationFactory) {
        factories[viewIdentifier] = factory
        factoriesWithVisibility.removeValue(forKey: viewIdentifier)
    }

    /// Register a factory that creates views with visibility support for animations.
    ///
    /// The visibility object's `isVisible` property will be updated when the annotation
    /// becomes visible or hidden due to collision detection or map bounds.
    ///
    /// Example:
    /// ```swift
    /// ViewAnnotationRegistry.shared.register(viewIdentifier: "animated_marker") { data, visibility in
    ///     let viewModel = MyMarkerViewModel(data: data, visibility: visibility)
    ///     return UIHostingController(rootView: MyMarkerView(viewModel: viewModel)).view
    /// }
    /// ```
    public func register(viewIdentifier: String, factory: @escaping ViewAnnotationFactoryWithVisibility) {
        factoriesWithVisibility[viewIdentifier] = factory
        factories.removeValue(forKey: viewIdentifier)
    }

    public func unregister(viewIdentifier: String) {
        factories.removeValue(forKey: viewIdentifier)
        factoriesWithVisibility.removeValue(forKey: viewIdentifier)
    }

    func createView(viewIdentifier: String, args: [String: Any]?) -> UIView? {
        return factories[viewIdentifier]?(args)
    }

    func createView(viewIdentifier: String, args: [String: Any]?, visibility: ViewAnnotationVisibility) -> UIView? {
        if let factory = factoriesWithVisibility[viewIdentifier] {
            return factory(args, visibility)
        }
        // Fallback to factory without visibility if not registered with visibility
        return factories[viewIdentifier]?(args)
    }

    func hasFactory(for viewIdentifier: String) -> Bool {
        return factories[viewIdentifier] != nil || factoriesWithVisibility[viewIdentifier] != nil
    }

    func supportsVisibility(for viewIdentifier: String) -> Bool {
        return factoriesWithVisibility[viewIdentifier] != nil
    }

    // MARK: - Image Factories

    /// Register an image factory that renders directly to UIImage using CoreGraphics.
    /// Image factories are thread-safe and can run on background queues.
    public func registerImageFactory(viewIdentifier: String, factory: @escaping ViewAnnotationImageFactory) {
        imageFactories[viewIdentifier] = factory
    }

    public func unregisterImageFactory(viewIdentifier: String) {
        imageFactories.removeValue(forKey: viewIdentifier)
    }

    func getImageFactory(for viewIdentifier: String) -> ViewAnnotationImageFactory? {
        return imageFactories[viewIdentifier]
    }

    func hasImageFactory(for viewIdentifier: String) -> Bool {
        return imageFactories[viewIdentifier] != nil
    }
}





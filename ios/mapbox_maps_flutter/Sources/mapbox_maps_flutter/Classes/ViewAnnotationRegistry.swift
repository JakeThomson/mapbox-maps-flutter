import UIKit

public typealias ViewAnnotationFactory = ([String: Any]?) -> UIView

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


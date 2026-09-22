import Foundation
@_spi(Experimental) import MapboxMaps
import Flutter

final class InteractionsController {
    private var cancelables = [String: AnyCancelable]()
    private let mapboxMap: MapboxMap

    /// What was registered, in registration order.
    ///
    /// The sdk keeps its own copy of this and dispatches from its gesture
    /// recognisers. In headless texture mode those recognisers never fire —
    /// the map's view is offscreen, so UIKit delivers it no touches — and the
    /// dispatch the sdk uses for that is internal to the sdk. So the same
    /// facts are recorded here and [dispatch] walks them by hand.
    private struct Registered {
        let id: String
        let type: _InteractionType
        let featureset: MapboxMaps.FeaturesetDescriptor<MapboxMaps.FeaturesetFeature>?
        let filter: Exp?
        let radius: CGFloat?
        let stopPropagation: Bool
        let listener: _InteractionsListener
    }
    private var registered: [Registered] = []

    init(withMapView mapView: MapView) {
        self.mapboxMap = mapView.mapboxMap
    }

    func addInteraction(messenger: SuffixBinaryMessenger, methodCall: FlutterMethodCall) {
        let listener = _InteractionsListener(binaryMessenger: messenger.messenger, messageChannelSuffix: messenger.suffix)
        guard let arguments = methodCall.arguments as? [String: Any],
              let interactionsList = arguments["interaction"] as? [Any?],
              let interaction = _InteractionPigeon.fromList(interactionsList),
              let interactionType = _InteractionType.fromString(interaction.interactionType) else {
            return
        }
        let id = interaction.identifier
        let stopPropagation = interaction.stopPropagation

        /// If there is a featuresetDescriptor add the interaction to that feature, including filter and radius if present
        if let featuresetDescriptorList = interaction.featuresetDescriptor,
            let featuresetDescriptor = FeaturesetDescriptor.fromList(featuresetDescriptorList) {
            let filterExpression = try? interaction.filter.flatMap { try $0.toExp() }
            let radius: CGFloat? = interaction.radius.flatMap { CGFloat($0) }
            registered.append(Registered(
                id: id,
                type: interactionType,
                featureset: featuresetDescriptor.toMapFeaturesetDescriptor(),
                filter: filterExpression,
                radius: radius,
                stopPropagation: stopPropagation,
                listener: listener))
            switch interactionType {
            case .tAP:
                let cancelable = mapboxMap.addInteraction(TapInteraction(featuresetDescriptor.toMapFeaturesetDescriptor(), filter: filterExpression, radius: radius, action: { featuresetFeature, context in
                    listener.onInteraction(feature: featuresetFeature.toFLTFeaturesetFeature(), context: context.toFLTMapContentGestureContext(), interactionID: id) { _ in }
                    return stopPropagation
                }))
                cancelables[interaction.identifier] = AnyCancelable(cancelable)
            case .lONGTAP:
                let cancelable = mapboxMap.addInteraction(LongPressInteraction(featuresetDescriptor.toMapFeaturesetDescriptor(), filter: filterExpression, radius: radius, action: { featuresetFeature, context in
                    listener.onInteraction(feature: featuresetFeature.toFLTFeaturesetFeature(), context: context.toFLTMapContentGestureContext(), interactionID: id) { _ in }
                    return stopPropagation
                }))
                cancelables[interaction.identifier] = AnyCancelable(cancelable)
            }
        /// Otherwise add interactions to the whole map view
        } else {
            registered.append(Registered(
                id: id,
                type: interactionType,
                featureset: nil,
                filter: nil,
                radius: nil,
                stopPropagation: stopPropagation,
                listener: listener))
            switch interactionType {
            case .tAP:
                let cancelable = mapboxMap.addInteraction(TapInteraction(action: { context in
                    listener.onInteraction(feature: nil, context: context.toFLTMapContentGestureContext(), interactionID: id) { _ in }
                    return stopPropagation
                }))
                cancelables[interaction.identifier] = AnyCancelable(cancelable)
            case .lONGTAP:
                let cancelable = mapboxMap.addInteraction(LongPressInteraction(action: { context in
                    listener.onInteraction(feature: nil, context: context.toFLTMapContentGestureContext(), interactionID: id) { _ in }
                    return stopPropagation
                }))
                cancelables[interaction.identifier] = AnyCancelable(cancelable)
            }
        }
    }

    func removeInteraction(methodCall: FlutterMethodCall) {
        guard let arguments = methodCall.arguments as? [String: Any],
            let interactionIdentifier = arguments["identifier"] as? String else {
            return
        }

        cancelables[interactionIdentifier]?.cancel()
        cancelables.removeValue(forKey: interactionIdentifier)
        registered.removeAll { $0.id == interactionIdentifier }
    }

    // MARK: - Headless dispatch

    /// Fire the interactions a tap at [point] would have fired, for a map
    /// whose view never receives touches (see [HeadlessMapTexture]).
    ///
    /// Same order the sdk uses: most recently added first, each one asked
    /// whether it matches, and a match that returns `stopPropagation` ends
    /// the walk. Featureset interactions are resolved with the public
    /// `queryRenderedFeatures`, which is what the sdk's own dispatch does
    /// one layer down.
    func dispatch(_ type: _InteractionType, at point: CGPoint) {
        let candidates = registered.reversed().filter { $0.type == type }
        step(through: Array(candidates), index: 0, at: point)
    }

    private func step(through items: [Registered], index: Int, at point: CGPoint) {
        guard index < items.count else { return }
        let item = items[index]
        let context = self.context(at: point)

        guard let featureset = item.featureset else {
            // A map-level interaction matches any tap.
            item.listener.onInteraction(feature: nil, context: context, interactionID: item.id) { _ in }
            if item.stopPropagation { return }
            step(through: items, index: index + 1, at: point)
            return
        }

        let handle: (Result<[MapboxMaps.FeaturesetFeature], Error>) -> Void = { [weak self] result in
            guard let self else { return }
            if case .success(let features) = result, let feature = features.first {
                item.listener.onInteraction(feature: feature.toFLTFeaturesetFeature(),
                                            context: context,
                                            interactionID: item.id) { _ in }
                if item.stopPropagation { return }
            }
            self.step(through: items, index: index + 1, at: point)
        }

        // A radius widens the hit area exactly as the sdk's own does. The two
        // geometries are different concrete types, and the query is generic
        // over them, so this is two calls rather than one.
        if let radius = item.radius, radius > 0 {
            let box = CGRect(x: point.x - radius, y: point.y - radius,
                             width: radius * 2, height: radius * 2)
            mapboxMap.queryRenderedFeatures(with: box, featureset: featureset,
                                            filter: item.filter, completion: handle)
        } else {
            mapboxMap.queryRenderedFeatures(with: point, featureset: featureset,
                                            filter: item.filter, completion: handle)
        }
    }

    private func context(at point: CGPoint) -> MapContentGestureContext {
        MapContentGestureContext(
            touchPosition: point.toFLTScreenCoordinate(),
            point: Point(mapboxMap.coordinate(for: point)),
            gestureState: .ended
        )
    }
}

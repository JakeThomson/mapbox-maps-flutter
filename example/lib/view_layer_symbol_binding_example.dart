import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'example.dart';

/// Demonstrates ViewLayer with symbol layer binding for shared collision detection.
///
/// This example shows how to bind view annotations to symbol layer features using
/// the `associatedSymbolLayerId` property. When bound, view annotations and symbol
/// layer features share collision detection - when a symbol hides due to collision,
/// its bound view annotation also hides, and vice versa.
class ViewLayerSymbolBindingExample extends StatefulWidget implements Example {
  @override
  final Widget leading = const Icon(Icons.layers);
  @override
  final String title = 'View Layer Symbol Binding';
  @override
  final String? subtitle = 'View annotations bound to symbol layer features';

  @override
  State<StatefulWidget> createState() => ViewLayerSymbolBindingExampleState();
}

class ViewLayerSymbolBindingExampleState
    extends State<ViewLayerSymbolBindingExample> {
  MapboxMap? mapboxMap;
  final Map<String, bool> _selectedAnnotations = {};

  void _onMapCreated(MapboxMap mapboxMap) {
    this.mapboxMap = mapboxMap;

    // Set up tap listener for view annotations
    mapboxMap.setOnViewAnnotationTapListener(
        (FeaturesetFeature? feature, Map<String, dynamic> data) {
      if (feature != null) {
        // Log feature information for debugging
        final viewLayerId = feature.featureset.layerId;
        final featureId = feature.id?.id;
        print('Tapped ViewLayer: $viewLayerId, feature: $featureId');
        print('Original properties: ${feature.properties}');

        // Construct annotation ID to toggle selection
        // Pattern: ${viewLayerId}_${sourceLayer}_${featureId}
        if (viewLayerId != null && featureId != null) {
          final annotationId = '${viewLayerId}_places_layer_$featureId';
          _toggleSelection(annotationId);
        }
      }
    });
  }

  void _onStyleLoaded(StyleLoadedEventData data) async {
    await _setupStyle();
  }

  Future<void> _setupStyle() async {
    final map = mapboxMap;
    if (map == null) return;

    try {
      // Add the vector source with POI data
      // NOTE: Use promoteId to ensure feature IDs are treated as strings from the start,
      // avoiding numeric conversion issues with large IDs in layer feature binding.
      await map.style.addSource(
        VectorSource(
          id: "test-poi-source",
          tiles: [
            "http://localhost:3001/test/map/tiles/{z}/{x}/{y}?limit=10",
          ],
          minzoom: 0,
          maxzoom: 22,
          // promoteId: {"places_layer": "id"},
        ),
      );

      // STEP 1: Add a Circle Layer for every point (always visible, allows overlap)
      await map.style.addLayer(
        CircleLayer(
          id: "poi-circles",
          sourceId: "test-poi-source",
          sourceLayer: "places_layer",
        )
          ..circleRadius = 2.0
          ..circleColor = Colors.blueAccent.toARGB32()
      );

      // STEP 2: Add the Symbol Layer
      // This layer contains the features that view annotations will bind to.
      await map.style.addLayer(
        SymbolLayer(
          id: "poi-symbols",
          sourceId: "test-poi-source",
          sourceLayer: "places_layer",
        )
          // Invisible icon to reserve space for the centered view annotation
          ..iconImage = ""
          ..iconPadding = 24.0
          ..iconAllowOverlap = false
          // Text label offset to the right
          ..textField = "{title}"
          ..textOffset = [1.5, 0.0]
          ..textAnchor = TextAnchor.LEFT
          ..textJustify = TextJustify.LEFT
          ..textSize = 12.0
          ..textColor = Colors.black.toARGB32()
          ..textHaloColor = Colors.white.toARGB32()
          ..textHaloWidth = 1.0
          ..textPadding = 16.0
          ..textOptional = false
          ..textAllowOverlap = false,
      );

      // STEP 3: Add the ViewLayer with symbol layer binding
      await map.style.addLayer(ViewLayer(
        id: "poi-views",
        sourceId: "test-poi-source",
        sourceLayer: "places_layer",
        associatedSymbolLayerId: "poi-symbols",
        layoutName: "custom_callout",
        propertyMapping: {
          'callout_emoji': FeatureProperty('emoji'),
          'callout_label': FeatureProperty('title'),
          'backgroundColor': ConstantValue(Colors.blueAccent.toARGB32()),
          'selected': ConstantValue(false),
        },
        anchor: ViewAnnotationAnchor.CENTER,
        allowOverlap: true,
      ));
    } catch (e) {
      // Style setup failed
    }
  }

  Future<void> _toggleSelection(String id) async {
    final currentSelected = _selectedAnnotations[id] ?? false;
    final newSelected = !currentSelected;
    _selectedAnnotations[id] = newSelected;

    await mapboxMap?.updateViewAnnotation(
      id: id,
      data: {
        'selected': newSelected,
      },
    );
  }

  Future<void> _removeAllAnnotations() async {
    await mapboxMap?.removeAllViewAnnotations();
    _selectedAnnotations.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: MapWidget(
              key: const ValueKey('mapWidget'),
              onMapCreated: _onMapCreated,
              onStyleLoadedListener: _onStyleLoaded,
              styleUri: MapboxStyles.STANDARD,
              cameraOptions: CameraOptions(
                center: Point(coordinates: Position(0.05, 51.52)),
                zoom: 10.0,
              ),
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'ViewLayer Symbol Binding Demo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'View annotations are bound to symbol layer features. '
                  'When symbols hide due to collision detection, their '
                  'bound view annotations also hide. Pan/zoom to see this in action.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Key: associatedSymbolLayerId connects ViewLayer to SymbolLayer',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.blue,
                      fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _removeAllAnnotations,
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('Remove All Annotations'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
        (String id, Map<String, dynamic> data) {
      debugPrint('View annotation tapped: $id');
      _toggleSelection(id);
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
      // NOTE: MVT tiles must include native feature IDs for symbol layer binding to work
      await map.style.addSource(
        VectorSource(
          id: "test-poi-source",
          tiles: [
            "http://localhost:3001/test/map/tiles/{z}/{x}/{y}?limit=10",
          ],
          minzoom: 0,
          maxzoom: 22,
        ),
      );

      // STEP 1: Add the Symbol Layer FIRST
      // This layer contains the features that view annotations will bind to.
      await map.style.addLayer(
        SymbolLayer(
          id: "poi-symbols",
          sourceId: "test-poi-source",
          sourceLayer: "places_layer",
        )
          ..textField = "{title}"
          ..textOffset = [1.5, 0.0]
          ..textAnchor = TextAnchor.LEFT
          ..textSize = 12.0
          ..textColor = Colors.black.value
          ..textHaloColor = Colors.white.value
          ..textHaloWidth = 1.0
          ..textOptional = true
          ..textAllowOverlap = false
          ..iconAllowOverlap = true,
      );

      // STEP 2: Add the ViewLayer with symbol layer binding
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
        anchor: ViewAnnotationAnchor.BOTTOM,
        allowOverlap: true,
      ));
    } catch (e) {
      debugPrint('Error setting up style: $e');
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

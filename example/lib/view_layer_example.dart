import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'example.dart';

class ViewLayerExample extends StatefulWidget implements Example {
  @override
  final Widget leading = const Icon(Icons.pin_drop);
  @override
  final String title = 'View Layer';
  @override
  final String? subtitle = 'Native view layer driven by external source data';

  @override
  State<StatefulWidget> createState() => ViewLayerExampleState();
}

class ViewLayerExampleState extends State<ViewLayerExample> {
  MapboxMap? mapboxMap;
  final Map<String, bool> _selectedAnnotations = {};
  void onMapCreated(MapboxMap mapboxMap) async {
    this.mapboxMap = mapboxMap;

    mapboxMap.logo.updateSettings(LogoSettings(enabled: false));
    mapboxMap.attribution.updateSettings(AttributionSettings(enabled: false));
    mapboxMap.gestures.updateSettings(
      GesturesSettings(doubleTapToZoomInEnabled: true),
    );

    // Set up tap listener for view annotations
    print('=== SETTING UP VIEW ANNOTATION TAP LISTENER ===');
    mapboxMap
        .setOnViewAnnotationTapListener((String annotationId, FeaturesetFeature? feature, Map<String, dynamic> data) {
      print('🎯🎯🎯 TAP DETECTED IN FLUTTER! 🎯🎯🎯');
      if (feature != null) {
        final viewLayerId = feature.featureset.layerId;
        final featureId = feature.id?.id;
        print('   ViewLayer: $viewLayerId, Feature: $featureId');
        print('   Properties: ${feature.properties}');
      }
      // Use the annotationId directly - no need to reconstruct it
      _toggleSelection(annotationId);
    });

    try {
      await Future.delayed(const Duration(milliseconds: 500));

      await mapboxMap.style.addSource(
        VectorSource(
          id: "test-poi-source",
          tiles: [
            "http://localhost:3001/test/map/tiles/{z}/{x}/{y}?limit=10",
          ],
          minzoom: 0,
          maxzoom: 22,
        ),
      );

      await mapboxMap.style.addLayer(
        CircleLayer(
          id: "test-poi-circle-right",
          sourceId: "test-poi-source",
          sourceLayer: "places_layer",
        )
          ..circleColor = Colors.blueAccent.value
          ..circleRadius = 6.0
          ..circleStrokeColor = Colors.white.value
          ..circleStrokeWidth = 2.0
          ..circleOpacity = 0.0,
      );

      // 2. Add the Symbol Layer (Icon + Conditional Text)
      await mapboxMap.style.addLayer(
        SymbolLayer(
          id: "test-poi-layer",
          sourceId: "test-poi-source",
          sourceLayer: "places_layer",
        )
          ..textField = "{title}"
          ..textOffset = [1.5, 0.0]
          ..textAnchor = TextAnchor.LEFT
          ..iconOffset = [40.0, 0.0]
          ..textSize = 12.0
          ..textColor = Colors.black.value
          ..textHaloColor = Colors.white.value
          ..textHaloWidth = 1.0
          // VISIBILITY LOGIC:
          ..textOptional = true // Hide text if it collides, keep icon
          ..textAllowOverlap = false // Collision detection for text
          ..iconAllowOverlap = true // Icon is always visible
          ..iconIgnorePlacement = true, // map labels won't hide your icon
      );

      mapboxMap.addInteraction(
        TapInteraction(FeaturesetDescriptor(layerId: "test-poi-layer"), (
          feature,
          context,
        ) {
          final properties = feature.properties;
          final id = properties['id']?.toString() ??
              properties['ID']?.toString() ??
              feature.id?.toString() ??
              'Unknown';
          print('Tapped label ID: $id');
        }),
        interactionID: "labelTapInteraction",
      );

      await mapboxMap.style.addLayer(ViewLayer(
        id: "test-poi-view-layer",
        sourceId: "test-poi-source",
        sourceLayer: "places_layer",
        layoutName: "custom_callout",
        propertyMapping: {
          'callout_emoji': FeatureProperty('emoji'),
          'callout_label': FeatureProperty('name'),
          // Assuming 'color' property in features is already an integer color value
          // If your features have hex color strings, you'll need to convert them in your tile source
          'backgroundColor': ConstantValue(Colors.blueAccent.toARGB32()),
          'selected': ConstantValue(false),
        },
        anchor: ViewAnnotationAnchor.BOTTOM,
        allowOverlap: true,
      ));

      mapboxMap.addInteraction(
        TapInteraction(FeaturesetDescriptor(layerId: "test-poi-circle-right"), (
          feature,
          context,
        ) {
          final properties = feature.properties;
          final id = properties['id']?.toString() ??
              properties['ID']?.toString() ??
              feature.id?.toString() ??
              'Unknown';
          print('Tapped label ID: $id');
        }),
        interactionID: "circleTapInteraction",
      );

      mapboxMap.setOnViewAnnotationTapListener(
          (String annotationId, FeaturesetFeature? feature, Map<String, dynamic> data) {
        // Use the annotationId directly - no need to reconstruct it
        _toggleSelection(annotationId);
      });
    } catch (e) {
      print('Error adding source/layer: $e');
    }
  }

  Future<void> _toggleSelection(String id) async {
    final currentSelected = _selectedAnnotations[id] ?? false;
    final newSelected = !currentSelected;
    _selectedAnnotations[id] = newSelected;

    // Update only the selection state
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
              onMapCreated: onMapCreated,
              styleUri: MapboxStyles.STANDARD,
              // textureView: false,
              // androidHostingMode: AndroidPlatformViewHostingMode.TLHC_HC
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'ViewLayer Demo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'View annotations are automatically created for visible POI features. Tap annotations to toggle selection. Pan/zoom to see annotations update.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
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

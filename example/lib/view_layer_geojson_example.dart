import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'example.dart';

/// Demonstrates ViewLayer with GeoJSON source fetched from a server URL.
///
/// This example passes a GeoJSON URL directly to the source,
/// letting Mapbox handle the data fetching automatically.
class ViewLayerGeoJsonExample extends StatefulWidget implements Example {
  @override
  final Widget leading = const Icon(Icons.restaurant);
  @override
  final String title = 'View Layer GeoJSON';
  @override
  final String? subtitle = 'ViewLayer with GeoJSON from server URL';

  @override
  State<StatefulWidget> createState() => ViewLayerGeoJsonExampleState();
}

class ViewLayerGeoJsonExampleState extends State<ViewLayerGeoJsonExample> {
  MapboxMap? mapboxMap;
  final Map<String, bool> _selectedAnnotations = {};
  Uint8List? _markerImage;

  static const String _sourceId = 'places-source';
  static const String _symbolLayerId = 'places-symbols';
  static const String _viewLayerId = 'places-views';
  static const String _markerIconId = 'place-marker';

  // Server URL for GeoJSON data - Mapbox will fetch this automatically
  static const String _geoJsonUrl =
      'http://localhost:3001/test/map/tiles/10/512/340?limit=10&format=geojson';

  @override
  void initState() {
    super.initState();
    _loadMarkerImage();
  }

  Future<void> _loadMarkerImage() async {
    final ByteData bytes =
        await rootBundle.load('assets/symbols/custom-icon.png');
    _markerImage = bytes.buffer.asUint8List();
  }

  void _onMapCreated(MapboxMap mapboxMap) async {
    this.mapboxMap = mapboxMap;

    // Center on London (where the data is located)
    await mapboxMap.setCamera(
      CameraOptions(
        center: Point(coordinates: Position(0.05, 51.52)),
        zoom: 10.0,
      ),
    );

    // Set up tap listener for view annotations
    mapboxMap.setOnViewAnnotationTapListener(
        (String id, Map<String, dynamic> data) {
      debugPrint('View annotation tapped: $id');
      debugPrint('Data: $data');
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
      // Add marker icon to style
      if (_markerImage != null) {
        try {
          await map.style.addStyleImage(
            _markerIconId,
            1.0,
            MbxImage(width: 40, height: 40, data: _markerImage!),
            true,
            [],
            [],
            null,
          );
        } catch (_) {
          // Icon might already exist
        }
      }

      // Add GeoJSON source with URL - Mapbox fetches the data automatically
      //
      // IMPORTANT: Do NOT use promoteId when using associatedSymbolLayerId!
      // The Mapbox SDK's .layerFeature() binding mechanism is incompatible with
      // promoteId - it cannot find features to bind to when promoteId is set.
      // This is a limitation of the native Mapbox SDK, not the Flutter wrapper.
      await map.style.addSource(
        GeoJsonSource(
          id: _sourceId,
          data: _geoJsonUrl, // Just pass the URL, Mapbox handles fetching
          // promoteId: "id", // DO NOT USE with associatedSymbolLayerId!
        ),
      );

      // Add symbol layer for markers
      await map.style.addLayer(
        SymbolLayer(
          id: _symbolLayerId,
          sourceId: _sourceId,
        )
          ..iconImage = _markerIconId
          ..iconSize = 0.5
          ..iconAnchor = IconAnchor.BOTTOM
          ..iconAllowOverlap = false
          ..iconIgnorePlacement = false
          // Also show title text
          ..textField = "{title}"
          ..textOffset = [0.0, 0.5]
          ..textAnchor = TextAnchor.TOP
          ..textSize = 11.0
          ..textColor = Colors.black.toARGB32()
          ..textHaloColor = Colors.white.toARGB32()
          ..textHaloWidth = 1.0
          ..textOptional = true
          ..textAllowOverlap = false,
      );

      // Add view layer bound to symbol layer
      await map.style.addLayer(ViewLayer(
        id: _viewLayerId,
        sourceId: _sourceId,
        associatedSymbolLayerId: _symbolLayerId,
        layoutName: 'custom_callout',
        propertyMapping: {
          'callout_emoji': FeatureProperty('emoji'),
          'callout_label': FeatureProperty('title'),
          'backgroundColor': ConstantValue(Colors.blueAccent.toARGB32()),
          'selected': ConstantValue(false),
        },
        anchor: ViewAnnotationAnchor.BOTTOM,
        allowOverlap: true,
      ));

      // Add tap interaction for symbol layer
      map.addInteraction(
        TapInteraction(FeaturesetDescriptor(layerId: _symbolLayerId), (
          feature,
          context,
        ) {
          final id = feature.id?.toString() ??
              feature.properties['id']?.toString() ??
              'Unknown';
          debugPrint('Symbol tapped - Feature ID: ${feature.id}');
          debugPrint('Symbol tapped - Properties: ${feature.properties}');
          _onMarkerTapped(id);
        }),
        interactionID: 'placeTapInteraction',
      );
    } catch (e) {
      debugPrint('Error setting up style: $e');
    }
  }

  void _onMarkerTapped(String id) {
    debugPrint('Marker tapped: $id');
    _toggleSelection(id);
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
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'ViewLayer with GeoJSON URL',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'GeoJSON source with URL - Mapbox fetches the data automatically. '
                    'Same data format as MVT but via GeoJSON.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'URL: $_geoJsonUrl',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.blue,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
          ),
        ],
      ),
    );
  }
}

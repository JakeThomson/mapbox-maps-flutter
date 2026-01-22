import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'example.dart';

/// Demonstrates view annotations connected to GeoJSON marker features.
///
/// This example shows how to:
/// - Add markers via long-press on the map
/// - Tap markers to show/manage view annotations
/// - Display lat/lon coordinates in annotations
/// - Switch between map styles
/// - Bind view annotations to symbol layer features
class ViewAnnotationMarkerExample extends StatefulWidget implements Example {
  @override
  final Widget leading = const Icon(Icons.pin_drop);
  @override
  final String title = 'View Annotation Markers';
  @override
  final String? subtitle =
      'Markers with view annotations showing coordinates';

  @override
  State<StatefulWidget> createState() => ViewAnnotationMarkerExampleState();
}

class ViewAnnotationMarkerExampleState
    extends State<ViewAnnotationMarkerExample> {
  MapboxMap? mapboxMap;
  int _markerId = 0;
  bool _isStandardStyle = true;
  final List<Feature> _pointList = [];
  final Map<String, bool> _selectedAnnotations = {};
  Uint8List? _markerImage;

  static const String _sourceId = 'markers-source';
  static const String _layerId = 'markers-layer';
  static const String _viewLayerId = 'markers-view-layer';
  static const String _markerIdPrefix = 'marker_';
  static const String _markerIconId = 'marker-icon';

  // Sample geographic data - famous landmarks
  final List<_LandmarkData> _sampleLandmarks = [
    _LandmarkData(
      name: 'Statue of Liberty',
      position: Position(-74.0445, 40.6892),
    ),
    _LandmarkData(
      name: 'Empire State Building',
      position: Position(-73.9857, 40.7484),
    ),
    _LandmarkData(
      name: 'Central Park',
      position: Position(-73.9654, 40.7829),
    ),
    _LandmarkData(
      name: 'Brooklyn Bridge',
      position: Position(-73.9969, 40.7061),
    ),
    _LandmarkData(
      name: 'Times Square',
      position: Position(-73.9855, 40.7580),
    ),
  ];

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

    await mapboxMap.setCamera(
      CameraOptions(
        center: Point(coordinates: Position(-73.9712, 40.7128)),
        zoom: 10.5,
      ),
    );

    // Set up tap listener for view annotations
    mapboxMap.setOnViewAnnotationTapListener(
        (String id, Map<String, dynamic> data) {
      _toggleSelection(id);
    });
  }

  void _onStyleLoaded(StyleLoadedEventData data) async {
    // Add sample markers first so there's data to display
    if (_pointList.isEmpty) {
      for (final landmark in _sampleLandmarks) {
        final currentId = '$_markerIdPrefix${_markerId++}';
        final feature = Feature(
          id: currentId,
          geometry: Point(coordinates: landmark.position),
          properties: {
            'id': currentId,
            'emoji': '\u{1F4CD}',
            'label': landmark.name,
            'color': Colors.blue.toARGB32(),
            'lat': landmark.position.lat,
            'lng': landmark.position.lng,
          },
        );
        _pointList.add(feature);
      }
    }

    await _setupStyle();
  }

  Future<void> _setupStyle() async {
    final map = mapboxMap;
    if (map == null) return;

    try {
      // Check if source already exists
      final sourceExists = await map.style.styleSourceExists(_sourceId);
      if (sourceExists) {
        // Remove existing layers and source to recreate them
        try {
          await map.style.removeStyleLayer(_viewLayerId);
        } catch (_) {}
        try {
          await map.style.removeStyleLayer(_layerId);
        } catch (_) {}
        try {
          await map.style.removeStyleSource(_sourceId);
        } catch (_) {}
      }

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

      // Create GeoJSON source with current markers
      final featureCollection = {
        'type': 'FeatureCollection',
        'features': _pointList.map((f) => _featureToJson(f)).toList(),
      };

      await map.style.addSource(
        GeoJsonSource(
          id: _sourceId,
          data: json.encode(featureCollection),
        ),
      );

      // Add symbol layer for markers
      await map.style.addLayer(
        SymbolLayer(
          id: _layerId,
          sourceId: _sourceId,
        )
          ..iconImage = _markerIconId
          ..iconSize = 0.5
          ..iconAnchor = IconAnchor.BOTTOM
          ..iconAllowOverlap = false
          ..iconIgnorePlacement = false,  // Participate in collision detection
      );

      // Add view layer bound to symbol layer for annotations
      await map.style.addLayer(ViewLayer(
        id: _viewLayerId,
        sourceId: _sourceId,
        associatedSymbolLayerId: _layerId,
        layoutName: 'custom_callout',
        propertyMapping: {
          'callout_emoji': FeatureProperty('emoji'),
          'callout_label': FeatureProperty('label'),
          'backgroundColor': FeatureProperty('color'),
          'selected': ConstantValue(false),
        },
        anchor: ViewAnnotationAnchor.BOTTOM,
        allowOverlap: true,
      ));

      // Add tap interaction for symbol layer
      map.addInteraction(
        TapInteraction(FeaturesetDescriptor(layerId: _layerId), (
          feature,
          context,
        ) {
          final id = feature.properties['id']?.toString() ??
              feature.id?.toString() ??
              'Unknown';
          _onMarkerTapped(id);
        }),
        interactionID: 'markerTapInteraction',
      );
    } catch (e) {
      debugPrint('Error setting up style: $e');
    }
  }

  Map<String, dynamic> _featureToJson(Feature feature) {
    final point = feature.geometry as Point;
    return {
      'type': 'Feature',
      'id': feature.id,
      'geometry': {
        'type': 'Point',
        'coordinates': [
          point.coordinates.lng,
          point.coordinates.lat,
        ],
      },
      'properties': feature.properties,
    };
  }

  void _onLongTap(MapContentGestureContext context) {
    _addMarker(context.point.coordinates);
  }

  Future<void> _addMarker(Position coordinate, {String? name}) async {
    final currentId = '$_markerIdPrefix${_markerId++}';
    final label = name ??
        'lat=${coordinate.lat.toStringAsFixed(2)}\nlon=${coordinate.lng.toStringAsFixed(2)}';

    final feature = Feature(
      id: currentId,
      geometry: Point(coordinates: coordinate),
      properties: {
        'id': currentId,
        'emoji': '\u{1F4CD}', // Pin emoji
        'label': label,
        'color': Colors.blue.toARGB32(),
        'lat': coordinate.lat,
        'lng': coordinate.lng,
      },
    );

    _pointList.add(feature);

    // Update the GeoJSON source
    await _updateSource();
  }

  Future<void> _updateSource() async {
    final map = mapboxMap;
    if (map == null) return;

    try {
      final featureCollection = {
        'type': 'FeatureCollection',
        'features': _pointList.map((f) => _featureToJson(f)).toList(),
      };

      // Update the source data
      await map.style.setStyleSourceProperty(
        _sourceId,
        'data',
        json.encode(featureCollection),
      );
    } catch (e) {
      debugPrint('Error updating source: $e');
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

  Future<void> _addMoreMarkers() async {
    // Add a few random markers near NYC
    final newMarkers = [
      _LandmarkData(
        name: 'Wall Street',
        position: Position(-74.0110, 40.7074),
      ),
      _LandmarkData(
        name: 'Yankee Stadium',
        position: Position(-73.9262, 40.8296),
      ),
      _LandmarkData(
        name: 'JFK Airport',
        position: Position(-73.7781, 40.6413),
      ),
    ];

    for (final landmark in newMarkers) {
      await _addMarker(landmark.position, name: landmark.name);
    }
  }

  Future<void> _removeAllMarkers() async {
    await mapboxMap?.removeAllViewAnnotations();
    _pointList.clear();
    _selectedAnnotations.clear();
    _markerId = 0;
    await _updateSource();
  }

  Future<void> _toggleStyle() async {
    final map = mapboxMap;
    if (map == null) return;

    _isStandardStyle = !_isStandardStyle;
    await map.loadStyleURI(
      _isStandardStyle ? MapboxStyles.STANDARD : MapboxStyles.SATELLITE_STREETS,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          MapWidget(
            key: const ValueKey('mapWidget'),
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: _onStyleLoaded,
            onLongTapListener: _onLongTap,
            styleUri: MapboxStyles.STANDARD,
            cameraOptions: CameraOptions(
              center: Point(coordinates: Position(-73.9712, 40.7128)),
              zoom: 10.5,
            ),
          ),
          // Info panel at bottom
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'View Annotation Markers',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Long-press anywhere on the map to add a marker. '
                      'Tap markers to toggle selection. '
                      'Annotations show lat/lon coordinates.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _addMoreMarkers,
                          icon: const Icon(Icons.add_location_alt),
                          label: const Text('Add More'),
                        ),
                        ElevatedButton.icon(
                          onPressed: _removeAllMarkers,
                          icon: const Icon(Icons.delete_sweep),
                          label: const Text('Clear All'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Style toggle button
          Positioned(
            top: 16,
            right: 16,
            child: SafeArea(
              child: ElevatedButton(
                onPressed: _toggleStyle,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                child: Text(_isStandardStyle ? 'Satellite' : 'Standard'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LandmarkData {
  final String name;
  final Position position;

  const _LandmarkData({
    required this.name,
    required this.position,
  });
}

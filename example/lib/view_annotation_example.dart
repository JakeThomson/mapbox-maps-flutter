import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'example.dart';

class ViewAnnotationExample extends StatefulWidget implements Example {
  @override
  final Widget leading = const Icon(Icons.pin_drop);
  @override
  final String title = 'View Annotations';
  @override
  final String? subtitle = 'Native view annotations anchored to coordinates';

  @override
  State<StatefulWidget> createState() => ViewAnnotationExampleState();
}

class ViewAnnotationExampleState extends State<ViewAnnotationExample> {
  MapboxMap? mapboxMap;
  int _annotationCounter = 0;

  final List<_AnnotationData> _sampleAnnotations = [
    _AnnotationData(
      emoji: '☕',
      label: 'Blue Bottle Coffee',
      color: const Color(0xFF3B82F6),
      position: Position(-122.4194, 37.7749),
    ),
    _AnnotationData(
      emoji: '🍕',
      label: 'Tony\'s Pizza',
      color: const Color(0xFFEF4444),
      position: Position(-122.4089, 37.7855),
    ),
    _AnnotationData(
      emoji: '🌳',
      label: 'Golden Gate Park',
      color: const Color(0xFF22C55E),
      position: Position(-122.4862, 37.7694),
    ),
    _AnnotationData(
      emoji: '🎭',
      label: 'SF Opera House',
      color: const Color(0xFF8B5CF6),
      position: Position(-122.4200, 37.7785),
    ),
    _AnnotationData(
      emoji: '🌉',
      label: 'Golden Gate Bridge',
      color: const Color(0xFFF97316),
      position: Position(-122.4783, 37.8199),
    ),
  ];

  void _onMapCreated(MapboxMap mapboxMap) async {
    this.mapboxMap = mapboxMap;
    await mapboxMap.setCamera(
      CameraOptions(
        center: Point(coordinates: Position(-122.4194, 37.7749)),
        zoom: 11.5,
      ),
    );
  }

  Future<void> _addAnnotation(_AnnotationData data) async {
    final id = 'annotation_${_annotationCounter++}';
    await mapboxMap?.addViewAnnotation(
      id: id,
      layoutName: 'custom_callout',
      coordinate: Point(coordinates: data.position),
      data: {
        'callout_emoji': data.emoji,
        'callout_label': data.label,
        'backgroundColor': _colorToInt(data.color),
      },
    );
  }

  Future<void> _addAllAnnotations() async {
    for (final data in _sampleAnnotations) {
      await _addAnnotation(data);
    }
  }

  Future<void> _removeAllAnnotations() async {
    await mapboxMap?.removeAllViewAnnotations();
    _annotationCounter = 0;
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
              styleUri: MapboxStyles.STANDARD,
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'View Annotations Demo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Native views anchored to map coordinates. On Android, uses XML layouts. On iOS, uses registered UIViews.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _addAllAnnotations,
                      icon: const Icon(Icons.add_location_alt),
                      label: const Text('Add All'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _removeAllAnnotations,
                      icon: const Icon(Icons.delete_sweep),
                      label: const Text('Remove All'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Add individual:', style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _sampleAnnotations.map((data) {
                    return ActionChip(
                      avatar: Text(data.emoji),
                      label: Text(data.label),
                      backgroundColor: data.color.withAlpha((0.2 * 255).round()),
                      onPressed: () => _addAnnotation(data),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AnnotationData {
  final String emoji;
  final String label;
  final Color color;
  final Position position;

  const _AnnotationData({
    required this.emoji,
    required this.label,
    required this.color,
    required this.position,
  });
}

int _colorToInt(Color color) {
  return (color.a.toInt() << 24) |
         (color.r.toInt() << 16) |
         (color.g.toInt() << 8) |
         color.b.toInt();
}


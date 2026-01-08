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
    _AnnotationData(
      emoji: '🏛️',
      label: 'City Hall',
      color: const Color(0xFF6366F1),
      position: Position(-122.4194, 37.7799),
    ),
    _AnnotationData(
      emoji: '🎨',
      label: 'SFMOMA',
      color: const Color(0xFFEC4899),
      position: Position(-122.4008, 37.7857),
    ),
    _AnnotationData(
      emoji: '🏖️',
      label: 'Ocean Beach',
      color: const Color(0xFF06B6D4),
      position: Position(-122.5100, 37.7594),
    ),
    _AnnotationData(
      emoji: '🏢',
      label: 'Transamerica Pyramid',
      color: const Color(0xFF64748B),
      position: Position(-122.4025, 37.7950),
    ),
    _AnnotationData(
      emoji: '🎢',
      label: 'Pier 39',
      color: const Color(0xFFF59E0B),
      position: Position(-122.4098, 37.8087),
    ),
    _AnnotationData(
      emoji: '🚢',
      label: 'Fisherman\'s Wharf',
      color: const Color(0xFF0891B2),
      position: Position(-122.4158, 37.8080),
    ),
    _AnnotationData(
      emoji: '🏛️',
      label: 'Alcatraz Island',
      color: const Color(0xFF475569),
      position: Position(-122.4225, 37.8267),
    ),
    _AnnotationData(
      emoji: '🌁',
      label: 'Lombard Street',
      color: const Color(0xFF10B981),
      position: Position(-122.4189, 37.8021),
    ),
    _AnnotationData(
      emoji: '🏟️',
      label: 'Oracle Park',
      color: const Color(0xFF059669),
      position: Position(-122.3894, 37.7786),
    ),
    _AnnotationData(
      emoji: '🎪',
      label: 'Chinatown Gate',
      color: const Color(0xFFDC2626),
      position: Position(-122.4058, 37.7941),
    ),
    _AnnotationData(
      emoji: '🌉',
      label: 'Bay Bridge',
      color: const Color(0xFF7C3AED),
      position: Position(-122.3823, 37.7983),
    ),
    _AnnotationData(
      emoji: '🏰',
      label: 'Palace of Fine Arts',
      color: const Color(0xFFD97706),
      position: Position(-122.4481, 37.8029),
    ),
    _AnnotationData(
      emoji: '🎓',
      label: 'UC Berkeley',
      color: const Color(0xFF1E40AF),
      position: Position(-122.2585, 37.8719),
    ),
    _AnnotationData(
      emoji: '🌲',
      label: 'Muir Woods',
      color: const Color(0xFF166534),
      position: Position(-122.5804, 37.8959),
    ),
    _AnnotationData(
      emoji: '🏔️',
      label: 'Twin Peaks',
      color: const Color(0xFF6B7280),
      position: Position(-122.4470, 37.7514),
    ),
    _AnnotationData(
      emoji: '🎬',
      label: 'Walt Disney Museum',
      color: const Color(0xFFBE185D),
      position: Position(-122.4581, 37.8014),
    ),
    _AnnotationData(
      emoji: '🍷',
      label: 'Napa Valley',
      color: const Color(0xFF991B1B),
      position: Position(-122.2869, 38.2975),
    ),
    _AnnotationData(
      emoji: '🏄',
      label: 'Stinson Beach',
      color: const Color(0xFF0EA5E9),
      position: Position(-122.6447, 37.9000),
    ),
    _AnnotationData(
      emoji: '🚂',
      label: 'Cable Car Museum',
      color: const Color(0xFF92400E),
      position: Position(-122.4153, 37.7947),
    ),
    _AnnotationData(
      emoji: '🎯',
      label: 'Mission District',
      color: const Color(0xFF7C2D12),
      position: Position(-122.4194, 37.7599),
    ),
    _AnnotationData(
      emoji: '🏛️',
      label: 'Coit Tower',
      color: const Color(0xFF374151),
      position: Position(-122.4058, 37.8024),
    ),
    _AnnotationData(
      emoji: '🌊',
      label: 'Crissy Field',
      color: const Color(0xFF0D9488),
      position: Position(-122.4469, 37.8027),
    ),
    _AnnotationData(
      emoji: '🎨',
      label: 'Mission Dolores',
      color: const Color(0xFF78350F),
      position: Position(-122.4265, 37.7633),
    ),
    _AnnotationData(
      emoji: '🏖️',
      label: 'Baker Beach',
      color: const Color(0xFF0284C7),
      position: Position(-122.4838, 37.7936),
    ),
    _AnnotationData(
      emoji: '🎪',
      label: 'Union Square',
      color: const Color(0xFFB91C1C),
      position: Position(-122.4078, 37.7879),
    ),
    _AnnotationData(
      emoji: '🌉',
      label: 'Fort Point',
      color: const Color(0xFF1E3A8A),
      position: Position(-122.4772, 37.8106),
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
                SizedBox(
                  height: 120,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    child: Wrap(
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


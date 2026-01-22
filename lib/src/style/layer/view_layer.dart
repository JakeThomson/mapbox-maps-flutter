part of mapbox_maps_flutter;

/// Base class for property mapping in ViewLayer
abstract class PropertyMapping {
  Object? getValue(Map<String, dynamic> featureProperties);
}

/// Maps a feature property to view data
class FeatureProperty extends PropertyMapping {
  final String propertyKey;
  final Object? Function(Object?)? transform;

  FeatureProperty(this.propertyKey, {this.transform});

  @override
  Object? getValue(Map<String, dynamic> featureProperties) {
    final value = featureProperties[propertyKey];
    if (transform != null) {
      return transform!(value);
    }
    return value;
  }
}

/// Provides a constant value for all features
class ConstantValue extends PropertyMapping {
  final Object? value;

  ConstantValue(this.value);

  @override
  Object? getValue(Map<String, dynamic> featureProperties) {
    return value;
  }
}

/// A layer that renders native view annotations for features from a source.
///
/// ViewLayer automatically creates view annotations for visible features in the viewport
/// and manages their lifecycle as the map moves. Features are rendered using native platform
/// views (Android Compose or iOS UIView) registered via ViewAnnotationRegistry.
///
/// Example:
/// ```dart
/// await mapboxMap.style.addLayer(
///   ViewLayer(
///     id: "poi-views",
///     sourceId: "poi-source",
///     sourceLayer: "places_layer",
///     layoutName: "custom_callout",
///     propertyMapping: {
///       'callout_emoji': FeatureProperty('emoji'),
///       'callout_label': FeatureProperty('name'),
///       'backgroundColor': FeatureProperty('color', transform: (value) {
///         if (value is String) {
///           return Color(int.parse(value.replaceFirst('#', '0xFF'))).value;
///         }
///         return Colors.blueAccent.value;
///       }),
///       'selected': ConstantValue(false),
///     },
///     anchor: ViewAnnotationAnchor.CENTER,
///     allowOverlap: true,
///   ),
/// );
/// ```
class ViewLayer extends Layer {
  ViewLayer({
    required String id,
    Visibility? visibility,
    List<Object>? visibilityExpression,
    List<Object>? filter,
    double? minZoom,
    double? maxZoom,
    String? slot,
    required String this.sourceId,
    String? this.sourceLayer,
    required String this.layoutName,
    required Map<String, PropertyMapping> this.propertyMapping,
    ViewAnnotationAnchor? this.anchor,
    bool? this.allowOverlap,
    String? this.associatedSymbolLayerId,
  }) : super(
            id: id,
            visibility: visibility,
            visibilityExpression: visibilityExpression,
            filter: filter,
            maxZoom: maxZoom,
            minZoom: minZoom,
            slot: slot);

  @override
  String getType() => "view";

  /// The id of the source.
  String sourceId;

  /// A source layer is an individual layer of data within a vector source.
  /// A vector source can have multiple source layers.
  String? sourceLayer;

  /// The layout name that corresponds to a registered native view factory.
  ///
  /// Android: Registered via ViewAnnotationRegistry.register()
  /// iOS: Registered via ViewAnnotationRegistry.shared.register()
  String layoutName;

  /// Maps feature properties to view data.
  ///
  /// Keys are the data keys passed to the native view factory.
  /// Values are PropertyMapping instances (FeatureProperty or ConstantValue)
  /// that define how to extract or generate the data.
  Map<String, PropertyMapping> propertyMapping;

  /// The anchor position of the view annotation relative to the feature coordinate.
  /// Default value: ViewAnnotationAnchor.CENTER
  ViewAnnotationAnchor? anchor;

  /// Whether the view annotation can overlap with other annotations.
  /// Default value: true
  bool? allowOverlap;

  /// The ID of an existing SymbolLayer to bind view annotations to.
  ///
  /// When set, view annotations are bound to symbol layer features using
  /// Mapbox's `annotatedFeature: .layerFeature()` API. This enables shared
  /// collision detection - when symbols hide due to collision, their bound
  /// view annotations also hide, and vice versa.
  ///
  /// The symbol layer must:
  /// - Already exist in the style before the ViewLayer is added
  /// - Use the same source as this ViewLayer
  /// - Have features with explicit IDs (feature.id or properties['id'])
  ///
  /// **IMPORTANT:** Do NOT use `promoteId` on the source when using this feature.
  /// The Mapbox SDK's `.layerFeature()` binding mechanism is incompatible with
  /// `promoteId` - it cannot find features to bind to when promoteId is set.
  /// This is a limitation of the native Mapbox SDK.
  ///
  /// Example:
  /// ```dart
  /// // First, add the symbol layer
  /// await mapboxMap.style.addLayer(SymbolLayer(
  ///   id: "poi-symbols",
  ///   sourceId: "poi-source",
  /// )..textField = "{name}"
  ///  ..textAllowOverlap = false);
  ///
  /// // Then, add the view layer referencing it
  /// await mapboxMap.style.addLayer(ViewLayer(
  ///   id: "poi-views",
  ///   sourceId: "poi-source",
  ///   associatedSymbolLayerId: "poi-symbols",
  ///   layoutName: "custom_callout",
  ///   propertyMapping: {...},
  /// ));
  /// ```
  String? associatedSymbolLayerId;

  @override
  Future<String> _encode() async {
    var layout = {};
    if (visibilityExpression != null) {
      layout["visibility"] = visibilityExpression!;
    }
    if (visibility != null) {
      layout["visibility"] =
          visibility!.name.toLowerCase().replaceAll("_", "-");
    }

    // Encode property mapping for native side
    var propertyMappingEncoded = <String, Map<String, dynamic>>{};
    propertyMapping.forEach((key, mapping) {
      if (mapping is FeatureProperty) {
        propertyMappingEncoded[key] = {
          'type': 'feature',
          'propertyKey': mapping.propertyKey,
          // Note: transform functions cannot be serialized to native
          // They will be applied on Dart side before sending to native
        };
      } else if (mapping is ConstantValue) {
        propertyMappingEncoded[key] = {
          'type': 'constant',
          'value': mapping.value,
        };
      }
    });

    var paint = {};

    var properties = {
      "id": id,
      "source": sourceId,
      "type": getType(),
      "layout": layout,
      "paint": paint,
      "layoutName": layoutName,
      "propertyMapping": propertyMappingEncoded,
    };

    if (sourceLayer != null) {
      properties["source-layer"] = sourceLayer!;
    }
    if (minZoom != null) {
      properties["minzoom"] = minZoom!;
    }
    if (maxZoom != null) {
      properties["maxzoom"] = maxZoom!;
    }
    if (slot != null) {
      properties["slot"] = slot!;
    }
    if (filter != null) {
      properties["filter"] = filter!;
    }
    if (anchor != null) {
      properties["anchor"] = anchor!.name;
    }
    if (allowOverlap != null) {
      properties["allowOverlap"] = allowOverlap!;
    }
    if (associatedSymbolLayerId != null) {
      properties["associatedSymbolLayerId"] = associatedSymbolLayerId!;
    }

    return json.encode(properties);
  }

  static ViewLayer decode(String properties) {
    var map = json.decode(properties);
    if (map["layout"] == null) {
      map["layout"] = {};
    }
    if (map["paint"] == null) {
      map["paint"] = {};
    }

    // Decode property mapping
    var propertyMappingDecoded = <String, PropertyMapping>{};
    if (map["propertyMapping"] != null) {
      (map["propertyMapping"] as Map<String, dynamic>).forEach((key, value) {
        if (value['type'] == 'feature') {
          propertyMappingDecoded[key] = FeatureProperty(value['propertyKey']);
        } else if (value['type'] == 'constant') {
          propertyMappingDecoded[key] = ConstantValue(value['value']);
        }
      });
    }

    return ViewLayer(
      id: map["id"],
      sourceId: map["source"],
      sourceLayer: map["source-layer"],
      layoutName: map["layoutName"],
      propertyMapping: propertyMappingDecoded,
      minZoom: map["minzoom"]?.toDouble(),
      maxZoom: map["maxzoom"]?.toDouble(),
      slot: map["slot"],
      visibility: map["layout"]["visibility"] == null
          ? Visibility.VISIBLE
          : Visibility.values.firstWhere((e) => e.name
              .toLowerCase()
              .replaceAll("_", "-")
              .contains(map["layout"]["visibility"])),
      visibilityExpression: _optionalCastList(map["layout"]["visibility"]),
      filter: _optionalCastList(map["filter"]),
      anchor: map["anchor"] == null
          ? null
          : ViewAnnotationAnchor.values.firstWhere(
              (e) => e.name == map["anchor"]),
      allowOverlap: map["allowOverlap"],
      associatedSymbolLayerId: map["associatedSymbolLayerId"] as String?,
    );
  }
}

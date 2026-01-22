package com.mapbox.maps.mapbox_maps

import android.os.Handler
import android.os.Looper
import com.mapbox.geojson.Feature
import com.mapbox.geojson.Point
import com.mapbox.maps.CameraChangedCallback
import com.mapbox.maps.MapView
import com.mapbox.maps.MapboxMap
import com.mapbox.maps.RenderedQueryGeometry
import com.mapbox.maps.RenderedQueryOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.common.BasicMessageChannel
import org.json.JSONArray
import org.json.JSONObject

data class ViewLayerConfig(
    val id: String,
    val sourceId: String,
    val sourceLayer: String?,
    val layoutName: String,
    val propertyMapping: Map<String, PropertyMappingConfig>,
    val anchor: String?,
    val allowOverlap: Boolean,
    val filter: List<Any>?,
    val minZoom: Double?,
    val maxZoom: Double?,
    val associatedSymbolLayerId: String?
)

data class PropertyMappingConfig(
    val type: String,  // "feature" or "constant"
    val propertyKey: String?,  // For feature type
    val value: Any?  // For constant type
)

class ViewLayerController(
    private val mapView: MapView,
    private val mapboxMap: MapboxMap,
    private val viewAnnotationController: ViewAnnotationController,
    private val messenger: BinaryMessenger,
    private val channelSuffix: String
) {
    companion object {
        private const val DEBOUNCE_DELAY_MS = 150L
    }

    private val viewLayers = mutableMapOf<String, ViewLayerConfig>()
    private val featureAnnotations = mutableMapOf<String, MutableSet<String>>() // layerId -> Set of annotation IDs
    private val mainHandler = Handler(Looper.getMainLooper())
    private var updatePending = false
    private val visibleFeatureIds = mutableMapOf<String, MutableSet<String>>() // layerId -> Set of feature IDs

    private val cameraListener = CameraChangedCallback {
        scheduleUpdate()
    }

    init {
        setupMethodChannel()
        mapboxMap.subscribeCameraChanged(cameraListener)
    }

    private fun setupMethodChannel() {
        val addChannel = BasicMessageChannel<Any?>(
            "dev.flutter.pigeon.mapbox_maps_flutter.ViewLayerManager.addViewLayer.$channelSuffix",
            StandardMessageCodec(),
            messenger
        )

        addChannel.setMessageHandler { message, reply ->
            try {
                val args = message as? List<*>
                val propertiesJson = args?.get(0) as? String
                    ?: throw Exception("Missing properties argument")

                val config = parseViewLayerConfig(propertiesJson)
                viewLayers[config.id] = config
                featureAnnotations[config.id] = mutableSetOf()
                visibleFeatureIds[config.id] = mutableSetOf()
                scheduleUpdate()

                reply.reply(emptyMap<String, Any>())
            } catch (e: Exception) {
                reply.reply(mapOf("error" to mapOf(
                    "code" to "view_layer_error",
                    "message" to e.message
                )))
            }
        }

        val updateChannel = BasicMessageChannel<Any?>(
            "dev.flutter.pigeon.mapbox_maps_flutter.ViewLayerManager.updateViewLayer.$channelSuffix",
            StandardMessageCodec(),
            messenger
        )

        updateChannel.setMessageHandler { message, reply ->
            try {
                val args = message as? List<*>
                val propertiesJson = args?.get(0) as? String
                    ?: throw Exception("Missing properties argument")

                val config = parseViewLayerConfig(propertiesJson)
                if (!viewLayers.containsKey(config.id)) {
                    throw Exception("ViewLayer '${config.id}' not found")
                }

                viewLayers[config.id] = config
                scheduleUpdate()

                reply.reply(emptyMap<String, Any>())
            } catch (e: Exception) {
                reply.reply(mapOf("error" to mapOf(
                    "code" to "view_layer_error",
                    "message" to e.message
                )))
            }
        }
    }

    private fun parseViewLayerConfig(json: String): ViewLayerConfig {
        val obj = JSONObject(json)

        val propertyMappingJson = obj.optJSONObject("propertyMapping") ?: JSONObject()
        val propertyMapping = mutableMapOf<String, PropertyMappingConfig>()

        propertyMappingJson.keys().forEach { key ->
            val mappingObj = propertyMappingJson.getJSONObject(key)
            propertyMapping[key] = PropertyMappingConfig(
                type = mappingObj.getString("type"),
                propertyKey = mappingObj.optString("propertyKey", null),
                value = if (mappingObj.has("value")) mappingObj.get("value") else null
            )
        }

        return ViewLayerConfig(
            id = obj.getString("id"),
            sourceId = obj.getString("source"),
            sourceLayer = obj.optString("source-layer", null).takeIf { it.isNotEmpty() },
            layoutName = obj.getString("layoutName"),
            propertyMapping = propertyMapping,
            anchor = obj.optString("anchor", null).takeIf { it.isNotEmpty() },
            allowOverlap = obj.optBoolean("allowOverlap", true),
            filter = parseFilter(obj.optJSONArray("filter")),
            minZoom = if (obj.has("minzoom")) obj.getDouble("minzoom") else null,
            maxZoom = if (obj.has("maxzoom")) obj.getDouble("maxzoom") else null,
            associatedSymbolLayerId = obj.optString("associatedSymbolLayerId", null).takeIf { it.isNotEmpty() }
        )
    }

    private fun parseFilter(filterArray: JSONArray?): List<Any>? {
        if (filterArray == null) return null
        val result = mutableListOf<Any>()
        for (i in 0 until filterArray.length()) {
            val item = filterArray.get(i)
            when (item) {
                is JSONArray -> result.add(parseFilter(item) ?: emptyList<Any>())
                is JSONObject -> {
                    val map = mutableMapOf<String, Any>()
                    item.keys().forEach { key ->
                        map[key] = item.get(key)
                    }
                    result.add(map)
                }
                else -> result.add(item)
            }
        }
        return result
    }

    private fun scheduleUpdate() {
        if (updatePending) return

        updatePending = true
        mainHandler.postDelayed({
            updatePending = false
            updateVisibleFeatures()
        }, DEBOUNCE_DELAY_MS)
    }

    private fun updateVisibleFeatures() {
        val currentZoom = mapboxMap.cameraState.zoom

        viewLayers.values.forEach { config ->
            // Check zoom level
            if (config.minZoom != null && currentZoom < config.minZoom) {
                removeAllAnnotationsForLayer(config.id)
                return@forEach
            }
            if (config.maxZoom != null && currentZoom >= config.maxZoom) {
                removeAllAnnotationsForLayer(config.id)
                return@forEach
            }

            // Query rendered features for this layer
            // We need to query a source, but ViewLayers don't exist as actual layers in the map
            // So we query features from the source directly
            queryFeaturesForLayer(config)
        }
    }

    private fun queryFeaturesForLayer(config: ViewLayerConfig) {
        try {
            // Query rendered features - use null layerIds to query all layers,
            // then filter by source and sourceLayer below
            val options = RenderedQueryOptions(
                null,  // Query all layers, filter by source below
                config.filter
            )

            // Query entire viewport using screen bounds
            val screenBox = com.mapbox.maps.ScreenBox(
                com.mapbox.maps.ScreenCoordinate(0.0, 0.0),
                com.mapbox.maps.ScreenCoordinate(
                    mapView.width.toDouble(),
                    mapView.height.toDouble()
                )
            )

            mapboxMap.queryRenderedFeatures(screenBox, options) { expected ->
                expected.value?.let { queriedFeatures ->
                    val currentFeatureIds = mutableSetOf<String>()
                    val previousFeatureIds = visibleFeatureIds[config.id] ?: mutableSetOf()
                    val useLayerFeatureBinding = config.associatedSymbolLayerId != null

                    queriedFeatures.forEach { queriedFeature ->
                        // Filter by source
                        if (queriedFeature.queriedFeature.source != config.sourceId) {
                            return@forEach
                        }

                        // Filter by sourceLayer if specified
                        if (config.sourceLayer != null &&
                            queriedFeature.queriedFeature.sourceLayer != config.sourceLayer) {
                            return@forEach
                        }

                        val feature = queriedFeature.queriedFeature.feature

                        // Get the namespaced feature ID for tracking
                        val featureId = getFeatureId(
                            feature,
                            config.sourceLayer,
                            requireExplicit = useLayerFeatureBinding
                        )

                        if (featureId == null) {
                            return@forEach
                        }

                        currentFeatureIds.add(featureId)

                        // If this is a new feature, create annotation
                        if (!previousFeatureIds.contains(featureId)) {
                            // Get raw feature ID for layer feature binding
                            val rawFeatureId: String? = if (useLayerFeatureBinding) {
                                getFeatureId(feature, config.sourceLayer, requireExplicit = true, rawId = true)
                            } else null

                            createAnnotationForFeature(config, feature, featureId, rawFeatureId)
                        }
                    }

                    // Remove annotations for features no longer visible
                    val removedFeatures = previousFeatureIds - currentFeatureIds
                    removedFeatures.forEach { featureId ->
                        removeAnnotationForFeature(config.id, featureId)
                    }

                    visibleFeatureIds[config.id] = currentFeatureIds
                }

                // Errors are silently ignored
            }
        } catch (e: Exception) {
            // Errors are silently ignored
        }
    }

    /**
     * Gets the feature ID for annotation tracking.
     * @param feature The map feature
     * @param sourceLayer The source layer name for namespacing
     * @param requireExplicit If true, returns null when no explicit ID is found (no coordinate fallback)
     * @param rawId If true, returns just the raw ID without sourceLayer prefix (for layer feature binding)
     *
     * IMPORTANT: When using `associatedSymbolLayerId` for layer feature binding, do NOT use
     * `promoteId` on the source. The Mapbox SDK's `.layerFeature()` binding mechanism is
     * incompatible with promoteId - it cannot find features when promoteId is set.
     */
    private fun getFeatureId(feature: Feature, sourceLayer: String?, requireExplicit: Boolean = false, rawId: Boolean = false): String? {
        // Try to get feature ID
        val featureId = feature.id() ?: feature.getStringProperty("id")

        return if (featureId != null) {
            if (rawId) featureId else "${sourceLayer ?: "default"}_$featureId"
        } else if (!requireExplicit) {
            // Only use coordinate fallback if not requiring explicit IDs
            val geometry = feature.geometry()
            if (geometry is Point) {
                "${sourceLayer ?: "default"}_${geometry.longitude()}_${geometry.latitude()}"
            } else {
                null
            }
        } else {
            null
        }
    }

    /**
     * Creates an annotation for a feature.
     * @param config The ViewLayer configuration
     * @param feature The map feature
     * @param featureId The namespaced feature ID for tracking (e.g., "sourceLayer_123")
     * @param rawFeatureId The raw feature ID for layer feature binding (e.g., "123"). Only needed when using associatedSymbolLayerId.
     */
    private fun createAnnotationForFeature(config: ViewLayerConfig, feature: Feature, featureId: String, rawFeatureId: String? = null) {
        val geometry = feature.geometry()
        if (geometry !is Point) {
            return
        }

        // Map feature properties to view data using property mapping
        val viewData = mutableMapOf<String, Any?>()
        config.propertyMapping.forEach { (dataKey, mapping) ->
            when (mapping.type) {
                "feature" -> {
                    mapping.propertyKey?.let { propKey ->
                        // Get property from feature
                        val value = feature.getProperty(propKey)
                        viewData[dataKey] = value?.asString ?: value?.asJsonPrimitive
                    }
                }
                "constant" -> {
                    viewData[dataKey] = mapping.value
                }
            }
        }

        val annotationId = "${config.id}_$featureId"

        // Use layer feature binding if associatedSymbolLayerId is set
        if (config.associatedSymbolLayerId != null && rawFeatureId != null) {
            viewAnnotationController.addWithLayerFeature(
                id = annotationId,
                layoutName = config.layoutName,
                associatedLayerId = config.associatedSymbolLayerId,
                featureId = rawFeatureId,
                data = viewData,
                anchor = config.anchor,
                allowOverlap = config.allowOverlap
            )
        } else {
            // Fallback to coordinate-based (legacy behavior)
            viewAnnotationController.add(
                id = annotationId,
                layoutName = config.layoutName,
                latitude = geometry.latitude(),
                longitude = geometry.longitude(),
                data = viewData,
                anchor = config.anchor,
                allowOverlap = config.allowOverlap
            )
        }

        featureAnnotations[config.id]?.add(annotationId)
    }

    private fun removeAnnotationForFeature(layerId: String, featureId: String) {
        val annotationId = "${layerId}_$featureId"
        viewAnnotationController.remove(annotationId)
        featureAnnotations[layerId]?.remove(annotationId)
    }

    private fun removeAllAnnotationsForLayer(layerId: String) {
        featureAnnotations[layerId]?.toList()?.forEach { annotationId ->
            viewAnnotationController.remove(annotationId)
        }
        featureAnnotations[layerId]?.clear()
        visibleFeatureIds[layerId]?.clear()
    }

    fun dispose() {
        mapboxMap.unsubscribeCameraChanged(cameraListener)
        viewLayers.keys.forEach { layerId ->
            removeAllAnnotationsForLayer(layerId)
        }
        viewLayers.clear()
        featureAnnotations.clear()
        visibleFeatureIds.clear()
    }
}

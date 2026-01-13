package com.mapbox.maps.mapbox_maps

import android.os.Handler
import android.os.Looper
import android.util.Log
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
    val maxZoom: Double?
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
        private const val TAG = "ViewLayerController"
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

                Log.d(TAG, "Added ViewLayer: ${config.id}")
                scheduleUpdate()

                reply.reply(emptyMap<String, Any>())
            } catch (e: Exception) {
                Log.e(TAG, "Error adding ViewLayer", e)
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
                Log.d(TAG, "Updated ViewLayer: ${config.id}")
                scheduleUpdate()

                reply.reply(emptyMap<String, Any>())
            } catch (e: Exception) {
                Log.e(TAG, "Error updating ViewLayer", e)
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
            maxZoom = if (obj.has("maxzoom")) obj.getDouble("maxzoom") else null
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
            // Query features from the source
            val options = RenderedQueryOptions(
                listOf(config.sourceId),
                config.filter
            )

            // Query entire viewport
            val geometry = RenderedQueryGeometry(mapboxMap.pixelForCoordinate(
                mapboxMap.cameraState.center
            ))

            mapboxMap.queryRenderedFeatures(geometry, options) { expected ->
                expected.value?.let { queriedFeatures ->
                    val currentFeatureIds = mutableSetOf<String>()
                    val previousFeatureIds = visibleFeatureIds[config.id] ?: mutableSetOf()

                    queriedFeatures.forEach { queriedFeature ->
                        val feature = queriedFeature.queriedFeature.feature
                        val featureId = getFeatureId(feature, config.sourceLayer)

                        if (featureId != null) {
                            currentFeatureIds.add(featureId)

                            // If this is a new feature, create annotation
                            if (!previousFeatureIds.contains(featureId)) {
                                createAnnotationForFeature(config, feature, featureId)
                            }
                        }
                    }

                    // Remove annotations for features no longer visible
                    val removedFeatures = previousFeatureIds - currentFeatureIds
                    removedFeatures.forEach { featureId ->
                        removeAnnotationForFeature(config.id, featureId)
                    }

                    visibleFeatureIds[config.id] = currentFeatureIds
                }

                expected.error?.let { error ->
                    Log.e(TAG, "Error querying features for layer ${config.id}: $error")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error querying features for layer ${config.id}", e)
        }
    }

    private fun getFeatureId(feature: Feature, sourceLayer: String?): String? {
        // Try to get feature ID
        val featureId = feature.id() ?: feature.getStringProperty("id")

        // If no ID, create one from geometry and properties
        return if (featureId != null) {
            "${sourceLayer ?: "default"}_$featureId"
        } else {
            // Use geometry coordinates as fallback ID
            val geometry = feature.geometry()
            if (geometry is Point) {
                "${sourceLayer ?: "default"}_${geometry.longitude()}_${geometry.latitude()}"
            } else {
                null
            }
        }
    }

    private fun createAnnotationForFeature(config: ViewLayerConfig, feature: Feature, featureId: String) {
        val geometry = feature.geometry()
        if (geometry !is Point) {
            Log.w(TAG, "ViewLayer only supports Point geometries, skipping feature")
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

        viewAnnotationController.add(
            id = annotationId,
            layoutName = config.layoutName,
            latitude = geometry.latitude(),
            longitude = geometry.longitude(),
            data = viewData,
            anchor = config.anchor,
            allowOverlap = config.allowOverlap
        )

        featureAnnotations[config.id]?.add(annotationId)
        Log.d(TAG, "Created annotation $annotationId for feature $featureId")
    }

    private fun removeAnnotationForFeature(layerId: String, featureId: String) {
        val annotationId = "${layerId}_$featureId"
        viewAnnotationController.remove(annotationId)
        featureAnnotations[layerId]?.remove(annotationId)
        Log.d(TAG, "Removed annotation $annotationId")
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

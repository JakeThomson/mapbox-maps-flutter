package com.mapbox.maps.mapbox_maps

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.mapbox.common.Cancelable
import com.mapbox.geojson.Feature
import com.mapbox.geojson.Point
import com.mapbox.maps.CameraChangedCallback
import com.mapbox.maps.MapIdleCallback
import com.mapbox.maps.MapView
import com.mapbox.maps.MapboxMap
import com.mapbox.maps.RenderedQueryGeometry
import com.mapbox.maps.SourceDataLoadedCallback
import com.mapbox.maps.mapbox_maps.pigeons.RenderedQueryOptions
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
    val associatedSymbolLayerId: String?,
    val maxVisibleAnnotations: Int?,
    val imageCacheKeys: List<String>?,
    val imageCachePadding: Double?,
    val useImageMode: Boolean
)

data class PropertyMappingConfig(
    val type: String,  // "feature" or "constant"
    val propertyKey: String?,  // For feature type
    val value: Any?  // For constant type
)

data class PromotedFeatureInfo(
    val configId: String,
    val sourceId: String,
    val sourceLayer: String?,
    val rawFeatureId: String
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
        private const val TAG = "ViewLayerPerf"
    }

    private val viewLayers = mutableMapOf<String, ViewLayerConfig>()
    private val featureAnnotations = mutableMapOf<String, MutableSet<String>>() // layerId -> Set of annotation IDs
    private val mainHandler = Handler(Looper.getMainLooper())
    private var updatePending = false
    private val visibleFeatureIds = mutableMapOf<String, MutableSet<String>>() // layerId -> Set of feature IDs

    // Time-based grace period
    private val hiddenTimestamps = mutableMapOf<String, MutableMap<String, Long>>() // layerId -> featureId -> hide time (elapsedRealtime)
    private val hiddenAnnotations = mutableMapOf<String, MutableSet<String>>() // layerId -> Set of featureIds currently hidden
    private val maxHiddenPerLayer = 200
    private val graceDurationMs = 5000L

    // Staggered batch creation
    private data class PendingCreate(
        val config: ViewLayerConfig,
        val feature: Feature,
        val featureId: String,
        val rawFeatureId: String?
    )
    private val pendingCreations = mutableListOf<PendingCreate>()
    private val maxCreatesPerFrame = 15
    private var isDrainingCreationQueue = false

    // Staggered image-mode rendering
    private data class PendingImageRender(
        val config: ViewLayerConfig,
        val cacheKey: String,
        val viewData: Map<String, Any?>,
        val padding: Float
    )
    private val pendingImageRenders = mutableListOf<PendingImageRender>()
    private data class RenderedImageResult(val cacheKey: String, val bitmap: Bitmap)
    private val pendingImageResults = mutableListOf<RenderedImageResult>()
    private var isImageRenderBatchActive = false
    private val maxImageRendersPerFrame = 8
    private var activeImageBatchConfig: ViewLayerConfig? = null
    private var activeImageBatchSymbolLayerId: String? = null

    // Churn detection
    private val recentlyRemoved = mutableMapOf<String, MutableMap<String, Long>>() // layerId -> featureId -> remove time
    private var periodChurnCount = 0

    // Image mode: style image tracking
    private val registeredStyleImages = mutableMapOf<String, MutableSet<String>>()  // layerId -> set of registered style image IDs
    private val imageModeExpressionSet = mutableSetOf<String>()  // layers where iconImage expression has been set
    private val imageModeFeatureMapping = mutableMapOf<String, MutableMap<String, String>>()  // layerId → (featureId → imageName)

    // Promote/demote: tracking promoted features (image-mode → live ViewAnnotation)
    private val promotedFeatures = mutableMapOf<String, PromotedFeatureInfo>()  // annotationId -> info
    private val opacityExpressionSet = mutableSetOf<String>()  // layers where opacity expressions have been set
    private val pendingDemotions = mutableMapOf<String, Runnable>()  // annotationId -> delayed cleanup runnable

    // Image mode: initial batch tracking (hide symbol layer until first images render)
    private val imageModeInitialBatchDone = mutableSetOf<String>()
    private var needsImmediateUpdate = false

    private var cameraChangedCancelable: Cancelable? = null
    private var sourceDataCancelable: Cancelable? = null
    private var mapIdleCancelable: Cancelable? = null

    init {
        setupMethodChannel()
        cameraChangedCancelable = mapboxMap.subscribeCameraChanged(CameraChangedCallback {
            scheduleUpdate()
        })
        sourceDataCancelable = mapboxMap.subscribeSourceDataLoaded(SourceDataLoadedCallback { event ->
            val sourceId = event.sourceId
            val hasAffectedLayers = viewLayers.values.any { it.sourceId == sourceId }
            if (hasAffectedLayers) {
                Log.d(TAG, "ViewLayerController: sourceDataLoaded | source=$sourceId, type=${event.type}, scheduling delayed update (400ms)")
                mainHandler.postDelayed({
                    updateVisibleFeatures()
                }, 400L)
            }
        })
        mapIdleCancelable = mapboxMap.subscribeMapIdle(MapIdleCallback {
            val hasClusterLayers = viewLayers.values.any { it.id.contains("cluster") }
            if (hasClusterLayers) {
                updateVisibleFeatures()
            }
        })
    }

    private fun setupMethodChannel() {
        val addChannel = BasicMessageChannel<Any?>(
            messenger,
            "dev.flutter.pigeon.mapbox_maps_flutter.ViewLayerManager.addViewLayer.$channelSuffix",
            StandardMessageCodec()
        )

        addChannel.setMessageHandler { message, reply ->
            try {
                val args = message as? List<*>
                val propertiesJson = args?.get(0) as? String
                    ?: throw Exception("Missing properties argument")

                val config = parseViewLayerConfig(propertiesJson)
                Log.d(TAG, "addViewLayer PARSED | id=${config.id} useImageMode=${config.useImageMode} imageCacheKeys=${config.imageCacheKeys} isImageMode=${isImageMode(config)}")
                viewLayers[config.id] = config
                featureAnnotations[config.id] = mutableSetOf()
                visibleFeatureIds[config.id] = mutableSetOf()

                // Register image-mode layer for tap fallback
                if (isImageMode(config) && config.associatedSymbolLayerId != null) {
                    viewAnnotationController.registerImageModeLayer(ImageModeLayerConfig(
                        symbolLayerId = config.associatedSymbolLayerId,
                        viewLayerId = config.id,
                        sourceId = config.sourceId,
                        sourceLayer = config.sourceLayer,
                        propertyMapping = config.propertyMapping
                    ))

                    // Hide symbol layer until first image batch completes
                    val style = mapboxMap.getStyle()
                    style?.setStyleLayerProperty(config.associatedSymbolLayerId, "icon-opacity", com.mapbox.bindgen.Value.valueOf(0.0))
                    style?.setStyleLayerProperty(config.associatedSymbolLayerId, "text-opacity", com.mapbox.bindgen.Value.valueOf(0.0))

                    // Eagerly set icon-image expression so features participate in queries
                    // Only for explicit keys (concat path); hash path sets expression in first handleImageModeFeatures cycle
                    val effectiveKeys = getEffectiveKeys(config)
                    if (effectiveKeys != null) {
                        val (_, exprKeys) = effectiveKeys
                        val parts = mutableListOf<Any>()
                        parts.add("concat")
                        parts.add("${config.layoutName}_")
                        for ((i, key) in exprKeys.withIndex()) {
                            if (i > 0) parts.add("_")
                            parts.add(listOf("get", key))
                        }
                        val expressionJson = org.json.JSONArray(parts).toString()
                        Log.d(TAG, "addViewLayer ICON_IMAGE_EXPR | layer=${config.id} expression=$expressionJson")
                        val expressionValue = com.mapbox.bindgen.Value.fromJson(expressionJson)
                        if (!expressionValue.isError) {
                            val setResult = style?.setStyleLayerProperty(config.associatedSymbolLayerId, "icon-image", expressionValue.value!!)
                            Log.d(TAG, "addViewLayer ICON_IMAGE_SET | layer=${config.id} symbolLayer=${config.associatedSymbolLayerId} error=${setResult?.isError} errorMsg=${setResult?.error}")
                            imageModeExpressionSet.add(config.id)
                        } else {
                            Log.w(TAG, "addViewLayer ICON_IMAGE_PARSE_FAIL | layer=${config.id} error=${expressionValue.error}")
                        }
                    }

                    needsImmediateUpdate = true
                }

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
            messenger,
            "dev.flutter.pigeon.mapbox_maps_flutter.ViewLayerManager.updateViewLayer.$channelSuffix",
            StandardMessageCodec()
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

        val removeChannel = BasicMessageChannel<Any?>(
            messenger,
            "dev.flutter.pigeon.mapbox_maps_flutter.ViewLayerManager.removeViewLayer.$channelSuffix",
            StandardMessageCodec()
        )

        removeChannel.setMessageHandler { message, reply ->
            try {
                val args = message as? List<*>
                val layerId = args?.get(0) as? String
                    ?: throw Exception("Missing layerId argument")

                val config = viewLayers[layerId]
                    ?: throw Exception("ViewLayer '$layerId' not found")

                // Clean up all annotations for this layer
                removeAllAnnotationsForLayer(layerId)

                // Cancel any in-progress image render batch for this layer
                if (activeImageBatchConfig?.id == layerId) {
                    pendingImageRenders.clear()
                    pendingImageResults.clear()
                    isImageRenderBatchActive = false
                    activeImageBatchConfig = null
                    activeImageBatchSymbolLayerId = null
                }

                // Unregister image-mode layer from ViewAnnotationController
                if (config.associatedSymbolLayerId != null && isImageMode(config)) {
                    viewAnnotationController.unregisterImageModeLayer(config.associatedSymbolLayerId)
                }

                // Remove the layer config
                viewLayers.remove(layerId)
                featureAnnotations.remove(layerId)
                visibleFeatureIds.remove(layerId)
                hiddenTimestamps.remove(layerId)
                hiddenAnnotations.remove(layerId)

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
        Log.d(TAG, "parseViewLayerConfig RAW_JSON: $json")
        Log.d(TAG, "parseViewLayerConfig useImageMode_RAW: has=${obj.has("useImageMode")} rawValue=${obj.opt("useImageMode")} rawType=${obj.opt("useImageMode")?.javaClass?.simpleName} optBoolean=${obj.optBoolean("useImageMode", false)}")

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
            associatedSymbolLayerId = obj.optString("associatedSymbolLayerId", null).takeIf { it.isNotEmpty() },
            maxVisibleAnnotations = if (obj.has("maxVisibleAnnotations")) obj.getInt("maxVisibleAnnotations") else null,
            imageCacheKeys = obj.optJSONArray("imageCacheKeys")?.let { arr ->
                (0 until arr.length()).map { arr.getString(it) }
            },
            imageCachePadding = if (obj.has("imageCachePadding")) obj.getDouble("imageCachePadding") else null,
            useImageMode = obj.optBoolean("useImageMode", false)
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

    private fun isImageMode(config: ViewLayerConfig): Boolean =
        config.useImageMode || config.imageCacheKeys != null

    /**
     * Returns (dataKeys, expressionKeys) for property-based image cache keys.
     * Only used when imageCacheKeys is explicitly provided.
     * When null, the hash-based match expression path is used instead.
     */
    private fun getEffectiveKeys(config: ViewLayerConfig): Pair<List<String>, List<String>>? {
        if (config.imageCacheKeys != null) {
            return config.imageCacheKeys to config.imageCacheKeys
        }
        return null
    }

    /**
     * Computes a hex hash of the view data dictionary for use as a stable image cache key.
     * Sorts keys and normalizes numeric values (whole-number doubles drop ".0").
     */
    private fun computeViewDataHash(data: Map<String, Any?>): String {
        val combined = StringBuilder()
        for (key in data.keys.sorted()) {
            val value = data[key]
            val normalized: String = when {
                value == null -> "nil"
                else -> {
                    val str = value.toString()
                    val d = str.toDoubleOrNull()
                    if (d != null && d == Math.floor(d) && !d.isInfinite()) {
                        d.toLong().toString()
                    } else {
                        str
                    }
                }
            }
            combined.append("$key=$normalized;")
        }
        return (combined.toString().hashCode().toLong() and 0xFFFFFFFFL).toString(16)
    }

    private fun scheduleUpdate() {
        if (updatePending) {
            Log.d(TAG, "ViewLayerController: scheduleUpdate SKIPPED | already pending")
            return
        }

        updatePending = true

        if (needsImmediateUpdate) {
            needsImmediateUpdate = false
            Log.d(TAG, "ViewLayerController: scheduleUpdate IMMEDIATE | bypassing debounce for initial image-mode load")
            mainHandler.post {
                updatePending = false
                updateVisibleFeatures()
            }
        } else {
            Log.d(TAG, "ViewLayerController: scheduleUpdate SCHEDULED | delay=${DEBOUNCE_DELAY_MS}ms")
            mainHandler.postDelayed({
                updatePending = false
                updateVisibleFeatures()
            }, DEBOUNCE_DELAY_MS)
        }
    }

    private fun updateVisibleFeatures() {
        val currentZoom = mapboxMap.cameraState.zoom
        Log.d(TAG, "ViewLayerController: updateVisibleFeatures START | zoom=%.2f, layers=${viewLayers.size}".format(currentZoom))

        viewLayers.values.forEach { config ->
            // Check zoom level
            if (config.minZoom != null && currentZoom < config.minZoom) {
                Log.d(TAG, "ViewLayerController: ZOOM_OUT_OF_RANGE | layer=${config.id} zoom=$currentZoom < minZoom=${config.minZoom}")
                removeAllAnnotationsForLayer(config.id)
                return@forEach
            }
            if (config.maxZoom != null && currentZoom >= config.maxZoom) {
                Log.d(TAG, "ViewLayerController: ZOOM_OUT_OF_RANGE | layer=${config.id} zoom=$currentZoom >= maxZoom=${config.maxZoom}")
                removeAllAnnotationsForLayer(config.id)
                return@forEach
            }

            queryFeaturesForLayer(config)
        }
    }

    private fun queryFeaturesForLayer(config: ViewLayerConfig) {
        try {
            val queryStartTime = SystemClock.elapsedRealtime()
            Log.d(TAG, "ViewLayerController: queryFeatures START | layer=${config.id}")

            // Image-mode layers go through querySourceFeatures so we see every
            // feature in the loaded tiles, not just the ones that are currently
            // rendered. queryRenderedFeatures has a chicken-and-egg problem with
            // symbols whose icon-image expression resolves to a yet-unregistered
            // cache key AND whose text-field renders nothing — the symbol is
            // invisible, queryRenderedFeatures skips it, the icon never registers,
            // and the pin stays blank forever. Mirrors the iOS controller.
            if (isImageMode(config)) {
                querySourceFeaturesForImageMode(config, queryStartTime)
                return
            }

            // Convert filter list to JSON string for pigeon RenderedQueryOptions
            val filterString: String? = config.filter?.let {
                JSONArray(it).toString()
            }

            val pigeonOptions = RenderedQueryOptions(
                config.associatedSymbolLayerId?.let { listOf(it) },
                filterString
            )
            val options = pigeonOptions.toRenderedQueryOptions()

            // Query entire viewport using screen bounds
            val screenBox = com.mapbox.maps.ScreenBox(
                com.mapbox.maps.ScreenCoordinate(0.0, 0.0),
                com.mapbox.maps.ScreenCoordinate(
                    mapView.width.toDouble(),
                    mapView.height.toDouble()
                )
            )

            mapboxMap.queryRenderedFeatures(
                RenderedQueryGeometry.valueOf(screenBox),
                options
            ) { expected ->
                val queryDuration = SystemClock.elapsedRealtime() - queryStartTime

                if (expected.isError) {
                    Log.w(TAG, "ViewLayerController: queryFeatures ERROR | layer=${config.id}, duration=${queryDuration}ms, error=${expected.error}")
                    return@queryRenderedFeatures
                }

                expected.value?.let { queriedRenderedFeatures ->
                    // --- Image mode short-circuit: render to style images, skip ViewAnnotations ---
                    val imageModeBranch = isImageMode(config)
                    Log.d(TAG, "queryFeatures BRANCH_DECISION | layer=${config.id} useImageMode=${config.useImageMode} imageCacheKeys=${config.imageCacheKeys} takingImageModePath=$imageModeBranch")
                    if (imageModeBranch) {
                        handleImageModeRenderedFeatures(config, queriedRenderedFeatures)
                        return@let
                    }

                    val now = SystemClock.elapsedRealtime()
                    val currentFeatureIds = mutableSetOf<String>()
                    val previousFeatureIds = visibleFeatureIds[config.id] ?: mutableSetOf()
                    val currentHidden = hiddenAnnotations[config.id] ?: mutableSetOf()
                    val useLayerFeatureBinding = config.associatedSymbolLayerId != null
                    var queuedCount = 0
                    var unhiddenCount = 0

                    // Collect all valid feature IDs + features from the query
                    val queriedFeatureMap = mutableListOf<Pair<String, Feature>>()

                    queriedRenderedFeatures.forEach { queriedRendered ->
                        val queriedFeature = queriedRendered.queriedFeature

                        if (queriedFeature.source != config.sourceId) {
                            return@forEach
                        }

                        if (config.sourceLayer != null &&
                            queriedFeature.sourceLayer != config.sourceLayer) {
                            return@forEach
                        }

                        val feature = queriedFeature.feature
                        val featureId = getFeatureId(
                            feature,
                            config.sourceLayer,
                            requireExplicit = useLayerFeatureBinding
                        ) ?: return@forEach

                        queriedFeatureMap.add(featureId to feature)
                    }

                    // Cap max visible annotations — truncate to first N from query (render/z-order)
                    val cappedFeatures = if (config.maxVisibleAnnotations != null && queriedFeatureMap.size > config.maxVisibleAnnotations) {
                        queriedFeatureMap.take(config.maxVisibleAnnotations)
                    } else {
                        queriedFeatureMap
                    }

                    for ((featureId, feature) in cappedFeatures) {
                        currentFeatureIds.add(featureId)

                        // Feature reappeared from hidden state — unhide and clear timestamp
                        if (currentHidden.contains(featureId)) {
                            val annotationId = "${config.id}_$featureId"
                            viewAnnotationController.setVisible(annotationId, true)
                            hiddenAnnotations[config.id]?.remove(featureId)
                            hiddenTimestamps[config.id]?.remove(featureId)
                            unhiddenCount++
                            continue
                        }

                        if (!previousFeatureIds.contains(featureId)) {
                            queuedCount++
                            val rawFeatureId: String? = if (useLayerFeatureBinding) {
                                getFeatureId(feature, config.sourceLayer, requireExplicit = true, rawId = true)
                            } else null

                            // Staggered creation — enqueue instead of creating inline
                            pendingCreations.add(PendingCreate(config, feature, featureId, rawFeatureId))
                        }
                    }

                    // Process removals with time-based grace period
                    val removedFeatures = previousFeatureIds - currentFeatureIds
                    var hiddenCount = 0
                    var actualRemovedCount = 0

                    removedFeatures.forEach { featureId ->
                        if (currentHidden.contains(featureId)) {
                            // Already hidden — check if grace period expired
                            val hideTime = hiddenTimestamps[config.id]?.get(featureId)
                            if (hideTime != null && now - hideTime >= graceDurationMs) {
                                // Grace period expired — actually remove
                                removeAnnotationForFeature(config.id, featureId)
                                hiddenAnnotations[config.id]?.remove(featureId)
                                hiddenTimestamps[config.id]?.remove(featureId)
                                actualRemovedCount++
                            }
                            // Otherwise keep hidden, still within grace period
                            return@forEach
                        }

                        // First time absent — immediately hide and record timestamp
                        val annotationId = "${config.id}_$featureId"
                        viewAnnotationController.setVisible(annotationId, false)
                        hiddenAnnotations.getOrPut(config.id) { mutableSetOf() }.add(featureId)
                        hiddenTimestamps.getOrPut(config.id) { mutableMapOf() }[featureId] = now
                        hiddenCount++
                    }

                    // Enforce max hidden per layer — remove oldest hidden if over limit
                    val timestamps = hiddenTimestamps[config.id]
                    if (timestamps != null && timestamps.size > maxHiddenPerLayer) {
                        val sorted = timestamps.entries.sortedBy { it.value }
                        val excess = sorted.size - maxHiddenPerLayer
                        for (i in 0 until excess) {
                            val featureId = sorted[i].key
                            removeAnnotationForFeature(config.id, featureId)
                            hiddenAnnotations[config.id]?.remove(featureId)
                            hiddenTimestamps[config.id]?.remove(featureId)
                            actualRemovedCount++
                        }
                    }

                    // Keep hidden features in visibleFeatureIds so they aren't re-created
                    val hiddenFeatureIds = hiddenAnnotations[config.id] ?: mutableSetOf()
                    val combined = mutableSetOf<String>()
                    combined.addAll(currentFeatureIds)
                    combined.addAll(hiddenFeatureIds)

                    // Also add pending creation featureIds to prevent duplicate creation
                    pendingCreations.filter { it.config.id == config.id }.forEach { combined.add(it.featureId) }

                    visibleFeatureIds[config.id] = combined

                    if (unhiddenCount > 0) {
                        Log.d(TAG, "VISIBILITY_RESTORE layer=${config.id} restored=$unhiddenCount")
                    }
                    if (hiddenCount > 0) {
                        Log.d(TAG, "GRACE_HIDE layer=${config.id} hidden=$hiddenCount")
                    }

                    Log.d(TAG, "BATCH layer=${config.id} queryMs=${queryDuration} queued=$queuedCount hidden=$hiddenCount restored=$unhiddenCount removed=$actualRemovedCount total=${featureAnnotations[config.id]?.size ?: 0}")

                    // Start draining the creation queue
                    drainCreationQueue()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "ViewLayerController: queryFeatures EXCEPTION | layer=${config.id}, error=${e.message}")
        }
    }

    // region Image mode (style image rendering)

    /**
     * Queries source features for image-mode layers. Bypasses the chicken-
     * and-egg in queryRenderedFeatures (where un-rendered symbols don't
     * appear so their icons never register).
     */
    private fun querySourceFeaturesForImageMode(config: ViewLayerConfig, queryStartTime: Long) {
        val sourceLayerIds: List<String>? = config.sourceLayer?.let { listOf(it) }
        // Always-true filter — source-feature queries require a non-optional
        // filter expression.
        val options = com.mapbox.maps.SourceQueryOptions(
            sourceLayerIds,
            com.mapbox.bindgen.Value.valueOf(true)
        )

        mapboxMap.querySourceFeatures(config.sourceId, options) { expected ->
            val queryDuration = SystemClock.elapsedRealtime() - queryStartTime

            if (expected.isError) {
                Log.w(TAG, "ViewLayerController: queryFeatures ERROR | layer=${config.id}, duration=${queryDuration}ms, error=${expected.error} (source-query path)")
                return@querySourceFeatures
            }

            // Whatever is loaded in the source tiles — can include features
            // outside the viewport. The symbol layer's own viewport-based
            // collision keeps the on-screen behavior sane.
            val features = expected.value?.map { it.queriedFeature.feature } ?: emptyList()
            Log.d(TAG, "QUERY_COUNT layer=${config.id} symbolLayer=${config.associatedSymbolLayerId ?: "(nil)"} rendered=0 source=${features.size} queryMs=$queryDuration")
            handleImageModeFeatures(config, features)
        }
    }

    /**
     * Convenience: extract raw Features from a rendered-feature query and
     * forward to the main impl. Used by the legacy non-source query path.
     *
     * Named distinctly rather than overloaded: `List<QueriedRenderedFeature>`
     * and `List<Feature>` erase to the same JVM signature, and the Kotlin
     * compiler rejects the pair as a platform declaration clash.
     */
    private fun handleImageModeRenderedFeatures(config: ViewLayerConfig, queriedRenderedFeatures: List<com.mapbox.maps.QueriedRenderedFeature>) {
        val features = queriedRenderedFeatures.mapNotNull { queriedRendered ->
            val queriedFeature = queriedRendered.queriedFeature
            if (queriedFeature.source != config.sourceId) return@mapNotNull null
            if (config.sourceLayer != null && queriedFeature.sourceLayer != config.sourceLayer) return@mapNotNull null
            queriedFeature.feature
        }
        handleImageModeFeatures(config, features)
    }

    // region Phase 1: Data extraction (cheap, synchronous)
    private fun handleImageModeFeatures(config: ViewLayerConfig, features: List<Feature>) {
        val symbolLayerId = config.associatedSymbolLayerId ?: return
        val effectiveKeys = getEffectiveKeys(config)
        val useFeatureIds = effectiveKeys == null

        // If a batch is already active for this layer, cancel it and restart with fresh data
        if (isImageRenderBatchActive && activeImageBatchConfig?.id == config.id) {
            pendingImageRenders.clear()
            pendingImageResults.clear()
            isImageRenderBatchActive = false
            Log.d(TAG, "IMAGE_BATCH_CANCELLED layer=${config.id} (superseded by new query)")
        }

        val existingImages = registeredStyleImages.getOrPut(config.id) { mutableSetOf() }
        Log.d(TAG, "handleImageMode START | layer=${config.id} useFeatureIds=$useFeatureIds existingImagesCount=${existingImages.size} features=${features.size}")

        val pendingItems = mutableListOf<PendingImageRender>()
        val currentCycleMapping = mutableMapOf<String, String>()  // featureId → imageName (for hash-based match expression)

        for (feature in features) {
            // Build data from property mapping
            val viewData = mutableMapOf<String, Any?>()
            config.propertyMapping.forEach { (dataKey, mapping) ->
                when (mapping.type) {
                    "feature" -> {
                        mapping.propertyKey?.let { propKey ->
                            val value = feature.getProperty(propKey)
                            viewData[dataKey] = value?.asString ?: value?.asJsonPrimitive
                        }
                    }
                    "constant" -> viewData[dataKey] = mapping.value
                }
            }

            val cacheKey: String
            if (useFeatureIds) {
                val featureId = feature.id() ?: continue
                val hash = computeViewDataHash(viewData)
                cacheKey = "${config.layoutName}_$hash"
                currentCycleMapping[featureId] = cacheKey
            } else {
                cacheKey = viewAnnotationController.computeImageCacheKey(config.layoutName, viewData, effectiveKeys!!.first)
            }
            if (existingImages.contains(cacheKey)) continue
            if (pendingItems.any { it.cacheKey == cacheKey }) continue

            val padding = (config.imageCachePadding ?: 0.0).toFloat()
            pendingItems.add(PendingImageRender(config, cacheKey, viewData, padding))
        }

        // For hash-based path: update mapping and set match expression every cycle
        if (useFeatureIds) {
            setHashBasedMatchExpression(config, symbolLayerId, currentCycleMapping)
        }

        if (pendingItems.isEmpty()) {
            // No new images needed — set expression and reveal immediately
            if (!useFeatureIds) {
                setIconImageExpression(config, symbolLayerId, effectiveKeys?.second)
            }
            revealImageModeLayerIfNeeded(config, symbolLayerId)
            Log.d(TAG, "IMAGE_MODE_BATCH layer=${config.id} newImages=0 totalImages=${existingImages.size}")
            return
        }

        // Queue for staggered rendering
        pendingImageRenders.clear()
        pendingImageRenders.addAll(pendingItems)
        pendingImageResults.clear()
        isImageRenderBatchActive = true
        activeImageBatchConfig = config
        activeImageBatchSymbolLayerId = symbolLayerId
        Log.d(TAG, "IMAGE_BATCH_QUEUED layer=${config.id} count=${pendingItems.size}")
        drainImageRenderQueue()
    }
    // endregion

    // region Phase 2: Staggered rendering (main thread, batched across frames)
    private fun drainImageRenderQueue() {
        if (!isImageRenderBatchActive) return

        // Fast path: if an image factory is registered, render ALL pending items on a background thread
        val config = activeImageBatchConfig
        if (config != null && ViewAnnotationRegistry.hasImageFactory(config.layoutName)) {
            val allPending = ArrayList(pendingImageRenders)
            pendingImageRenders.clear()
            val density = mapView.context.resources.displayMetrics.density

            Log.d(TAG, "IMAGE_FACTORY_DISPATCH layer=${config.layoutName} count=${allPending.size}")

            Thread {
                val results = mutableListOf<RenderedImageResult>()

                for (pending in allPending) {
                    val bitmap = viewAnnotationController.renderFromImageFactory(
                        pending.config.layoutName,
                        pending.viewData,
                        pending.cacheKey,
                        pending.padding,
                        density
                    )
                    if (bitmap != null) {
                        results.add(RenderedImageResult(pending.cacheKey, bitmap))
                    } else {
                        Log.w(TAG, "IMAGE_FACTORY_RENDER_FAIL cacheKey=${pending.cacheKey}")
                    }
                }

                mainHandler.post {
                    if (!isImageRenderBatchActive) return@post
                    pendingImageResults.addAll(results)
                    commitImageBatch()
                }
            }.start()
            return
        }

        // Slow path: staggered main-thread rendering (existing behavior)
        val batch = pendingImageRenders.take(maxImageRendersPerFrame)
        pendingImageRenders.subList(0, batch.size).clear()

        var inFlightCount = batch.size
        val hasMorePending = pendingImageRenders.isNotEmpty()

        for (pending in batch) {
            viewAnnotationController.renderViewToBitmap(pending.config.layoutName, pending.viewData, emptyList(), pending.padding, overrideCacheKey = pending.cacheKey) { bitmap ->
                if (!isImageRenderBatchActive) return@renderViewToBitmap

                if (bitmap != null) {
                    pendingImageResults.add(RenderedImageResult(pending.cacheKey, bitmap))
                } else {
                    Log.w(TAG, "IMAGE_MODE_RENDER_FAIL cacheKey=${pending.cacheKey}")
                }

                inFlightCount--
                if (inFlightCount == 0) {
                    if (hasMorePending && pendingImageRenders.isNotEmpty()) {
                        // More to render — yield to run loop and continue next frame
                        mainHandler.post { drainImageRenderQueue() }
                    } else {
                        // All renders complete — commit the batch
                        commitImageBatch()
                    }
                }
            }
        }
    }
    // endregion

    // region Phase 3: Batch style registration (background bitmap conversion + main thread registration)
    private fun commitImageBatch() {
        if (!isImageRenderBatchActive) return
        val config = activeImageBatchConfig ?: return
        val symbolLayerId = activeImageBatchSymbolLayerId ?: return
        val effectiveKeys = getEffectiveKeys(config)
        val useFeatureIds = effectiveKeys == null

        val results = ArrayList(pendingImageResults)
        pendingImageResults.clear()

        // Move bitmap-to-ByteBuffer conversion to background thread
        Thread {
            data class PreparedImage(val cacheKey: String, val width: Int, val height: Int, val byteBuffer: java.nio.ByteBuffer)
            val preparedImages = mutableListOf<PreparedImage>()

            for (result in results) {
                val bitmapCopy = result.bitmap.copy(Bitmap.Config.ARGB_8888, false)
                val byteBuffer = java.nio.ByteBuffer.allocateDirect(bitmapCopy.byteCount)
                bitmapCopy.copyPixelsToBuffer(byteBuffer)
                preparedImages.add(PreparedImage(result.cacheKey, bitmapCopy.width, bitmapCopy.height, byteBuffer))
                bitmapCopy.recycle()
            }

            // Post back to main thread for style registration
            mainHandler.post {
                if (!isImageRenderBatchActive || activeImageBatchConfig?.id != config.id) return@post

                val existingImages = registeredStyleImages.getOrPut(config.id) { mutableSetOf() }
                val scale = mapView.context.resources.displayMetrics.density
                var successCount = 0

                for (prepared in preparedImages) {
                    val expected = mapboxMap.getStyle()?.addStyleImage(
                        prepared.cacheKey,
                        scale,
                        com.mapbox.maps.Image(prepared.width, prepared.height, com.mapbox.bindgen.DataRef(prepared.byteBuffer)),
                        false,
                        emptyList(),
                        emptyList(),
                        null
                    )

                    if (expected?.isError == true) {
                        Log.w(TAG, "STYLE_IMAGE_REGISTER_FAIL cacheKey=${prepared.cacheKey} error=${expected.error}")
                    } else {
                        existingImages.add(prepared.cacheKey)
                        successCount++
                        Log.d(TAG, "STYLE_IMAGE_REGISTERED cacheKey=${prepared.cacheKey} size=${prepared.width}x${prepared.height}")
                    }
                }

                if (useFeatureIds) {
                    // Re-set match expression to force renderer to pick up newly registered images
                    val layerMapping = imageModeFeatureMapping[config.id]
                    if (layerMapping != null) {
                        val matchParts = mutableListOf<Any>()
                        matchParts.add("match")
                        matchParts.add(listOf("to-string", listOf("id")))
                        for ((fid, imgName) in layerMapping) {
                            matchParts.add(fid)
                            matchParts.add(imgName)
                        }
                        matchParts.add("")  // fallback
                        val matchJson = JSONArray(matchParts).toString()
                        val matchValue = com.mapbox.bindgen.Value.fromJson(matchJson)
                        if (!matchValue.isError) {
                            mapboxMap.getStyle()?.setStyleLayerProperty(symbolLayerId, "icon-image", matchValue.value!!)
                            Log.d(TAG, "HASH_EXPRESSION_REFRESH layer=${config.id} mappingCount=${layerMapping.size}")
                        }
                    }
                } else {
                    setIconImageExpression(config, symbolLayerId, effectiveKeys?.second)
                }
                revealImageModeLayerIfNeeded(config, symbolLayerId)

                // Force renderer to re-evaluate icon-image expression after new images are registered
                if (successCount > 0) {
                    mapboxMap.getStyle()?.let { style ->
                        val currentExpr = style.getStyleLayerProperty(symbolLayerId, "icon-image")
                        style.setStyleLayerProperty(symbolLayerId, "icon-image", currentExpr.value)
                        Log.d(TAG, "IMAGE_MODE_REFRESH | layer=${config.id} re-set icon-image to force re-render")
                    }
                }

                Log.d(TAG, "IMAGE_MODE_BATCH layer=${config.id} newImages=$successCount attempted=${preparedImages.size} totalImages=${existingImages.size}")

                // Clear batch state
                isImageRenderBatchActive = false
                activeImageBatchConfig = null
                activeImageBatchSymbolLayerId = null
            }
        }.start()
    }
    // endregion

    /**
     * Sets the icon-image expression on the symbol layer.
     * @param expressionKeys When non-null, builds property-based expression using ["get", key].
     *                       When null, builds feature-ID-based expression using ["to-string", ["id"]].
     */
    private fun setIconImageExpression(config: ViewLayerConfig, symbolLayerId: String, expressionKeys: List<String>?) {
        if (imageModeExpressionSet.contains(config.id)) return

        val expressionJson: String
        if (expressionKeys != null) {
            // Property-based: ["concat", "layoutName_", ["get", "key1"], "_", ["get", "key2"], ...]
            val parts = mutableListOf<Any>()
            parts.add("concat")
            parts.add("${config.layoutName}_")
            for ((i, key) in expressionKeys.withIndex()) {
                if (i > 0) {
                    parts.add("_")
                }
                parts.add(listOf("get", key))
            }
            expressionJson = org.json.JSONArray(parts).toString()
        } else {
            // Feature ID-based: ["concat", "layoutName_", ["to-string", ["id"]]]
            expressionJson = """["concat","${config.layoutName}_",["to-string",["id"]]]"""
        }

        val expressionValue = com.mapbox.bindgen.Value.fromJson(expressionJson)

        if (expressionValue.isError) {
            Log.w(TAG, "ICON_IMAGE_EXPRESSION_PARSE_FAIL layer=${config.id} error=${expressionValue.error}")
            return
        }

        val result = mapboxMap.getStyle()?.setStyleLayerProperty(symbolLayerId, "icon-image", expressionValue.value!!)
        if (result?.isError == true) {
            Log.w(TAG, "ICON_IMAGE_EXPRESSION_FAIL layer=${config.id} error=${result.error}")
        } else {
            imageModeExpressionSet.add(config.id)
            Log.d(TAG, "ICON_IMAGE_EXPRESSION_SET layer=${config.id} symbolLayer=$symbolLayerId")
        }

        // Set opacity expression for promote/demote (hides icon when feature state "promoted" is true)
        if (!opacityExpressionSet.contains(config.id)) {
            val opacityJson = """["case",["boolean",["feature-state","promoted"],false],0,1]"""
            val opacityValue = com.mapbox.bindgen.Value.fromJson(opacityJson)
            if (!opacityValue.isError) {
                val iconResult = mapboxMap.getStyle()?.setStyleLayerProperty(symbolLayerId, "icon-opacity", opacityValue.value!!)
                if (iconResult?.isError != true) {
                    opacityExpressionSet.add(config.id)
                    Log.d(TAG, "OPACITY_EXPRESSION_SET layer=${config.id} symbolLayer=$symbolLayerId")
                } else {
                    Log.w(TAG, "OPACITY_EXPRESSION_FAIL layer=${config.id}")
                }
            }
        }
    }

    /**
     * Builds and sets a match expression that maps feature IDs to hash-based image names.
     * Called every cycle for the hash-based path (when imageCacheKeys is null).
     */
    private fun setHashBasedMatchExpression(config: ViewLayerConfig, symbolLayerId: String, currentCycleMapping: Map<String, String>) {
        // Merge current cycle mapping into persistent mapping
        var layerMapping = imageModeFeatureMapping.getOrPut(config.id) { mutableMapOf() }
        layerMapping.putAll(currentCycleMapping)
        // Trim if too large — keep only currently visible features
        if (layerMapping.size > 500) {
            layerMapping.clear()
            layerMapping.putAll(currentCycleMapping)
        }

        // Build match expression: ["match", ["to-string", ["id"]], "fid1", "img1", ..., ""]
        val matchParts = mutableListOf<Any>()
        matchParts.add("match")
        matchParts.add(listOf("to-string", listOf("id")))
        for ((fid, imgName) in layerMapping) {
            matchParts.add(fid)
            matchParts.add(imgName)
        }
        matchParts.add("")  // fallback

        val matchJson = JSONArray(matchParts).toString()
        val matchValue = com.mapbox.bindgen.Value.fromJson(matchJson)
        if (matchValue.isError) {
            Log.w(TAG, "HASH_EXPRESSION_PARSE_FAIL layer=${config.id} error=${matchValue.error}")
            return
        }

        val result = mapboxMap.getStyle()?.setStyleLayerProperty(symbolLayerId, "icon-image", matchValue.value!!)
        if (result?.isError == true) {
            Log.w(TAG, "HASH_EXPRESSION_FAIL layer=${config.id} error=${result.error}")
        } else {
            imageModeExpressionSet.add(config.id)
            Log.d(TAG, "HASH_EXPRESSION layer=${config.id} symbolLayer=$symbolLayerId mappingCount=${layerMapping.size}")
        }

        // Set opacity expression for promote/demote (only once)
        if (!opacityExpressionSet.contains(config.id)) {
            val opacityJson = """["case",["boolean",["feature-state","promoted"],false],0,1]"""
            val opacityValue = com.mapbox.bindgen.Value.fromJson(opacityJson)
            if (!opacityValue.isError) {
                val iconResult = mapboxMap.getStyle()?.setStyleLayerProperty(symbolLayerId, "icon-opacity", opacityValue.value!!)
                if (iconResult?.isError != true) {
                    opacityExpressionSet.add(config.id)
                    Log.d(TAG, "OPACITY_EXPRESSION_SET layer=${config.id} symbolLayer=$symbolLayerId")
                }
            }
        }
    }

    private fun revealImageModeLayerIfNeeded(config: ViewLayerConfig, symbolLayerId: String) {
        if (imageModeInitialBatchDone.contains(config.id)) {
            Log.d(TAG, "revealImageMode SKIPPED (already done) | layer=${config.id}")
            return
        }

        // Don't reveal until at least one image has been registered
        val existingImages = registeredStyleImages[config.id]
        if (existingImages == null || existingImages.isEmpty()) {
            Log.d(TAG, "revealImageMode DEFERRED (no images yet) | layer=${config.id}")
            return
        }

        Log.d(TAG, "revealImageMode REVEALING | layer=${config.id} symbolLayer=$symbolLayerId imageCount=${existingImages.size}")
        imageModeInitialBatchDone.add(config.id)

        val style = mapboxMap.getStyle() ?: return

        // Set transitions for smooth ~200ms fade-in
        val transition = hashMapOf(
            "duration" to com.mapbox.bindgen.Value.valueOf(200L),
            "delay" to com.mapbox.bindgen.Value.valueOf(0L)
        )
        style.setStyleLayerProperty(symbolLayerId, "icon-opacity-transition", com.mapbox.bindgen.Value.valueOf(transition))
        style.setStyleLayerProperty(symbolLayerId, "text-opacity-transition", com.mapbox.bindgen.Value.valueOf(transition))

        // Restore icon-opacity to promote/demote expression
        val opacityJson = """["case",["boolean",["feature-state","promoted"],false],0,1]"""
        val opacityValue = com.mapbox.bindgen.Value.fromJson(opacityJson)
        if (!opacityValue.isError) {
            style.setStyleLayerProperty(symbolLayerId, "icon-opacity", opacityValue.value!!)
            opacityExpressionSet.add(config.id)
        }

        // Restore text-opacity
        style.setStyleLayerProperty(symbolLayerId, "text-opacity", com.mapbox.bindgen.Value.valueOf(1.0))

        // Verify icon-image property was set correctly
        val iconImageProp = style.getStyleLayerProperty(symbolLayerId, "icon-image")
        val iconOpacityProp = style.getStyleLayerProperty(symbolLayerId, "icon-opacity")
        Log.d(TAG, "IMAGE_MODE_REVEALED layer=${config.id} symbolLayer=$symbolLayerId iconImage=${iconImageProp.value} iconOpacity=${iconOpacityProp.value}")
    }

    // endregion

    // region Staggered batch creation

    private fun drainCreationQueue() {
        if (isDrainingCreationQueue || pendingCreations.isEmpty()) return
        isDrainingCreationQueue = true

        val batch = pendingCreations.take(maxCreatesPerFrame)
        pendingCreations.subList(0, batch.size).clear()

        batch.forEach { pending ->
            createAnnotationForFeature(pending.config, pending.feature, pending.featureId, pending.rawFeatureId)
        }

        isDrainingCreationQueue = false

        // If more remain, schedule next batch on the next frame
        if (pendingCreations.isNotEmpty()) {
            mainHandler.post { drainCreationQueue() }
        }
    }

    // endregion

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
     * Creates an annotation for a feature, with churn detection.
     * @param config The ViewLayer configuration
     * @param feature The map feature
     * @param featureId The namespaced feature ID for tracking (e.g., "sourceLayer_123")
     * @param rawFeatureId The raw feature ID for layer feature binding (e.g., "123"). Only needed when using associatedSymbolLayerId.
     */
    private fun createAnnotationForFeature(config: ViewLayerConfig, feature: Feature, featureId: String, rawFeatureId: String? = null) {
        val createStartTime = SystemClock.elapsedRealtime()
        val geometry = feature.geometry()
        if (geometry !is Point) {
            return
        }

        // Churn detection — check if this feature was recently removed
        val removeTime = recentlyRemoved[config.id]?.get(featureId)
        if (removeTime != null) {
            val removedAgoMs = createStartTime - removeTime
            if (removedAgoMs < 5000L) {
                Log.w(TAG, "CHURN_DETECTED id=$featureId removedAgo=${removedAgoMs}ms")
                periodChurnCount++
            }
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
                allowOverlap = config.allowOverlap,
                viewLayerId = config.id,
                feature = feature
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
        val createDuration = SystemClock.elapsedRealtime() - createStartTime
        Log.d(TAG, "ViewLayerController: createAnnotation | id=$annotationId, duration=${createDuration}ms")
    }

    private fun removeAnnotationForFeature(layerId: String, featureId: String) {
        val annotationId = "${layerId}_$featureId"
        Log.d(TAG, "ViewLayerController: removeAnnotation | id=$annotationId")
        viewAnnotationController.remove(annotationId)
        featureAnnotations[layerId]?.remove(annotationId)

        // Record removal time for churn detection
        val now = SystemClock.elapsedRealtime()
        recentlyRemoved.getOrPut(layerId) { mutableMapOf() }[featureId] = now

        // Clean stale entries older than 10s
        recentlyRemoved[layerId]?.entries?.removeIf { now - it.value >= 10000L }
    }

    // region Promote / Demote (image-mode → live ViewAnnotation)

    fun promoteFeature(annotationId: String, data: Map<String, Any?>?): Result<Unit> {
        // 1. Find matching image-mode config by prefix
        val config = findImageModeConfig(annotationId)
            ?: return Result.failure(Exception("No image-mode config matches annotation '$annotationId'"))

        // 2. Parse rawFeatureId from annotationId
        val prefix = "${config.id}_${config.sourceLayer ?: ""}_"
        if (!annotationId.startsWith(prefix)) {
            return Result.failure(Exception("Cannot parse feature ID from '$annotationId'"))
        }
        val rawFeatureId = annotationId.removePrefix(prefix)

        // 3. Check if annotation is being animated out — cancel and re-promote
        if (pendingDemotions.containsKey(annotationId)) {
            cancelPendingDemotion(annotationId)
            // View still exists, just update it back to selected
            val mergedData = (viewAnnotationController.imageModeFeatureData[annotationId] ?: emptyMap()).toMutableMap()
            data?.forEach { (key, value) -> mergedData[key] = value }
            mergedData["selected"] = true
            viewAnnotationController.update(annotationId, null, null, mergedData)
            return Result.success(Unit)
        }

        // 4. Look up cached feature data from original tap
        val cachedData = viewAnnotationController.imageModeFeatureData[annotationId] ?: emptyMap()

        // 5. Merge with provided data
        val mergedData = cachedData.toMutableMap()
        data?.forEach { (key, value) -> mergedData[key] = value }

        // 6. Set feature state to hide icon
        mapboxMap.setFeatureState(
            config.sourceId,
            config.sourceLayer,
            rawFeatureId,
            com.mapbox.bindgen.Value(hashMapOf("promoted" to com.mapbox.bindgen.Value(true)))
        ) { }

        // 7. Set opacity expression if not already set (safety fallback)
        val symbolLayerId = config.associatedSymbolLayerId
        if (symbolLayerId != null && !opacityExpressionSet.contains(config.id)) {
            val opacityJson = """["case",["boolean",["feature-state","promoted"],false],0,1]"""
            val opacityValue = com.mapbox.bindgen.Value.fromJson(opacityJson)
            if (!opacityValue.isError) {
                mapboxMap.getStyle()?.setStyleLayerProperty(symbolLayerId, "icon-opacity", opacityValue.value!!)
                opacityExpressionSet.add(config.id)
            }
        }

        // 8. Create live ViewAnnotation with selected=false (for opening animation)
        if (symbolLayerId == null) {
            return Result.failure(Exception("No associated symbol layer for config '${config.id}'"))
        }

        val savedSelected = mergedData["selected"]
        mergedData["selected"] = false

        val result = viewAnnotationController.addWithLayerFeature(
            id = annotationId,
            layoutName = config.layoutName,
            associatedLayerId = symbolLayerId,
            featureId = rawFeatureId,
            data = mergedData,
            anchor = config.anchor,
            allowOverlap = config.allowOverlap,
            viewLayerId = config.id
        )

        return result.map {
            // 9. Track in promotedFeatures
            promotedFeatures[annotationId] = PromotedFeatureInfo(
                configId = config.id,
                sourceId = config.sourceId,
                sourceLayer = config.sourceLayer,
                rawFeatureId = rawFeatureId
            )

            // 10. After short delay, update to selected=true to trigger opening animation
            val selectedValue = savedSelected ?: true
            mainHandler.postDelayed({
                if (promotedFeatures.containsKey(annotationId)) {
                    val openData = mergedData.toMutableMap()
                    openData["selected"] = selectedValue
                    viewAnnotationController.update(annotationId, null, null, openData)
                }
            }, 50L)
        }
    }

    fun demoteFeatureIfNeeded(annotationId: String): Boolean {
        val info = promotedFeatures[annotationId] ?: return false

        // Already pending demotion — skip
        if (pendingDemotions.containsKey(annotationId)) return true

        // 1. Update view to selected=false (triggers closing animation)
        viewAnnotationController.update(annotationId, null, null, mapOf("selected" to false))

        // 2. Schedule delayed cleanup after animation completes
        val runnable = Runnable {
            pendingDemotions.remove(annotationId)
            promotedFeatures.remove(annotationId)

            // Remove feature state (restore icon)
            mapboxMap.removeFeatureState(
                info.sourceId,
                info.sourceLayer,
                info.rawFeatureId,
                "promoted"
            ) { }

            // Remove the ViewAnnotation
            viewAnnotationController.remove(annotationId)
        }

        pendingDemotions[annotationId] = runnable
        mainHandler.postDelayed(runnable, 400L)

        return true
    }

    fun cancelPendingDemotion(annotationId: String) {
        pendingDemotions.remove(annotationId)?.let { runnable ->
            mainHandler.removeCallbacks(runnable)
        }
    }

    fun demoteAllFeatures() {
        // Cancel and immediately clean up all pending demotions
        pendingDemotions.forEach { (_, runnable) ->
            mainHandler.removeCallbacks(runnable)
        }
        pendingDemotions.clear()

        promotedFeatures.forEach { (annotationId, info) ->
            mapboxMap.removeFeatureState(
                info.sourceId,
                info.sourceLayer,
                info.rawFeatureId,
                "promoted"
            ) { }
            viewAnnotationController.remove(annotationId)
        }
        promotedFeatures.clear()
    }

    private fun findImageModeConfig(annotationId: String): ViewLayerConfig? {
        return viewLayers.values.firstOrNull { config ->
            isImageMode(config) &&
            annotationId.startsWith("${config.id}_${config.sourceLayer ?: ""}_")
        }
    }

    // endregion

    private fun removeAllAnnotationsForLayer(layerId: String) {
        val imageCount = registeredStyleImages[layerId]?.size ?: 0
        val annotationCount = featureAnnotations[layerId]?.size ?: 0
        Log.d(TAG, "removeAllAnnotationsForLayer CALLED | layer=$layerId images=$imageCount annotations=$annotationCount expressionSet=${imageModeExpressionSet.contains(layerId)} initialBatchDone=${imageModeInitialBatchDone.contains(layerId)}")
        // Cancel any pending demotions for this layer
        val pendingForLayer = pendingDemotions.filter { (key, _) -> key.startsWith(layerId) }
        pendingForLayer.forEach { (annotationId, runnable) ->
            mainHandler.removeCallbacks(runnable)
            pendingDemotions.remove(annotationId)
        }

        // Demote all promoted features for this layer
        val promotedForLayer = promotedFeatures.filter { it.value.configId == layerId }
        promotedForLayer.forEach { (annotationId, info) ->
            mapboxMap.removeFeatureState(info.sourceId, info.sourceLayer, info.rawFeatureId, "promoted") { }
            viewAnnotationController.remove(annotationId)
            promotedFeatures.remove(annotationId)
        }

        // Clean up image-mode style images
        registeredStyleImages[layerId]?.let { imageIds ->
            imageIds.forEach { imageId ->
                mapboxMap.getStyle()?.removeStyleImage(imageId)
            }
            registeredStyleImages.remove(layerId)
        }

        // Clean up feature-to-image mapping
        imageModeFeatureMapping.remove(layerId)

        // Reset iconImage expression if it was set
        if (imageModeExpressionSet.contains(layerId)) {
            viewLayers[layerId]?.associatedSymbolLayerId?.let { symbolLayerId ->
                mapboxMap.getStyle()?.setStyleLayerProperty(symbolLayerId, "icon-image", com.mapbox.bindgen.Value.valueOf(""))
            }
            imageModeExpressionSet.remove(layerId)
        }

        // Reset opacity expressions if they were set
        opacityExpressionSet.remove(layerId)

        // Reset initial batch tracking so reveal can re-trigger if layer is re-added
        imageModeInitialBatchDone.remove(layerId)

        featureAnnotations[layerId]?.toList()?.forEach { annotationId ->
            viewAnnotationController.remove(annotationId)
        }
        featureAnnotations[layerId]?.clear()
        visibleFeatureIds[layerId]?.clear()
        hiddenTimestamps[layerId]?.clear()
        hiddenAnnotations[layerId]?.clear()

        // Remove pending creations for this layer
        pendingCreations.removeAll { it.config.id == layerId }
    }

    fun dispose() {
        cameraChangedCancelable?.cancel()
        sourceDataCancelable?.cancel()
        mapIdleCancelable?.cancel()

        // Cancel all pending demotions
        pendingDemotions.forEach { (_, runnable) ->
            mainHandler.removeCallbacks(runnable)
        }
        pendingDemotions.clear()

        viewLayers.keys.forEach { layerId ->
            removeAllAnnotationsForLayer(layerId)
        }

        // Unregister image-mode layers from ViewAnnotationController
        viewLayers.values.forEach { config ->
            if (config.associatedSymbolLayerId != null && isImageMode(config)) {
                viewAnnotationController.unregisterImageModeLayer(config.associatedSymbolLayerId)
            }
        }

        viewLayers.clear()
        featureAnnotations.clear()
        visibleFeatureIds.clear()
        hiddenTimestamps.clear()
        hiddenAnnotations.clear()
        pendingCreations.clear()
        recentlyRemoved.clear()
        registeredStyleImages.clear()
        imageModeExpressionSet.clear()
        imageModeInitialBatchDone.clear()
        promotedFeatures.clear()
        opacityExpressionSet.clear()
    }
}

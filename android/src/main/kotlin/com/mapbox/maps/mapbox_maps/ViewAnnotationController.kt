package com.mapbox.maps.mapbox_maps

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.AndroidUiDispatcher
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.mapbox.geojson.Feature
import com.mapbox.geojson.Point
import com.mapbox.maps.mapbox_maps.pigeons.FeaturesetDescriptor
import com.mapbox.maps.mapbox_maps.pigeons.FeaturesetFeature
import com.mapbox.maps.mapbox_maps.pigeons.FeaturesetFeatureId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import com.mapbox.maps.MapView
import com.mapbox.maps.ViewAnnotationAnchor
import com.mapbox.maps.viewannotation.OnViewAnnotationUpdatedListener
import com.mapbox.maps.viewannotation.ViewAnnotationManager
import com.mapbox.maps.viewannotation.viewAnnotationOptions
import com.mapbox.maps.viewannotation.*

data class ImageModeLayerConfig(
    val symbolLayerId: String,
    val viewLayerId: String,
    val sourceId: String,
    val sourceLayer: String?,
    val propertyMapping: Map<String, PropertyMappingConfig>
)

class ViewAnnotationController(
    private val mapView: MapView,
    private val messenger: BinaryMessenger,
    private val channelSuffix: String
) {
    companion object {
        private const val TAG = "ViewLayerPerf"
    }

    private val annotations = mutableMapOf<String, View>()
    private val layoutNames = mutableMapOf<String, String>()
    private val imageCache = mutableMapOf<String, Bitmap>()
    private val pendingRenders = mutableSetOf<String>()  // Track in-flight render cache keys to prevent flooding
    private val annotationData = mutableMapOf<String, Map<String, Any?>>()
    private val viewLayerAnnotations = mutableSetOf<String>()  // Track ViewLayer-created annotations
    private val visibilityStates = mutableMapOf<String, MutableState<Boolean>>()  // Track visibility state per annotation
    private val annotationFeatures = mutableMapOf<String, FeaturesetFeature?>()  // Store FeaturesetFeature for tap callback
    private val imageModeLayerConfigs = mutableMapOf<String, ImageModeLayerConfig>()  // symbolLayerId -> config for tap fallback
    val imageModeFeatureData = mutableMapOf<String, Map<String, Any?>>()  // annotationId -> cached feature data from image-mode tap
    private val context = mapView.context
    private val viewAnnotationManager: ViewAnnotationManager
        get() = mapView.viewAnnotationManager
    
    private val tapEventChannel = MethodChannel(messenger, "plugins.flutter.io.$channelSuffix/viewAnnotationTap")
    
    private val composeLifecycleOwner = ComposeLifecycleOwner()
    private val coroutineScope = CoroutineScope(AndroidUiDispatcher.Main)
    private val recomposer = Recomposer(coroutineScope.coroutineContext)
    private val mainHandler = Handler(Looper.getMainLooper())
    
    private val tapDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onSingleTapUp(e: MotionEvent): Boolean {
            handleMapTap(e.rawX, e.rawY)
            return false
        }
    })

    init {
        coroutineScope.launch {
            recomposer.runRecomposeAndApplyChanges()
        }

        mapView.setOnTouchListener { _, event ->
            tapDetector.onTouchEvent(event)
            false
        }

        // Register listener for visibility changes (e.g., due to collision detection)
        viewAnnotationManager.addOnViewAnnotationUpdatedListener(
            object : OnViewAnnotationUpdatedListener {
                override fun onViewAnnotationVisibilityUpdated(view: View, visible: Boolean) {
                    val scanStart = SystemClock.elapsedRealtime()
                    val totalAnnotations = annotations.size
                    // Find annotation ID by view reference and update its visibility state
                    annotations.entries.find { it.value == view }?.key?.let { id ->
                        visibilityStates[id]?.value = visible
                    }
                    val scanDuration = SystemClock.elapsedRealtime() - scanStart
                    Log.d(TAG, "ViewAnnotationController: visibilityUpdate | scanned=$totalAnnotations, duration=${scanDuration}ms, visible=$visible")
                }
            }
        )
    }

    fun add(
        id: String,
        layoutName: String,
        latitude: Double,
        longitude: Double,
        data: Map<String, Any?>?,
        anchor: String?,
        allowOverlap: Boolean
    ): Result<Unit> {
        if (annotations.containsKey(id)) {
            return Result.failure(Exception("Annotation with id '$id' already exists"))
        }

        val factory = ViewAnnotationRegistry.getFactory(layoutName)
            ?: return Result.failure(Exception("No view registered for '$layoutName'. Register it using ViewAnnotationRegistry.register()"))

        val container = FrameLayout(context).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

        val composeView = ComposeView(context).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        }
        
        container.setViewTreeLifecycleOwner(composeLifecycleOwner)
        container.setViewTreeViewModelStoreOwner(composeLifecycleOwner)
        container.setViewTreeSavedStateRegistryOwner(composeLifecycleOwner)
        
        composeView.setParentCompositionContext(recomposer)

        container.addView(composeView)

        // Store references before async operation
        annotations[id] = container
        layoutNames[id] = layoutName
        annotationData[id] = data ?: emptyMap()

        // Create visibility state for this annotation (default to visible)
        val visibilityState = mutableStateOf(true)
        visibilityStates[id] = visibilityState

        // For manual annotations, feature is null
        annotationFeatures[id] = null

        // Get the activity's root view to temporarily attach our view
        val activity = findActivity(context)
            ?: return Result.failure(Exception("Could not find Activity from context"))

        val rootView = activity.window.decorView.findViewById<ViewGroup>(android.R.id.content)

        // Temporarily add to window (invisible) so ComposeView can attach and compose
        container.visibility = View.INVISIBLE
        rootView.addView(container)

        composeView.setContent {
            CompositionLocalProvider(LocalViewAnnotationVisible provides visibilityState) {
                factory(data ?: emptyMap())
            }
        }

        // Wait for composition and layout
        composeView.post {
            composeView.post {
                // Remove from root view
                rootView.removeView(container)
                container.visibility = View.VISIBLE

                if (annotations.containsKey(id)) {
                    val options = viewAnnotationOptions {
                        geometry(Point.fromLngLat(longitude, latitude))
                        allowOverlap(allowOverlap)
                        annotationAnchor {
                            anchor(parseAnchor(anchor))
                        }
                    }

                    viewAnnotationManager.addViewAnnotation(container, options)
                }
            }
        }

        return Result.success(Unit)
    }

    /// Computes a cache key from layoutName and the values of the specified data keys.
    /// Numeric values are normalized to match Mapbox expression `concat` stringification
    /// (ECMAScript Number.toString): whole-number doubles omit the ".0" suffix.
    fun computeImageCacheKey(layoutName: String, data: Map<String, Any?>?, keys: List<String>): String {
        val parts = mutableListOf(layoutName)
        for (key in keys) {
            parts.add(normalizeValueForCacheKey(data?.get(key)))
        }
        return parts.joinToString("_")
    }

    private fun normalizeValueForCacheKey(value: Any?): String {
        if (value == null) return "nil"
        val str = value.toString()
        val d = str.toDoubleOrNull()
        if (d != null && d == Math.floor(d) && !d.isInfinite()) {
            return d.toLong().toString()
        }
        return str
    }

    /// Renders a native view to a Bitmap for use as a Mapbox style image.
    /// Creates ComposeView, composes, renders to Bitmap, caches it, returns via callback.
    /// Does NOT create any ViewAnnotation.
    fun renderViewToBitmap(layoutName: String, data: Map<String, Any?>?, cacheKeys: List<String>, padding: Float = 0f, overrideCacheKey: String? = null, callback: (Bitmap?) -> Unit) {
        val cacheKey = overrideCacheKey ?: computeImageCacheKey(layoutName, data, cacheKeys)

        val cachedBitmap = imageCache[cacheKey]
        if (cachedBitmap != null) {
            callback(cachedBitmap)
            return
        }

        // Prevent flooding: skip if this cache key is already being rendered
        if (pendingRenders.contains(cacheKey)) {
            Log.d(TAG, "renderViewToBitmap DEDUPED — already in-flight cacheKey=$cacheKey")
            callback(null)
            return
        }
        pendingRenders.add(cacheKey)

        val factory = ViewAnnotationRegistry.getFactory(layoutName)
        if (factory == null) {
            Log.w(TAG, "renderViewToBitmap FAILED — no factory for '$layoutName'")
            pendingRenders.remove(cacheKey)
            callback(null)
            return
        }

        Log.d(TAG, "renderViewToBitmap START | cacheKey=$cacheKey layout=$layoutName pendingCount=${pendingRenders.size}")

        val density = context.resources.displayMetrics.density
        val paddingPx = (padding * density).toInt()

        val container = FrameLayout(context).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            clipChildren = false
            clipToPadding = false
        }

        val composeView = ComposeView(context).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        }

        container.setViewTreeLifecycleOwner(composeLifecycleOwner)
        container.setViewTreeViewModelStoreOwner(composeLifecycleOwner)
        container.setViewTreeSavedStateRegistryOwner(composeLifecycleOwner)
        composeView.setParentCompositionContext(recomposer)
        container.addView(composeView)

        val activity = findActivity(context)
        if (activity == null) {
            Log.w(TAG, "renderViewToBitmap FAILED — no activity")
            pendingRenders.remove(cacheKey)
            callback(null)
            return
        }
        val rootView = activity.window.decorView.findViewById<ViewGroup>(android.R.id.content)

        container.visibility = View.INVISIBLE
        rootView.addView(container)

        composeView.setContent {
            factory(data ?: emptyMap())
        }

        composeView.post {
            Log.d(TAG, "renderViewToBitmap POST1 | cacheKey=$cacheKey")
            composeView.post {
                Log.d(TAG, "renderViewToBitmap POST2 | cacheKey=$cacheKey width=${container.width} height=${container.height}")

                val width = container.width
                val height = container.height
                if (width <= 0 || height <= 0) {
                    Log.w(TAG, "renderViewToBitmap FAILED — size=${width}x${height} cacheKey=$cacheKey")
                    rootView.removeView(container)
                    pendingRenders.remove(cacheKey)
                    callback(null)
                    return@post
                }

                val paddedWidth = width + paddingPx * 2
                val paddedHeight = height + paddingPx * 2

                val bitmap = Bitmap.createBitmap(paddedWidth, paddedHeight, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                canvas.translate(paddingPx.toFloat(), paddingPx.toFloat())
                container.draw(canvas)

                rootView.removeView(container)

                imageCache[cacheKey] = bitmap
                pendingRenders.remove(cacheKey)
                Log.d(TAG, "STYLE_IMAGE_RENDERED cacheKey=$cacheKey size=${paddedWidth}x${paddedHeight} (content=${width}x${height} padding=${paddingPx}px)")
                callback(bitmap)
            }
        }
    }

    // region Image mode layer registration (for tap fallback)

    fun registerImageModeLayer(config: ImageModeLayerConfig) {
        imageModeLayerConfigs[config.symbolLayerId] = config
    }

    fun unregisterImageModeLayer(symbolLayerId: String) {
        imageModeLayerConfigs.remove(symbolLayerId)
    }

    // endregion

    /// Add a view annotation bound to a symbol layer feature.
    /// This enables shared collision detection between the view annotation and symbol layer.
    fun addWithLayerFeature(
        id: String,
        layoutName: String,
        associatedLayerId: String,
        featureId: String,
        data: Map<String, Any?>?,
        anchor: String?,
        allowOverlap: Boolean,
        viewLayerId: String? = null,
        feature: Feature? = null
    ): Result<Unit> {
        val addStartTime = SystemClock.elapsedRealtime()
        Log.d(TAG, "ViewAnnotationController: addWithLayerFeature START | id=$id, layout=$layoutName")

        if (annotations.containsKey(id)) {
            return Result.failure(Exception("Annotation with id '$id' already exists"))
        }

        // --- Live view mode ---

        val factory = ViewAnnotationRegistry.getFactory(layoutName)
            ?: return Result.failure(Exception("No view registered for '$layoutName'. Register it using ViewAnnotationRegistry.register()"))

        val container = FrameLayout(context).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

        val composeView = ComposeView(context).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        }

        container.setViewTreeLifecycleOwner(composeLifecycleOwner)
        container.setViewTreeViewModelStoreOwner(composeLifecycleOwner)
        container.setViewTreeSavedStateRegistryOwner(composeLifecycleOwner)

        composeView.setParentCompositionContext(recomposer)

        container.addView(composeView)

        // Store references before async operation
        annotations[id] = container
        layoutNames[id] = layoutName
        annotationData[id] = data ?: emptyMap()
        viewLayerAnnotations.add(id)  // Mark as ViewLayer annotation

        // Build and store FeaturesetFeature for tap callback
        annotationFeatures[id] = buildFeaturesetFeature(featureId, viewLayerId, feature)

        // Create visibility state for this annotation (default to visible)
        val visibilityState = mutableStateOf(true)
        visibilityStates[id] = visibilityState

        // Get the activity's root view to temporarily attach our view
        val activity = findActivity(context)
            ?: return Result.failure(Exception("Could not find Activity from context"))

        val rootView = activity.window.decorView.findViewById<ViewGroup>(android.R.id.content)

        // Temporarily add to window (invisible) so ComposeView can attach and compose
        container.visibility = View.INVISIBLE
        rootView.addView(container)

        composeView.setContent {
            CompositionLocalProvider(LocalViewAnnotationVisible provides visibilityState) {
                factory(data ?: emptyMap())
            }
        }

        // Wait for composition and layout
        composeView.post {
            composeView.post {
                val composeSetup = SystemClock.elapsedRealtime() - addStartTime
                // Remove from root view
                rootView.removeView(container)
                container.visibility = View.VISIBLE

                if (annotations.containsKey(id)) {
                    // Use annotatedLayerFeature for binding to symbol layer
                    val options = viewAnnotationOptions {
                        annotatedLayerFeature(associatedLayerId) {
                            featureId(featureId)
                        }
                        allowOverlap(allowOverlap)
                        annotationAnchor {
                            anchor(parseAnchor(anchor))
                        }
                    }

                    viewAnnotationManager.addViewAnnotation(container, options)
                    Log.d(TAG, "ViewAnnotationController: addWithLayerFeature COMPLETE | id=$id, composeSetup=${composeSetup}ms, totalAnnotations=${annotations.size}")
                }
            }
        }

        return Result.success(Unit)
    }

    /// Build FeaturesetFeature for tap callback storage.
    private fun buildFeaturesetFeature(featureId: String, viewLayerId: String?, feature: Feature?): FeaturesetFeature? {
        return feature?.let {
            FeaturesetFeature(
                id = FeaturesetFeatureId(featureId, null),
                featureset = FeaturesetDescriptor(null, null, viewLayerId),
                geometry = it.geometry()?.toMap() ?: emptyMap(),
                properties = it.properties()?.let { props -> org.json.JSONObject(props.toString()).toFilteredMap() } ?: emptyMap(),
                state = emptyMap()
            )
        }
    }

    fun update(
        id: String,
        latitude: Double?,
        longitude: Double?,
        data: Map<String, Any?>?
    ): Result<Unit> {
        val view = annotations[id]
            ?: return Result.failure(Exception("Annotation with id '$id' not found"))

        if (data != null && view is FrameLayout) {
            // Update stored data
            annotationData[id] = data

            val composeView = view.getChildAt(0) as? ComposeView
            if (composeView != null) {
                val layoutName = layoutNames[id]
                if (layoutName != null) {
                    val factory = ViewAnnotationRegistry.getFactory(layoutName)
                    if (factory != null) {
                        val visibilityState = visibilityStates[id] ?: mutableStateOf(true)
                        composeView.setContent {
                            CompositionLocalProvider(LocalViewAnnotationVisible provides visibilityState) {
                                factory(data)
                            }
                        }
                    }
                }
            }
        }

        // Only update coordinates for non-ViewLayer annotations (ViewLayer annotations are bound to features)
        if (latitude != null && longitude != null && !viewLayerAnnotations.contains(id)) {
            val updateOptions = viewAnnotationOptions {
                geometry(Point.fromLngLat(longitude, latitude))
            }
            viewAnnotationManager.updateViewAnnotation(view, updateOptions)
        }

        return Result.success(Unit)
    }

    fun setVisible(id: String, visible: Boolean) {
        val container = annotations[id] ?: return
        container.visibility = if (visible) View.VISIBLE else View.GONE
    }

    fun remove(id: String): Result<Unit> {
        val view = annotations.remove(id)
            ?: return Result.failure(Exception("Annotation with id '$id' not found"))

        layoutNames.remove(id)
        annotationData.remove(id)
        viewLayerAnnotations.remove(id)
        visibilityStates.remove(id)
        annotationFeatures.remove(id)
        viewAnnotationManager.removeViewAnnotation(view)
        Log.d(TAG, "ViewAnnotationController: remove | id=$id, remaining=${annotations.size}")
        return Result.success(Unit)
    }

    fun removeAll() {
        annotations.values.forEach { view ->
            viewAnnotationManager.removeViewAnnotation(view)
        }
        annotations.clear()
        layoutNames.clear()
        annotationData.clear()
        viewLayerAnnotations.clear()
        visibilityStates.clear()
        annotationFeatures.clear()
        imageModeFeatureData.clear()
    }

    private fun handleMapTap(rawX: Float, rawY: Float) {
        val mapLocation = IntArray(2)
        mapView.getLocationOnScreen(mapLocation)

        // Phase 1: Check ViewAnnotation views (existing behavior)
        for ((id, container) in annotations.entries.reversed()) {
            if (container.visibility != View.VISIBLE) continue
            val visState = visibilityStates[id]
            if (visState != null && !visState.value) continue

            val viewLocation = IntArray(2)
            container.getLocationOnScreen(viewLocation)

            val relX = rawX - viewLocation[0]
            val relY = rawY - viewLocation[1]

            if (relX >= 0 && relX <= container.width && relY >= 0 && relY <= container.height) {
                val tapData = annotationData[id] ?: emptyMap()
                val feature = annotationFeatures[id]
                tapEventChannel.invokeMethod("onTap", mapOf(
                    "annotationId" to id,
                    "feature" to serializeFeature(feature),
                    "data" to tapData
                ))
                return
            }
        }

        // Phase 2: Check image-mode symbol layers via queryRenderedFeatures
        if (imageModeLayerConfigs.isEmpty()) return

        val tapX = (rawX - mapLocation[0]).toDouble()
        val tapY = (rawY - mapLocation[1]).toDouble()

        val screenBox = com.mapbox.maps.ScreenBox(
            com.mapbox.maps.ScreenCoordinate(tapX - 22.0, tapY - 22.0),
            com.mapbox.maps.ScreenCoordinate(tapX + 22.0, tapY + 22.0)
        )

        val layerIds = imageModeLayerConfigs.keys.toList()
        val options = com.mapbox.maps.RenderedQueryOptions(layerIds, null)

        mapView.mapboxMap.queryRenderedFeatures(
            com.mapbox.maps.RenderedQueryGeometry.valueOf(screenBox),
            options
        ) { expected ->
            if (expected.isError) {
                Log.w(TAG, "IMAGE_MODE_TAP_QUERY_ERROR: ${expected.error}")
                return@queryRenderedFeatures
            }

            val queriedFeatures = expected.value ?: return@queryRenderedFeatures
            val first = queriedFeatures.firstOrNull() ?: return@queryRenderedFeatures
            val feature = first.queriedFeature.feature
            val sourceLayerId = first.queriedFeature.sourceLayer ?: ""

            // Find which image-mode config matched
            for (layerId in first.layers) {
                val config = imageModeLayerConfigs[layerId] ?: continue

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

                val featureId = feature.id() ?: feature.getStringProperty("id") ?: "unknown"
                val annotationId = "${config.viewLayerId}_${sourceLayerId}_$featureId"

                // Cache feature data for promote/demote
                if (imageModeFeatureData.size > 100) {
                    imageModeFeatureData.clear()
                }
                imageModeFeatureData[annotationId] = viewData
                return@queryRenderedFeatures
            }
        }
    }

    /// Serialize FeaturesetFeature to a list for method channel.
    /// The pigeon toList() doesn't recursively serialize nested objects.
    private fun serializeFeature(feature: FeaturesetFeature?): List<Any?>? {
        if (feature == null) return null

        val idList: List<Any?>? = feature.id?.let { listOf(it.id, it.namespace) }
        val featuresetList: List<Any?> = listOf(
            feature.featureset.featuresetId,
            feature.featureset.importId,
            feature.featureset.layerId
        )

        return listOf(idList, featuresetList, feature.geometry, feature.properties, feature.state)
    }

    private fun parseAnchor(anchor: String?): ViewAnnotationAnchor {
        return when (anchor?.uppercase()) {
            "TOP" -> ViewAnnotationAnchor.TOP
            "LEFT" -> ViewAnnotationAnchor.LEFT
            "BOTTOM" -> ViewAnnotationAnchor.BOTTOM
            "RIGHT" -> ViewAnnotationAnchor.RIGHT
            "TOP_LEFT" -> ViewAnnotationAnchor.TOP_LEFT
            "TOP_RIGHT" -> ViewAnnotationAnchor.TOP_RIGHT
            "BOTTOM_LEFT" -> ViewAnnotationAnchor.BOTTOM_LEFT
            "BOTTOM_RIGHT" -> ViewAnnotationAnchor.BOTTOM_RIGHT
            "CENTER" -> ViewAnnotationAnchor.CENTER
            else -> ViewAnnotationAnchor.CENTER
        }
    }

    private fun findActivity(context: Context): Activity? {
        var ctx: Context? = context
        while (ctx != null) {
            if (ctx is Activity) {
                return ctx
            }
            ctx = if (ctx is ContextWrapper) ctx.baseContext else null
        }
        return null
    }
}

private class ComposeLifecycleOwner : LifecycleOwner, ViewModelStoreOwner, SavedStateRegistryOwner {
    private val lifecycleRegistry = LifecycleRegistry(this)
    private val store = ViewModelStore()
    private val savedStateRegistryController = SavedStateRegistryController.create(this)

    init {
        savedStateRegistryController.performRestore(null)
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
    }

    override val lifecycle: Lifecycle
        get() = lifecycleRegistry
    
    override val viewModelStore: ViewModelStore
        get() = store
    
    override val savedStateRegistry: SavedStateRegistry
        get() = savedStateRegistryController.savedStateRegistry
}
package com.mapbox.maps.mapbox_maps

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.State
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
import com.mapbox.geojson.Point
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import com.mapbox.maps.MapView
import com.mapbox.maps.ViewAnnotationAnchor
import com.mapbox.maps.viewannotation.ViewAnnotationManager
import com.mapbox.maps.viewannotation.viewAnnotationOptions
import com.mapbox.maps.viewannotation.*

class ViewAnnotationController(
    private val mapView: MapView,
    private val messenger: BinaryMessenger,
    private val channelSuffix: String
) {
    private val annotations = mutableMapOf<String, View>()
    private val layoutNames = mutableMapOf<String, String>()
    private val annotationData = mutableMapOf<String, Map<String, Any?>>()
    private val viewLayerAnnotations = mutableSetOf<String>()  // Track ViewLayer-created annotations
    private val visibilityStates = mutableMapOf<View, androidx.compose.runtime.MutableState<Boolean>>()  // Visibility state for Compose animations
    private val context = mapView.context
    private val viewAnnotationManager: ViewAnnotationManager
        get() = mapView.viewAnnotationManager

    private val tapEventChannel = MethodChannel(messenger, "plugins.flutter.io.$channelSuffix/viewAnnotationTap")

    private val composeLifecycleOwner = ComposeLifecycleOwner()
    private val coroutineScope = CoroutineScope(AndroidUiDispatcher.Main)
    private val recomposer = Recomposer(coroutineScope.coroutineContext)
    private val mainHandler = Handler(Looper.getMainLooper())

    private val visibilityListener = OnViewAnnotationUpdatedListener { updatedViews ->
        for (view in updatedViews) {
            val visibilityState = visibilityStates[view] ?: continue
            val isVisible = view.visibility == View.VISIBLE

            if (visibilityState.value != isVisible) {
                visibilityState.value = isVisible
            }
        }
    }

    init {
        coroutineScope.launch {
            recomposer.runRecomposeAndApplyChanges()
        }
        viewAnnotationManager.addOnViewAnnotationUpdatedListener(visibilityListener)
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

        // Create visibility state for this annotation (starts visible for non-ViewLayer annotations)
        val visibilityState = mutableStateOf(true)
        visibilityStates[container] = visibilityState

        // Store references before async operation
        annotations[id] = container
        layoutNames[id] = layoutName
        annotationData[id] = data ?: emptyMap()

        // Set click listener immediately (before any async work)
        container.setOnClickListener {
            val tapData = annotationData[id] ?: emptyMap()
            tapEventChannel.invokeMethod("onTap", mapOf(
                "id" to id,
                "data" to tapData
            ))
        }

        // Get the activity's root view to temporarily attach our view
        val activity = findActivity(context)
            ?: return Result.failure(Exception("Could not find Activity from context"))

        val rootView = activity.window.decorView.findViewById<ViewGroup>(android.R.id.content)

        // Temporarily add to window (invisible) so ComposeView can attach and compose
        container.visibility = View.INVISIBLE
        rootView.addView(container)

        composeView.setContent {
            factory(data ?: emptyMap(), visibilityState)
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

    /// Add a view annotation bound to a symbol layer feature.
    /// This enables shared collision detection between the view annotation and symbol layer.
    fun addWithLayerFeature(
        id: String,
        layoutName: String,
        associatedLayerId: String,
        featureId: String,
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

        // Create visibility state for this annotation (starts hidden for ViewLayer annotations)
        val visibilityState = mutableStateOf(false)
        visibilityStates[container] = visibilityState

        // Store references before async operation
        annotations[id] = container
        layoutNames[id] = layoutName
        annotationData[id] = data ?: emptyMap()
        viewLayerAnnotations.add(id)  // Mark as ViewLayer annotation

        // Set click listener immediately (before any async work)
        container.setOnClickListener {
            val tapData = annotationData[id] ?: emptyMap()
            tapEventChannel.invokeMethod("onTap", mapOf(
                "id" to id,
                "data" to tapData
            ))
        }

        // Get the activity's root view to temporarily attach our view
        val activity = findActivity(context)
            ?: return Result.failure(Exception("Could not find Activity from context"))

        val rootView = activity.window.decorView.findViewById<ViewGroup>(android.R.id.content)

        // Temporarily add to window (invisible) so ComposeView can attach and compose
        container.visibility = View.INVISIBLE
        rootView.addView(container)

        composeView.setContent {
            factory(data ?: emptyMap(), visibilityState)
        }

        // Wait for composition and layout
        composeView.post {
            composeView.post {
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
                }
            }
        }

        return Result.success(Unit)
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
                val visibilityState = visibilityStates[view] ?: mutableStateOf(true)
                if (layoutName != null) {
                    val factory = ViewAnnotationRegistry.getFactory(layoutName)
                    if (factory != null) {
                        composeView.setContent {
                            factory(data, visibilityState)
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

    fun remove(id: String): Result<Unit> {
        val view = annotations.remove(id)
            ?: return Result.failure(Exception("Annotation with id '$id' not found"))

        layoutNames.remove(id)
        annotationData.remove(id)
        viewLayerAnnotations.remove(id)
        visibilityStates.remove(view)
        viewAnnotationManager.removeViewAnnotation(view)
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
    }

    fun dispose() {
        viewAnnotationManager.removeOnViewAnnotationUpdatedListener(visibilityListener)
        removeAll()
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
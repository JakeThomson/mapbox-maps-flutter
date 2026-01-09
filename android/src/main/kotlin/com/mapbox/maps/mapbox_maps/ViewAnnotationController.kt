package com.mapbox.maps.mapbox_maps

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import androidx.compose.runtime.Recomposer
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
    companion object {
        private const val TAG = "ViewAnnotationController"
    }
    
    private val annotations = mutableMapOf<String, View>()
    private val layoutNames = mutableMapOf<String, String>()
    private val annotationData = mutableMapOf<String, Map<String, Any?>>()
    private val context = mapView.context
    private val viewAnnotationManager: ViewAnnotationManager
        get() = mapView.viewAnnotationManager
    
    private val tapEventChannel = MethodChannel(messenger, "plugins.flutter.io.$channelSuffix/viewAnnotationTap")
    
    private val composeLifecycleOwner = ComposeLifecycleOwner()
    private val coroutineScope = CoroutineScope(AndroidUiDispatcher.Main)
    private val recomposer = Recomposer(coroutineScope.coroutineContext)
    private val mainHandler = Handler(Looper.getMainLooper())
    
    init {
        coroutineScope.launch {
            recomposer.runRecomposeAndApplyChanges()
        }
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

        // Get the activity's root view to temporarily attach our view
        val activity = findActivity(context)
        if (activity == null) {
            Log.e(TAG, "[$id] Could not find Activity from context")
            return Result.failure(Exception("Could not find Activity from context"))
        }
        
        val rootView = activity.window.decorView.findViewById<ViewGroup>(android.R.id.content)
        
        // Temporarily add to window (invisible) so ComposeView can attach and compose
        container.visibility = View.INVISIBLE
        rootView.addView(container)
        
        Log.d(TAG, "[$id] Temporarily attached to window, setting content")
        
        composeView.setContent {
            factory(data ?: emptyMap())
        }

        // Wait for composition and layout
        composeView.post {
            composeView.post {
                Log.d(TAG, "[$id] After posts - container: ${container.width}x${container.height}, composeView: ${composeView.width}x${composeView.height}")
                Log.d(TAG, "[$id] Measured - container: ${container.measuredWidth}x${container.measuredHeight}, composeView: ${composeView.measuredWidth}x${composeView.measuredHeight}")
                Log.d(TAG, "[$id] isAttachedToWindow: ${composeView.isAttachedToWindow}")
                
                // Remove from root view
                rootView.removeView(container)
                container.visibility = View.VISIBLE
                
                if (annotations.containsKey(id)) {
                    // Add click listener to handle taps
                    container.setOnClickListener {
                        Log.d(TAG, "[$id] View annotation tapped")
                        val data = annotationData[id] ?: emptyMap()
                        tapEventChannel.invokeMethod("onTap", mapOf(
                            "id" to id,
                            "data" to data
                        ))
                    }
                    
                    val options = viewAnnotationOptions {
                        geometry(Point.fromLngLat(longitude, latitude))
                        allowOverlap(allowOverlap)
                        annotationAnchor {
                            anchor(parseAnchor(anchor))
                        }
                    }
                    
                    Log.d(TAG, "[$id] Adding view annotation to map")
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
                if (layoutName != null) {
                    val factory = ViewAnnotationRegistry.getFactory(layoutName)
                    if (factory != null) {
                        composeView.setContent {
                            factory(data)
                        }
                    }
                }
            }
        }

        if (latitude != null && longitude != null) {
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

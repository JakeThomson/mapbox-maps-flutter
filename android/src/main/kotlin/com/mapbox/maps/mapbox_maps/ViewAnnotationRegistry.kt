package com.mapbox.maps.mapbox_maps

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateOf

typealias ViewAnnotationFactory = @Composable (Map<String, Any?>) -> Unit

/// Factory that renders directly to a Bitmap using Android Canvas (thread-safe, no Compose).
typealias ViewAnnotationImageFactory = (data: Map<String, Any?>, density: Float) -> Bitmap?

object ViewAnnotationRegistry {
    /**
     * CompositionLocal providing the current visibility state of a view annotation.
     *
     * Use this in your Composable factory to animate entrance/exit based on
     * Mapbox collision detection and visibility changes.
     *
     * Example usage:
     * ```kotlin
     * ViewAnnotationRegistry.register("my_marker") { data ->
     *     val isVisible by ViewAnnotationRegistry.LocalViewAnnotationVisible.current
     *
     *     val alpha by animateFloatAsState(
     *         targetValue = if (isVisible) 1f else 0f,
     *         animationSpec = tween(200)
     *     )
     *
     *     Box(modifier = Modifier.alpha(alpha)) {
     *         MyMarkerContent(data)
     *     }
     * }
     * ```
     */
    val LocalViewAnnotationVisible = compositionLocalOf<State<Boolean>> {
        mutableStateOf(true)
    }

    private val factories = mutableMapOf<String, ViewAnnotationFactory>()
    private val imageFactories = mutableMapOf<String, ViewAnnotationImageFactory>()

    fun register(viewIdentifier: String, factory: ViewAnnotationFactory) {
        factories[viewIdentifier] = factory
    }

    fun unregister(viewIdentifier: String) {
        factories.remove(viewIdentifier)
    }

    internal fun getFactory(viewIdentifier: String): ViewAnnotationFactory? {
        return factories[viewIdentifier]
    }

    internal fun hasFactory(viewIdentifier: String): Boolean {
        return factories.containsKey(viewIdentifier)
    }

    // Image Factories

    fun registerImageFactory(viewIdentifier: String, factory: ViewAnnotationImageFactory) {
        imageFactories[viewIdentifier] = factory
    }

    fun unregisterImageFactory(viewIdentifier: String) {
        imageFactories.remove(viewIdentifier)
    }

    internal fun getImageFactory(viewIdentifier: String): ViewAnnotationImageFactory? {
        return imageFactories[viewIdentifier]
    }

    internal fun hasImageFactory(viewIdentifier: String): Boolean {
        return imageFactories.containsKey(viewIdentifier)
    }
}


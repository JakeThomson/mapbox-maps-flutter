package com.mapbox.maps.mapbox_maps

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateOf

/**
 * CompositionLocal providing the current visibility state of a view annotation.
 *
 * Use this in your Composable factory to animate entrance/exit based on
 * Mapbox collision detection and visibility changes.
 *
 * Example usage:
 * ```kotlin
 * ViewAnnotationRegistry.register("my_marker") { data ->
 *     val isVisible by LocalViewAnnotationVisible.current
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

typealias ViewAnnotationFactory = @Composable (Map<String, Any?>) -> Unit

object ViewAnnotationRegistry {
    private val factories = mutableMapOf<String, ViewAnnotationFactory>()

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
}


package com.mapbox.maps.mapbox_maps

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State

/**
 * Factory function for creating view annotation content.
 *
 * @param data The data map containing properties for the view
 * @param isVisible A state indicating whether the annotation is visible (for collision-based animations)
 */
typealias ViewAnnotationFactory = @Composable (data: Map<String, Any?>, isVisible: State<Boolean>) -> Unit

object ViewAnnotationRegistry {
    private val factories = mutableMapOf<String, ViewAnnotationFactory>()

    /**
     * Register a view annotation factory.
     *
     * The factory receives:
     * - data: Properties passed from Flutter/ViewLayer
     * - isVisible: Observable state for visibility changes (use with animateFloatAsState for animations)
     *
     * Example:
     * ```kotlin
     * ViewAnnotationRegistry.register("my_callout") { data, isVisible ->
     *     val scale by animateFloatAsState(if (isVisible.value) 1f else 0f)
     *     Box(modifier = Modifier.scale(scale)) {
     *         // Your content
     *     }
     * }
     * ```
     */
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


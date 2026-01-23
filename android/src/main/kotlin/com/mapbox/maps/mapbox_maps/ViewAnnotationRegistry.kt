package com.mapbox.maps.mapbox_maps

import androidx.compose.runtime.Composable

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


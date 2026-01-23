package com.mapbox.maps.mapbox_maps_example

import android.os.Bundle
import androidx.compose.ui.graphics.Color
import com.mapbox.maps.mapbox_maps.ViewAnnotationRegistry
import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        ViewAnnotationRegistry.register("custom_callout") { data, isVisible ->
            CalloutView(
                emoji = data["callout_emoji"] as? String ?: "",
                label = data["callout_label"] as? String ?: "",
                backgroundColor = (data["backgroundColor"] as? Number)?.let {
                    Color(it.toLong().toInt())
                } ?: Color(0xFF3B82F6),
                selected = (data["selected"] as? Boolean) ?: false,
                isVisible = isVisible
            )
        }
    }
}
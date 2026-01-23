package com.mapbox.maps.mapbox_maps_example

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mapbox.maps.mapbox_maps.LocalRequestRemeasure
import com.mapbox.maps.mapbox_maps.LocalViewAnnotationVisible
import kotlinx.coroutines.delay

@Composable
fun CalloutView(
    emoji: String,
    label: String,
    backgroundColor: Color = Color(0xFF3B82F6),
    selected: Boolean = false
) {
    // Visibility state from Mapbox collision detection
    val isVisible by LocalViewAnnotationVisible.current

    // Remeasure callback to notify parent when size changes
    val requestRemeasure = LocalRequestRemeasure.current

    // Visibility animation (for collision detection show/hide)
    val visibilityScale by animateFloatAsState(
        targetValue = if (isVisible) 1f else 0f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "visibilityScale"
    )
    val visibilityAlpha by animateFloatAsState(
        targetValue = if (isVisible) 1f else 0f,
        animationSpec = tween(durationMillis = if (isVisible) 200 else 150),
        label = "visibilityAlpha"
    )

    // Track if this is the first composition
    val isFirstComposition = remember { mutableStateOf(true) }

    // Use a state that starts from false on first composition, then animates to selected
    // This ensures animations always have a starting point
    val animatedSelected = remember { mutableStateOf(false) }

    // Update animatedSelected when selected changes
    LaunchedEffect(selected) {
        if (isFirstComposition.value) {
            // On first composition, set immediately without animation to match the target
            animatedSelected.value = selected
            isFirstComposition.value = false
        } else {
            // On subsequent changes, animate to the new value
            animatedSelected.value = selected
            // Wait for animation to complete, then request remeasure
            delay(300) // Match animation duration
            requestRemeasure?.invoke()
        }
    }

    val size by animateDpAsState(
        targetValue = if (animatedSelected.value) 48.dp else 32.dp,
        animationSpec = tween(durationMillis = 300),
        label = "size"
    )

    val fontSize by animateFloatAsState(
        targetValue = if (animatedSelected.value) 28f else 24f,
        animationSpec = tween(durationMillis = 300),
        label = "fontSize"
    )

    val borderWidth by animateFloatAsState(
        targetValue = if (animatedSelected.value) 4f else 0f,
        animationSpec = tween(durationMillis = 300),
        label = "borderWidth"
    )

    val arrowHeight by animateFloatAsState(
        targetValue = if (animatedSelected.value) 12f else 0f,
        animationSpec = tween(durationMillis = 300),
        label = "arrowHeight"
    )

    Column(
        modifier = Modifier
            .graphicsLayer(
                scaleX = visibilityScale,
                scaleY = visibilityScale,
                alpha = visibilityAlpha
            ),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Circle with emoji and border
        Box(
            modifier = Modifier.size(size),
            contentAlignment = Alignment.Center
        ) {
            // Background circle with emoji
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(CircleShape)
                    .background(Color.White),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = emoji,
                    fontSize = fontSize.sp,
                    textAlign = TextAlign.Center,
                    color = Color.Black
                )
            }

            // Border overlay
            if (borderWidth > 0) {
                Canvas(modifier = Modifier.fillMaxSize()) {
                    val centerX = this.size.width / 2
                    val centerY = this.size.height / 2
                    val radius = this.size.minDimension / 2 - borderWidth / 2
                    drawCircle(
                        color = Color.Black,
                        radius = radius,
                        center = androidx.compose.ui.geometry.Offset(centerX, centerY),
                        style = Stroke(width = borderWidth)
                    )
                }
            }
        }

        // Arrow pointing down (measured as part of layout)
        if (arrowHeight > 0) {
            Canvas(
                modifier = Modifier
                    .width(16.dp)
                    .height(arrowHeight.dp)
            ) {
                val centerX = this.size.width / 2
                val arrowWidth = this.size.width

                val path = Path().apply {
                    moveTo(centerX, 0f)
                    lineTo(centerX - arrowWidth / 2, this@Canvas.size.height)
                    lineTo(centerX + arrowWidth / 2, this@Canvas.size.height)
                    close()
                }

                drawPath(path, color = Color.Black)
            }
        }
    }
}

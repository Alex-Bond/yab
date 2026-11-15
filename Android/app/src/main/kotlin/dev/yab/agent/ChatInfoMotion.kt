package dev.yab.agent

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.sin

/** A public same-root cover, sized through system bars without creating another Window.
 * The parent's original FLAG_SECURE and synchronous owner/privacy curtain keep applying. */
@Composable internal fun ChatInfoCanvas(extendBars: Boolean, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val top = if (extendBars) WindowInsets.statusBars.getTop(density) else 0
    val bottom = if (extendBars) WindowInsets.navigationBars.getBottom(density) else 0
    Layout(content = content, modifier = Modifier.fillMaxSize()) { children, constraints ->
        val height = constraints.maxHeight + top + bottom
        val child = children.single().measure(Constraints.fixed(constraints.maxWidth, height))
        layout(constraints.maxWidth, constraints.maxHeight) { child.place(0, -top) }
    }
}

/** Reference: iPhone 0.1.13 chatInfo film. Page zooms from the 44-point face,
 * rounds while travelling and follows the dismissing finger. Values are local UI geometry. */
internal data class ChatInfoZoom(val scale: Float, val top: Float, val visibleHeight: Float, val corner: Float, val dim: Float) {
    companion object {
        fun pose(width: Float, height: Float, faceTop: Float, fraction: Float, drag: Float, reduced: Boolean): ChatInfoZoom {
            val f = fraction.coerceIn(0f, 1f)
            val displacement = drag.coerceAtLeast(0f)
            if (reduced) return ChatInfoZoom(1f, 0f, height, 0f, .15f * f)
            val initial = (44f / width.coerceAtLeast(44f)).coerceAtMost(1f)
            val follow = (displacement / (height * .5f).coerceAtLeast(1f)).coerceIn(0f, 1f)
            val scale = (initial + (1f - initial) * f) * (1f - .2f * follow)
            val top = faceTop * (1f - f) + sin(PI * f).toFloat() * 52.8f + displacement
            val visible = (44f + (height - 44f) * f.pow(1.45f)).coerceIn(0f, height)
            val corner = (width / 2f) * (1f - f).pow(1.6f) + 32f * follow
            return ChatInfoZoom(scale, top, visible, corner, .15f * f * (1f - follow))
        }
    }
}

internal class ChatInfoClip(private val height: Float, private val radius: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val h = height.coerceIn(0f, size.height)
        val r = radius.coerceIn(0f, minOf(size.width, h) / 2f)
        return Outline.Generic(Path().apply { addRoundRect(RoundRect(0f, 0f, size.width, h, CornerRadius(r))) })
    }
}

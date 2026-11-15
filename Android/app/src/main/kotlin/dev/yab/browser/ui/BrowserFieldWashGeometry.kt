package dev.yab.browser.ui

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** NewTabSpaces has a full-height main wash, followed by a separate 600pt plain foot.
 * Its real callers pass fullness=1; reveal/cards opacity never changes that geometry. */
internal data class BrowserFieldWashGeometry(val width: Double, val height: Double,
    val cardBottom: Double, val bottom: Double, val rowsDrop: Double, val extended: Boolean = true) {
    init { require(listOf(width, height, cardBottom, bottom, rowsDrop).all(Double::isFinite) &&
        width >= 0 && height >= 0 && cardBottom >= 0 && cardBottom <= height && bottom in 0.0..height) }

    val mainHeight get() = bottom
    val footHeight get() = UNDER_KEYBOARD
    val visibleFootHeight get() = if (extended) min(UNDER_KEYBOARD, height - bottom) else 0.0
    val decorationHeight get() = if (extended) min(height, bottom + UNDER_KEYBOARD) else cardBottom
    // The alpha layer owns the visible paint, never an offscreen H+600 texture. Padding
    // after that layer restores the exact old Column/cardBottom measurement.
    val layerHeight get() = min(height, max(cardBottom, decorationHeight))
    val innerBottomPadding get() = layerHeight - cardBottom
    val fullness get() = 1.0
    fun innerBottomPaddingPixels(density: Float): Int {
        require(density.isFinite() && density > 0)
        // Match Dp's Float pixel conversion independently for the layer and old body.
        return ((layerHeight.toFloat() * density).roundToInt() - (cardBottom.toFloat() * density).roundToInt()).coerceAtLeast(0)
    }

    /** Coordinates come from the attached Pages and actual Field-root LayoutCoordinates.
     * All supplied coordinates/extents and the returned projection use the same unit;
     * drawing supplies actual pixels, overriding every logical default. The root-space
     * clip is applied BEFORE translating the decorative child. */
    fun projection(pageX: Double, pageY: Double, measuredWidth: Double = width, measuredHeight: Double = height,
        layerX: Double = 0.0, layerY: Double = rowsDrop, bodyHeight: Double = cardBottom): FieldWashProjection {
        require(listOf(pageX, pageY, measuredWidth, measuredHeight, layerX, layerY, bodyHeight).all(Double::isFinite) &&
            measuredWidth >= 0 && measuredHeight >= 0 && bodyHeight >= 0)
        return FieldWashProjection(layerX - pageX, layerY - pageY,
            -pageX, -pageY, measuredWidth - pageX, measuredHeight - pageY,
            layerY - pageY, layerY + bodyHeight - pageY)
    }

    companion object { const val UNDER_KEYBOARD = 600.0 }
}

internal data class FieldWashProjection(val translateX: Double, val translateY: Double,
    val clipLeft: Double, val clipTop: Double, val clipRight: Double, val clipBottom: Double,
    val bodyClipTop: Double, val bodyClipBottom: Double)

/** A drawing-only keyboardFollow track. A reversal samples the current pose; it cannot
 * move the input, request a keyboard, reveal Private, or accept a page action. */
internal class BrowserFieldWashMotion(initialBottom: Double) {
    init { require(initialBottom.isFinite() && initialBottom >= 0) }
    var value = initialBottom; private set
    private var from = value
    private var target = value
    private var clock = 0L
    private var start = 0L
    private var reduced = false
    var running = false; private set

    fun target(bottom: Double, now: Long, reduced: Boolean, animations: Boolean) {
        require(bottom.isFinite() && bottom >= 0)
        advance(now)
        if (bottom == target && reduced == this.reduced && animations) return
        from = value; target = bottom; start = clock; this.reduced = reduced
        running = animations && abs(from - target) > 1e-9
        if (!running) value = target
    }

    fun advance(now: Long): Double {
        clock = maxOf(clock, now)
        if (!running) return value
        val duration = if (reduced) 200_000_000.0 else 300_000_000.0
        val q = ((clock - start) / duration).coerceIn(0.0, 1.0)
        val t = if (reduced) curve(q, .42, 0.0, .58, 1.0) else curve(q, .2, .8, .2, 1.0)
        value = from + (target - from) * t
        if (q == 1.0) { value = target; running = false }
        return value
    }

    private fun curve(x: Double, x1: Double, y1: Double, x2: Double, y2: Double): Double {
        if (x <= 0 || x >= 1) return x.coerceIn(0.0, 1.0)
        fun at(a: Double, b: Double, t: Double): Double {
            val u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var low = 0.0; var high = 1.0
        repeat(40) { val t = (low + high) / 2; if (at(x1, x2, t) < x) low = t else high = t }
        return at(y1, y2, (low + high) / 2)
    }
}

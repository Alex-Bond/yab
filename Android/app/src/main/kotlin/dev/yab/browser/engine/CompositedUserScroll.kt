package dev.yab.browser.engine

/** Gecko's compositor reports CSS pixels; Chrome measures logical screen points. */
internal fun compositedUserScroll(cssY: Float, zoom: Float, density: Float, fromUser: Boolean): Float? {
    if (!fromUser || !cssY.isFinite() || !zoom.isFinite() || zoom <= 0f || !density.isFinite() || density <= 0f) return null
    val logical = cssY.toDouble().coerceAtLeast(0.0) * zoom / density
    return logical.takeIf { it.isFinite() && it <= Float.MAX_VALUE }?.toFloat()
}

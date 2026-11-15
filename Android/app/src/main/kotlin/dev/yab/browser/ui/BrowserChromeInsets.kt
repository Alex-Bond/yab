package dev.yab.browser.ui

/** The source's distance is from the pane edge, not from its navigation safe area.
 * Only an opaque/system-owned tap obstruction can increase it, never add it twice. */
internal fun browserChromeBottom(requested: Float, drawnHeight: Float, tappableBottom: Float): Float {
    require(listOf(requested, drawnHeight, tappableBottom).all { it.isFinite() && it >= 0 })
    val touchOutset = ((48f - drawnHeight) / 2).coerceAtLeast(0f)
    return maxOf(requested, tappableBottom + touchOutset)
}

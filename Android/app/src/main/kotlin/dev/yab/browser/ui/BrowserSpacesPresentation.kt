package dev.yab.browser.ui

/** The retained host owns lifetime, exact measured origin, frame clock and close generation.
 * [lower] receives cumulative screen-space dy in logical dp, down positive. The host converts
 * it to incremental lowerMoved calls and accepts the release velocity in logical dp/second. */
internal data class BrowserSpacesPresentation(
    val reveal: Double,
    val interactive: Boolean,
    val close: () -> Unit,
    val lower: (dy: Double, ended: Boolean, velocity: Double) -> Unit,
    val cancelLower: () -> Unit,
)

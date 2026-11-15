package dev.yab.browser.model

/** Measured root coordinates in logical pixels. This anchor is process-local and never synced. */
data class FieldAnchor(val x: Double, val y: Double, val width: Double, val height: Double) {
    fun valid() = listOf(x, y, width, height).all(Double::isFinite) && width > 0 && height > 0 &&
        width <= 100_000 && height <= 100_000 && kotlin.math.abs(x) <= 100_000 && kotlin.math.abs(y) <= 100_000
}

/** Opaque controller generation. Retained exit content never grants an input or page authority. */
class FieldPresentationLease internal constructor(internal val ownership: Long, val surfaceEpoch: Long)

/** Editor callbacks can outlive their composition; text is deliberately not part of this lease. */
class FieldInputLease internal constructor(internal val ownership: Long, internal val epoch: Long,
    internal val surface: BrowserSurface, internal val space: String?, internal val profile: WebsiteProfile?,
    internal val tab: String?, internal val url: String?, internal val newTab: Boolean, internal val privately: Boolean)

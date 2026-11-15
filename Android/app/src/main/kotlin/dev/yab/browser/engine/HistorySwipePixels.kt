package dev.yab.browser.engine

import android.graphics.Bitmap

/** One process-local renderer lease. Cache pixels are never recycled while published. */
internal class HistorySwipePixels(private var pixels: (() -> Bitmap?)?, private val current: () -> Boolean) {
    fun bitmapIfCurrent(): Bitmap? = if (current()) pixels?.invoke() else null
    fun close() { pixels = null }
}

internal data class HistoryPixelState(val firstPaint: Boolean, val pageStopped: Boolean,
    val spaDisqualified: Boolean, val frames: Int, val reservedFrames: Int, val nativeBusy: Boolean, val stage: String)

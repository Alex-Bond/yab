package dev.yab.browser.engine

import android.graphics.Bitmap

/** One presentation reference, never a cache entry. Published pixels are not recycled while a
 * Compose/render frame may still hold them; release only removes this owner's reference. */
class PagingFrame internal constructor(bitmap: Bitmap, private val current: () -> Boolean,
    release: () -> Unit = {}) {
    private var pixels: Bitmap? = bitmap
    private var release: (() -> Unit)? = release
    fun bitmapIfCurrent(): Bitmap? = pixels?.takeIf { current() }
    fun close() { pixels = null; release?.invoke(); release = null }
}

enum class PagingCaptureOutcome {
    READY, UNAVAILABLE, NOT_CURRENT, VIEW_UNAVAILABLE, COMPOSITOR_NOT_READY,
    DIMENSIONS_REFUSED, CAPTURE_FAILED, TIMED_OUT, REVOKED
}
data class PagingCaptureResult(val outcome: PagingCaptureOutcome, val frame: PagingFrame? = null)

/** Main-thread generation and allocation contract, shared by the real compositor adapter/tests. */
internal class PagingCaptureLifetime(private val arbiter: NativeFrameCaptureArbiter = NativeFrameCaptureArbiter()) {
    private var generation = 0L
    private var nativeTicket: NativeFrameCaptureArbiter.Ticket? = null
    fun tryBeginNative(): Boolean {
        if (nativeTicket != null) return false
        nativeTicket = arbiter.acquire() ?: return false
        return true
    }
    fun nativeFinished() { nativeTicket?.let(arbiter::finish); nativeTicket = null }
    fun begin(): Long { invalidate(); return generation }
    fun current(token: Long) = generation == token
    fun invalidate() { check(generation != Long.MAX_VALUE); generation++ }
    companion object {
        const val MAX_BYTES = 16L * 1024 * 1024
        const val MAX_DIMENSION = 8192
        const val DEADLINE_MILLIS = 400L
        fun permits(width: Int, height: Int): Boolean = width in 1..MAX_DIMENSION && height in 1..MAX_DIMENSION &&
            width.toLong() * height * 4 <= MAX_BYTES
    }
}

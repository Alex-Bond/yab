package dev.yab.browser.engine

import java.lang.ref.WeakReference

internal fun interface WeakFrameReference<T : Any> { fun get(): T? }

/** Logical ARGB frame budget, including in-flight allocations and published renderer references.
 * Does not include GPU surfaces/native compositor copies or other existing bounded caches. */
internal class NativeFrameBudget<T : Any>(private val weak: (T) -> WeakFrameReference<T> = { value ->
    val reference = WeakReference(value)
    WeakFrameReference { reference.get() }
}) {
    private val entries = linkedSetOf<Reservation>()

    inner class Reservation internal constructor() {
        private var valid = true
        private var started = false
        private var finished = false
        private var retained: WeakFrameReference<T>? = null
        private var published: WeakReference<BudgetedNativeFrame<T>>? = null
        val current get() = valid && this in entries
        val pending get() = started && !finished
        internal fun collected() = finished && retained?.get() == null

        /** Must happen BEFORE the actual native allocation. */
        fun startNative(): Boolean {
            if (!current || started) return false
            started = true; return true
        }
        /** Caller must recycle only unpublished pixels BEFORE releasing this reservation. */
        fun unpublishedFinished() {
            check(retained == null) { "Published pixels retain their weak allocation charge" }
            valid = false; finished = true; entries.remove(this)
        }
        fun publish(value: T): BudgetedNativeFrame<T>? {
            if (!current || !started || finished) return null
            retained = weak(value); finished = true
            return BudgetedNativeFrame(value, { current }) { collectReleased() }.also { published = WeakReference(it) }
        }
        /** A cancelled native request still owns its allocation until the real callback. */
        fun revoke() {
            valid = false
            published?.get()?.close()
            if (!started) { finished = true; entries.remove(this) }
        }
    }

    fun reserve(): Reservation? {
        collectReleased()
        if (entries.size >= MAX_FRAMES) return null
        return Reservation().also(entries::add)
    }
    fun collectReleased() { entries.removeAll { it.collected() } }
    fun revokeAll() { entries.toList().forEach { it.revoke() }; collectReleased() }
    val slots get() = entries.size
    val reservedBytes get() = entries.size * MAX_FRAME_BYTES
    companion object {
        const val MAX_FRAMES = 2
        const val MAX_FRAME_BYTES = 16L * 1024 * 1024
        const val MAX_TOTAL_BYTES = MAX_FRAMES * MAX_FRAME_BYTES
    }
}

/** Owner close drops only this reference. A renderer may still hold the same pixels safely. */
internal class BudgetedNativeFrame<T : Any> internal constructor(value: T, private val current: () -> Boolean,
    private val released: () -> Unit) {
    private var value: T? = value
    fun valueIfCurrent(): T? = value?.takeIf { current() }
    fun close() { value = null; released() }
}

package dev.yab.browser.ui

internal data class ReloadPose(val stop: Float = 0f, val rotation: Float = 0f, val opacity: Float = 1f)

/** Current Phone PlateMarks timing, driven by the caller's real or explicit test frame clock. */
internal class ReloadPresentation {
    private class Track(initial: Float) {
        var value = initial
        private var from = initial
        private var target = initial
        private var start = 0L
        private var duration = 0L
        private var symmetric = false
        fun set(target: Float, now: Long, millis: Long, symmetric: Boolean = false) {
            from = value; this.target = target; start = now
            duration = if (target == value) 0 else millis * 1_000_000L
            this.symmetric = symmetric
            if (duration == 0L) value = target
        }
        fun advance(now: Long) {
            if (duration == 0L) return
            val progress = ((now - start).coerceAtLeast(0).toDouble() / duration).coerceIn(0.0, 1.0)
            value = (from + (target - from) * curve(progress, symmetric)).toFloat()
            if (progress == 1.0) { value = target; duration = 0 }
        }
        val moving get() = duration != 0L
    }

    private val glyph = Track(0f)
    private val rotation = Track(0f)
    private val opacity = Track(1f)
    private var configured = false
    private var loading = false
    private var pressed = false
    private var reduced = false
    private var animations = true
    private var showingStop = false
    private var stopAt: Long? = null
    private var clock = 0L
    val pose get() = ReloadPose(glyph.value, rotation.value, opacity.value)
    val moving get() = stopAt != null || glyph.moving || rotation.moving || opacity.moving

    fun update(nanos: Long, loading: Boolean, pressed: Boolean, reduced: Boolean, animations: Boolean): ReloadPose {
        // A loading task cancelled between frames must not expire at the next
        // frame before its replacement is applied and flash an obsolete cross.
        if (!configured || this.loading != loading || this.animations != animations) stopAt = null
        advance(nanos)
        if (!configured || this.loading != loading || this.animations != animations) {
            stopAt = null
            if (loading && animations && !showingStop) stopAt = clock + 450_000_000L
            else if (showingStop != loading || !animations) show(loading, clock, animations)
        }
        val turns = !loading && !reduced && animations
        val turn = if (turns && pressed) 90f else 0f
        val dim = if (!turns && pressed) .6f else 1f
        val pressChanged = configured && this.pressed != pressed
        val contextChanged = !configured || this.loading != loading || this.reduced != reduced || this.animations != animations
        if (pressChanged || contextChanged) {
            // Phone's press animation is keyed by isPressed. A different action
            // or reduced-motion preference does not animate an old press state.
            val duration = if (pressChanged && animations) if (pressed) 100L else 140L else 0L
            rotation.set(turn, clock, duration)
            opacity.set(dim, clock, duration)
        }
        this.loading = loading; this.pressed = pressed; this.reduced = reduced; this.animations = animations
        configured = true
        return pose
    }

    fun advance(nanos: Long): ReloadPose {
        clock = maxOf(clock, nanos)
        stopAt?.takeIf { clock >= it }?.let { due ->
            glyph.advance(due)
            stopAt = null; show(true, due, animations)
        }
        glyph.advance(clock); rotation.advance(clock); opacity.advance(clock)
        return pose
    }

    private fun show(stop: Boolean, now: Long, animated: Boolean) {
        showingStop = stop
        glyph.set(if (stop) 1f else 0f, now, if (animated) 100 else 0, symmetric = true)
    }

    companion object {
        /** SwiftUI easeInOut=(.42,0,.58,1), easeOut=(0,0,.58,1). */
        private fun curve(x: Double, symmetric: Boolean): Double {
            if (x <= 0.0 || x >= 1.0) return x
            fun bezier(a: Double, b: Double, t: Double): Double {
                val u = 1 - t
                return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
            }
            var low = 0.0; var high = 1.0
            repeat(32) {
                val t = (low + high) / 2
                if (bezier(if (symmetric) .42 else 0.0, .58, t) < x) low = t else high = t
            }
            return bezier(0.0, 1.0, (low + high) / 2)
        }
    }
}

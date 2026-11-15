package dev.yab.agent

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.abs

internal enum class ParkedLinePhase { READY, DRAGGING, RETURNING, LEAVING, COMPLETE, REVOKED }
internal data class ParkedLineFrame(val phase: ParkedLinePhase = ParkedLinePhase.READY,
    val offset: Double = 0.0, val opacity: Double = 1.0, val velocity: Double = 0.0) {
    val running get() = phase == ParkedLinePhase.RETURNING || phase == ParkedLinePhase.LEAVING
    val interactive get() = phase in setOf(ParkedLinePhase.READY, ParkedLinePhase.DRAGGING, ParkedLinePhase.RETURNING)
}

/** Current Phone ParkedNowLine and Motion. Logical points; caller supplies a monotonic frame clock. */
internal class ParkedChatPresentation(val owner: ParkedChat) {
    private val mutable = MutableStateFlow(ParkedLineFrame())
    val frame = mutable.asStateFlow()
    private var clock = 0L
    private var start = 0L
    private var duration = 0L
    private var from = 0.0
    private var target = 0.0
    private var reduced = false
    private var dragBase = 0.0
    private var translation = 0.0
    private var completionClaimed = false

    fun beginDrag(nanos: Long): Boolean {
        advance(nanos)
        if (!frame.value.interactive) return false
        dragBase = frame.value.offset; translation = 0.0
        mutable.value = frame.value.copy(phase = ParkedLinePhase.DRAGGING, velocity = 0.0)
        return true
    }
    fun drag(distance: Double) {
        if (frame.value.phase != ParkedLinePhase.DRAGGING || !distance.isFinite()) return
        translation = distance
        val offset = dragBase + distance
        mutable.value = ParkedLineFrame(ParkedLinePhase.DRAGGING, offset, dragOpacity(offset))
    }
    fun release(velocity: Double, nanos: Long, reduceMotion: Boolean, animations: Boolean = true): Boolean {
        if (frame.value.phase != ParkedLinePhase.DRAGGING || !velocity.isFinite()) return false
        val commit = abs(translation) > distance || abs(velocity) > flick
        if (commit) leave(if (translation == 0.0) velocity else translation, nanos, reduceMotion, animations, velocity)
        else returnToRest(nanos, reduceMotion, animations)
        return commit
    }
    fun cancel(nanos: Long, reduceMotion: Boolean, animations: Boolean = true) {
        if (frame.value.phase == ParkedLinePhase.DRAGGING) returnToRest(nanos, reduceMotion, animations)
    }
    fun leave(direction: Double, nanos: Long, reduceMotion: Boolean, animations: Boolean = true, velocity: Double = 0.0) {
        advance(nanos)
        if (!frame.value.interactive || !direction.isFinite() || !velocity.isFinite()) return
        start(ParkedLinePhase.LEAVING, if (direction < 0) -flight else flight, nanos,
            reduceMotion, if (animations) 200 else 0, velocity)
    }
    private fun returnToRest(nanos: Long, reduceMotion: Boolean, animations: Boolean) {
        start(ParkedLinePhase.RETURNING, 0.0, nanos, reduceMotion,
            if (!animations) 0 else if (reduceMotion) 200 else 300, 0.0)
    }
    private fun start(phase: ParkedLinePhase, target: Double, nanos: Long, reduced: Boolean, millis: Int, velocity: Double) {
        clock = maxOf(clock, nanos); start = clock; duration = millis * 1_000_000L
        from = frame.value.offset; this.target = target; this.reduced = reduced
        mutable.value = ParkedLineFrame(phase, from, if (phase == ParkedLinePhase.LEAVING) exitOpacity(from) else dragOpacity(from), velocity)
        advance(clock)
    }
    fun advance(nanos: Long): ParkedLineFrame {
        clock = maxOf(clock, nanos)
        val current = frame.value
        if (!current.running) return current
        val fraction = if (duration == 0L) 1.0 else ((clock - start).coerceAtLeast(0).toDouble() / duration).coerceIn(0.0, 1.0)
        val eased = when {
            reduced -> curve(fraction, .42, 0.0, .58, 1.0)
            current.phase == ParkedLinePhase.LEAVING -> curve(fraction, .3, 0.0, .8, .2)
            else -> curve(fraction, .3, 1.2, .4, 1.0)
        }
        val offset = from + (target - from) * eased
        val phase = if (fraction < 1) current.phase else if (current.phase == ParkedLinePhase.LEAVING) ParkedLinePhase.COMPLETE else ParkedLinePhase.READY
        mutable.value = current.copy(phase = phase, offset = offset,
            opacity = if (current.phase == ParkedLinePhase.LEAVING) exitOpacity(offset) else dragOpacity(offset))
        return frame.value
    }
    fun claimCompletion(): Boolean {
        if (frame.value.phase != ParkedLinePhase.COMPLETE || completionClaimed) return false
        completionClaimed = true
        return true
    }
    fun revoke() { completionClaimed = true; mutable.value = ParkedLineFrame(ParkedLinePhase.REVOKED, opacity = 0.0) }

    companion object {
        const val minimum = 7.0
        const val distance = 110.0
        const val flick = 650.0
        const val flight = 420.0
        const val fade = 320.0
        private fun dragOpacity(offset: Double) = (1 - abs(offset) / fade).coerceIn(0.0, 1.0)
        private fun exitOpacity(offset: Double) = 1 - (abs(offset) / flight).coerceIn(0.0, 1.0)
        /** Solves the timing curve's x before evaluating y, retaining the return curve's overshoot. */
        internal fun curve(x: Double, x1: Double, y1: Double, x2: Double, y2: Double): Double {
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
}

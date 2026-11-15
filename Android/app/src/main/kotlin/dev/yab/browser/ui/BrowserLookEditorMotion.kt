package dev.yab.browser.ui

import kotlin.math.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Source response/damping values, not a measurement of SwiftUI's rendering or .snappy. */
internal enum class LookEditorFlight(val response: Double, val damping: Double) {
    DIRECT(.2, .75), LINKS(.2, .75), PRESET(.27, .65), PAGE(.32, 1.0),
}

/** Scalar mass-one spring. A new target keeps the sampled position and velocity. All
 * coordinates use a 1000-unit scale; hue is never interpolated through a long 2π arc. */
internal class LookEditorSpring(initial: Double) {
    var value = initial; private set
    var velocity = 0.0; private set
    private var target = initial
    private var response = .27
    private var damping = .65
    val moving get() = value != target || velocity != 0.0
    fun target(next: Double, response: Double, damping: Double, animated: Boolean) {
        require(next.isFinite() && response > 0 && response.isFinite() && damping in 0.0..1.0 && damping > 0)
        target = next; this.response = response; this.damping = damping
        if (!animated) snap(next)
    }
    fun snap(next: Double) { require(next.isFinite()); value = next; target = next; velocity = 0.0 }
    fun settle() = snap(target)
    fun advance(seconds: Double) {
        if (!moving || !seconds.isFinite() || seconds <= 0) return
        val w = 2 * PI / response
        val q = value - target
        val decay = exp(-damping * w * seconds)
        if (damping == 1.0) {
            val c = velocity + w * q
            value = target + (q + c * seconds) * decay
            velocity = (velocity - w * c * seconds) * decay
        } else {
            val wd = w * sqrt(1 - damping * damping)
            val b = (velocity + damping * w * q) / wd
            val c = cos(wd * seconds); val s = sin(wd * seconds)
            val v = q * c + b * s
            value = target + decay * v
            velocity = decay * ((-q * s + b * c) * wd - damping * w * v)
        }
        if (abs(value - target) < .04 && abs(velocity) < 2) settle()
    }
}

internal data class LookHandleTarget(val index: Int, val x: Double, val y: Double, val color: Long)
internal data class LookEditorFrame(val handles: List<LookHandleTarget>, val page: Double,
    val ring: Double?, val chosen: Map<Int, Double>, val running: Boolean = false)

/** Drawing only. Callers own original editor leases and every palette publication. Removed
 * links disappear immediately, while surviving handles retain their original tracks. New
 * links start at their target; implicit SwiftUI insertion/color transitions remain unclaimed. */
internal class BrowserLookEditorMotion(initial: List<LookHandleTarget>, page: Int, selected: Pair<Int, Int>?) {
    private class Handle(target: LookHandleTarget) {
        val x = LookEditorSpring(target.x * 1000); val y = LookEditorSpring(target.y * 1000)
        var color = target.color
    }
    private val handles = linkedMapOf<Int, Handle>().apply { initial.forEach { put(it.index, Handle(it)) } }
    private val pageTrack = LookEditorSpring(page * 1000.0)
    private var selected = selected
    private var ring = selected?.let { LookEditorSpring(ringPosition(it)) }
    private val chosen = linkedMapOf<Int, LookEditorSpring>().apply { selected?.let { put(id(it), LookEditorSpring(1000.0)) } }
    private var animations = true
    private var revoked = false
    private var previous: Long? = null
    private val mutable = MutableStateFlow(snapshot())
    val frame = mutable.asStateFlow()
    private fun tracks() = handles.values.flatMap { listOf(it.x, it.y) } + listOfNotNull(pageTrack, ring) + chosen.values
    private fun running() = !revoked && tracks().any { it.moving }
    private fun snapshot() = LookEditorFrame(handles.map { (index, handle) ->
        LookHandleTarget(index, handle.x.value / 1000, handle.y.value / 1000, handle.color)
    }, pageTrack.value / 1000, ring?.value?.div(1000), chosen.mapValues { it.value.value / 1000 }, running())
    private fun publish() { mutable.value = snapshot() }
    fun configure(animated: Boolean) {
        if (revoked || animations == animated) return
        animations = animated
        if (!animated) { tracks().forEach { it.settle() }; previous = null; publish() }
    }
    fun handles(next: List<LookHandleTarget>, flight: LookEditorFlight): Boolean {
        if (revoked) return false
        if (!running()) previous = null
        handles.keys.retainAll(next.map { it.index }.toSet())
        next.forEach { target ->
            val handle = handles.getOrPut(target.index) { Handle(target) }
            handle.color = target.color
            val animated = animations && flight != LookEditorFlight.DIRECT
            handle.x.target(target.x * 1000, flight.response, flight.damping, animated)
            handle.y.target(target.y * 1000, flight.response, flight.damping, animated)
        }
        publish(); return true
    }
    /** Stops a previous preset flight before a new physical drag owns the field. */
    fun rebase(): Boolean {
        if (revoked) return false
        handles.values.forEach { it.x.snap(it.x.value); it.y.snap(it.y.value) }
        publish(); return true
    }
    fun selected(next: Pair<Int, Int>?) {
        if (revoked || next == selected) return
        if (!running()) previous = null
        selected = next
        if (next == null) ring = null
        else {
            val at = ringPosition(next)
            if (ring == null) ring = LookEditorSpring(at)
            else ring!!.target(at, .27, .65, animations)
        }
        chosen.values.forEach { it.target(0.0, .27, .65, animations) }
        next?.let { chosen.getOrPut(id(it)) { LookEditorSpring(0.0) }.target(1000.0, .27, .65, animations) }
        publish()
    }
    fun page(next: Int) {
        if (revoked) return
        if (!running()) previous = null
        pageTrack.target(next.coerceIn(0, 4) * 1000.0, .32, 1.0, animations); publish()
    }
    fun onFrame(nanos: Long) {
        if (!running()) { previous = null; return }
        val elapsed = previous?.let { (nanos - it).coerceAtLeast(0) / 1e9 } ?: 0.0
        previous = nanos
        tracks().forEach { it.advance(elapsed) }
        chosen.entries.removeAll { it.value.value == 0.0 && !it.value.moving }
        if (!running()) previous = null
        publish()
    }
    fun revoke() { revoked = true; previous = null; publish() }
    companion object {
        fun id(selected: Pair<Int, Int>) = selected.first * 100 + selected.second
        private fun ringPosition(selected: Pair<Int, Int>) = (selected.first + (selected.second + .5) / 9) * 1000
    }
}

internal data class LookEditorPressFrame(val amount: Double = 0.0, val running: Boolean = false)
internal class BrowserLookEditorPress {
    private val spring = LookEditorSpring(0.0)
    private var pressed = false
    private var animated = true
    private var previous: Long? = null
    private val mutable = MutableStateFlow(LookEditorPressFrame())
    val frame = mutable.asStateFlow()
    fun target(pressed: Boolean, animated: Boolean) {
        if (this.pressed == pressed && this.animated == animated) return
        if (!spring.moving) previous = null
        this.pressed = pressed; this.animated = animated
        spring.target(if (pressed) 1000.0 else 0.0, if (pressed) .16 else .28, 1.0, animated)
        publish()
    }
    fun onFrame(nanos: Long) {
        if (!spring.moving) { previous = null; return }
        val elapsed = previous?.let { (nanos - it).coerceAtLeast(0) / 1e9 } ?: 0.0
        previous = nanos; spring.advance(elapsed)
        if (!spring.moving) previous = null
        publish()
    }
    private fun publish() { mutable.value = LookEditorPressFrame(spring.value / 1000, spring.moving) }
}

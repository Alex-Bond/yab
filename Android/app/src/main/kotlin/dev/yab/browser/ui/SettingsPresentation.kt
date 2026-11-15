package dev.yab.browser.ui

import kotlin.math.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import dev.yab.browser.model.SettingsDestination

internal enum class SettingsPhase { MOUNTED, OPENING, OPEN, DRAGGING, CLOSING, CLOSED, REVOKED }
internal data class SettingsRouteFrame(val id: Long, val title: String, val x: Double, val dim: Double,
    val visible: Boolean, val interactive: Boolean, val retired: Boolean = false,
    val destination: SettingsDestination = SettingsDestination.Page(title))
internal data class SettingsFrame(val phase: SettingsPhase = SettingsPhase.MOUNTED, val offset: Double = 1.0,
    val opacity: Double = 1.0, val drag: Double = 0.0, val presence: Double = 0.0,
    val running: Boolean = false, val routes: List<SettingsRouteFrame> = emptyList(),
    val canBack: Boolean = false, val generation: Long = 0, val sheetSettled: Boolean = false, val backButton: Double = 0.0, val shadow: Double = 0.0) {
    val shown get() = phase !in setOf(SettingsPhase.CLOSING, SettingsPhase.CLOSED, SettingsPhase.REVOKED)
    val title get() = routes.lastOrNull { it.interactive }?.title ?: routes.lastOrNull { !it.retired }?.title ?: "Settings"
}

/** SettingsLook's actual consumer: open500/close300/push420/back350. The comment above
 * SettingsSheet is older than settingsBody; the body uses a horizontal third-width stack.
 * Numeric source timing is not a claim about SwiftUI's presented frames. */
internal class SettingsPresentation(initialPage: String = "Settings") {
    private data class Route(val id: Long, val title: String, val position: SettingsTrack, var retired: Boolean = false,
        val destination: SettingsDestination = SettingsDestination.Page(title))
    private val mutable = MutableStateFlow(SettingsFrame())
    val frame = mutable.asStateFlow()
    var beforeRouteLeave: ((Long) -> Unit)? = null
    private val position = SettingsTrack(1.0)
    private val opacity = SettingsTrack(1.0)
    private val drag = SettingsTrack(0.0)
    private val head = SettingsTrack(0.0)
    private val grown = SettingsTrack(0.0)
    private var clock = 0L
    private var serial = 0L
    private var generation = 0L
    private var phase = SettingsPhase.MOUNTED
    private var shown = true
    private var reduced = false
    private var animations = true
    private var dragHeight = 1.0
    private var edgeRoute: Long? = null
    private data class EdgeCompletion(val route: Long, val path: List<Long>, val generation: Long)
    private var edgeCompletion: EdgeCompletion? = null
    private var edgePath = emptyList<Long>()
    private val routes = mutableListOf(Route(serial++, "Settings", SettingsTrack(0.0)))
    private val openedAt = initialPage.takeUnless { it == "Settings" }
    init {
        if (openedAt != null) {
            routes[0].position.snap(-1.0 / 3)
            routes += Route(serial++, openedAt, SettingsTrack(0.0))
        }
        publish()
    }
    fun show(now: Long, reduced: Boolean, animations: Boolean) {
        val mounted = phase == SettingsPhase.MOUNTED
        advance(now)
        if (!mounted && drag.value != 0.0) position.snap((position.value + drag.value / dragHeight).coerceIn(0.0, 1.0))
        val interruptedEdge = edgeCompletion != null
        edgeCompletion = null
        if (interruptedEdge) retarget(350)
        generation++; shown = true; phase = SettingsPhase.OPENING
        configure(reduced, animations)
        if (mounted && reduced && animations) { position.snap(0.0); opacity.snap(0.0) }
        position.to(0.0, clock, if (reduced || !animations) 0 else 500, OPEN)
        grown.to(1.0, clock, if (!animations) 0 else if (reduced) 200 else 500, if (reduced) FADE else OPEN)
        opacity.to(1.0, clock, if (reduced && animations) 200 else 0, FADE)
        drag.to(0.0, clock, 0, BACK)
        publish(); advance(clock)
    }
    fun hide(now: Long, flick: Boolean = false): Boolean {
        advance(now)
        if (!shown || phase in setOf(SettingsPhase.CLOSED, SettingsPhase.REVOKED)) return false
        val revision = generation
        routes.lastOrNull { !it.retired }?.let { beforeRouteLeave?.invoke(it.id) }
        if (generation != revision || !shown) return false
        val interruptedEdge = edgeCompletion != null
        edgeCompletion = null
        if (interruptedEdge) retarget(350)
        generation++; shown = false; edgeRoute = null; phase = SettingsPhase.CLOSING
        if (flick && !reduced && animations) drag.spring(dragHeight, clock, .32, 1.0)
        else {
            position.to(if (reduced) 0.0 else 1.0, clock, if (reduced || !animations) 0 else 300, CLOSE)
            opacity.to(if (reduced) 0.0 else 1.0, clock, if (reduced && animations) 200 else 0, FADE)
        }
        publish(); advance(clock); return true
    }
    fun configure(reduced: Boolean, animations: Boolean) {
        this.reduced = reduced; this.animations = animations
        if (!animations) {
            position.snap(if (shown) 0.0 else 1.0); opacity.snap(if (shown) 1.0 else 0.0)
            drag.snap(0.0); grown.snap(if (shown) 1.0 else 0.0)
            routes.forEach { it.position.snap(target(it)) }; head.snap(headTarget())
        } else if (reduced) {
            // SettingsSheet disables its child navigation transactions under Reduce Motion.
            routes.forEach { it.position.snap(target(it)) }; head.snap(headTarget())
            if (phase == SettingsPhase.MOUNTED) { position.snap(0.0); opacity.snap(0.0) }
        }
        publish()
    }
    fun push(title: String, now: Long): Boolean = pushAll(listOf(SettingsDestination.Page(title)), now)
    fun pushAll(destinations: List<SettingsDestination>, now: Long): Boolean {
        advance(now)
        if (!shown || phase == SettingsPhase.REVOKED || destinations.isEmpty() || destinations.size > 2 || destinations.any { it.title.isBlank() }) return false
        edgeRoute = null; edgeCompletion = null
        destinations.forEach { destination ->
            routes += Route(serial++, destination.title, SettingsTrack(if (reduced || !animations) 0.0 else 1.0), destination = destination)
        }
        retarget(420); generation++; publish(); return true
    }
    /** An explicit newly-owned create request after Private revocation cannot reuse old pixels.
     * Start its safe public sheet settled. Continuous cross-owner geometry remains unverified. */
    fun showSettled(now: Long, reduced: Boolean, animations: Boolean) {
        advance(now); generation++; shown = true; phase = SettingsPhase.OPEN
        edgeRoute = null; edgeCompletion = null; this.reduced = reduced; this.animations = animations
        position.snap(0.0); opacity.snap(1.0); grown.snap(1.0); drag.snap(0.0)
        routes.forEach { it.position.snap(target(it)) }; head.snap(headTarget()); publish()
    }
    fun back(now: Long): Boolean {
        advance(now)
        if (!shown || !canBack) return false
        val leaving = routes.last { !it.retired }.id
        val revision = generation
        beforeRouteLeave?.invoke(leaving)
        if (generation != revision || !routeCurrent(leaving)) return false
        edgeRoute = null; edgeCompletion = null
        routes.last { !it.retired }.retired = true
        retarget(350); generation++; publish(); return true
    }
    fun routeCurrent(id: Long) = shown && phase !in setOf(SettingsPhase.CLOSED, SettingsPhase.REVOKED) &&
        routes.lastOrNull { !it.retired }?.id == id
    fun routeCurrent(id: Long, revision: Long) = generation == revision && routeCurrent(id)
    fun beginBack(id: Long, now: Long): Boolean {
        advance(now)
        if (!canBack || !routeCurrent(id)) return false
        edgeCompletion = null
        edgeRoute = id; edgePath = routes.filterNot { it.retired }.map { it.id }
        routes.filterNot { it.retired }.forEach { it.position.stop() }; head.stop()
        return true
    }
    fun pullBack(id: Long, fraction: Double) {
        if (!validEdge(id) || !fraction.isFinite()) return
        val p = fraction.coerceAtLeast(0.0)
        val active = routes.filterNot { it.retired }
        active.last().position.snap(p)
        active[active.lastIndex - 1].position.snap(-1.0 / 3 * (1 - p.coerceAtMost(1.0)))
        head.snap(if (active.size == (if (openedAt == null) 2 else 3)) 1 - p.coerceAtMost(1.0) else 1.0)
        publish()
    }
    fun endBack(id: Long, width: Double, velocity: Double, now: Long, cancelled: Boolean = false): Boolean {
        advance(now)
        if (!validEdge(id) || !width.isFinite() || width <= 0 || !velocity.isFinite()) return false
        val pulled = routes.last { !it.retired }.position.value * width
        val commit = !cancelled && (pulled + velocity * .16 > width * .4 || velocity > 600)
        edgeRoute = null
        if (commit) {
            // Phone keeps navigation.last until this edge flight lands. Button Back remains
            // immediate; it cancels this captured completion before changing the path.
            edgeCompletion = EdgeCompletion(id, edgePath, generation)
            retarget(350); advance(clock)
        } else { retarget(350); publish() }
        return commit
    }
    fun pullSheet(distance: Double, height: Double, now: Long) {
        if (!shown || !distance.isFinite() || !height.isFinite() || height <= 0) return
        advance(now)
        if (edgeCompletion != null) { edgeCompletion = null; retarget(350) }
        dragHeight = height; phase = SettingsPhase.DRAGGING
        drag.snap(distance.coerceAtLeast(0.0)); publish()
    }
    fun releaseSheet(velocity: Double, now: Long, cancelled: Boolean = false): Boolean {
        advance(now)
        if (phase != SettingsPhase.DRAGGING || !velocity.isFinite()) return false
        val close = !cancelled && (drag.value > 120 || velocity > 600)
        if (close) hide(clock, flick = true)
        else {
            phase = SettingsPhase.OPENING
            if (reduced || !animations) drag.to(0.0, clock, if (animations) 200 else 0, FADE)
            else drag.spring(0.0, clock, .32, .9)
            publish()
        }
        return close
    }
    fun advance(now: Long): SettingsFrame {
        clock = maxOf(clock, now)
        if (phase in setOf(SettingsPhase.CLOSED, SettingsPhase.REVOKED)) return frame.value
        listOf(position, opacity, drag, head, grown).forEach { it.sample(clock) }
        routes.forEach { it.position.sample(clock) }
        finishEdge()
        routes.removeAll { it.retired && !it.position.running && it.position.value == 1.0 }
        if (!shown && !position.running && !opacity.running && !drag.running) {
            phase = SettingsPhase.CLOSED
            listOf(position, opacity, drag, head, grown).forEach(SettingsTrack::stop)
            routes.forEach { it.position.stop() }
        } else if (shown && !moving && phase != SettingsPhase.DRAGGING) phase = SettingsPhase.OPEN
        publish(); return frame.value
    }
    fun revoke() {
        shown = false; generation++; edgeRoute = null; edgeCompletion = null; phase = SettingsPhase.REVOKED
        listOf(position, opacity, drag, head, grown).forEach(SettingsTrack::stop)
        routes.clear(); publish()
    }
    private fun validEdge(id: Long) = edgeRoute == id && routeCurrent(id) &&
        edgePath == routes.filterNot { it.retired }.map { it.id }
    private val canBack get() = routes.count { !it.retired } > if (openedAt == null) 1 else 2
    private val moving get() = position.running || opacity.running || drag.running || head.running || grown.running || routes.any { it.position.running }
    private fun finishEdge() {
        val pending = edgeCompletion ?: return
        val active = routes.filterNot { it.retired }
        if (!shown || pending.generation != generation || pending.path != active.map { it.id } ||
            active.lastOrNull()?.id != pending.route) { edgeCompletion = null; return }
        val top = active.last()
        if (top.position.running || top.position.value != 1.0) return
        beforeRouteLeave?.invoke(top.id)
        if (edgeCompletion !== pending || generation != pending.generation || pending.path != routes.filterNot { it.retired }.map { it.id }) return
        // No old completion may remove a new push, a regrab, reopened sheet or source.
        edgeCompletion = null
        routes.remove(top)
        generation++
        head.snap(headTarget())
    }
    private fun headTarget(): Double = if (edgeCompletion != null) {
        if (routes.count { !it.retired } - 1 > if (openedAt == null) 1 else 2) 1.0 else 0.0
    } else if (canBack) 1.0 else 0.0
    private fun target(route: Route): Double {
        val pending = edgeCompletion
        if (pending != null && !route.retired) {
            val active = routes.filterNot { it.retired }
            if (route === active.lastOrNull()) return 1.0
            if (route === active.dropLast(1).lastOrNull()) return 0.0
        }
        if (route.retired) return 1.0
        return if (routes.lastOrNull { !it.retired } === route) 0.0 else -1.0 / 3
    }
    private fun retarget(millis: Long) { routes.forEach {
        it.position.to(target(it), clock, if (reduced || !animations) 0 else millis, BACK)
    }; head.to(headTarget(), clock, if (reduced || !animations) 0 else millis, BACK) }
    private fun publish() {
        val active = routes.filterNot { it.retired }
        val top = active.lastOrNull()
        val under = active.dropLast(1).lastOrNull()
        val visible = routes.map { r -> SettingsRouteFrame(r.id, r.title, r.position.value,
            (-r.position.value * .24).coerceIn(0.0, .08), r === top || r === under || r.retired,
            routeCurrent(r.id), r.retired, r.destination) }
        mutable.value = SettingsFrame(phase, if (reduced) 0.0 else position.value, opacity.value, if (reduced) 0.0 else drag.value,
            ((1 - position.value).coerceIn(0.0, 1.0) * opacity.value * (1 - drag.value / dragHeight).coerceIn(0.0, 1.0)),
            moving, visible, canBack, generation, shown && phase != SettingsPhase.DRAGGING && !position.running && !opacity.running && !drag.running, head.value, .18 * grown.value.coerceIn(0.0, 1.0))
    }
    companion object {
        private val OPEN = doubleArrayOf(.32, .72, 0.0, 1.0)
        private val CLOSE = doubleArrayOf(.4, 0.0, .8, .2)
        private val BACK = OPEN
        private val FADE = doubleArrayOf(.42, 0.0, .58, 1.0)
    }
}

private class SettingsTrack(initial: Double) {
    var value = initial; private set
    var running = false; private set
    private var from = initial
    private var target = initial
    private var start = 0L
    private var duration = 0L
    private var curve = doubleArrayOf(.0, .0, 1.0, 1.0)
    private var response = .32
    private var damping = 1.0
    private var spring = false
    fun snap(next: Double) { value = next; running = false }
    fun stop() { running = false }
    fun to(next: Double, now: Long, millis: Long, curve: DoubleArray) {
        sample(now); from = value; target = next; start = now; duration = millis * 1_000_000; this.curve = curve; spring = false
        running = millis > 0 && abs(target - value) > 1e-9
        if (!running) snap(target)
    }
    fun spring(next: Double, now: Long, response: Double, damping: Double) {
        sample(now); from = value; target = next; start = now; spring = true; this.response = response; this.damping = damping
        running = abs(target - value) > 1e-9
    }
    fun sample(now: Long) {
        if (!running) return
        // Both the curve and the spring start at the exact captured value. Inverting the
        // Bezier with a finite binary search at x0 otherwise invents an initial displacement.
        if (now <= start) { value = from; return }
        val seconds = (now - start).coerceAtLeast(0).toDouble() / 1e9
        if (spring) {
            val w = 2 * PI / response
            val y = from - target
            value = if (damping < 1) {
                val d = w * sqrt(1 - damping * damping)
                target + exp(-damping * w * seconds) * (y * cos(d * seconds) + damping * w * y / d * sin(d * seconds))
            } else target + y * (1 + w * seconds) * exp(-w * seconds)
            if (seconds > 3 || abs(value - target) < .001 && seconds > response) snap(target)
        } else {
            val x = ((now - start).coerceAtLeast(0).toDouble() / duration).coerceIn(0.0, 1.0)
            fun at(a: Double, b: Double, t: Double): Double { val u = 1 - t; return 3*u*u*t*a + 3*u*t*t*b + t*t*t }
            var low = 0.0; var high = 1.0
            repeat(40) { val t = (low + high) / 2; if (at(curve[0], curve[2], t) < x) low = t else high = t }
            value = from + (target - from) * at(curve[1], curve[3], (low + high) / 2)
            if (x == 1.0) snap(target)
        }
    }
}

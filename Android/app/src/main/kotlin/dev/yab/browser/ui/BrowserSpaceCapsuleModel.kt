package dev.yab.browser.ui

import kotlin.math.*

/** The current Phone CapsuleModel's deterministic six-spring model, in logical points/dp.
 * Name widths are native measurements supplied by the renderer, not guessed from characters.
 * Source equivalence still requires native frame and font acceptance. */
internal class BrowserSpaceCapsuleModel(
    val widths: List<Double>, current: Int, val mid: Double,
    val restWidth: Double, val wideWidth: Double, pair: Boolean,
) {
    internal class Spring(value: Double, var response: Double, val epsilon: Double = 0.002) {
        var value = value
        var target = value
        var velocity = 0.0
        val atRest get() = value == target && velocity == 0.0
        fun jump(next: Double) { value = next; target = next; velocity = 0.0 }
        fun step(dt: Double) {
            if (atRest) return
            val w = 2 * PI / response
            velocity += (-w * w * (value - target) - 2 * w * velocity) * dt
            value += velocity * dt
            if (abs(value - target) < epsilon && abs(velocity) < epsilon * 10) { value = target; velocity = 0.0 }
        }
    }
    enum class Mode { HUG, CENTER, DRAG }
    sealed interface Event {
        data class Tap(val index: Int) : Event
        data class Release(val index: Int) : Event
        data object PressCurrent : Event
    }
    private data class Drag(var x0: Double, var tx0: Double, var moved: Boolean = false,
        var lastX: Double, var lastTime: Double, var velocity: Double = 0.0,
        val startIndex: Int, var anchor: Double = 0.0)

    val centers: List<Double> = buildList { var x = 0.0; for (width in widths) { add(x + width / 2); x += width } }
    val total = widths.sum()
    val count get() = widths.size
    private val pair = pair && count == 2
    var current = if (count == 0) 0 else current.coerceIn(0, count - 1)
        private set
    var mode = Mode.CENTER
        private set
    var rest = 9.0
        private set
    var viaTap = false
        private set
    var time = 0.0
        private set
    var ticks = 0
        private set
    var external = false
        private set
    private var stripMoving = false
    private var from = -1
    private var drag: Drag? = null
    private var lastIndex = this.current
    private var pressUntil: Double? = null
    val trackX = Spring(0.0, TRACK_RESPONSE, 0.01)
    val capWidth = Spring(restWidth, CAP_RESPONSE, 0.01)
    val side = Spring(0.0, SIDE_RESPONSE)
    val fraction = Spring(this.current.toDouble(), F_RESPONSE, 0.0005)
    val press = Spring(0.0, PRESS_RESPONSE)
    val pull = Spring(0.0, SIDE_RESPONSE)

    init {
        require(widths.all { it.isFinite() && it > 0 } && mid.isFinite() && restWidth > 0 && restWidth.isFinite() && wideWidth >= restWidth && wideWidth.isFinite())
        if (hugs(this.current)) mode = Mode.HUG
        val target = if (hugs(this.current)) hugTarget(this.current) else restWidth to centerTarget(this.current)
        capWidth.jump(target.first); trackX.jump(target.second)
    }
    fun interpolate(values: List<Double>, at: Double): Double {
        if (values.isEmpty()) return 0.0
        val i = floor(at).toInt().coerceIn(0, values.lastIndex)
        val j = min(i + 1, values.lastIndex)
        return values[i] + (values[j] - values[i]) * (at - i)
    }
    private fun centerTarget(index: Int) = mid - interpolate(centers, index.toDouble())
    private fun hugs(index: Int) = pair || count > 2 && (index == 0 || index == count - 1)
    private fun neighbor(index: Int): Int? = when {
        index + from in widths.indices -> index + from
        index - 1 >= 0 -> index - 1
        index + 1 < count -> index + 1
        else -> null
    }
    /** Width then track-left, including the end slot's three-point lens inset. */
    fun hugTarget(index: Int): Pair<Double, Double> {
        if (widths.isEmpty()) return restWidth to mid
        val pad = LENS_LESS / 2 - INSET
        fun left(i: Int) = centers[i] - widths[i] / 2
        fun right(i: Int) = centers[i] + widths[i] / 2
        var a = index; var b = index
        val other = neighbor(index)
        if (other != null && max(right(index), right(other)) - min(left(index), left(other)) - 2 * pad <= restWidth) {
            a = min(index, other); b = max(index, other)
        }
        val span = right(b) - left(a) - 2 * pad
        val width = min(restWidth, span)
        val x = if (span > restWidth) mid - centers[index] else mid - width / 2 - pad - left(a)
        return width to x
    }
    val capLeft get() = mid - capWidth.value / 2
    val isTouched get() = drag != null
    val isDragging get() = drag?.moved == true
    val isSettled: Boolean get() {
        if (drag != null || pressUntil != null || stripMoving) return false
        if (hugs(current) && mode != Mode.HUG) return false
        if (mode == Mode.CENTER && (side.target != 0.0 || capWidth.target != restWidth)) return false
        return trackX.atRest && capWidth.atRest && side.atRest && fraction.atRest && press.atRest && pull.atRest
    }
    val pose: BrowserSpaceCapsulePose get() {
        val reach = LENS_LESS / 2 - INSET
        return BrowserSpaceCapsulePose(capLeft, capWidth.value, trackX.value,
            trackX.value + interpolate(centers, fraction.value), max(0.0, interpolate(widths, fraction.value) - LENS_LESS),
            fraction.value, side.value.coerceIn(0.0, 1.0), max(0.0, press.value),
            trackX.value < capLeft - reach - 0.5, trackX.value + total > capLeft + capWidth.value + reach + 0.5)
    }
    fun hit(x: Double): Int? {
        if (x < capLeft || x > capLeft + capWidth.value) return null
        val u = x - trackX.value
        return centers.indices.firstOrNull { abs(u - centers[it]) <= widths[it] / 2 }
    }
    fun reset(index: Int) {
        if (count == 0) return
        val i = index.coerceIn(0, count - 1)
        drag = null; pressUntil = null; external = false; stripMoving = false; viaTap = false
        current = i; lastIndex = i; from = -1; rest = 9.0
        mode = if (hugs(i)) Mode.HUG else Mode.CENTER
        val target = if (hugs(i)) hugTarget(i) else restWidth to centerTarget(i)
        capWidth.jump(target.first); trackX.jump(target.second)
        side.jump(0.0); fraction.jump(i.toDouble()); press.jump(0.0); pull.jump(0.0)
    }
    fun follow(position: Double, index: Int) {
        if (count == 0) return
        val p = position.coerceIn(0.0, (count - 1).toDouble())
        drag = null; external = true
        stripMoving = abs(p - p.roundToInt()) > 0.002
        current = index.coerceIn(0, count - 1)
        if (stripMoving) { mode = Mode.CENTER; viaTap = false; rest = 0.0 }
        fraction.jump(p); lastIndex = p.roundToInt()
        if (mode != Mode.HUG) trackX.jump(mid - interpolate(centers, p))
    }
    fun down(x: Double, now: Double = time) {
        external = false; stripMoving = false
        drag = Drag(x, trackX.value, lastX = x, lastTime = now, startIndex = current)
    }
    fun move(x: Double, now: Double = time) {
        val d = drag ?: return
        val dx = x - d.x0
        if (!d.moved && abs(dx) > SLOP) {
            d.moved = true; viaTap = false; mode = Mode.DRAG
            side.target = 1.0; capWidth.target = wideWidth; pull.target = 1.0
            trackX.response = TRACK_RESPONSE; fraction.response = F_RESPONSE
            d.x0 = x; d.tx0 = trackX.value; d.anchor = fraction.value
        }
        if (d.moved) {
            val lo = mid - (centers.lastOrNull() ?: 0.0); val hi = mid - (centers.firstOrNull() ?: 0.0)
            var tx = d.tx0 + x - d.x0
            if (tx > hi) tx = hi + (tx - hi) * RUBBER
            if (tx < lo) tx = lo + (tx - lo) * RUBBER
            trackX.jump(tx)
            val dt = max(0.001, now - d.lastTime)
            d.velocity = d.velocity * 0.6 + 0.4 * ((x - d.lastX) / dt)
            d.lastX = x; d.lastTime = now
        }
    }
    fun up(x: Double): Event? {
        val d = drag ?: return null
        drag = null
        if (!d.moved) return hit(x)?.let(::select)
        val projected = trackX.value + d.velocity * PROJECTION
        var index = 0; var best = Double.MAX_VALUE
        for ((i, center) in centers.withIndex()) if (abs(mid - projected - center) < best) { best = abs(mid - projected - center); index = i }
        from = if (index < d.startIndex) 1 else if (index > d.startIndex) -1 else from
        current = index; mode = Mode.CENTER; rest = 0.0; pull.target = 0.0
        trackX.response = TRACK_RESPONSE; fraction.response = F_RESPONSE
        trackX.velocity = d.velocity; trackX.target = centerTarget(index); fraction.target = index.toDouble()
        return Event.Release(index)
    }
    fun cancel() {
        val d = drag ?: return
        drag = null
        if (!d.moved) return
        mode = Mode.CENTER; rest = 0.0; pull.target = 0.0
        trackX.target = centerTarget(current); fraction.target = current.toDouble()
    }
    fun select(index: Int): Event? {
        if (index !in widths.indices) return null
        external = false; stripMoving = false
        if (index == current) { press.target = 1.0; pressUntil = time + 0.09; return Event.PressCurrent }
        from = if (index < current) 1 else -1
        current = index; fraction.target = index.toDouble(); ticks++
        trackX.response = TAP_RESPONSE; fraction.response = TAP_RESPONSE
        if (!pair) { mode = if (hugs(index)) Mode.HUG else Mode.CENTER; viaTap = true }
        return Event.Tap(index)
    }
    fun step(dt: Double) {
        if (dt <= 0 || !dt.isFinite()) return
        val n = max(1, ceil(dt * 240).toInt())
        repeat(n) { substep(dt / n) }
    }
    private fun substep(dt: Double) {
        time += dt
        pressUntil?.let { if (time > it) { press.target = 0.0; pressUntil = null } }
        when (mode) {
            Mode.DRAG -> {
                val anchor = drag?.anchor ?: fraction.value
                val attached = trackX.value + interpolate(centers, anchor)
                val u = attached + (mid - attached) * pull.value - trackX.value
                var at = 0.0
                for (i in 0 until max(0, count - 1)) if (u >= centers[i]) at = i + min(1.0, (u - centers[i]) / (centers[i + 1] - centers[i]))
                if (count > 0 && u < centers[0]) at = 0.0
                fraction.jump(at)
                val index = at.roundToInt()
                if (index != lastIndex) { lastIndex = index; ticks++ }
            }
            Mode.CENTER -> {
                if (!external) { trackX.target = centerTarget(current); fraction.target = current.toDouble() }
                val still = if (external) !stripMoving else abs(trackX.value - trackX.target) < 0.6 && abs(trackX.velocity) < 8
                rest = if (still) rest + dt else 0.0
                val back = viaTap || rest >= BACK
                side.target = if (back) 0.0 else 1.0; capWidth.target = if (back) restWidth else wideWidth
                if (!external) {
                    val index = fraction.value.roundToInt()
                    if (index != lastIndex) { lastIndex = index; if (!viaTap) ticks++ }
                }
                if (hugs(current) && rest >= BACK + HUG) mode = Mode.HUG
            }
            Mode.HUG -> Unit
        }
        if (mode == Mode.HUG) {
            val target = hugTarget(current)
            capWidth.target = target.first; trackX.target = target.second; side.target = 0.0
            if (!external) fraction.target = current.toDouble()
            lastIndex = current
        }
        if (mode != Mode.DRAG && !(external && mode == Mode.CENTER)) { trackX.step(dt); if (!external) fraction.step(dt) }
        capWidth.step(dt); side.step(dt); press.step(dt); pull.step(dt)
    }
    companion object {
        const val INSET = 3.0
        const val LENS_HEIGHT = 44.0
        const val LENS_LESS = 12.0
        const val EDGE = 18.0
        const val SLOP = 6.0
        const val BACK = 0.28
        const val HUG = 0.3
        const val PROJECTION = 0.16
        const val RUBBER = 0.35
        const val TRACK_RESPONSE = 0.32
        const val CAP_RESPONSE = 0.42
        const val SIDE_RESPONSE = 0.33
        const val F_RESPONSE = 0.32
        const val PRESS_RESPONSE = 0.18
        const val TAP_RESPONSE = 0.2
    }
}

internal data class BrowserSpaceCapsulePose(val left: Double, val width: Double, val trackX: Double,
    val lensCenter: Double, val lensWidth: Double, val fraction: Double, val side: Double,
    val press: Double, val fadeLeft: Boolean, val fadeRight: Boolean)

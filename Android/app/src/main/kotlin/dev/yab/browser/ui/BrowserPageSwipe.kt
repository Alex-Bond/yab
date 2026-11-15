package dev.yab.browser.ui

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Current Phone Pager's point-space rules. No pixels, persistence or engine authority. */
internal object BrowserPageSwipeMath {
    const val commit = 150.0
    const val projection = 0.2
    const val cardCorner = 55.0
    fun slot(width: Double): Double {
        require(width.isFinite() && width > 0)
        return (width + 117.0) / 1.2
    }
    fun beside(width: Double, offset: Double): Pair<Double, Double> =
        (min(0.0, 1.2 * max(offset, 0.0) - 117.0) - width) to
            max(0.0, width + 117.0 + 1.2 * min(offset, 0.0))
    private fun rubber(x: Double, distance: Double): Double =
        (if (x < 0) -1 else 1) * (1 - 1 / (abs(x) * 0.55 / distance + 1)) * distance
    fun edge(raw: Double, slot: Double, hasBefore: Boolean, hasAfter: Boolean): Double = when {
        raw > 0 && !hasBefore -> rubber(raw, 70.0)
        raw < -slot && !hasAfter -> -slot - rubber(-slot - raw, 40.0)
        else -> raw
    }
    /** Phone intentionally uses <= for New Tab and strict inequalities for existing tabs. */
    fun destination(projected: Double, hasBefore: Boolean, hasAfter: Boolean): Int = when {
        !hasAfter && projected <= -commit -> 1
        hasAfter && projected < -commit -> 1
        hasBefore && projected > commit -> -1
        else -> 0
    }
}

/** One gesture and its interruptible spring. The host must recheck its opaque source lease
 * before drawing, advancing, or acting on an event. A model event grants no authority. */
internal class BrowserPageSwipeModel(val width: Double, val hasBefore: Boolean, val hasAfter: Boolean) {
    sealed interface Event {
        data class Settled(val direction: Int) : Event
        data object Blank : Event
    }
    val slot = BrowserPageSwipeMath.slot(width)
    var offset = 0.0; private set
    var velocity = 0.0; private set
    var target = 0.0; private set
    var moving = false; private set
    var touching = false; private set
    var blank = false; private set
    var active = true; private set
    var ticks = 0; private set
    var edgeTicks = 0; private set
    private var origin = 0.0
    private var landingNewTab = false
    private var step = 0
    private var response = 0.3
    private var decided = 0
    private var resisted = false

    fun down(): Boolean {
        if (!active || blank) return false
        moving = false
        landingNewTab = false
        origin = offset
        touching = true
        return true
    }

    fun move(translation: Double) {
        if (!touching || !translation.isFinite()) return
        val raw = origin + translation
        if (!raw.isFinite()) return
        offset = BrowserPageSwipeMath.edge(raw, slot, hasBefore, hasAfter)
        target = offset; velocity = 0.0
        val now = when {
            offset <= -150 -> 1
            offset >= 150 && hasBefore -> -1
            else -> 0
        }
        if (now != 0 && now != decided) ticks++
        decided = now
        if (!hasBefore && raw > 24 && !resisted) { resisted = true; edgeTicks++ }
    }

    fun up(translation: Double, speed: Double, reduced: Boolean = false): Event? {
        if (!touching) return null
        touching = false
        if (!translation.isFinite() || !speed.isFinite() || !(origin + translation).isFinite()) return cancel(reduced)
        val x = BrowserPageSwipeMath.edge(origin + translation, slot, hasBefore, hasAfter)
        val projected = x + speed * BrowserPageSwipeMath.projection
        if (!projected.isFinite()) return cancel(reduced)
        step = BrowserPageSwipeMath.destination(projected, hasBefore, hasAfter)
        val thrown = when {
            projected <= -150 -> 1
            projected >= 150 && hasBefore -> -1
            else -> 0
        }
        if (thrown != 0 && thrown != decided) ticks++
        landingNewTab = !hasAfter && step == 1
        return animate(-step * slot, 0.3, speed, reduced)
    }

    /** Cancellation can never turn a page, even beyond the usual commit distance. */
    fun cancel(reduced: Boolean = false): Event? {
        if (!active || blank) return null
        touching = false; moving = false; landingNewTab = false; step = 0
        return animate(0.0, 0.32, velocity, reduced)
    }

    fun leaveBlank(reduced: Boolean = false): Event? {
        if (!active || !blank) return null
        blank = false; step = 0
        return animate(0.0, 0.32, velocity, reduced)
    }

    fun revoke() { active = false; touching = false; moving = false; blank = false; landingNewTab = false }

    private fun animate(to: Double, period: Double, speed: Double, reduced: Boolean): Event? {
        target = to; response = period; velocity = speed; moving = true
        if (reduced || abs(target - offset) < 0.04 && abs(velocity) < 2) {
            offset = target; velocity = 0.0; moving = false
            return arrived()
        }
        return null
    }

    fun frame(elapsed: Double): Event? {
        if (!active || !moving) return null
        val next = browserStepSpring(offset, target, velocity, response, 1.0, elapsed)
        offset = next.value; velocity = next.velocity; moving = !next.settled
        // The field starts at the visible landing, not at the end of the slow spring tail.
        if (landingNewTab && offset <= -slot + 3) {
            landingNewTab = false; blank = true
            return Event.Blank
        }
        return if (next.settled) arrived() else null
    }

    private fun arrived(): Event? {
        if (landingNewTab) {
            landingNewTab = false; blank = true
            return Event.Blank
        }
        if (blank) return null
        active = false
        return Event.Settled(step)
    }
}

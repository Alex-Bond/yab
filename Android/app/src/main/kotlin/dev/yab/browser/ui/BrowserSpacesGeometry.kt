package dev.yab.browser.ui

import kotlin.math.*

internal data class SpacesRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val bottom get() = y + height
}

/** Exact current FieldLayer.LiftFrame geometry; its source origin is measured once per opening. */
internal data class BrowserSpacesLiftFrame(val rect: SpacesRect, val radius: Double, val drop: Double) {
    companion object {
        fun at(reveal: Double, width: Double, bottom: Double, plate: SpacesRect): BrowserSpacesLiftFrame? {
            require(reveal.isFinite() && width.isFinite() && width > 0 && bottom.isFinite() && bottom > 0)
            require(listOf(plate.x, plate.y, plate.width, plate.height).all(Double::isFinite) && plate.width > 0 && plate.height > 0)
            if (reveal >= 0.999) return null
            val r = max(0.0, reveal)
            fun ease(value: Double) = 1 - (1 - value.coerceIn(0.0, 1.0)).pow(3)
            fun mix(a: Double, b: Double, t: Double) = a + (b - a) * t
            val foot = mix(plate.bottom, bottom, ease(r / 0.35))
            val top = min(foot - plate.height, mix(plate.y, 0.0, r))
            val side = ease(r / 0.5)
            return BrowserSpacesLiftFrame(SpacesRect(mix(plate.x, 0.0, side), top,
                mix(plate.width, width, side), foot - top),
                mix(plate.height / 2, 55.0, min(1.0, r / 0.5)), top)
        }
    }
}

/** The actual current FieldModel.follow and SpacePagesCard thresholds share one travel. */
internal data class BrowserSpacesPose(val reveal: Double) {
    val fieldProgress get() = ((reveal - 0.05) / 0.45).coerceIn(0.0, 1.0)
    val backdrop get() = (reveal.coerceIn(0.0, 1.0) / 0.6).coerceIn(0.0, 1.0)
    val chromeVeil get() = (max(0.0, reveal) / 0.15).coerceIn(0.0, 1.0)
    val cardOpacity get() = chromeVeil
    val materialOpacity get() = 1 - ((reveal - 0.05) / 0.4).coerceIn(0.0, 1.0)
    val pagesOpacity get() = ((reveal - 0.06) / 0.18).coerceIn(0.0, 1.0)
    val capsuleOpacity get() = ((reveal - 0.04) / 0.16).coerceIn(0.0, 1.0)
}

/** Explicit field-generation lease. Revocation drops source pixels before a replacement paints. */
internal data class BrowserSpacesOwner(val surfaceEpoch: Long, val originTab: String?, val privateOrigin: Boolean)
internal class BrowserSpacesRetainedOrigin {
    var owner: BrowserSpacesOwner? = null
        private set
    var plate: SpacesRect? = null
        private set
    fun retain(next: BrowserSpacesOwner, measured: SpacesRect) {
        if (owner != next) { owner = next; plate = measured }
    }
    fun isCurrent(expected: BrowserSpacesOwner) = owner == expected
    fun release(expected: BrowserSpacesOwner): Boolean {
        if (!isCurrent(expected)) return false
        owner = null; plate = null
        return true
    }
    fun invalidate() { owner = null; plate = null }
}

/** Current Phone SpringValue at 1000-point scale, with one reveal for shape/words/backdrop.
 * The renderer must drive this from its real frame clock and provide the actual Reduce Motion
 * cross-dissolve. This pure model does not turn off any system animator preference. */
internal class BrowserSpacesTravel(val screenHeight: Double, val highest: Double, initial: Double = 0.0) {
    private var value = initial * 1000
    private var velocity = 0.0
    private var target = value
    private var lowered = 0.0
    var lifting = false
        private set
    var closing = false
        private set
    var moving = false
        private set
    var generation = 0L
        private set
    val reveal get() = value / 1000
    val pose get() = BrowserSpacesPose(reveal)
    val liftSpan get() = max(300.0, screenHeight - highest - 110)
    val normalizedVelocity get() = velocity / 1000

    init { require(screenHeight > 0 && screenHeight.isFinite() && highest >= 0 && highest.isFinite() && initial.isFinite()) }
    fun open(reduced: Boolean = false) = animate(1.0, 0.0, reduced)
    fun close(reduced: Boolean = false) = animate(0.0, 0.0, reduced)
    fun beginLift() { stop(); lifting = true; closing = false; follow(0.0) }
    fun liftMoved(dy: Double) { if (lifting && dy.isFinite()) follow((-dy / liftSpan).coerceIn(0.0, 1.06)) }
    fun liftEnded(fingerVelocity: Double, reduced: Boolean = false): Long {
        if (!lifting || !fingerVelocity.isFinite()) return generation
        lifting = false
        return animate(if (reveal > 0.25 || fingerVelocity < -600) 1.0 else 0.0, -fingerVelocity / liftSpan, reduced)
    }
    fun beginLower() {
        if (lifting) return
        stop(); closing = false; lifting = true; lowered = (1 - reveal) * liftSpan
    }
    fun lowerMoved(dy: Double) {
        if (!lifting || !dy.isFinite()) return
        lowered = max(0.0, lowered + dy)
        follow(1 - min(lowered / liftSpan, 1.0))
    }
    fun lowerEnded(fingerVelocity: Double, reduced: Boolean = false): Long {
        if (!lifting || !fingerVelocity.isFinite()) return generation
        lifting = false; lowered = 0.0
        val end = if (reveal > 0.75 && fingerVelocity < 600 || fingerVelocity < -600) 1.0 else 0.0
        return animate(end, -fingerVelocity / liftSpan, reduced)
    }
    /** Returns the completion's generation; an interrupted completion cannot dismiss a new owner. */
    private fun animate(end: Double, speed: Double, reduced: Boolean): Long {
        generation++; lifting = false; target = end * 1000; velocity = speed * 1000; closing = end == 0.0
        moving = !reduced && !(abs(target - value) < 0.04 && abs(velocity) < 2)
        if (!moving) { value = target; velocity = 0.0 }
        return generation
    }
    private fun follow(next: Double) { value = next * 1000; target = value; velocity = 0.0; moving = false }
    fun stop() { generation++; moving = false }
    fun isClosedCompletion(expected: Long) = generation == expected && closing && !moving && reveal == 0.0
    fun step(elapsed: Double) {
        if (!moving || !elapsed.isFinite() || elapsed <= 0) return
        val next = browserStepSpring(value, target, velocity, 0.42, 1.0, elapsed)
        value = next.value; velocity = next.velocity
        if (next.settled) moving = false
    }
}

internal data class BrowserSpacesRgb(val red: Double, val green: Double, val blue: Double) {
    fun mix(to: BrowserSpacesRgb, t: Double) = BrowserSpacesRgb(red + (to.red - red) * t,
        green + (to.green - green) * t, blue + (to.blue - blue) * t)
}
internal data class BrowserSpacesWash(val foot: BrowserSpacesRgb, val head: BrowserSpacesRgb,
    val privateDarkness: Double, val darkOverlay: Double) {
    companion object {
        fun at(tints: List<BrowserSpacesRgb>, position: Double, privateIndex: Int?, darkTheme: Boolean): BrowserSpacesWash {
            require(tints.isNotEmpty() && position.isFinite())
            val f = position.coerceIn(0.0, tints.lastIndex.toDouble())
            val i = floor(f).toInt(); val j = min(i + 1, tints.lastIndex)
            val darkness = privateIndex?.let { max(0.0, 1 - abs(f - it)) } ?: 0.0
            val foot = tints[i].mix(tints[j], f - i)
            val head = foot.mix(BrowserSpacesRgb(255.0, 255.0, 255.0), 0.35 * (1 - darkness))
            return BrowserSpacesWash(foot, head, darkness, if (darkTheme) 0.45 * (1 - darkness) else 0.0)
        }
    }
}

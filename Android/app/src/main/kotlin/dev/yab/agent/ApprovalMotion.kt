package dev.yab.agent

import dev.yab.browser.ui.browserStepSpring
import kotlin.math.abs

/** Current Phone ApprovalMotion.swift. Values are logical points, not device pixels. */
internal data class ApprovalSpring(val response: Double, val damping: Double = 1.0)
internal object ApprovalTiming {
    val arrive = ApprovalSpring(.34, .88)
    val leave = ApprovalSpring(.22)
    val back = ApprovalSpring(.30, .82)
    val step = ApprovalSpring(.32, .88)
    val height = ApprovalSpring(.30, .88)
    val window = ApprovalSpring(.50, .86)
    val page = ApprovalSpring(.50, .86)
    val scroll = ApprovalSpring(.45)
    val picture = ApprovalSpring(.42, .88)
    val pictureBack = ApprovalSpring(.40, .90)
    val fold = ApprovalSpring(.46, .92)
    val island = ApprovalSpring(.38, .86)
    val keyboard = ApprovalSpring(.34)
    const val fade = .20
}

/** Same interruption/velocity and 240Hz integration as Phone SpringValue, with its .02 frame cap. */
internal class ApprovalSpringValue(initial: Double, private val unit: Boolean = false) {
    private val scale = if (unit) 1000.0 else 1.0
    private var position = initial * scale
    private var speed = 0.0
    private var destination = position
    private var timing = ApprovalTiming.arrive
    val value get() = position / scale
    val velocity get() = speed / scale
    val target get() = destination / scale
    var moving = false
        private set

    fun set(value: Double) {
        require(value.isFinite())
        position = value * scale; destination = position; speed = 0.0; moving = false
    }

    fun animate(target: Double, motion: ApprovalSpring, velocity: Double? = null) {
        require(target.isFinite() && (velocity == null || velocity.isFinite()))
        destination = target * scale
        if (velocity != null) speed = velocity * scale
        timing = motion
        moving = !(abs(destination - position) < .04 && abs(speed) < 2)
        if (!moving) { position = destination; speed = 0.0 }
    }

    fun advance(seconds: Double) {
        if (!moving) return
        val next = browserStepSpring(position, destination, speed, timing.response, timing.damping, seconds, maxStep = .02)
        position = next.value; speed = next.velocity; moving = !next.settled
    }
}

internal data class ApprovalRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val right get() = x + width
    val bottom get() = y + height
    fun mix(to: ApprovalRect, progress: Double) = ApprovalRect(
        x + (to.x - x) * progress, y + (to.y - y) * progress,
        width + (to.width - width) * progress, height + (to.height - height) * progress)
}

internal object ApprovalMetrics {
    const val inset = 8.0
    const val radius = 38.0
    const val pad = 16.0
    const val maxWidth = 500.0
    const val header = 60.0
    const val close = 36.0
    const val row = 64.0
    const val button = 50.0
    const val dim = .28
    const val windowDim = .18
    const val rise = 8.0
    const val pullClose = 130.0
    const val pullFlick = 650.0
    fun band(distance: Double) = if (distance <= 0) 0.0 else .8 * distance / (1 + distance / 1400)
}

/** Geometry directly follows Phone ApprovalGeometry; Android uses its no-Island capsule path. */
internal data class ApprovalGeometry(
    val screenWidth: Double, val screenHeight: Double, val safeTop: Double,
    val contentHeight: Double, val lift: Double = 0.0, val rise: Double = 0.0,
    val drag: Double = 0.0, val fold: Double = 0.0, val window: Double = 0.0,
    val trayFade: Double = 1.0,
) {
    init { require(listOf(screenWidth, screenHeight, safeTop, contentHeight, lift, rise, drag, fold, window, trayFade).all(Double::isFinite)) }
    val width get() = (screenWidth - 2 * ApprovalMetrics.inset).coerceIn(1.0, ApprovalMetrics.maxWidth)
    val x get() = (screenWidth - width) / 2
    val bottom get() = screenHeight - ApprovalMetrics.inset - lift
    val cap get() = (bottom - safeTop - ApprovalMetrics.inset).coerceAtLeast(ApprovalMetrics.header)
    val trayHeight get() = (ApprovalMetrics.header + contentHeight.coerceAtLeast(0.0)).coerceAtMost(cap)
    val bodyCap get() = cap - ApprovalMetrics.header
    val rest get() = ApprovalRect(x, bottom - trayHeight, width, trayHeight)
    val island get() = ApprovalRect(screenWidth / 2 - 63, (safeTop + 2).coerceAtLeast(6.0), 126.0, 37.0)
    val rect get() = rest.copy(y = rest.y + rise + drag).mix(island, fold.coerceIn(0.0, 1.0))
    val radius get() = ApprovalMetrics.radius + (rect.height / 2 - ApprovalMetrics.radius) * fold.coerceIn(0.0, 1.0)
    val wordsOpacity get() = (1 - fold.coerceIn(0.0, 1.0) / .55).coerceAtLeast(0.0)
    val behindScale get() = 1 - .07 * window.coerceIn(0.0, 1.0)
    val dim get() = (ApprovalMetrics.dim * (1 - (rise + drag) / trayHeight.coerceAtLeast(1.0)).coerceIn(0.0, 1.0) * trayFade +
        ApprovalMetrics.windowDim * window.coerceIn(0.0, 1.0)) * (1 - fold.coerceIn(0.0, 1.0))
    val windowRect get() = ApprovalRect(x, safeTop + 8, width, (bottom - safeTop - 8).coerceAtLeast(1.0))
}

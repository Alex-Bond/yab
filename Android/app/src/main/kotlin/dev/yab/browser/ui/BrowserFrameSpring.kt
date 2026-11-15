package dev.yab.browser.ui

import kotlin.math.*

/** Current Phone SpringValue integration. Caller owns its frame clock, lifetime and generation.
 * Values/velocity use logical points or the source's explicit 1000-point normalized scale. */
internal data class BrowserSpringStep(val value: Double, val velocity: Double, val settled: Boolean)
internal fun browserStepSpring(value: Double, target: Double, velocity: Double,
    response: Double, damping: Double, elapsed: Double, maxStep: Double = 0.05): BrowserSpringStep {
    require(listOf(value, target, velocity, response, damping, maxStep).all(Double::isFinite) && response > 0 && damping > 0 && maxStep > 0)
    if (!elapsed.isFinite()) return BrowserSpringStep(value, velocity, false)
    val dt = elapsed.coerceIn(0.0, maxStep)
    val n = max(1, ceil(dt * 240).toInt()); val h = dt / n
    val stiffness = (2 * PI / response).pow(2); val friction = 4 * PI * damping / response
    var position = value; var speed = velocity
    repeat(n) { speed += (-stiffness * (position - target) - friction * speed) * h; position += speed * h }
    val settled = abs(position - target) < 0.04 && abs(speed) < 2
    return if (settled) BrowserSpringStep(target, 0.0, true) else BrowserSpringStep(position, speed, false)
}

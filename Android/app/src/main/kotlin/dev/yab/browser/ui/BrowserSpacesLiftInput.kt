package dev.yab.browser.ui

import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserSurface

/** Keeps the actual finger's latest input across the first composition. A release arriving
 * before the card mounts remains a release, not a delayed automatic tap-open animation. */
internal class BrowserSpacesLiftInput {
    private data class Pending(val epoch: Long, var dy: Double, var ended: Boolean = false, var velocity: Double = 0.0)
    private var pending: Pending? = null
    private var host: BrowserSpacesHostState? = null
    fun move(controller: BrowserController, dy: Double): Long? {
        if (!dy.isFinite()) return null
        val current = controller.state.value
        var input = pending
        if (input == null || input.ended || input.epoch != current.surfaceEpoch) {
            if (current.surface != BrowserSurface.PAGE || current.privateContentBlocked) return null
            controller.show(BrowserSurface.SPACES)
            input = Pending(controller.state.value.surfaceEpoch, dy)
            pending = input; host = null
        } else input.dy = dy
        if (controller.state.value.surface == BrowserSurface.SPACES && controller.state.value.surfaceEpoch == input.epoch) {
            host?.takeIf { it.owner.surfaceEpoch == input.epoch }?.liftMoved(dy)
        }
        return input.epoch
    }
    fun end(epoch: Long, dy: Double, velocity: Double) {
        val input = pending?.takeIf { it.epoch == epoch && !it.ended } ?: return
        if (!dy.isFinite() || !velocity.isFinite()) return
        input.dy = dy; input.ended = true; input.velocity = velocity
        host?.takeIf { it.owner.surfaceEpoch == epoch }?.let { it.liftMoved(dy); it.liftEnded(velocity) }
    }
    fun attach(next: BrowserSpacesHostState) {
        val input = pending?.takeIf { it.epoch == next.owner.surfaceEpoch } ?: return
        host = next
        next.beginLift(); next.liftMoved(input.dy)
        if (input.ended) next.liftEnded(input.velocity)
    }
    fun detach(previous: BrowserSpacesHostState) { if (host === previous) { host = null; pending = null } }
}

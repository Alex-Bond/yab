package dev.yab.agent

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class ApprovalPresentationKey(val account: String, val epoch: Long, val mac: String,
    val id: String, val facts: String, val generation: Long)
internal data class ApprovalPresented(val key: ApprovalPresentationKey, val request: ApprovalRequest,
    val receipt: ApprovalReceipt? = null, val action: ApprovalDisplayLease? = null, val retry: ApprovalReceipt? = null) {
    val content = ApprovalContent(request)
}
internal enum class ApprovalTravel { ENTERING, READY, LEAVING, FOLDING, ISLAND, ISLAND_LEAVING }
internal data class ApprovalTrayFrame(val content: ApprovalPresented? = null, val phase: ApprovalTravel = ApprovalTravel.READY,
    val height: Double = 400.0, val rise: Double = 0.0, val drag: Double = 0.0, val fold: Double = 0.0,
    val island: Double = 0.0, val fade: Double = 1.0, val islandFade: Double = 1.0, val running: Boolean = false,
    val riseVelocity: Double = 0.0, val awaitingDecline: Boolean = false) {
    val interactive get() = !awaitingDecline && content?.action != null && phase in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)
}

/** Retained by ApprovalController, not by an Activity or a dialog composition. */
internal class ApprovalTrayPresentation {
    private val mutable = MutableStateFlow(ApprovalTrayFrame())
    val frame = mutable.asStateFlow()
    private var current: ApprovalPresented? = null
    private var pending: ApprovalPresented? = null
    private var phase = ApprovalTravel.READY
    private var reduced = false
    private var measured = false
    private var elapsed = 0.0
    private var fadeFrom = 1.0
    private var fade = 1.0
    private var dragBase = 0.0
    private var committedSpeed: Double? = null
    private val height = ApprovalSpringValue(400.0)
    private val rise = ApprovalSpringValue(0.0)
    private val drag = ApprovalSpringValue(0.0)
    private val fold = ApprovalSpringValue(0.0, unit = true)
    private val island = ApprovalSpringValue(0.0, unit = true)

    fun offer(next: ApprovalPresented?, ownerCurrent: (ApprovalPresented) -> Boolean, reduceMotion: Boolean) {
        if (current?.let { !ownerCurrent(it) } == true) clear()
        pending = next?.takeIf(ownerCurrent)
        if (reduced != reduceMotion) {
            reduced = reduceMotion
            if (reduced) { rise.set(0.0); drag.set(0.0); fold.set(0.0); island.set(if (phase == ApprovalTravel.ISLAND) 1.0 else 0.0) }
        }
        val existing = current
        if (existing == null) { adoptPending(); return }
        if (pending?.key == existing.key) {
            current = pending
            if (phase in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)) publish()
            return
        }
        // Phone keeps the declined tray in place when the same actual context asks
        // again. The controller supplies a fresh display lease and permitted draft.
        if (existing.receipt?.result?.phase == ApprovalResultPhase.declined &&
            pending?.retry == existing.receipt && pending?.action != null &&
            phase in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)) {
            current = pending
            publish()
            return
        }
        if (phase in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)) {
            elapsed = 0.0; fadeFrom = fade
            val receipt = existing.receipt
            val hasIsland = receipt != null && receipt.result?.phase !in setOf(ApprovalResultPhase.declined, ApprovalResultPhase.failed)
            phase = if (hasIsland) ApprovalTravel.FOLDING else ApprovalTravel.LEAVING
            if (!reduced) {
                if (hasIsland) { fold.animate(1.0, ApprovalTiming.fold); island.animate(1.0, ApprovalTiming.island) }
                else {
                    val speed = committedSpeed
                    rise.set(rise.value + drag.value); drag.set(0.0)
                    rise.animate(maxOf(height.value + ApprovalMetrics.header + ApprovalMetrics.inset + 30, rise.value + 1), ApprovalTiming.leave, speed)
                    committedSpeed = null
                }
            } else if (hasIsland) island.set(1.0)
        }
        publish()
    }

    fun measure(key: ApprovalPresentationKey, bodyAndFooter: Double) {
        if (current?.key != key || !bodyAndFooter.isFinite() || bodyAndFooter < 0 || phase !in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)) return
        if (!measured) {
            measured = true; height.set(bodyAndFooter)
            if (!reduced) {
                rise.set(ApprovalMetrics.header + bodyAndFooter + ApprovalMetrics.inset + 24)
                rise.animate(0.0, ApprovalTiming.arrive)
            }
        } else if (height.target != bodyAndFooter) {
            if (reduced) height.set(bodyAndFooter) else height.animate(bodyAndFooter, ApprovalTiming.height)
        }
        publish()
    }

    fun beginDrag(key: ApprovalPresentationKey) {
        if (current?.key != key || !mutable.value.interactive || reduced) return
        if (committedSpeed != null) return
        dragBase = drag.value
        drag.set(dragBase)
    }
    fun drag(key: ApprovalPresentationKey, distance: Double) {
        if (current?.key != key || !mutable.value.interactive || reduced || !distance.isFinite()) return
        val offset = distance + dragBase
        drag.set(if (offset > 0) offset else -60.0 * (1 - 1 / (-offset * .55 / 60.0 + 1)))
        publish()
    }

    fun releaseDrag(key: ApprovalPresentationKey, velocity: Double): Boolean {
        if (current?.key != key || !mutable.value.interactive || !velocity.isFinite()) return false
        val commit = drag.value > (height.value + ApprovalMetrics.header) / 3 || velocity > ApprovalMetrics.pullFlick
        if (commit) {
            // Hold the finger's position until the real answer is accepted. The exit
            // then receives its original screen-space velocity, without a spring-back frame.
            committedSpeed = velocity.coerceIn(0.0, 4000.0)
            drag.set(drag.value)
        } else drag.animate(0.0, ApprovalTiming.back, velocity)
        publish()
        return commit
    }

    fun cancelDrag(key: ApprovalPresentationKey) {
        if (current?.key != key || committedSpeed != null || phase !in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)) return
        drag.animate(0.0, ApprovalTiming.back)
        publish()
    }

    fun submissionRetainedQuestion(key: ApprovalPresentationKey) {
        if (current?.key != key || committedSpeed == null || phase !in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)) return
        committedSpeed = null
        drag.animate(0.0, ApprovalTiming.back)
        publish()
    }

    fun advance(seconds: Double) {
        if (current == null || !seconds.isFinite() || seconds < 0) return
        elapsed += seconds
        if (!reduced) {
            height.advance(seconds); rise.advance(seconds); drag.advance(seconds); fold.advance(seconds); island.advance(seconds)
        }
        when (phase) {
            ApprovalTravel.ENTERING -> {
                if (reduced) fade = eased((elapsed / ApprovalTiming.fade).coerceIn(0.0, 1.0))
                if (measured && (if (reduced) elapsed >= ApprovalTiming.fade else !rise.moving)) phase = ApprovalTravel.READY
            }
            ApprovalTravel.LEAVING -> {
                if (reduced) fade = fadeFrom * (1 - eased((elapsed / ApprovalTiming.fade).coerceIn(0.0, 1.0)))
                if (if (reduced) elapsed >= ApprovalTiming.fade else !rise.moving) { finish(); return }
            }
            ApprovalTravel.FOLDING -> {
                if (reduced) fade = fadeFrom * (1 - eased((elapsed / ApprovalTiming.fade).coerceIn(0.0, 1.0)))
                if (if (reduced) elapsed >= ApprovalTiming.fade else !fold.moving) {
                    phase = ApprovalTravel.ISLAND
                    // Phone's ordinary Island hold starts with the fold, its reduced hold after the fade.
                    if (reduced) elapsed = 0.0
                    if (reduced) island.set(1.0)
                }
            }
            ApprovalTravel.ISLAND -> if (elapsed >= if (reduced) 1.3 else 1.5) {
                phase = ApprovalTravel.ISLAND_LEAVING; elapsed = 0.0
                if (!reduced) island.animate(0.0, ApprovalTiming.island)
            }
            ApprovalTravel.ISLAND_LEAVING -> if (if (reduced) elapsed >= ApprovalTiming.fade else !island.moving) { finish(); return }
            ApprovalTravel.READY -> Unit
        }
        publish()
    }

    private fun adoptPending() {
        current = pending
        if (current == null) { publish(); return }
        phase = ApprovalTravel.ENTERING; measured = false; elapsed = 0.0; committedSpeed = null
        height.set(400.0); rise.set(if (reduced) 0.0 else 4096.0); drag.set(0.0); fold.set(0.0); island.set(0.0)
        fade = if (reduced) 0.0 else 1.0
        publish()
    }
    private fun finish() { current = null; adoptPending() }
    private fun clear() {
        current = null; pending = null; phase = ApprovalTravel.READY; measured = false; committedSpeed = null
        height.set(400.0); rise.set(0.0); drag.set(0.0); fold.set(0.0); island.set(0.0); fade = 1.0
    }
    private fun publish() {
        val travelling = current != null && ((phase != ApprovalTravel.READY && (phase != ApprovalTravel.ENTERING || measured || reduced)) ||
            height.moving || rise.moving || drag.moving || fold.moving || island.moving)
        mutable.value = ApprovalTrayFrame(current, phase, height.value, rise.value, drag.value, fold.value, island.value,
            fade, when {
                reduced && phase == ApprovalTravel.FOLDING -> eased((elapsed / ApprovalTiming.fade).coerceIn(0.0, 1.0))
                reduced && phase == ApprovalTravel.ISLAND_LEAVING -> 1 - eased((elapsed / ApprovalTiming.fade).coerceIn(0.0, 1.0))
                else -> 1.0
            }, travelling, rise.velocity, committedSpeed != null)
    }
    /** SwiftUI .easeInOut uses the (0.42,0,0.58,1) cubic, not a linear fade. */
    private fun eased(x: Double): Double {
        var low = 0.0; var high = 1.0
        repeat(24) {
            val t = (low + high) / 2
            val curveX = 3 * (1 - t) * (1 - t) * t * .42 + 3 * (1 - t) * t * t * .58 + t * t * t
            if (curveX < x) low = t else high = t
        }
        val t = (low + high) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }
}

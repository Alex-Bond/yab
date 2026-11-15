package dev.yab.browser.ui

import dev.yab.browser.model.PageMenuLease
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.*

internal enum class PageMenuPhase { MOUNTED, OPENING, OPEN, DRAGGING, CLOSING, CLOSED, HANDING_OFF, HANDED_OFF, REVOKED }
internal enum class PageMenuPage { MENU, SITE, CERTIFICATE }
internal enum class PageMenuRelease { LANDED, HANDED_OFF, REVOKED }
internal data class PageMenuCompletion(val reason: PageMenuRelease, val action: (() -> Unit)?)
internal data class PageMenuFrame(val phase: PageMenuPhase = PageMenuPhase.MOUNTED, val shown: Boolean = false,
    val progress: Double = 0.0, val drag: Double = 0.0, val site: Double = 0.0,
    val certificate: Double = 0.0, val toField: Double = 0.0, val running: Boolean = false,
    val targetPage: PageMenuPage = PageMenuPage.MENU) {
    val interactive get() = shown && progress > .98 && toField == 0.0 &&
        phase !in setOf(PageMenuPhase.CLOSING, PageMenuPhase.CLOSED, PageMenuPhase.HANDING_OFF, PageMenuPhase.HANDED_OFF, PageMenuPhase.REVOKED)
}

/** One captured owner per presentation. A reopening uses the live position and velocity; a new
 * owner gets a new presentation. Spring parameters come from current PageMenuModel, not the old
 * Motion.plateMenu token. The analytic Android oscillator is not a SwiftUI frame-equivalence claim. */
internal class BrowserPageMenuPresentation(val lease: PageMenuLease) {
    private val mutable = MutableStateFlow(PageMenuFrame())
    val frame = mutable.asStateFlow()
    private val progress = MenuTrack()
    private val drag = MenuTrack()
    private val site = MenuTrack()
    private val certificate = MenuTrack()
    private val field = MenuTrack()
    private var clock: Long? = null
    private var closeDeadline: Long? = null
    private var queued: (() -> Unit)? = null
    private var claimed = false
    private var dragBase = 0.0
    private var translation = 0.0
    private var targetPage = PageMenuPage.MENU

    fun open(nanos: Long, reduced: Boolean, animations: Boolean = true) {
        advance(nanos)
        if (frame.value.phase in setOf(PageMenuPhase.REVOKED, PageMenuPhase.CLOSED, PageMenuPhase.HANDING_OFF, PageMenuPhase.HANDED_OFF)) return
        closeDeadline = null; queued = null
        progress.to(1.0, now, .4, .9, reduced, animations)
        drag.to(0.0, now, .4, .9, reduced, animations)
        publish(PageMenuPhase.OPENING, true)
        advance(now)
    }

    /** Only one exit can own an action. A reversal cancels it before any later landing. */
    fun close(nanos: Long, reduced: Boolean, animations: Boolean = true, afterLanding: (() -> Unit)? = null): Boolean {
        advance(nanos)
        if (!frame.value.shown || frame.value.phase in setOf(PageMenuPhase.CLOSED, PageMenuPhase.HANDING_OFF, PageMenuPhase.HANDED_OFF, PageMenuPhase.REVOKED)) return false
        queued = afterLanding
        closeDeadline = now + (if (!animations) 0L else if (reduced) 200_000_000L else 320_000_000L)
        progress.to(0.0, now, .32, 1.0, reduced, animations)
        drag.to(0.0, now, .32, 1.0, reduced, animations)
        publish(PageMenuPhase.CLOSING, false)
        advance(now)
        return true
    }

    /** Phone pageMenuEditAddress: the Field opens at the tap, while this same row/sheet
     * shrinks into its measured destination. A late first layout keeps the original tap time. */
    fun toField(nanos: Long, reduced: Boolean, animations: Boolean = true): Boolean {
        advance(nanos)
        if (!frame.value.interactive) return false
        queued = null; closeDeadline = null
        field.to(1.0, nanos, .38, 1.0, reduced, animations)
        publish(PageMenuPhase.HANDING_OFF)
        advance(now)
        return true
    }

    fun navigate(page: PageMenuPage, nanos: Long, reduced: Boolean, animations: Boolean = true): Boolean {
        advance(nanos)
        if (!frame.value.interactive) return false
        val inward = (if (page == PageMenuPage.MENU) 0.0 else 1.0) > site.value ||
            (page == PageMenuPage.CERTIFICATE && certificate.value < 1.0)
        val response = if (inward) .38 else .34
        site.to(if (page == PageMenuPage.MENU) 0.0 else 1.0, now, response, 1.0, reduced, animations)
        certificate.to(if (page == PageMenuPage.CERTIFICATE) 1.0 else 0.0, now, response, 1.0, reduced, animations)
        targetPage = page
        publish(); return true
    }

    /** Phone siteSettingsBack reads PageMenuModel.page, which changes at the request.
     * The drawn certificate spring may still be below its midpoint when Back arrives. */
    fun back(nanos: Long, reduced: Boolean, animations: Boolean = true): Boolean =
        navigate(if (targetPage == PageMenuPage.CERTIFICATE) PageMenuPage.SITE else PageMenuPage.MENU,
            nanos, reduced, animations)

    fun beginDrag(nanos: Long): Boolean {
        advance(nanos)
        if (!frame.value.interactive) return false
        dragBase = drag.value; translation = 0.0
        drag.stop(); publish(PageMenuPhase.DRAGGING); return true
    }
    fun drag(distance: Double) {
        if (frame.value.phase != PageMenuPhase.DRAGGING || !distance.isFinite()) return
        translation = distance.coerceAtLeast(0.0)
        drag.snap((dragBase + translation).coerceAtLeast(0.0)); publish()
    }
    /** SwiftUI owns predictedEndTranslation's physics. The host supplies an explicit predictor;
     * this contract implements the source decision without inventing a deceleration constant. */
    fun release(predictedEndY: Double, travel: Double, nanos: Long, reduced: Boolean, animations: Boolean = true): Boolean {
        if (frame.value.phase != PageMenuPhase.DRAGGING || !predictedEndY.isFinite() || !travel.isFinite() || travel <= 0) return false
        val leave = translation > 0 && (translation > travel * .3 || predictedEndY > travel * .6)
        if (leave) close(nanos, reduced, animations) else cancelDrag(nanos, reduced, animations)
        return leave
    }
    fun cancelDrag(nanos: Long, reduced: Boolean, animations: Boolean = true) {
        if (frame.value.phase == PageMenuPhase.DRAGGING) open(nanos, reduced, animations)
    }

    fun advance(nanos: Long): PageMenuFrame {
        clock = clock?.let { maxOf(it, nanos) } ?: nanos
        if (frame.value.phase in setOf(PageMenuPhase.REVOKED, PageMenuPhase.CLOSED, PageMenuPhase.HANDED_OFF)) return frame.value
        listOf(progress, drag, site, certificate, field).forEach { it.sample(now) }
        if (frame.value.phase == PageMenuPhase.HANDING_OFF && !field.running && field.value == 1.0) {
            listOf(progress, drag, site, certificate).forEach(MenuTrack::stop)
            publish(PageMenuPhase.HANDED_OFF, false)
        } else if (closeDeadline?.let { now >= it } == true) {
            listOf(progress, drag, site, certificate, field).forEach(MenuTrack::stop)
            progress.snap(0.0); drag.snap(0.0); closeDeadline = null
            publish(PageMenuPhase.CLOSED, false)
        } else publish(if (frame.value.phase == PageMenuPhase.OPENING && !progress.running && !drag.running) PageMenuPhase.OPEN else frame.value.phase)
        return frame.value
    }
    fun claimCompletion(current: (PageMenuLease) -> Boolean): PageMenuCompletion? {
        if (claimed || frame.value.phase !in setOf(PageMenuPhase.CLOSED, PageMenuPhase.HANDED_OFF, PageMenuPhase.REVOKED)) return null
        claimed = true
        val action = queued; queued = null
        val landed = frame.value.phase == PageMenuPhase.CLOSED && current(lease)
        val handedOff = frame.value.phase == PageMenuPhase.HANDED_OFF && current(lease)
        return PageMenuCompletion(if (landed) PageMenuRelease.LANDED else if (handedOff) PageMenuRelease.HANDED_OFF else PageMenuRelease.REVOKED,
            action?.takeIf { landed })
    }
    fun revoke() {
        queued = null; closeDeadline = null
        targetPage = PageMenuPage.MENU
        listOf(progress, drag, site, certificate, field).forEach(MenuTrack::stop)
        mutable.value = PageMenuFrame(PageMenuPhase.REVOKED)
    }
    private val now get() = checkNotNull(clock)
    private fun publish(phase: PageMenuPhase = frame.value.phase, shown: Boolean = frame.value.shown) {
        mutable.value = PageMenuFrame(phase, shown, progress.value, drag.value, site.value, certificate.value, field.value,
            listOf(progress, drag, site, certificate, field).any { it.running } || closeDeadline != null, targetPage)
    }
}

/** Closed-form damped oscillator with source response/damping, preserving velocity on interruption.
 * Reduced Motion follows Motion.fade's cubic timing on the same numeric property. */
private class MenuTrack {
    var value = 0.0; private set
    var running = false; private set
    private var velocity = 0.0
    private var start = 0L
    private var from = 0.0
    private var speed = 0.0
    private var target = 0.0
    private var response = .4
    private var damping = 1.0
    private var reduced = false
    fun snap(next: Double) { value = next; velocity = 0.0; running = false }
    fun stop() { velocity = 0.0; running = false }
    fun to(next: Double, nanos: Long, response: Double, damping: Double, reduced: Boolean, animations: Boolean) {
        sample(nanos); from = value; speed = velocity; target = next; start = nanos
        this.response = response; this.damping = damping; this.reduced = reduced
        running = animations && (abs(value - target) > .000001 || abs(velocity) > .000001)
        if (!running) snap(target)
    }
    fun sample(nanos: Long) {
        if (!running) return
        val seconds = (nanos - start).coerceAtLeast(0).toDouble() / 1e9
        if (reduced) {
            val f = (seconds / .2).coerceIn(0.0, 1.0)
            value = from + (target - from) * menuFade(f)
            velocity = 0.0
            if (f == 1.0) snap(target)
            return
        }
        val omega = 2 * PI / response
        val displacement = from - target
        if (damping < 1) {
            val damped = omega * sqrt(1 - damping * damping)
            val b = (speed + damping * omega * displacement) / damped
            val wave = displacement * cos(damped * seconds) + b * sin(damped * seconds)
            val decay = exp(-damping * omega * seconds)
            value = target + decay * wave
            velocity = decay * (-damping * omega * wave + damped * (-displacement * sin(damped * seconds) + b * cos(damped * seconds)))
        } else {
            val b = speed + omega * displacement
            val decay = exp(-omega * seconds)
            value = target + (displacement + b * seconds) * decay
            velocity = (b - omega * (displacement + b * seconds)) * decay
        }
        if (abs(value - target) < .0001 && abs(velocity) < .002) snap(target)
    }
}

private fun menuFade(x: Double): Double {
    if (x <= 0 || x >= 1) return x.coerceIn(0.0, 1.0)
    fun at(a: Double, b: Double, t: Double): Double { val u = 1 - t; return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t }
    var low = 0.0; var high = 1.0
    repeat(40) { val t = (low + high) / 2; if (at(.42, .58, t) < x) low = t else high = t }
    return at(0.0, 1.0, (low + high) / 2)
}

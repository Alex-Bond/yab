package dev.yab.browser.engine

import dev.yab.browser.model.HistorySwipeDirection
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

internal enum class HistoryTouchPhase { SYNC, ARMED, START, CHANGE, END, CANCEL }

/** Typed projection from the existing exact document/port, never a page evaluation result. */
internal class HistoryTouchReceipt(val phase: HistoryTouchPhase, val sequence: Long, val contacts: Int,
    val serial: Long = 0, val token: String? = null, val accepted: Boolean = false, val held: Boolean = true)

internal class HistoryArmRequest internal constructor(val serial: Long, val token: String,
    val afterSequence: Long, internal val nativeSequence: Long)

internal class HistoryDownTicket internal constructor(internal val generation: Long, val nativeSequence: Long,
    internal val expectedDomSequence: Long, internal val arm: HistoryArmRequest)

/** Conservative APZ projection: only positively handled native panning can be eligible. */
internal data class HistoryApzResult(val handled: Boolean, val contentOwned: Boolean, val ignored: Boolean,
    val scrollsLeft: Boolean, val scrollsRight: Boolean, val horizontalOverscroll: Boolean,
    val known: Boolean = true)

/** The root adapter alone implements this for one exact native entry/document/view lifetime. */
internal interface HistoryTouchChannel {
    val identity: Any
    fun current(): Boolean
    fun interactive(): Boolean = current()
    fun sync(): Boolean
    fun arm(request: HistoryArmRequest): Boolean
    fun disarm(serial: Long)
    fun observe(receive: (HistoryTouchReceipt) -> Unit): AutoCloseable
}

/** PREARMED before DOWN, with no event buffering or timer-derived permission. */
internal class HistorySwipePolicy(private val newToken: () -> String = { UUID.randomUUID().toString().replace("-", "") }) {
    private var generation = 0L
    private var nativeSequence = 0L
    private var nativeActive = false
    private var domSequence: Long? = null
    private var domContacts = -1
    private var offset: Long? = null
    private var request: HistoryArmRequest? = null
    private var armed: HistoryArmRequest? = null
    private var active: HistoryDownTicket? = null
    private var ended: HistoryDownTicket? = null
    private var retiredArm: HistoryArmRequest? = null
    private var pageAgreed = false
    private var apz: HistoryApzResult? = null
    private var vetoed = false
    private var eligible = false
    private var initialInputLost = false
    private var handedOff = false

    fun configure(allowed: Boolean) {
        if (!allowed && eligible) invalidate()
        eligible = allowed
    }

    fun invalidate() {
        generation++
        (active?.arm ?: ended?.arm ?: armed ?: request)?.let { retiredArm = it }
        request = null; armed = null; active = null; ended = null
        pageAgreed = false; apz = null; vetoed = true; handedOff = false
    }

    /** Call at a native document start, before its first input, not on a later port bind. */
    fun newDocument(inputInFlight: Boolean = false) {
        invalidate(); nativeSequence = 0; nativeActive = false
        domSequence = null; domContacts = -1; offset = null; initialInputLost = inputInFlight
        retiredArm = null
    }

    val prearmed get() = armed != null && eligible && !nativeActive
    val pendingSerial get() = (armed ?: request)?.serial

    fun requestArm(): HistoryArmRequest? {
        val dom = domSequence ?: return null
        if (!eligible || nativeActive || domContacts != 0 || request != null || armed != null || initialInputLost ||
            offset?.let { dom != it + nativeSequence } == true) return null
        val serial = serials.incrementAndGet().takeIf { it in 1..MAX_SEQUENCE } ?: return null
        val token = newToken().takeIf { it.matches(Regex("[a-f0-9]{32}")) } ?: return null
        return HistoryArmRequest(serial, token, dom, nativeSequence).also { request = it }
    }

    fun armRefused(value: HistoryArmRequest) { if (request === value) request = null }

    fun receive(value: HistoryTouchReceipt) {
        if (value.sequence !in 0..MAX_SEQUENCE || value.contacts !in 0..10) { vetoed = true; return }
        when (value.phase) {
            HistoryTouchPhase.SYNC -> {
                // A BFCache realm can start at N, but initial input cannot be
                // renumbered after it was already delivered without an ACK.
                if (!nativeActive && nativeSequence == 0L && offset == null && request == null && armed == null &&
                    !initialInputLost && value.contacts == 0) {
                    domSequence = value.sequence; domContacts = 0
                }
            }
            HistoryTouchPhase.ARMED -> {
                val pending = request ?: return
                if (!matches(value, pending)) return
                request = null
                if (value.accepted && eligible && !nativeActive && nativeSequence == pending.nativeSequence &&
                    value.contacts == 0 && value.sequence == pending.afterSequence && !initialInputLost) {
                    val proposedOffset = value.sequence - nativeSequence
                    if (offset == null || offset == proposedOffset) {
                        offset = proposedOffset; domSequence = value.sequence; domContacts = 0; armed = pending
                    }
                }
            }
            HistoryTouchPhase.START, HistoryTouchPhase.CHANGE -> {
                val ticket = active ?: return
                if (!nativeActive || value.sequence != ticket.expectedDomSequence || !matches(value, ticket.arm)) return
                if (value.phase == HistoryTouchPhase.START) pageAgreed = !value.held && value.contacts == 1
                if (value.held || value.contacts != 1) vetoed = true
                domSequence = value.sequence; domContacts = value.contacts
            }
            HistoryTouchPhase.END, HistoryTouchPhase.CANCEL -> {
                val ticket = active ?: ended
                if (ticket == null) {
                    // A rapid unarmed gesture remains native-only. Its proven
                    // end can restore idle only under the already-known offset.
                    if (!nativeActive && offset != null && value.sequence == offset!! + nativeSequence && value.contacts == 0 &&
                        (value.serial == 0L && value.token == null || retiredArm?.let { matches(value, it) } == true)) {
                        domSequence = value.sequence; domContacts = 0
                        retiredArm = null
                    }
                    return
                }
                if (value.sequence != ticket.expectedDomSequence || !matches(value, ticket.arm)) return
                if (value.phase == HistoryTouchPhase.CANCEL && !handedOff || value.held || value.contacts != 0) vetoed = true
                domSequence = value.sequence; domContacts = value.contacts
                if (value.contacts == 0 && !nativeActive) ended = null
            }
        }
    }

    fun down(): HistoryDownTicket? {
        if (nativeActive) { vetoed = true; return null }
        nativeSequence++
        nativeActive = true
        val permit = armed
        val pending = request
        request = null; armed = null; active = null; ended = null
        pageAgreed = false; apz = null; vetoed = !eligible; handedOff = false
        if (offset == null && permit == null) initialInputLost = true
        if (pending != null) vetoed = true // A late ARMED reply cannot grant this DOWN.
        if (permit == null || permit.nativeSequence + 1 != nativeSequence || offset == null) return null
        return HistoryDownTicket(generation, nativeSequence, permit.afterSequence + 1, permit).also { active = it }
    }

    fun apz(ticket: HistoryDownTicket, value: HistoryApzResult) {
        if (active !== ticket || ticket.generation != generation || !nativeActive) return
        apz = value
        if (!value.known || !value.handled || value.contentOwned || value.ignored) vetoed = true
    }

    fun multipleContacts() { vetoed = true }

    /** The browser cancels Gecko's stream exactly once after a permitted claim. */
    fun handoff(ticket: HistoryDownTicket): Boolean {
        if (active !== ticket || !nativeActive || vetoed || !pageAgreed || handedOff) return false
        handedOff = true
        return true
    }

    fun mayClaim(ticket: HistoryDownTicket, direction: HistorySwipeDirection): Boolean {
        val result = apz ?: return false
        return eligible && nativeActive && active === ticket && ticket.generation == generation && !vetoed && pageAgreed &&
            result.known && result.handled && !result.contentOwned && !result.ignored && result.horizontalOverscroll &&
            !(if (direction == HistorySwipeDirection.BACK) result.scrollsLeft else result.scrollsRight)
    }

    fun up(ticket: HistoryDownTicket?, direction: HistorySwipeDirection?, cancelled: Boolean): Boolean {
        val accepted = !cancelled && ticket != null && direction != null && mayClaim(ticket, direction)
        nativeActive = false
        ended = active; active = null
        if (ended != null && domContacts == 0 && domSequence == ended?.expectedDomSequence) ended = null
        if (cancelled) vetoed = true
        return accepted
    }

    private fun matches(value: HistoryTouchReceipt, arm: HistoryArmRequest) = value.serial == arm.serial && value.token == arm.token

    companion object {
        const val MAX_SEQUENCE = 9_007_199_254_740_991L
        private val serials = AtomicLong()
    }
}

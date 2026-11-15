package dev.yab.browser.ui

import dev.yab.browser.model.BrowserVisit
import kotlin.math.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class HistoryRowTicket(val source: Any, val visit: BrowserVisit, val serial: Long)
internal data class HistoryRowPose(val x: Double, val deleting: Boolean = false)
internal data class HistoryRowsFrame(val rows: Map<String, HistoryRowPose> = emptyMap(), val open: String? = null, val running: Boolean = false)

/** Phone HistoryRowPan and explicit Metrics/rowSwipe policy in logical points.
 * This is no measurement of UIKit recognition or SwiftUI logical completion. */
internal class HistoryRowMotion {
    private class Row(val source: Any, val visit: BrowserVisit, var x: Double = 0.0) {
        var target = x; var velocity = 0.0; var age = 0.0; var from = x
        var deleting = false; var serial = 0L
        val moving get() = x != target || velocity != 0.0
        fun snap(value: Double) { x = value; target = value; velocity = 0.0; age = 0.0; from = value }
        fun aim(value: Double) { target = value; age = 0.0; from = x }
    }
    private val rows = linkedMapOf<String, Row>()
    private var open: String? = null
    private var held: HistoryRowTicket? = null
    private var heldFrom = 0.0
    private var serial = 0L
    private var previous: Long? = null
    private var reduced = false
    private var animated = true
    private var revoked = false
    private val mutable = MutableStateFlow(HistoryRowsFrame())
    val frame = mutable.asStateFlow()

    fun configure(reduceMotion: Boolean, animations: Boolean) {
        if (reduced != reduceMotion) rows.values.filter { it.moving }.forEach { it.from = it.x; it.age = 0.0 }
        reduced = reduceMotion; animated = animations
        if (!animated) rows.values.forEach { it.snap(it.target) }
        publish()
    }
    fun reconcile(current: Boolean, accepts: (Any, BrowserVisit) -> Boolean) {
        if (!current) { revoke(); return }
        if (revoked) return
        val removed = rows.filterValues { !accepts(it.source, it.visit) }.keys
        rows.keys.removeAll(removed)
        if (open in removed) open = null
        if (held?.visit?.identity in removed) held = null
        publish()
    }
    fun revoke() {
        revoked = true; rows.clear(); held = null; open = null; previous = null; serial++; publish()
    }
    fun canStart(visit: BrowserVisit, dx: Double, dy: Double, vx: Double, vy: Double): Boolean =
        !revoked && listOf(dx, dy, vx, vy).all(Double::isFinite) &&
            abs(vx) + abs(dx) > abs(vy) + abs(dy) && (vx < 0 || open == visit.identity)

    fun begin(source: Any, visit: BrowserVisit): HistoryRowTicket? {
        if (revoked) return null
        val keepClock = rows.values.any { it.visit.identity != visit.identity && it.moving }
        held?.let { cancel(it) }
        // A single logical open row; another row's outgoing pose may finish closing.
        rows.values.filter { it.visit.identity != visit.identity }.forEach { it.deleting = false; it.aim(0.0) }
        val old = rows[visit.identity]
        val row = if (old != null && old.source === source && old.visit == visit) old else Row(source, visit).also { rows[visit.identity] = it }
        heldFrom = row.x
        row.snap(row.x); row.deleting = false; row.serial = ++serial
        val ticket = HistoryRowTicket(source, visit, serial)
        held = ticket; open = visit.identity; if (!keepClock) previous = null; publish(); return ticket
    }
    fun move(ticket: HistoryRowTicket, translation: Double): Boolean {
        val row = heldRow(ticket) ?: return false
        if (!translation.isFinite()) return false
        row.snap(displacement(heldFrom + translation)); publish(); return true
    }
    fun release(ticket: HistoryRowTicket, velocity: Double): Boolean {
        val row = heldRow(ticket) ?: return false
        if (!velocity.isFinite()) return false
        held = null; if (rows.values.none { it !== row && it.moving }) previous = null
        if (-row.x > ACT) { row.deleting = true; row.aim(-AWAY); open = ticket.visit.identity }
        else {
            val reveal = -row.x > OPEN_DISTANCE || velocity < -OPEN_VELOCITY
            row.aim(if (reveal) -OPEN else 0.0); open = if (reveal) ticket.visit.identity else null
        }
        if (!animated) row.snap(row.target)
        publish(); return true
    }
    /** Consumed/aborted Android input never manufactures a destructive release. */
    fun cancel(ticket: HistoryRowTicket): Boolean {
        val row = heldRow(ticket) ?: return false
        held = null; row.deleting = false; row.aim(if (heldFrom < -4) -OPEN else 0.0)
        open = if (heldFrom < -4) ticket.visit.identity else null
        if (rows.values.none { it !== row && it.moving }) previous = null
        if (!animated) row.snap(row.target)
        publish(); return true
    }
    /** Phone's first tap on any row closes the currently open row. */
    fun tap(): Boolean {
        if (revoked) return false
        if (open == null) return true
        close(); return false
    }
    fun close() {
        held = null; open = null; if (rows.values.none { it.moving }) previous = null; serial++
        rows.values.forEach { it.deleting = false; it.aim(0.0); if (!animated) it.snap(0.0) }
        publish()
    }
    fun advance(now: Long, current: Boolean, accepts: (Any, BrowserVisit) -> Boolean): List<HistoryRowTicket> {
        reconcile(current, accepts)
        if (revoked) return emptyList()
        val before = previous
        if (before != null && now < before) return emptyList()
        previous = now
        val seconds = before?.let { ((now - it).coerceAtLeast(0) / 1_000_000_000.0).coerceAtMost(1.0) } ?: 0.0
        for (row in rows.values) if (row.moving && held?.visit?.identity != row.visit.identity) {
            if (!animated) row.snap(row.target)
            else if (reduced) {
                row.age += seconds
                val p = (row.age / .2).coerceIn(0.0, 1.0)
                row.x = row.from + (row.target - row.from) * ease(p)
                row.velocity = 0.0
                if (p == 1.0) row.snap(row.target)
            } else {
                val w = 2 * PI / .3; val q = row.x - row.target; val c = row.velocity + w * q; val decay = exp(-w * seconds)
                row.x = row.target + (q + c * seconds) * decay
                row.velocity = (row.velocity - w * c * seconds) * decay
                if (abs(row.x - row.target) < .04 && abs(row.velocity) < 2) row.snap(row.target)
            }
        }
        val completed = rows.values.filter { it.deleting && !it.moving && accepts(it.source, it.visit) }
            .map { HistoryRowTicket(it.source, it.visit, it.serial) }
        rows.keys.removeAll(completed.map { it.visit.identity }.toSet())
        if (completed.any { it.visit.identity == open }) open = null
        rows.keys.removeAll { id -> rows[id]?.let { !it.moving && !it.deleting && it.x == 0.0 && held?.visit?.identity != id } == true }
        publish(); return completed
    }
    private fun heldRow(ticket: HistoryRowTicket): Row? = rows[ticket.visit.identity]?.takeIf {
        !revoked && held == ticket && it.serial == ticket.serial && it.source === ticket.source && it.visit == ticket.visit
    }
    private fun publish() { mutable.value = HistoryRowsFrame(rows.mapValues { HistoryRowPose(it.value.x, it.value.deleting) }, open,
        !revoked && rows.values.any { it.moving || it.deleting }) }
    companion object {
        const val OPEN = 108.0; const val ACT = 250.0; const val LIMIT = 330.0; const val AWAY = 400.0
        const val OPEN_DISTANCE = 60.0; const val OPEN_VELOCITY = 500.0
        fun displacement(value: Double): Double {
            val x = min(0.0, value)
            return if (-x <= LIMIT) x else -(LIMIT + (1 - 1 / ((-x - LIMIT) * .55 / 30 + 1)) * 30)
        }
        private fun ease(p: Double): Double {
            if (p <= 0 || p >= 1) return p
            fun axis(t: Double, a: Double, b: Double) = 3 * (1-t).pow(2) * t * a + 3 * (1-t) * t*t*b + t*t*t
            var lo = 0.0; var hi = 1.0
            repeat(32) { val t = (lo+hi)/2; if (axis(t,.42,.58)<p) lo=t else hi=t }
            return axis((lo+hi)/2,0.0,1.0)
        }
    }
}

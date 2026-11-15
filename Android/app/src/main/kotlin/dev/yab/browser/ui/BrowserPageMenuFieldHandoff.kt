package dev.yab.browser.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.yab.browser.model.FieldInputLease

/** The outgoing menu gets a drawing lease, never the succeeding Field's input authority.
 * A refusal is permanent, including a source/account/viewport ABA before a later draw. */
internal class BrowserPageMenuFieldHandoff(val input: FieldInputLease, val requestedNanos: Long,
    val reduced: Boolean, val animations: Boolean, private val current: () -> Boolean) {
    private var revoked = false
    var destination by mutableStateOf<PageMenuRect?>(null); private set
    var started = false; private set
    fun owned(): Boolean {
        if (revoked) return false
        if (!runCatching(current).getOrDefault(false)) { revoked = true; return false }
        return true
    }
    fun measure(rect: FieldRect): Boolean {
        val next = PageMenuRect(rect.x, rect.y, rect.width, rect.height)
        if (!owned() || !next.valid()) { revoked = true; return false }
        destination = next
        return true
    }
    fun start(presentation: BrowserPageMenuPresentation, nanos: Long): Boolean {
        if (started || destination == null || !owned()) return false
        started = true
        if (!presentation.toField(requestedNanos, reduced, animations)) return false
        presentation.advance(nanos)
        return true
    }
    fun revoke() { revoked = true }
}

/** Exact current FieldLayer.fromMenu gates, independent of the platform spring solver. */
internal data class PageMenuFieldFactors(val backdrop: Float, val cards: Float, val pill: Float) {
    companion object {
        fun at(progress: Double): PageMenuFieldFactors {
            val t = progress.coerceIn(0.0, 1.0)
            return PageMenuFieldFactors(t.toFloat(), ((t - .6) / .3).coerceIn(0.0, 1.0).toFloat(),
                ((t - .6) / .4).coerceIn(0.0, 1.0).toFloat())
        }
    }
}

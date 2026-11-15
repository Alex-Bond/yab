package dev.yab.browser.engine

/** Process recovery budget belongs to the page, including its replacement native session. */
internal class NativePageRecovery {
    enum class Phase { IDLE, DEFERRED, QUEUED, LOADING, FAILED }
    data class Ticket internal constructor(val generation: Long)
    var phase = Phase.IDLE
        private set
    private var generation = 0L
    private var attempted = false

    fun stopped(away: Boolean) {
        generation++
        // Away includes a tab behind the visible pages. Its next actual showing
        // gets a new attempt, even if an earlier foreground recovery never finished.
        // The caller's eligible gate still prevents loading while away or hidden.
        if (away) attempted = false
        phase = if (away || !attempted) Phase.DEFERRED else Phase.FAILED
    }

    fun foregrounded() {
        if (phase !in setOf(Phase.DEFERRED, Phase.FAILED)) return
        attempted = false; generation++; phase = Phase.DEFERRED
    }

    fun queue(eligible: Boolean): Ticket? {
        if (!eligible || phase != Phase.DEFERRED) return null
        if (attempted) { phase = Phase.FAILED; return null }
        phase = Phase.QUEUED
        return Ticket(++generation)
    }

    fun begin(ticket: Ticket, eligible: Boolean): Boolean {
        if (phase != Phase.QUEUED || ticket.generation != generation) return false
        if (!eligible) { generation++; phase = Phase.DEFERRED; return false }
        attempted = true; phase = Phase.LOADING
        return true
    }

    fun failed() { generation++; phase = Phase.FAILED }
    fun succeeded() = reset()
    fun reset() { generation++; attempted = false; phase = Phase.IDLE }
    fun invalidate() { generation++; phase = Phase.IDLE }
}

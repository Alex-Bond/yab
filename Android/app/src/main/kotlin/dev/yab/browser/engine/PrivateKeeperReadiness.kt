package dev.yab.browser.engine

/** A native open() call is not an acknowledgement that a Private window exists. */
internal class PrivateKeeperReadiness(val generation: Long, private val deadline: Long) {
    enum class Phase { OPENING, READY, FAILED, TIMED_OUT, REVOKED }
    private data class Waiting(val current: () -> Boolean, val commit: () -> Unit)
    var phase = Phase.OPENING
        private set
    private val waiting = linkedMapOf<String, Waiting>()
    val pendingCount get() = waiting.size

    /** A later state for the same tab replaces the old captured state, never both. */
    fun afterReady(tab: String, now: Long, current: () -> Boolean, commit: () -> Unit): Boolean {
        expire(now)
        if (!current()) { waiting.remove(tab); return false }
        return when (phase) {
            Phase.OPENING -> { waiting[tab] = Waiting(current, commit); true }
            Phase.READY -> { if (current()) commit(); true }
            else -> false
        }
    }

    fun acknowledge(capturedGeneration: Long, success: Boolean, now: Long): Boolean {
        if (capturedGeneration != generation || phase != Phase.OPENING) return false
        if (expire(now)) return false
        phase = if (success) Phase.READY else Phase.FAILED
        val held = waiting.values.toList()
        waiting.clear()
        if (success) held.forEach { if (phase == Phase.READY && it.current()) it.commit() }
        return true
    }

    fun expire(now: Long): Boolean {
        if (phase != Phase.OPENING || now < deadline) return false
        phase = Phase.TIMED_OUT; waiting.clear(); return true
    }

    fun cancel(tab: String) { waiting.remove(tab) }
    fun cancelPending() { waiting.clear() }
    fun revoke() { phase = Phase.REVOKED; waiting.clear() }
}

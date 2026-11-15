package dev.yab.agent

import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first

/** Approval UI authority only. It never represents biometric or remote attestation. */
class ApprovalInteractionTicket internal constructor(
    private val lifetime: ApprovalInteractionLifetime,
    private val generation: Long,
) {
    internal fun isCurrent(): Boolean = lifetime.current(generation)
    internal suspend fun awaitResumed(): Boolean = lifetime.awaitResumed(generation)
    internal fun register(job: Job): AutoCloseable? = lifetime.register(generation, job)

    // The caller must keep this synchronous: only the final local journal batch belongs here.
    internal fun <T> withCurrent(write: () -> T): T = lifetime.withCurrent(generation, write)
}

/** The production bridge requires UI authority even though compatibility fake ports may omit it. */
internal fun ApprovalAnswer.requireCurrentInteraction(): ApprovalInteractionTicket =
    requireNotNull(interaction) { "The approval screen is no longer active" }.also {
        check(it.isCurrent()) { "The approval screen is no longer active" }
    }

internal data class ApprovalInteractionState(val generation: Long = 0, val resumed: Boolean = false, val disposed: Boolean = false)

/** STOP/disposal permanently revoke captured tickets; PAUSE only suspends admission. */
internal class ApprovalInteractionLifetime {
    private val lock = Any()
    private val mutable = MutableStateFlow(ApprovalInteractionState())
    val state = mutable.asStateFlow()
    private val jobs = mutableMapOf<Any, Job>()

    fun resume() = synchronized(lock) { if (!mutable.value.disposed) mutable.value = mutable.value.copy(resumed = true) }
    fun pause() = synchronized(lock) { mutable.value = mutable.value.copy(resumed = false) }
    fun stop() = revoke(false)
    fun dispose() = revoke(true)
    private fun revoke(dispose: Boolean) {
        val pending = synchronized(lock) {
            val old = mutable.value
            if (old.disposed) return
            mutable.value = old.copy(generation = old.generation + 1, resumed = false, disposed = dispose)
            jobs.values.toSet().also { jobs.clear() }
        }
        // Cancellation may run authentication callbacks. Never call them under the authority lock.
        pending.forEach { it.cancel() }
    }
    fun capture(rendered: ApprovalInteractionState): ApprovalInteractionTicket? = synchronized(lock) {
        if (mutable.value != rendered || !rendered.resumed || rendered.disposed) null
        else ApprovalInteractionTicket(this, rendered.generation)
    }
    internal fun current(generation: Long): Boolean = synchronized(lock) { currentLocked(generation) }
    private fun currentLocked(generation: Long): Boolean = mutable.value.let { !it.disposed && it.resumed && it.generation == generation }
    internal suspend fun awaitResumed(generation: Long): Boolean {
        state.first { it.disposed || it.generation != generation || it.resumed }
        return current(generation)
    }
    internal fun register(generation: Long, job: Job): AutoCloseable? = synchronized(lock) {
        if (!currentLocked(generation)) return null
        val registration = Any()
        jobs[registration] = job
        AutoCloseable { synchronized(lock) { jobs.remove(registration) }; Unit }
    }
    internal fun <T> withCurrent(generation: Long, write: () -> T): T = synchronized(lock) {
        check(currentLocked(generation)) { "The approval screen is no longer active" }
        write()
    }
}

package dev.yab.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One original command. Cancellation and commit can finish only its own admission. */
internal class RecoveryHandoff(
    private val owner: Any,
    internal val source: SyncOperationLease.Source,
    internal val marker: SyncOperationLease.Marker,
    private val cancelOriginal: (RecoveryHandoff, Presentation) -> Boolean = { _, _ -> false },
    private val retryOriginal: (RecoveryHandoff) -> RecoveryHandoff?,
) {
    enum class Phase { QUEUED, ADMITTED, COMMITTED, CANCELLED, REFUSED, FAILED, COMPLETE }
    data class Presentation(val phase: Phase, val error: String? = null)
    private val mutable = MutableStateFlow(Presentation(Phase.QUEUED))
    val presentation = mutable.asStateFlow()
    private var used = false
    private var retried = false
    private var ticket: SyncOperationLease.Ticket? = null
    fun cancel(snapshot: Presentation): Boolean = cancelOriginal(this, snapshot)
    /** The callback validates source and finishes only this ticket, with no I/O. */
    @Synchronized fun cancel(expectedOwner: Any, snapshot: Presentation,
        cancelAdmission: (SyncOperationLease.Ticket?) -> Boolean): Boolean {
        if (owner !== expectedOwner || mutable.value !== snapshot ||
            snapshot.phase !in setOf(Phase.QUEUED, Phase.ADMITTED)) return false
        val original = if (snapshot.phase == Phase.ADMITTED) ticket ?: return false else null
        used = true
        if (!cancelAdmission(original)) {
            mutable.value = Presentation(Phase.REFUSED, "Sync unavailable")
            return false
        }
        mutable.value = Presentation(Phase.CANCELLED)
        return true
    }
    @Synchronized fun reject(expectedOwner: Any): Boolean {
        if (owner !== expectedOwner || used) return false
        used = true; mutable.value = Presentation(Phase.REFUSED, "Sync unavailable")
        return true
    }

    /** Callback contains only native source/closing + atomic idle/begin checks, never I/O. */
    @Synchronized fun admit(expectedOwner: Any, begin: () -> SyncOperationLease.Ticket?): SyncOperationLease.Ticket? {
        if (used) return null
        used = true
        if (owner !== expectedOwner) { mutable.value = Presentation(Phase.REFUSED, "Sync unavailable"); return null }
        val value = begin()
        if (value == null) { mutable.value = Presentation(Phase.REFUSED, "Sync unavailable"); return null }
        ticket = value
        mutable.value = Presentation(Phase.ADMITTED)
        return value
    }
    @Synchronized fun refuse(expectedOwner: Any, value: SyncOperationLease.Ticket): Boolean {
        if (owner !== expectedOwner || ticket !== value || mutable.value.phase != Phase.ADMITTED) return false
        mutable.value = Presentation(Phase.REFUSED, "Sync unavailable")
        return true
    }
    /** The winner excludes accepted cancellation before any durable work starts. */
    @Synchronized fun commit(expectedOwner: Any, value: SyncOperationLease.Ticket, finishOriginal: () -> Boolean): Boolean {
        if (owner !== expectedOwner || ticket !== value || mutable.value.phase != Phase.ADMITTED) return false
        if (!finishOriginal()) { mutable.value = Presentation(Phase.REFUSED, "Sync unavailable"); return false }
        mutable.value = Presentation(Phase.COMMITTED)
        return true
    }
    @Synchronized fun committed(expectedOwner: Any, value: SyncOperationLease.Ticket): Boolean =
        owner === expectedOwner && ticket === value && mutable.value.phase == Phase.COMMITTED
    @Synchronized fun outcome(expectedOwner: Any, value: SyncOperationLease.Ticket, error: String? = null): Boolean {
        if (owner !== expectedOwner || ticket !== value || mutable.value.phase != Phase.COMMITTED) return false
        mutable.value = Presentation(if (error == null) Phase.COMPLETE else Phase.FAILED, error)
        return true
    }
    fun retry(): RecoveryHandoff? = retryOriginal(this)
    /** Retry keeps the exact finished ticket marker; it cannot capture a new idle generation. */
    @Synchronized fun retry(expectedOwner: Any, current: (SyncOperationLease.Marker) -> Boolean,
        create: (SyncOperationLease.Marker) -> RecoveryHandoff): RecoveryHandoff? {
        val originalTicket = ticket ?: return null
        if (owner !== expectedOwner || retried || mutable.value.phase != Phase.FAILED) return null
        retried = true
        if (!current(originalTicket.marker)) {
            mutable.value = Presentation(Phase.REFUSED, "Sync unavailable")
            return null
        }
        return create(originalTicket.marker)
    }
}

package dev.yab.sync

import java.io.Closeable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Opaque original code request. It never obtains a newer operation or account. */
class CodeJoinRequest internal constructor(
    private val owner: Any,
    private val original: SyncOperationLease.Source,
    private val originalCurrent: (SyncOperationLease.Ticket?, Closeable?, Boolean) -> Boolean,
    private val recoveryCurrent: (SyncOperationLease.Ticket?) -> Boolean,
    private val handoffOriginal: (CodeJoinRequest, Presentation) -> RecoveryHandoff?,
    private val cancelOriginal: (CodeJoinRequest) -> Boolean,
) {
    internal constructor(owner: Any, original: SyncOperationLease.Source,
        originalCurrent: (SyncOperationLease.Ticket?, Closeable?, Boolean) -> Boolean,
        recoveryCurrent: (SyncOperationLease.Ticket?) -> Boolean,
        cancelOriginal: (CodeJoinRequest) -> Boolean) : this(owner, original, originalCurrent, recoveryCurrent, { _, _ -> null }, cancelOriginal)
    internal constructor(owner: Any, original: SyncOperationLease.Source,
        originalCurrent: (SyncOperationLease.Ticket?, Closeable?, Boolean) -> Boolean,
        cancelOriginal: (CodeJoinRequest) -> Boolean) : this(owner, original, originalCurrent, { true }, { _, _ -> null }, cancelOriginal)
    internal constructor(owner: Any, original: SyncOperationLease.Source, cancelOriginal: (CodeJoinRequest) -> Boolean) :
        this(owner, original, { _, _, _ -> true }, { true }, { _, _ -> null }, cancelOriginal)
    enum class Stage { PENDING, PUBLISHED, COMMITTED, FAILED, CANCELLED, RETIRED, COMPLETE }
    /** Presentation data only. A snapshot cannot grant a session, ticket or account. */
    data class Presentation internal constructor(val revision: Long, val stage: Stage,
        val code: String? = null, val check: String? = null, val error: String? = null)
    private val mutablePresentation = MutableStateFlow(Presentation(0, Stage.PENDING))
    val presentation = mutablePresentation.asStateFlow()
    private fun emit(stage: Stage, code: String? = null, check: String? = null, error: String? = null) {
        mutablePresentation.value = Presentation(mutablePresentation.value.revision + 1, stage, code, check, error)
    }
    internal data class Cancelled(val ticket: SyncOperationLease.Ticket?, val session: Closeable?)
    private var retired = false
    private var finished = false
    private var recoveryRetired = false
    private var handoffClaimed = false
    private var ticket: SyncOperationLease.Ticket? = null
    private var session: Closeable? = null
    fun cancel(): Boolean = cancelOriginal(this)
    internal fun recoveryHandoff(snapshot: Presentation): RecoveryHandoff? = handoffOriginal(this, snapshot)
    @Synchronized internal fun claimRecovery(expectedOwner: Any, snapshot: Presentation,
        create: (SyncOperationLease.Ticket?) -> RecoveryHandoff): RecoveryHandoff? {
        if (owner !== expectedOwner || handoffClaimed || presentation.value !== snapshot ||
            snapshot.stage !in setOf(Stage.PENDING, Stage.PUBLISHED, Stage.FAILED)) return null
        fun refuse(): RecoveryHandoff {
            handoffClaimed = true
            val refused = create(ticket)
            check(refused.reject(expectedOwner))
            retired = true; emit(Stage.RETIRED)
            return refused
        }
        if (!permitsRecovery(snapshot)) return refuse()
        if (snapshot.stage != Stage.FAILED && !cancelOriginal(this)) return refuse()
        handoffClaimed = true
        val result = create(ticket)
        retired = true; emit(Stage.RETIRED)
        return result
    }
    /** Action-time check of this exact source/ticket/session, never a latest-request lookup. */
    @Synchronized fun permits(snapshot: Presentation): Boolean {
        if (presentation.value !== snapshot || snapshot.stage == Stage.RETIRED) return false
        if (!originalCurrent(ticket, session, !finished && !retired)) {
            if (!finished && !retired) { retired = true; emit(Stage.RETIRED) }
            return false
        }
        return true
    }
    /** Terminal local Back needs no new command; Recovery handoff also proves no operation ABA. */
    @Synchronized internal fun permitsRecovery(snapshot: Presentation): Boolean {
        if (recoveryRetired || !permits(snapshot)) return false
        if (!recoveryCurrent(ticket)) { recoveryRetired = true; return false }
        return true
    }

    private fun valid(expected: Any, source: SyncOperationLease.Source): Boolean {
        if (owner !== expected || retired || finished) return false
        if (source != original) { retired = true; emit(Stage.RETIRED); return false }
        return true
    }
    @Synchronized internal fun current(expected: Any, source: SyncOperationLease.Source): Boolean = valid(expected, source)
    @Synchronized internal fun allocate(expected: Any, source: SyncOperationLease.Source,
        begin: () -> SyncOperationLease.Ticket?): SyncOperationLease.Ticket? {
        if (!valid(expected, source) || ticket != null) return null
        val value = begin() ?: return null
        check(value.source == original)
        ticket = value
        return value
    }
    /** Only nonblocking publication/session construction belongs inside this short lock. */
    @Synchronized internal fun publish(expected: Any, source: SyncOperationLease.Source, value: SyncOperationLease.Ticket,
        operationCurrent: () -> Boolean, code: String? = null, check: String? = null, create: () -> Closeable): Boolean {
        if (!valid(expected, source) || ticket !== value || session != null) return false
        if (!operationCurrent()) { retired = true; emit(Stage.RETIRED); return false }
        session = create()
        emit(Stage.PUBLISHED, code, check)
        return true
    }
    /** The commit excludes accepted cancellation before any durable identity/attach work. */
    @Synchronized internal fun commit(expected: Any, source: SyncOperationLease.Source, value: SyncOperationLease.Ticket,
        finishOperation: () -> Boolean): Boolean {
        if (!valid(expected, source) || ticket !== value) return false
        if (!finishOperation()) { retired = true; emit(Stage.RETIRED); return false }
        finished = true
        emit(Stage.COMMITTED)
        return true
    }
    /** Only the winning original commit can finish its own local presentation. */
    @Synchronized internal fun outcome(expected: Any, value: SyncOperationLease.Ticket, error: String? = null): Boolean {
        if (owner !== expected || retired || !finished || ticket !== value || presentation.value.stage != Stage.COMMITTED) return false
        emit(if (error == null) Stage.COMPLETE else Stage.FAILED, error = error)
        return true
    }
    @Synchronized internal fun failUnbound(expected: Any, source: SyncOperationLease.Source, error: String? = null, publish: () -> Unit): Boolean {
        if (!valid(expected, source) || ticket != null) return false
        finished = true
        emit(Stage.FAILED, error = error)
        publish()
        return true
    }
    @Synchronized internal fun cancel(expected: Any, source: SyncOperationLease.Source,
        sourceCurrent: () -> Boolean = { true }): Cancelled? {
        if (!valid(expected, source)) return null
        if (!sourceCurrent() || !originalCurrent(ticket, session, true)) { retired = true; emit(Stage.RETIRED); return null }
        retired = true
        emit(Stage.CANCELLED)
        return Cancelled(ticket, session)
    }
}

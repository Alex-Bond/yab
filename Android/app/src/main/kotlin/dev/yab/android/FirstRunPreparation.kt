package dev.yab.android

import dev.yab.sync.SyncIdentityLease
import dev.yab.sync.AccountRecordsSnapshot
import dev.yab.sync.AndroidSyncBridge
import dev.yab.sync.SyncUiState
import dev.yab.agent.RemoteConnection
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A local read/publication request, never a join, a restored account or native input authority. */
internal class FirstRunPreparation(private val source: () -> Source) {
    internal data class Source(val noFlow: Boolean, val loading: Boolean, val welcomed: Boolean,
        val identity: SyncIdentityLease?, val epoch: Long, val nativeAvailable: Boolean,
        val entryAvailable: Boolean = nativeAvailable) {
        val eligible: Boolean get() = noFlow && !loading && !welcomed && !entryAvailable &&
            (identity == null || identity.epoch == epoch)
    }
    internal enum class Phase { PENDING, PREPARING, FAILED }
    internal data class State(val phase: Phase = Phase.PENDING, val revision: Long = 0)
    internal class Control internal constructor(internal val owner: FirstRunPreparation,
        internal val host: FirstRunPresentation.Host, internal val original: Source, internal val revision: Long) {
        private var retired = false
        fun retire() { retired = true }
        internal fun consume(expected: FirstRunPreparation): Boolean {
            if (owner !== expected || retired) return false
            retired = true
            return owner.matches(host, original, revision)
        }
    }
    internal class Ticket internal constructor(internal val owner: FirstRunPreparation,
        internal val host: FirstRunPresentation.Host, internal val original: Source) {
        internal var invoked = false
        internal var retired = false
    }
    private val mutable = MutableStateFlow(State())
    val state = mutable.asStateFlow()
    private var active: Ticket? = null
    private var reportedSource: Source? = null
    private var reportedHost: FirstRunPresentation.Host? = null
    fun snapshot(): Source = source()
    /** A fresh native render can retire an abandoned old read without waiting for it. */
    fun observe(host: FirstRunPresentation.Host) {
        if (!host.current()) return
        val now = source()
        val old = active
        if (old != null && (!old.host.current() || now != old.original) || reportedSource?.let { it != now } == true ||
            reportedHost?.let { it !== host || !it.current() } == true) invalidate()
    }
    fun retireHost(host: FirstRunPresentation.Host) {
        if (active?.host === host || reportedHost === host) invalidate()
    }
    private fun matches(host: FirstRunPresentation.Host, original: Source, revision: Long): Boolean =
        original.eligible && active == null && state.value.revision == revision &&
            host.current() && source() == original && host.current() && state.value.revision == revision && active == null
    fun control(host: FirstRunPresentation.Host, expected: Source? = null): Control? {
        val original = source(); if (expected != null && original != expected) return null
        val revision = state.value.revision
        return if (matches(host, original, revision)) Control(this, host, original, revision) else null
    }
    fun begin(control: Control?): Ticket? {
        if (control?.consume(this) != true) return null
        return Ticket(this, control.host, control.original).also {
            reportedSource = null; reportedHost = null
            active = it; mutable.value = State(Phase.PREPARING, state.value.revision + 1)
        }
    }
    /** Last caller-side check before the existing dispatcher API is enqueued. */
    fun beforeCall(ticket: Ticket): Boolean {
        if (ticket.owner !== this || active !== ticket || ticket.retired || ticket.invoked) return false
        if (!ticket.host.current() || source() != ticket.original || !ticket.host.current()) {
            ticket.retired = true; return false
        }
        ticket.invoked = true
        return true
    }
    /** Own busy cleanup only. A result cannot create a FirstRun owner or adopt a new identity. */
    fun complete(ticket: Ticket, failed: Boolean): Boolean {
        if (ticket.owner !== this || active !== ticket) return false
        val reportFailure = failed && !ticket.retired && ticket.invoked && ticket.host.current() &&
            source() == ticket.original && ticket.host.current()
        ticket.retired = true; active = null
        reportedSource = ticket.original.takeIf { reportFailure }
        reportedHost = ticket.host.takeIf { reportFailure }
        mutable.value = State(if (reportFailure) Phase.FAILED else Phase.PENDING, state.value.revision + 1)
        return reportFailure
    }
    /** The VM calls this synchronously before any logical FirstRun slot changes, including ABA. */
    fun invalidate() {
        active?.retired = true; active = null; reportedSource = null; reportedHost = null
        mutable.value = State(Phase.PENDING, state.value.revision + 1)
    }
}

/** Fresh entry only. An existing genuine join still uses its original completion contract. */
internal fun firstRunEntryReady(source: TabletJoinPresentation.Source, records: AccountRecordsSnapshot,
    ui: SyncUiState, connection: RemoteConnection): Boolean {
    if (!source.available || records.removed || records.epoch != source.epoch ||
        records.account != source.identity?.account || records.device != source.identity?.device) return false
    val identity = source.identity ?: return true
    return identity.epoch == source.epoch && ui.phase == "live" && ui.account == identity.account &&
        connection.account == identity.account && connection.epoch == identity.epoch
}

/** Native ownership is sampled before and after the live saved-account entry facts. */
internal fun firstRunEntryAvailable(sync: AndroidSyncBridge): Boolean {
    val records = sync.accountRecords.value
    val source = tabletJoinSource(sync)
    val ui = sync.ui.value
    val connection = sync.connection.value
    return firstRunEntryReady(source, records, ui, connection) && sync.identityLease() == source.identity &&
        sync.accountEpoch == source.epoch && sync.ui.value == ui && sync.connection.value == connection &&
        sync.nativeOwnerCurrent(records)
}

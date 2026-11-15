package dev.yab.sync

/** A late account operation can neither finish nor report an error in a newer session. */
internal class SyncOperationLease {
    data class Source(val account: String?, val device: String?, val epoch: Long)
    class Marker internal constructor()
    class Ticket internal constructor(internal val source: Source, internal val marker: Marker)
    private var active: Ticket? = null
    private var generation = Marker()

    @Synchronized fun marker(): Marker = generation
    @Synchronized fun idleSince(marker: Marker): Boolean = active == null && generation === marker
    @Synchronized fun beginIfIdleSince(marker: Marker, source: Source): Ticket? =
        if (idleSince(marker)) begin(source) else null
    @Synchronized fun begin(source: Source): Ticket = Ticket(source, Marker().also { generation = it }).also { active = it }
    @Synchronized fun current(ticket: Ticket, source: Source): Boolean = active === ticket && ticket.source == source
    @Synchronized fun finish(ticket: Ticket, source: Source): Boolean {
        if (!current(ticket, source)) return false
        active = null
        return true
    }
    @Synchronized fun invalidate() { active = null; generation = Marker() }
}

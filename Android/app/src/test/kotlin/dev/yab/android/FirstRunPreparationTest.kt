package dev.yab.android

import dev.yab.sync.SyncIdentityLease
import dev.yab.sync.AccountRecordsSnapshot
import dev.yab.sync.SyncUiState
import dev.yab.agent.RemoteConnection
import org.junit.Assert.*
import org.junit.Test

/** Read/publication ownership only. These callbacks do not qualify an OS/Bridge recovery. */
class FirstRunPreparationTest {
    private class Fixture {
        var source = FirstRunPreparation.Source(true, false, false, SyncIdentityLease("saved", "device", 4), 4, false)
        var generation = 0L
        var nativeToken = Any()
        var active = true
        val owner = FirstRunPreparation { source }
        fun host(): FirstRunPresentation.Host {
            val originalGeneration = generation; val originalToken = nativeToken
            return FirstRunPresentation.RenderedHost { active && generation == originalGeneration && nativeToken === originalToken }
        }
        fun control() = requireNotNull(owner.control(host()))
    }
    @Test fun oneRealUserControlProducesOnlyOneReadTicketAndCannotBeReentered() {
        val f = Fixture(); val control = f.control(); val ticket = requireNotNull(f.owner.begin(control))
        assertNull(f.owner.begin(control)); assertNull(f.owner.control(f.host()))
        assertEquals(FirstRunPreparation.Phase.PREPARING, f.owner.state.value.phase)
        assertTrue(f.owner.beforeCall(ticket)); assertFalse(f.owner.beforeCall(ticket))
        assertFalse(f.owner.complete(ticket, failed = false)); assertFalse(f.owner.complete(ticket, failed = true))
        assertEquals(FirstRunPreparation.Phase.PENDING, f.owner.state.value.phase)
    }
    @Test fun onlyMatchingCurrentFailureProducesTheFixedRetryState() {
        val f = Fixture(); val ticket = requireNotNull(f.owner.begin(f.control()))
        assertTrue(f.owner.beforeCall(ticket)); assertTrue(f.owner.complete(ticket, failed = true))
        assertEquals(FirstRunPreparation.Phase.FAILED, f.owner.state.value.phase)
        val retry = requireNotNull(f.owner.begin(f.control())); assertTrue(f.owner.beforeCall(retry))
        assertFalse(f.owner.complete(ticket, failed = true)); assertFalse(f.owner.complete(retry, failed = false))
        assertEquals(FirstRunPreparation.Phase.PENDING, f.owner.state.value.phase)
        val failedHost = f.host(); val failedTicket = requireNotNull(f.owner.begin(f.owner.control(failedHost)))
        assertTrue(f.owner.beforeCall(failedTicket)); assertTrue(f.owner.complete(failedTicket, failed = true))
        f.generation++; f.owner.observe(f.host())
        assertEquals(FirstRunPreparation.Phase.PENDING, f.owner.state.value.phase)
        assertNotNull(f.owner.control(f.host()))
    }
    @Test fun stoppedOrReplacedWindowCannotEnqueueItsSavedControlOrTicket() {
        val f = Fixture(); val old = f.control(); f.generation++
        assertNull(f.owner.begin(old)); val ticket = requireNotNull(f.owner.begin(f.control()))
        f.nativeToken = Any(); assertFalse(f.owner.beforeCall(ticket))
        assertFalse(f.owner.complete(ticket, failed = true)); assertEquals(FirstRunPreparation.Phase.PENDING, f.owner.state.value.phase)
    }
    @Test fun accountEpochWelcomedAndANewFlowRefuseTheOriginalPrequeueTicket() {
        for (change in listOf<(FirstRunPreparation.Source) -> FirstRunPreparation.Source>(
            { it.copy(identity = SyncIdentityLease("new", "other", 5), epoch = 5) },
            { it.copy(welcomed = true) }, { it.copy(noFlow = false) }, { it.copy(loading = true) })) {
            val f = Fixture(); val ticket = requireNotNull(f.owner.begin(f.control())); f.source = change(f.source)
            assertFalse(f.owner.beforeCall(ticket)); assertFalse(f.owner.complete(ticket, failed = true))
        }
    }
    @Test fun synchronousSlotRetirementPreventsNoFlowToFlowToNoFlowAba() {
        val f = Fixture(); val saved = f.control(); val ticket = requireNotNull(f.owner.begin(f.control()))
        assertTrue(f.owner.beforeCall(ticket))
        f.owner.invalidate(); f.source = f.source.copy(noFlow = false)
        f.owner.invalidate(); f.source = f.source.copy(noFlow = true)
        assertNull(f.owner.begin(saved)); assertFalse(f.owner.complete(ticket, failed = true))
        assertEquals(FirstRunPreparation.Phase.PENDING, f.owner.state.value.phase)
        assertTrue(f.owner.beforeCall(requireNotNull(f.owner.begin(f.control()))))
        f.generation++; f.owner.observe(f.host())
        val freshAfterStop = requireNotNull(f.owner.begin(f.control()))
        assertTrue(f.owner.beforeCall(freshAfterStop))
    }
    @Test fun aReadTicketCannotCompleteOrWelcomeASeparatelyAdmittedFreshLogicalJourney() {
        val f = Fixture(); val ticket = requireNotNull(f.owner.begin(f.control())); assertTrue(f.owner.beforeCall(ticket))
        f.source = f.source.copy(nativeAvailable = true, entryAvailable = true)
        assertFalse(f.owner.complete(ticket, failed = false)); assertNull(f.owner.control(f.host()))
        assertTrue(f.source.noFlow); assertFalse(f.source.welcomed)
        // A separately admitted logical journey has its own owner. Main entry facts are tested below.
        val source = TabletJoinPresentation.Source(f.source.identity, f.source.epoch, true)
        val fresh = FirstRunPresentation({ source }, { null }); val host = f.host()
        assertTrue(fresh.begin(fresh.control(host)))
        assertTrue(fresh.advance(requireNotNull(fresh.timer(host, false)), FirstRunPresentation.DefaultBrowser(true, false), { false }))
        assertEquals(FirstRunPresentation.Step.FOUND, fresh.state.value.step); assertFalse(fresh.state.value.counting)
        assertFalse(f.owner.complete(ticket, failed = true))
    }
    @Test fun unknownOrUnreadSavedIdentityIsNotClaimedToBeTheResultOfItsOldCallerScope() {
        val f = Fixture(); f.source = f.source.copy(identity = null)
        val ticket = requireNotNull(f.owner.begin(f.control())); assertTrue(f.owner.beforeCall(ticket))
        // Existing prepareNativeOwner reads the actual saved key; it accepts no expected owner argument.
        f.source = f.source.copy(identity = SyncIdentityLease("read-from-store", "stored", 4), nativeAvailable = true, entryAvailable = true)
        assertFalse(f.owner.complete(ticket, failed = true)); assertFalse(f.source.welcomed)
        assertEquals(FirstRunPreparation.Phase.PENDING, f.owner.state.value.phase)
    }
    @Test fun disposedOrForeignControlsAndLateFailureCannotAffectAFreshTicket() {
        val f = Fixture(); val foreign = Fixture(); assertNull(f.owner.begin(foreign.control()))
        val disposed = f.control(); disposed.retire(); assertNull(f.owner.begin(disposed))
        val old = requireNotNull(f.owner.begin(f.control())); assertTrue(f.owner.beforeCall(old))
        f.owner.invalidate(); val fresh = requireNotNull(f.owner.begin(f.control())); assertTrue(f.owner.beforeCall(fresh))
        assertFalse(f.owner.complete(old, failed = true)); assertEquals(FirstRunPreparation.Phase.PREPARING, f.owner.state.value.phase)
        assertTrue(f.owner.complete(fresh, failed = true)); assertEquals(FirstRunPreparation.Phase.FAILED, f.owner.state.value.phase)
    }
    @Test fun aCurrentUnpairedPublicationCanEnterWithoutPretendingToHaveALiveConnection() {
        val source = TabletJoinPresentation.Source(null, 4, true)
        val records = AccountRecordsSnapshot(epoch = 4)
        assertTrue(firstRunEntryReady(source, records, SyncUiState(), RemoteConnection()))
        assertFalse(firstRunEntryReady(source.copy(available = false), records, SyncUiState(), RemoteConnection()))
        assertFalse(firstRunEntryReady(source, records.copy(removed = true), SyncUiState(), RemoteConnection()))
        assertFalse(firstRunEntryReady(source, records.copy(account = "stale"), SyncUiState(), RemoteConnection()))
    }
    @Test fun savedNativePublicationCannotEnterFoundUntilTheSameAccountAndEpochAreActuallyLive() {
        val identity = SyncIdentityLease("saved", "device", 4)
        val source = TabletJoinPresentation.Source(identity, 4, true)
        val records = AccountRecordsSnapshot("saved", 4, device = "device")
        val connection = RemoteConnection(account = "saved", epoch = 4)
        for (phase in listOf("off", "connecting", "waiting", "removed")) {
            assertFalse(firstRunEntryReady(source, records, SyncUiState(phase, "saved"), connection))
        }
        val live = SyncUiState("live", "saved")
        assertTrue(firstRunEntryReady(source, records, live, connection))
        assertFalse(firstRunEntryReady(source, records, live.copy(account = "other"), connection))
        assertFalse(firstRunEntryReady(source, records, live, connection.copy(account = "other")))
        assertFalse(firstRunEntryReady(source, records, live, connection.copy(epoch = 3)))
        assertFalse(firstRunEntryReady(source, records.copy(device = "other"), live, connection))
        assertFalse(firstRunEntryReady(source, records.copy(epoch = 3), live, connection))
        assertFalse(firstRunEntryReady(source.copy(identity = identity.copy(epoch = 3)), records, live, connection))
    }
    @Test fun aCurrentButNonLiveSavedPublicationPermitsOnlyAnotherLocalReadTicket() {
        val f = Fixture(); f.source = f.source.copy(nativeAvailable = true, entryAvailable = false)
        val ticket = requireNotNull(f.owner.begin(f.control()))
        assertTrue(f.owner.beforeCall(ticket)); assertFalse(f.owner.complete(ticket, failed = false))
        assertTrue(f.source.noFlow); assertFalse(f.source.welcomed); assertFalse(f.source.entryAvailable)
        assertNotNull(f.owner.control(f.host()))
    }

}

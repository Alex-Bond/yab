package dev.yab.sync

import java.io.Closeable
import org.junit.Assert.*
import org.junit.Test

class CodeJoinRequestTest {
    private class Fixture {
        val owner = Any()
        var source = SyncOperationLease.Source(null, null, 7)
        val operations = SyncOperationLease()
        var cancelled: CodeJoinRequest.Cancelled? = null
        fun request() = CodeJoinRequest(owner, source) { request ->
            request.cancel(owner, source)?.let { cancelled = it; true } ?: false
        }
        fun bind(request: CodeJoinRequest): SyncOperationLease.Ticket =
            checkNotNull(request.allocate(owner, source) { operations.begin(source) })
    }
    @Test fun aQueuedCancellationIsOneUseAndCannotBindAnyLaterOperation() {
        val f = Fixture(); val request = f.request()
        assertTrue(request.cancel()); assertFalse(request.cancel())
        assertNull(f.cancelled!!.ticket); assertNull(f.cancelled!!.session)
        val fresh = f.operations.begin(f.source)
        assertNull(request.allocate(f.owner, f.source) { error("Cancelled request must not allocate") })
        assertTrue(f.operations.current(fresh, f.source))
    }
    @Test fun cancellationDuringHealthRefusesCodePublicationAndCompletion() {
        val f = Fixture(); val request = f.request(); val ticket = f.bind(request)
        assertTrue(request.current(f.owner, f.source)) // before the external health request
        assertTrue(request.cancel())
        var publications = 0; var commits = 0
        assertFalse(request.publish(f.owner, f.source, ticket, { true }) { publications++; Closeable { } })
        assertFalse(request.commit(f.owner, f.source, ticket) { commits++; f.operations.finish(ticket, f.source) })
        assertEquals(0, publications); assertEquals(0, commits)
        assertSame(ticket, f.cancelled!!.ticket)
    }
    @Test fun replacementDoesNotLetTheOldRequestAdoptOrCancelTheFreshTicketOrSession() {
        val f = Fixture(); val old = f.request(); val oldTicket = f.bind(old); val oldSession = Closeable { }
        assertTrue(old.publish(f.owner, f.source, oldTicket, { f.operations.current(oldTicket, f.source) }) { oldSession })
        val fresh = f.request(); val freshTicket = f.bind(fresh); val freshSession = Closeable { }
        assertTrue(fresh.publish(f.owner, f.source, freshTicket, { f.operations.current(freshTicket, f.source) }) { freshSession })
        assertTrue(old.cancel()); assertSame(oldTicket, f.cancelled!!.ticket); assertSame(oldSession, f.cancelled!!.session)
        assertFalse(f.operations.finish(f.cancelled!!.ticket!!, f.source))
        assertNull(old.allocate(f.owner, f.source) { error("Old request must not allocate") })
        assertTrue(f.operations.current(freshTicket, f.source)); assertTrue(fresh.current(f.owner, f.source))
    }
    @Test fun accountEpochLossPermanentlyRefusesItsOldRequestEvenIfValuesAreRestored() {
        val f = Fixture(); val request = f.request(); val original = f.source
        f.source = f.source.copy(epoch = 8)
        assertFalse(request.current(f.owner, f.source))
        f.source = original
        assertFalse(request.current(f.owner, f.source)); assertFalse(request.cancel())
        val fresh = f.request(); assertTrue(fresh.current(f.owner, f.source))
    }
    @Test fun commitWinsOnceAndMakesCancellationRefuseBeforeAnyIdentityWork() {
        val f = Fixture(); val request = f.request(); val ticket = f.bind(request); var commits = 0
        assertTrue(request.commit(f.owner, f.source, ticket) { commits++; f.operations.finish(ticket, f.source) })
        assertFalse(request.cancel()); assertFalse(request.current(f.owner, f.source))
        assertFalse(request.commit(f.owner, f.source, ticket) { commits++; true })
        assertEquals(1, commits)
    }
    @Test fun foreignOwnersTicketsAndChangedAccountCannotPublishOrCancelAnOriginalRequest() {
        val f = Fixture(); val request = f.request(); val ticket = f.bind(request)
        assertNull(request.cancel(Any(), f.source))
        val foreign = SyncOperationLease().begin(f.source)
        assertFalse(request.publish(f.owner, f.source, foreign, { true }) { error("Foreign ticket") })
        assertFalse(request.commit(f.owner, f.source, foreign) { error("Foreign ticket") })
        assertTrue(request.current(f.owner, f.source))
        assertNull(request.cancel(f.owner, f.source.copy(account = "replacement")))
        assertFalse(request.commit(f.owner, f.source, ticket) { true })
    }
    @Test fun codeSessionPublicationCanOnlyUseItsBoundOriginalTicketOnce() {
        val f = Fixture(); val request = f.request(); val ticket = f.bind(request); var sessions = 0
        assertTrue(request.publish(f.owner, f.source, ticket, { true }) { sessions++; Closeable { } })
        assertFalse(request.publish(f.owner, f.source, ticket, { true }) { sessions++; Closeable { } })
        assertEquals(1, sessions); assertNull(request.allocate(f.owner, f.source) { error("No replacement allocation") })
    }
    @Test fun anUnboundValidationFailurePublishesOnceButNeverAfterAcceptedCancellation() {
        val f = Fixture(); val cancelled = f.request(); assertTrue(cancelled.cancel()); var errors = 0
        assertFalse(cancelled.failUnbound(f.owner, f.source) { errors++ })
        val current = f.request(); assertTrue(current.failUnbound(f.owner, f.source) { errors++ })
        assertFalse(current.failUnbound(f.owner, f.source) { errors++ }); assertFalse(current.cancel())
        assertEquals(1, errors)
    }
    @Test fun cancellationAfterTheFirstCurrentReadCannotAllocateOrRevokeAnExistingOperation() {
        val f = Fixture(); val existing = f.operations.begin(f.source); val request = f.request()
        assertTrue(request.current(f.owner, f.source)); assertTrue(request.cancel())
        var allocations = 0
        assertNull(request.allocate(f.owner, f.source) { allocations++; f.operations.begin(f.source) })
        assertEquals(0, allocations); assertTrue(f.operations.current(existing, f.source))
    }
    @Test fun cancellationRechecksOriginalSourceInsideItsLatchAndCannotReviveAfterLoss() {
        val f = Fixture(); val request = f.request(); val sampled = f.source
        f.source = f.source.copy(epoch = 8)
        assertNull(request.cancel(f.owner, sampled) { f.source == sampled })
        f.source = sampled
        assertFalse(request.cancel()); assertFalse(request.current(f.owner, f.source))
    }
    @Test fun onlyASuccessfullyConstructedOriginalSessionPublishesItsOwnImmutableCodeSnapshot() {
        val f = Fixture(); val request = f.request(); val pending = request.presentation.value; val ticket = f.bind(request)
        assertEquals(CodeJoinRequest.Stage.PENDING, pending.stage); assertNull(pending.code); assertNull(pending.check); assertNull(pending.error)
        assertTrue(request.publish(f.owner, f.source, ticket, { true }, "OWN-CODE", "own-check") {
            assertSame(pending, request.presentation.value); Closeable { }
        })
        val published = request.presentation.value
        assertNotSame(pending, published); assertEquals(CodeJoinRequest.Stage.PUBLISHED, published.stage)
        assertEquals("OWN-CODE", published.code); assertEquals("own-check", published.check)
        assertTrue(request.cancel()); val cancelled = request.presentation.value
        assertEquals(CodeJoinRequest.Stage.CANCELLED, cancelled.stage); assertNull(cancelled.code); assertNull(cancelled.check)
        assertFalse(request.outcome(f.owner, ticket, "Late failure")); assertSame(cancelled, request.presentation.value)
        assertEquals("OWN-CODE", published.code)
    }
    @Test fun commitAndItsOwnTerminalOutcomeRetireCopyDataWithoutBorrowingAnyGlobalError() {
        val f = Fixture(); val request = f.request(); val ticket = f.bind(request)
        assertTrue(request.publish(f.owner, f.source, ticket, { true }, "OWN-CODE", "own-check") { Closeable { } })
        assertTrue(request.commit(f.owner, f.source, ticket) { f.operations.finish(ticket, f.source) })
        val committed = request.presentation.value
        assertEquals(CodeJoinRequest.Stage.COMMITTED, committed.stage); assertNull(committed.code); assertFalse(request.cancel())
        assertTrue(request.outcome(f.owner, ticket, "Own terminal failure")); val failed = request.presentation.value
        assertEquals(CodeJoinRequest.Stage.FAILED, failed.stage); assertEquals("Own terminal failure", failed.error)
        assertFalse(request.outcome(f.owner, ticket)); assertSame(failed, request.presentation.value)
        val fresh = f.request(); assertEquals(CodeJoinRequest.Stage.PENDING, fresh.presentation.value.stage)
        assertNull(fresh.presentation.value.error)
    }
    @Test fun replacedTicketOrObservedSourceLossPermanentlyRetiresItsPresentationEvenWithEqualPayloads() {
        val f = Fixture(); val old = f.request(); val oldTicket = f.bind(old)
        assertTrue(old.publish(f.owner, f.source, oldTicket, { true }, "SAME", "same-check") { Closeable { } })
        val fresh = f.request(); val freshTicket = f.bind(fresh)
        assertTrue(fresh.publish(f.owner, f.source, freshTicket, { true }, "SAME", "same-check") { Closeable { } })
        val freshView = fresh.presentation.value
        assertFalse(old.commit(f.owner, f.source, oldTicket) { f.operations.finish(oldTicket, f.source) })
        assertEquals(CodeJoinRequest.Stage.RETIRED, old.presentation.value.stage); assertNull(old.presentation.value.code)
        assertSame(freshView, fresh.presentation.value); assertFalse(old.cancel())
        val original = f.source; f.source = f.source.copy(epoch = 8)
        assertFalse(fresh.current(f.owner, f.source)); f.source = original
        assertFalse(fresh.current(f.owner, f.source)); assertEquals(CodeJoinRequest.Stage.RETIRED, fresh.presentation.value.stage)
    }
    @Test fun aCancelledOrFailedUnboundRequestCannotEverPublishAnotherRequestsPayload() {
        val f = Fixture(); val cancelled = f.request(); assertTrue(cancelled.cancel())
        assertFalse(cancelled.failUnbound(f.owner, f.source, "Foreign error") { error("Cancelled producer") })
        assertEquals(CodeJoinRequest.Stage.CANCELLED, cancelled.presentation.value.stage); assertNull(cancelled.presentation.value.error)
        val failed = f.request(); assertTrue(failed.failUnbound(f.owner, f.source, "Own validation failure") { })
        assertEquals(CodeJoinRequest.Stage.FAILED, failed.presentation.value.stage); assertNull(failed.presentation.value.code)
        assertNull(failed.allocate(f.owner, f.source) { error("Finished producer") })
    }

}

package dev.yab.android

import dev.yab.sync.CodeJoinRequest
import dev.yab.sync.SyncIdentityLease
import dev.yab.sync.SyncOperationLease
import java.io.Closeable
import org.junit.Assert.*
import org.junit.Test

/** Actual request latch + actual journey; no global code is an owned presentation source. */
class FirstRunRequestPresentationTest {
    private class Pending(val owner: Any, val source: () -> SyncOperationLease.Source) {
        val operations = SyncOperationLease()
        var cancellations = 0
        private val original = source()
        private val creationMarker = operations.marker()
        private var currentSession: Closeable? = null
        val request = CodeJoinRequest(owner, original, { ticket, session, operationRequired ->
            source() == original && (!operationRequired || ticket == null || operations.current(ticket, source()) &&
                (session == null || currentSession === session))
        }, { ticket ->
            if (ticket == null) operations.idleSince(creationMarker)
            else operations.current(ticket, source()) || operations.idleSince(ticket.marker)
        }) { value -> value.cancel(owner, source())?.let { cancellations++; true } ?: false }
        private var ticket: SyncOperationLease.Ticket? = null
        fun publish(code: String = "OWN-CODE", checkValue: String = "own-check") {
            val value = checkNotNull(request.allocate(owner, source()) { operations.begin(source()) })
            ticket = value
            check(request.publish(owner, source(), value, { operations.current(value, source()) }, code, checkValue) { Closeable { }.also { currentSession = it } })
        }
        fun commit() {
            val value = ticket ?: checkNotNull(request.allocate(owner, source()) { operations.begin(source()) }).also { ticket = it }
            check(request.commit(owner, source(), value) { operations.finish(value, source()) })
        }
        fun fail() {
            val value = ticket
            if (value == null) check(request.failUnbound(owner, source(), "Owned failure") { })
            else { commit(); check(request.outcome(owner, value, "Owned failure")) }
        }
    }
    private class Fixture {
        var source = TabletJoinPresentation.Source(null, 7, true)
        var globalCode: String? = null
        var generation = 0
        val nativeOwner = Any()
        val flow = FirstRunPresentation({ source }, { globalCode })
        fun host(): FirstRunPresentation.RenderedHost {
            val original = generation
            return FirstRunPresentation.RenderedHost { generation == original }
        }
        val first = host()
        val requests = mutableListOf<Pending>()
        var success: ((SyncIdentityLease) -> Unit)? = null
        var failure: (() -> Unit)? = null
        var joined = 0
        val start: ((SyncIdentityLease) -> Unit, () -> Unit) -> CodeJoinRequest = { done, failed ->
            success = done; failure = failed
            Pending(nativeOwner) { SyncOperationLease.Source(source.identity?.account, source.identity?.device, source.epoch) }
                .also { requests += it }.request
        }
        init {
            check(flow.begin(flow.control(first)))
            check(flow.advance(checkNotNull(flow.timer(first, false)), FirstRunPresentation.DefaultBrowser(false, false), finish = { false }))
        }
        fun choose(host: FirstRunPresentation.Host = first): Pending {
            check(flow.chooseMacOwnedRequest(flow.control(host), start, joined = { joined++ }))
            return requests.last()
        }
        fun observe(host: FirstRunPresentation.Host = first) {
            val request = flow.state.value.request
            flow.observeRequest(host, request, request?.presentation?.value)
            flow.observe(host)
        }
        fun back(host: FirstRunPresentation.Host = first, control: FirstRunPresentation.Control? = flow.control(host)): Boolean =
            flow.backOwnedRequest(control, flow.state.value.codeValue,
                { error("Owned Back must not cancel a global code") }, start, joined = { joined++ })
    }
    @Test fun replacementPendingNeverDisplaysOrCopiesAForeignGlobalCodeAndOnlyItsOwnPublicationWorks() {
        val f = Fixture(); val a = f.choose(); a.publish("A-CODE", "a-check"); f.observe()
        val oldCopy = f.flow.control(f.first); f.globalCode = "A-CODE"
        assertTrue(f.back()); val b = f.choose(); f.observe()
        assertTrue(f.flow.state.value.ownedRequest); assertNull(f.flow.state.value.codeValue)
        assertNull(f.flow.state.value.checkValue); assertNull(f.flow.state.value.requestError)
        var copies = 0
        assertFalse(f.flow.copyCode(oldCopy, "A-CODE") { copies++ })
        assertFalse(f.flow.copyCode(f.flow.control(f.first), "A-CODE") { copies++ })
        f.flow.observeCode(f.first, f.globalCode); assertNull(f.flow.state.value.codeValue)
        b.publish("B-CODE", "b-check"); f.observe()
        assertEquals("B-CODE", f.flow.state.value.codeValue); assertEquals("b-check", f.flow.state.value.checkValue)
        assertTrue(f.flow.copyCode(f.flow.control(f.first), "B-CODE") { assertEquals("B-CODE", it); copies++ })
        assertEquals(1, copies); assertFalse(a.request.cancel()); assertEquals("B-CODE", f.flow.state.value.codeValue)
    }
    @Test fun freshHostCannotBorrowRequestUntilExplicitObservationThenCancelsOnlyThatSameRequest() {
        val f = Fixture(); val a = f.choose(); a.publish(); f.observe(); val old = f.flow.control(f.first)
        f.generation++; val fresh = f.host()
        assertNull(f.flow.control(fresh)); assertFalse(f.back(fresh)); assertEquals(0, a.cancellations)
        f.observe(fresh); val revision = f.flow.state.value.requestBindingRevision
        f.observe(fresh); assertEquals(revision, f.flow.state.value.requestBindingRevision)
        assertFalse(f.back(f.first, old)); assertTrue(f.back(fresh)); assertEquals(1, a.cancellations)
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
    }
    @Test fun oldHostCopyAndAutomaticJoinedNeverAcquireTheFreshUserBinding() {
        val f = Fixture(); f.choose().publish(); f.observe()
        val old = f.flow.control(f.first); val originalSuccess = checkNotNull(f.success)
        f.generation++; val fresh = f.host(); f.observe(fresh)
        var copies = 0
        assertFalse(f.flow.copyCode(old, "OWN-CODE") { copies++ })
        assertTrue(f.flow.copyCode(f.flow.control(fresh), "OWN-CODE") { copies++ })
        val lease = SyncIdentityLease("actual-account", "actual-device", 8)
        f.source = TabletJoinPresentation.Source(lease, 8, true); originalSuccess(lease)
        assertNotEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step)
        assertEquals(0, f.joined); assertEquals(1, copies)
    }
    @Test fun oldHostAndEqualCodePayloadCannotReviveAnOldBindingOrAnOldRequest() {
        val f = Fixture(); val a = f.choose(); a.publish(); f.observe(); val oldCopy = f.flow.control(f.first)
        f.generation++; val fresh = f.host(); f.observe(fresh)
        f.generation++; val third = f.host(); f.observe(third)
        assertFalse(f.flow.copyCode(oldCopy, "OWN-CODE") { error("Old binding revived") })
        assertNull(f.flow.control(f.first)); assertTrue(f.back(third))
        val b = f.choose(third); b.publish(); f.observe(third)
        assertFalse(f.flow.copyCode(oldCopy, "OWN-CODE") { error("Equal payload revived old request") })
        assertTrue(f.flow.copyCode(f.flow.control(third), "OWN-CODE") { })
        assertFalse(a.request.cancel()); assertEquals(0, b.cancellations)
    }
    @Test fun terminalFailureBeforeAndAfterPublicationAllowsFreshLocalBackWithoutFinishedCancellation() {
        for (published in listOf(false, true)) {
            val f = Fixture(); val a = f.choose(); if (published) a.publish(); a.fail(); f.observe()
            f.generation++; val fresh = f.host(); f.observe(fresh)
            assertEquals("Owned failure", f.flow.state.value.requestError)
            assertTrue(f.back(fresh)); assertEquals(0, a.cancellations)
            assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
        }
    }
    @Test fun committedRequestRefusesFreshCancellationAndBothRecoveryHandoffs() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); val a = f.choose(); a.publish(); f.observe()
            assertTrue(f.flow.useRecovery(f.flow.control(f.first)))
            val input = checkNotNull(f.flow.input(f.first)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
            a.commit(); f.observe(); var submissions = 0
            val restore: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit = { _, _, _ -> submissions++ }
            assertFalse(if (fromInput) f.flow.restoreFromInputRequest(input, "owned recovery", restore)
                else f.flow.restoreRequest(f.flow.control(f.first, true), "owned recovery", restore))
            assertEquals(0, submissions); assertEquals(0, a.cancellations)
            assertTrue(f.back()); assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
            assertFalse(f.back()); assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        }
    }
    @Test fun recoverySnapshotObservationPreservesTypedValueAndItsOriginalInputLifetime() {
        val f = Fixture(); val a = f.choose(); f.observe()
        assertTrue(f.flow.useRecovery(f.flow.control(f.first)))
        val input = checkNotNull(f.flow.input(f.first)); assertTrue(f.flow.editRecovery(input, "retained recovery"))
        val revision = f.flow.state.value.revision; a.publish(); f.observe()
        assertEquals(revision, f.flow.state.value.revision); assertTrue(input.current())
        assertEquals("retained recovery", f.flow.state.value.recovery)
        assertTrue(f.back()); assertEquals(1, f.requests.size); assertEquals(0, a.cancellations)
        assertEquals("OWN-CODE", f.flow.state.value.codeValue)
    }
    @Test fun bothOwnedRecoveryRoutesCancelOriginalThenTerminalRecoveryBackCreatesANewOwnedPendingRequest() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); val a = f.choose(); a.publish(); f.observe()
            assertTrue(f.flow.useRecovery(f.flow.control(f.first)))
            val input = checkNotNull(f.flow.input(f.first)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
            var recoveryFailure: (() -> Unit)? = null
            val restore: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit = { _, _, failed ->
                assertEquals(1, a.cancellations); recoveryFailure = failed
            }
            assertTrue(if (fromInput) f.flow.restoreFromInputRequest(input, "owned recovery", restore)
                else f.flow.restoreRequest(f.flow.control(f.first, true), "owned recovery", restore))
            assertFalse(f.back()); checkNotNull(recoveryFailure)()
            assertTrue(f.back()); assertEquals(2, f.requests.size); f.observe()
            assertTrue(f.flow.state.value.ownedRequest); assertNull(f.flow.state.value.codeValue)
            assertSame(f.requests.last().request, f.flow.state.value.request)
            assertTrue(f.back()); assertEquals(1, f.requests.last().cancellations)
        }
    }
    @Test fun observedSourceLossAndFlowClosePermanentlyRefuseTheirOldRequestControls() {
        val f = Fixture(); f.choose().publish(); f.observe(); val old = f.flow.control(f.first); val original = f.source
        f.source = f.source.copy(epoch = 8); f.observe(); f.source = original
        assertNull(f.flow.control(f.first)); assertFalse(f.flow.copyCode(old, "OWN-CODE") { error("Source ABA") })
        assertEquals(FirstRunPresentation.Step.FINISHED, f.flow.state.value.step)
        val g = Fixture(); g.choose().publish(); g.observe(); val closed = g.flow.control(g.first); g.flow.close()
        assertFalse(g.flow.copyCode(closed, "OWN-CODE") { error("Closed flow") })
    }
    @Test fun originalCurrentCompletionAloneStillAcceptsItsGenuineIdentityAfterRequestCommit() {
        val f = Fixture(); val a = f.choose(); a.publish(); f.observe(); a.commit()
        val lease = SyncIdentityLease("genuine-account", "genuine-device", 8)
        f.source = TabletJoinPresentation.Source(lease, 8, true)
        f.observe() // May observe the real source change before the already queued original completion.
        checkNotNull(f.success)(lease)
        assertEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step); assertEquals(1, f.joined)
    }
    @Test fun terminalFailedOriginalCanSubmitRecoveryOnItsExplicitFreshHostWithoutCancellingFinishedHandle() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); val a = f.choose(); a.fail(); f.observe()
            f.generation++; val fresh = f.host(); f.observe(fresh)
            assertTrue(f.flow.useRecovery(f.flow.control(fresh)))
            val input = checkNotNull(f.flow.input(fresh)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
            var submitted = 0
            val restore: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit = { _, _, _ -> submitted++ }
            assertTrue(if (fromInput) f.flow.restoreFromInputRequest(input, "owned recovery", restore)
                else f.flow.restoreRequest(f.flow.control(fresh, true), "owned recovery", restore))
            assertEquals(1, submitted); assertEquals(0, a.cancellations)
            assertFalse(f.flow.state.value.ownedRequest); assertFalse(f.back(fresh))
        }
    }

    @Test fun stalePublishedCopyRefusesAtActionTimeAfterLegacyTicketReplacementBeforeItsOldCallbackRuns() {
        val f = Fixture(); val a = f.choose(); a.publish(); f.observe(); val oldCopy = f.flow.control(f.first)
        val replacement = a.operations.begin(SyncOperationLease.Source(null, null, 7))
        assertEquals(CodeJoinRequest.Stage.PUBLISHED, a.request.presentation.value.stage)
        var copies = 0
        assertFalse(f.flow.copyCode(oldCopy, "OWN-CODE") { copies++ })
        assertEquals(0, copies); assertEquals(CodeJoinRequest.Stage.RETIRED, a.request.presentation.value.stage)
        assertTrue(a.operations.current(replacement, SyncOperationLease.Source(null, null, 7)))
        f.generation++; val fresh = f.host(); f.observe(fresh)
        assertNull(f.flow.control(fresh)); assertFalse(f.back(fresh)); assertEquals(0, a.cancellations)
    }
    @Test fun retainedRecoveryInputCannotReplaceALegacySuccessorWhileItsOriginalSnapshotStillSaysPublished() {
        val f = Fixture(); val a = f.choose(); a.publish(); f.observe()
        assertTrue(f.flow.useRecovery(f.flow.control(f.first)))
        val input = checkNotNull(f.flow.input(f.first)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
        val replacement = a.operations.begin(SyncOperationLease.Source(null, null, 7)); var submitted = 0
        assertFalse(f.flow.restoreFromInputRequest(input, "owned recovery", { _, _, _ -> submitted++ }))
        assertEquals(0, submitted); assertEquals(0, a.cancellations)
        assertTrue(a.operations.current(replacement, SyncOperationLease.Source(null, null, 7)))
        assertEquals(CodeJoinRequest.Stage.RETIRED, a.request.presentation.value.stage)
    }

    @Test fun terminalFailedRecoveryHandoffRefusesLegacyBeginFinishABAWhileLocalBackStillWorks() {
        val f = Fixture(); val a = f.choose(); a.publish(); a.fail(); f.observe()
        assertTrue(f.flow.useRecovery(f.flow.control(f.first)))
        val input = checkNotNull(f.flow.input(f.first)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
        val replacement = a.operations.begin(SyncOperationLease.Source(null, null, 7))
        assertTrue(a.operations.finish(replacement, SyncOperationLease.Source(null, null, 7)))
        var submitted = 0
        assertFalse(f.flow.restoreFromInputRequest(input, "owned recovery", { _, _, _ -> submitted++ }))
        assertEquals(0, submitted); assertEquals(0, a.cancellations)
        assertEquals(CodeJoinRequest.Stage.FAILED, a.request.presentation.value.stage)
        assertTrue(f.back()); assertTrue(f.back())
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
    }
    @Test fun unallocatedPendingRecoveryHandoffCannotUseItsOldCreationMarkerAfterLegacyBeginFinish() {
        val f = Fixture(); val a = f.choose(); f.observe()
        assertTrue(f.flow.useRecovery(f.flow.control(f.first)))
        val input = checkNotNull(f.flow.input(f.first)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
        val replacement = a.operations.begin(SyncOperationLease.Source(null, null, 7)); var submitted = 0
        assertFalse(f.flow.restoreFromInputRequest(input, "owned recovery", { _, _, _ -> submitted++ }))
        assertTrue(a.operations.finish(replacement, SyncOperationLease.Source(null, null, 7)))
        assertFalse(f.flow.restoreFromInputRequest(input, "owned recovery", { _, _, _ -> submitted++ }))
        assertEquals(0, submitted); assertEquals(0, a.cancellations)
        assertTrue(f.back()); assertTrue(f.back()); assertEquals(1, a.cancellations)
    }

}

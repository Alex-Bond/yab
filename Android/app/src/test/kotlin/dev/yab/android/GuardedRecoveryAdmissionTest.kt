package dev.yab.android

import dev.yab.sync.CodeJoinRequest
import dev.yab.sync.RecoveryHandoff
import dev.yab.sync.SyncIdentityLease
import dev.yab.sync.SyncOperationLease
import java.io.Closeable
import org.junit.Assert.*
import org.junit.Test

/** Actual request/handoff/operation objects and the actual journey, with queued cleanup explicit. */
class GuardedRecoveryAdmissionTest {
    private class Fixture {
        val owner = Any()
        val operations = SyncOperationLease()
        var source = TabletJoinPresentation.Source(null, 7, true)
        fun native() = SyncOperationLease.Source(source.identity?.account, source.identity?.device, source.epoch)
        var closing = false
        var pairing: Closeable? = null
        val cleanups = mutableListOf<() -> Unit>()
        var cancellations = 0
        var starts = 0
        var joined = 0
        var generation = 0
        var beforeCancel: (() -> Unit)? = null
        fun host(): FirstRunPresentation.RenderedHost {
            val original = generation
            return FirstRunPresentation.RenderedHost { generation == original }
        }
        val first = host()
        val flow = FirstRunPresentation({ source }, { null })
        var request: CodeJoinRequest? = null
        var codeTicket: SyncOperationLease.Ticket? = null
        var handoff: RecoveryHandoff? = null
        var automaticSuccess: ((SyncIdentityLease) -> Unit)? = null
        var automaticFailure: (() -> Unit)? = null
        fun token(original: SyncOperationLease.Source, marker: SyncOperationLease.Marker): RecoveryHandoff =
            RecoveryHandoff(owner, original, marker, { value, snapshot -> value.cancel(owner, snapshot) { ticket ->
                !closing && native() == original && (ticket == null || operations.finish(ticket, original))
            } }) { value -> value.retry(owner,
                { expected -> !closing && native() == original && operations.idleSince(expected) },
                { expected -> token(original, expected) }) }
        val startCode: ((SyncIdentityLease) -> Unit, () -> Unit) -> CodeJoinRequest = { _, _ ->
            starts++
            val original = native(); val creation = operations.marker()
            CodeJoinRequest(owner, original, { ticket, session, required ->
                !closing && native() == original && (!required || ticket == null || operations.current(ticket, original) &&
                    (session == null || pairing === session))
            }, { ticket -> if (ticket == null) operations.idleSince(creation)
                else operations.current(ticket, original) || operations.idleSince(ticket.marker)
            }, { value, snapshot -> value.claimRecovery(owner, snapshot) { ticket -> token(original, ticket?.marker ?: creation) }
            }) { value ->
                beforeCancel?.invoke()
                value.cancel(owner, native()) { !closing && native() == original }?.let { cancelled ->
                cancellations++
                cleanups += {
                    cancelled.ticket?.let { operations.finish(it, native()) }
                    if (pairing === cancelled.session) pairing = null
                    cancelled.session?.close()
                }
                true
            } ?: false }.also { request = it }
        }
        val submit: (String, RecoveryHandoff, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit = { text, value, success, failure ->
            assertEquals("owned recovery", text); handoff = value; automaticSuccess = success; automaticFailure = failure
        }
        init {
            check(flow.begin(flow.control(first)))
            check(flow.advance(checkNotNull(flow.timer(first, false)), FirstRunPresentation.DefaultBrowser(false, false), finish = { false }))
        }
        fun choose(publish: Boolean = true) {
            check(flow.chooseMacOwnedRequest(flow.control(first), startCode))
            if (publish) {
                val value = checkNotNull(request); val ticket = checkNotNull(value.allocate(owner, native()) { operations.begin(native()) })
                codeTicket = ticket
                check(value.publish(owner, native(), ticket, { operations.current(ticket, native()) }, "OWN-CODE", "own-check") {
                    Closeable { }.also { pairing = it }
                })
            }
            observe()
            check(flow.useRecovery(flow.control(first)))
            check(flow.editRecovery(checkNotNull(flow.input(first)), "owned recovery"))
        }
        fun restore(fromInput: Boolean = false, host: FirstRunPresentation.Host = first): Boolean =
            if (fromInput) flow.restoreGuardedFromInput(flow.input(host), "owned recovery", submit, { joined++ })
            else flow.restoreGuardedRequest(flow.control(host, true), "owned recovery", submit, { joined++ })
        fun cleanup() { val values = cleanups.toList(); cleanups.clear(); values.forEach { it() } }
        fun admit(value: RecoveryHandoff = checkNotNull(handoff)): SyncOperationLease.Ticket? = value.admit(owner) {
            if (closing || native() != value.source || pairing != null) null else operations.beginIfIdleSince(value.marker, value.source)
        }
        fun commit(ticket: SyncOperationLease.Ticket, value: RecoveryHandoff = checkNotNull(handoff)): Boolean =
            value.commit(owner, ticket) { !closing && native() == value.source && operations.finish(ticket, value.source) }
        fun observe(host: FirstRunPresentation.Host = first) {
            val state = flow.state.value
            flow.observeRequest(host, state.request, state.request?.presentation?.value)
            flow.observeRecovery(host, state.handoff, state.handoff?.presentation?.value)
            flow.observe(host)
        }
        fun back(host: FirstRunPresentation.Host = first, control: FirstRunPresentation.Control? = flow.control(host)): Boolean =
            flow.backGuardedRequest(control, flow.state.value.codeValue, { error("No latest cancellation") }, startCode)
    }
    @Test fun publishedClaimCancelsOnlyOriginalAndAtomicAdmissionWorksOnceAfterItsExactCleanup() {
        val f = Fixture(); f.choose(); val original = checkNotNull(f.request)
        assertTrue(f.restore()); val token = checkNotNull(f.handoff)
        assertEquals(1, f.cancellations); assertFalse(original.cancel())
        f.cleanup(); val ticket = checkNotNull(f.admit())
        assertEquals(RecoveryHandoff.Phase.ADMITTED, token.presentation.value.phase)
        assertTrue(f.operations.current(ticket, f.native()))
        assertNull(f.admit()); assertTrue(f.operations.current(ticket, f.native()))
        assertNull(original.recoveryHandoff(original.presentation.value))
    }
    @Test fun originalFailedCodeClaimsWithoutFinishedCancellationAndRetainsItsOwnFinishedMarker() {
        val f = Fixture(); f.choose(); val request = checkNotNull(f.request); val ticket = checkNotNull(f.codeTicket)
        assertTrue(request.commit(f.owner, f.native(), ticket) { f.operations.finish(ticket, f.native()) })
        assertTrue(request.outcome(f.owner, ticket, "Own failure")); f.pairing = null; f.observe()
        assertTrue(f.restore()); assertEquals(0, f.cancellations)
        val admitted = checkNotNull(f.admit()); assertTrue(f.operations.current(admitted, f.native()))
    }
    @Test fun activeForeignOperationAtDispatchIsNotClosedParsedOrSupersededByTheGuardedAttempt() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        val foreign = f.operations.begin(f.native()); var afterAdmission = 0
        if (f.admit() != null) afterAdmission++
        assertEquals(0, afterAdmission); assertEquals(RecoveryHandoff.Phase.REFUSED, f.handoff!!.presentation.value.phase)
        assertTrue(f.operations.current(foreign, f.native())); assertEquals(1, f.cancellations)
    }
    @Test fun foreignBeginFinishABAAtDispatchRejectsEvenWhenIdleAndCannotReplayWithAFreshMarker() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        val foreign = f.operations.begin(f.native()); assertTrue(f.operations.finish(foreign, f.native()))
        assertNull(f.admit()); assertTrue(f.operations.idleSince(foreign.marker))
        assertNull(f.admit()); assertTrue(f.operations.idleSince(foreign.marker))
        assertEquals(RecoveryHandoff.Phase.REFUSED, f.handoff!!.presentation.value.phase)
    }
    @Test fun unallocatedPendingClaimUsesItsCreationMarkerAndCannotBorrowAForeignFinishedGeneration() {
        val f = Fixture(); f.choose(publish = false); assertTrue(f.restore()); f.cleanup()
        val foreign = f.operations.begin(f.native()); assertTrue(f.operations.finish(foreign, f.native()))
        assertNull(f.admit()); assertEquals(1, f.cancellations); assertTrue(f.operations.idleSince(foreign.marker))
    }
    @Test fun unallocatedOriginalCodeCanEnterGuardedRecoveryBeforeAnyCodePublication() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); f.choose(publish = false); val original = checkNotNull(f.request)
            assertNull(f.codeTicket); assertEquals(CodeJoinRequest.Stage.PENDING, original.presentation.value.stage)
            assertTrue(f.restore(fromInput)); f.cleanup(); val ticket = checkNotNull(f.admit()); f.observe()
            assertEquals(1, f.cancellations); assertTrue(f.operations.current(ticket, f.native()))
            assertNull(original.allocate(f.owner, f.native()) { error("Cancelled original must never allocate") })
            assertNull(f.admit()); assertTrue(f.back()); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
            assertTrue(f.operations.idleSince(ticket.marker)); assertEquals(1, f.starts); assertEquals(0, f.joined)
        }
    }
    @Test fun changedSourceClosingAndForeignOwnerRefuseWithoutInvokingTheAdmissionAllocator() {
        for (reason in 0..2) {
            val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup(); var allocations = 0
            if (reason == 0) f.source = f.source.copy(epoch = 8)
            if (reason == 1) f.closing = true
            val token = checkNotNull(f.handoff)
            val value = token.admit(if (reason == 2) Any() else f.owner) {
                if (f.closing || f.native() != token.source) null
                else { allocations++; f.operations.beginIfIdleSince(token.marker, token.source) }
            }
            assertNull(value); assertEquals(0, allocations)
            assertEquals(RecoveryHandoff.Phase.REFUSED, token.presentation.value.phase); assertNull(f.admit())
        }
    }
    @Test fun aCodeCommitWinnerAndAStaleOriginalSnapshotCannotIssueAnyHandoff() {
        val f = Fixture(); f.choose(); val request = checkNotNull(f.request); val old = request.presentation.value
        val ticket = checkNotNull(f.codeTicket)
        assertTrue(request.commit(f.owner, f.native(), ticket) { f.operations.finish(ticket, f.native()) })
        assertNull(request.recoveryHandoff(old)); f.observe(); assertFalse(f.restore()); assertEquals(0, f.cancellations)
    }
    @Test fun buttonAndReturnRefusalOfferLocalChooseWithoutAnyCodeRestartOrForeignCancellation() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); f.choose(); val oldInput = f.flow.input(f.first)
            assertTrue(f.restore(fromInput)); assertFalse(f.flow.restoreGuardedFromInput(oldInput, "owned recovery", f.submit))
            f.cleanup(); val foreign = f.operations.begin(f.native()); assertNull(f.admit()); f.observe()
            assertEquals("owned recovery", f.flow.state.value.recovery)
            assertTrue(f.back()); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
            assertEquals(1, f.starts); assertEquals(1, f.cancellations); assertTrue(f.operations.current(foreign, f.native()))
            assertEquals(0, f.joined)
        }
    }
    @Test fun freshHostNeedsExplicitRefusalObservationAndOnlyItsLocalBackCanAct() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        f.operations.begin(f.native()); assertNull(f.admit()); f.observe(); val old = f.flow.control(f.first)
        f.generation++; val fresh = f.host(); assertNull(f.flow.control(fresh)); assertFalse(f.back(fresh))
        f.observe(fresh); assertFalse(f.back(f.first, old)); assertTrue(f.back(fresh))
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step); assertEquals(1, f.starts)
        f.automaticFailure!!(); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
        assertEquals(0, f.joined)
    }
    @Test fun committedRecoveryRefusesCancellationAndPresentationAloneNeverDeclaresJoined() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup(); val ticket = checkNotNull(f.admit())
        assertTrue(f.commit(ticket)); f.observe()
        assertFalse(f.back()); assertFalse(f.restore()); assertEquals(1, f.cancellations)
        assertTrue(f.operations.idleSince(ticket.marker))
        assertTrue(f.handoff!!.outcome(f.owner, ticket)); f.observe()
        assertEquals(FirstRunPresentation.Step.RECOVERY, f.flow.state.value.step); assertEquals(0, f.joined)
        val lease = SyncIdentityLease("actual-account", "actual-device", 8)
        f.source = TabletJoinPresentation.Source(lease, 8, true); f.observe(); f.automaticSuccess!!(lease)
        assertEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step); assertEquals(1, f.joined)
    }
    @Test fun originalAdmittedFailureRetriesOnceFromItsOwnFinishedMarkerAndNeverFromANewerIdleGeneration() {
        for (foreignABA in listOf(false, true)) {
            val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
            val first = checkNotNull(f.handoff); val ticket = checkNotNull(f.admit())
            assertTrue(f.commit(ticket)); assertTrue(first.outcome(f.owner, ticket, "Own error"))
            f.automaticFailure!!(); f.observe()
            if (foreignABA) {
                val foreign = f.operations.begin(f.native()); assertTrue(f.operations.finish(foreign, f.native()))
                assertFalse(f.restore()); f.observe(); assertEquals(RecoveryHandoff.Phase.REFUSED, first.presentation.value.phase)
                assertTrue(f.back()); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
                assertEquals(1, f.starts); assertTrue(f.operations.idleSince(foreign.marker))
            } else {
                assertTrue(f.restore()); val retry = checkNotNull(f.handoff); assertNotSame(first, retry)
                assertNull(first.retry()); assertNotNull(f.admit()); assertEquals(1, f.starts)
            }
        }
    }
    @Test fun hostLossNeverMovesAutomaticRecoveryCompletionOrRetryAuthorityToTheFreshUserBinding() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup(); val ticket = checkNotNull(f.admit())
        assertTrue(f.commit(ticket)); assertTrue(f.handoff!!.outcome(f.owner, ticket, "Own error"))
        f.generation++; val fresh = f.host(); f.observe(fresh)
        assertFalse(f.restore(host = fresh)); assertTrue(f.back(fresh)); assertEquals(1, f.starts)
        val lease = SyncIdentityLease("late-account", "late-device", 8)
        f.source = TabletJoinPresentation.Source(lease, 8, true); f.automaticSuccess!!(lease)
        assertNotEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step); assertEquals(0, f.joined)
    }
    @Test fun atomicIdleAdmissionAndOneUseTokenCannotAllocateTwoOperationsOnConcurrentDispatch() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        val ready = java.util.concurrent.CountDownLatch(2)
        val go = java.util.concurrent.CountDownLatch(1)
        val executor = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val results = (0 until 2).map { executor.submit<SyncOperationLease.Ticket?> {
                ready.countDown(); check(go.await(5, java.util.concurrent.TimeUnit.SECONDS)); f.admit()
            } }
            assertTrue(ready.await(5, java.util.concurrent.TimeUnit.SECONDS)); go.countDown()
            val admitted = results.mapNotNull { it.get(5, java.util.concurrent.TimeUnit.SECONDS) }
            assertEquals(1, admitted.size); assertTrue(f.operations.current(admitted.single(), f.native()))
            assertEquals(RecoveryHandoff.Phase.ADMITTED, f.handoff!!.presentation.value.phase)
        } finally { go.countDown(); executor.shutdownNow() }
    }

    @Test fun immediateFailedCodeHandoffRefusalIsTypedLocalAndBackNeverRestartsOverAnActiveForeignJoin() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); f.choose(); val request = checkNotNull(f.request); val original = checkNotNull(f.codeTicket)
            assertTrue(request.commit(f.owner, f.native(), original) { f.operations.finish(original, f.native()) })
            assertTrue(request.outcome(f.owner, original, "Own failure")); f.pairing = null; f.observe()
            val foreign = f.operations.begin(f.native())
            assertTrue(f.restore(fromInput)); val refusal = checkNotNull(f.handoff)
            assertEquals(RecoveryHandoff.Phase.REFUSED, refusal.presentation.value.phase)
            assertNull(f.admit()); f.observe()
            assertTrue(f.back()); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
            assertEquals(1, f.starts); assertEquals(0, f.cancellations)
            assertTrue(f.operations.current(foreign, f.native())); assertEquals(0, f.joined)
        }
    }

    @Test fun replacementBetweenHandoffCheckAndOriginalCancellationStillProducesOnlyLocalRefusal() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); f.choose(); var foreign: SyncOperationLease.Ticket? = null
            f.beforeCancel = { foreign = f.operations.begin(f.native()) }
            assertTrue(f.restore(fromInput)); val refusal = checkNotNull(f.handoff)
            assertEquals(RecoveryHandoff.Phase.REFUSED, refusal.presentation.value.phase)
            assertEquals("Sync unavailable", refusal.presentation.value.error)
            assertNull(f.admit()); f.observe(); assertTrue(f.back())
            assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
            assertEquals(1, f.starts); assertEquals(0, f.cancellations); assertTrue(f.cleanups.isEmpty())
            assertTrue(f.operations.current(checkNotNull(foreign), f.native())); assertEquals(0, f.joined)
        }
    }

    @Test fun distinctOriginalTokensSharingOneMarkerCannotBothPassAtomicIdleAdmission() {
        val f = Fixture(); val marker = f.operations.marker()
        val tokens = List(2) { f.token(f.native(), marker) }
        val ready = java.util.concurrent.CountDownLatch(2); val go = java.util.concurrent.CountDownLatch(1)
        val executor = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val results = tokens.map { token -> executor.submit<SyncOperationLease.Ticket?> {
                ready.countDown(); check(go.await(5, java.util.concurrent.TimeUnit.SECONDS))
                token.admit(f.owner) { f.operations.beginIfIdleSince(token.marker, token.source) }
            } }
            assertTrue(ready.await(5, java.util.concurrent.TimeUnit.SECONDS)); go.countDown()
            val admitted = results.mapNotNull { it.get(5, java.util.concurrent.TimeUnit.SECONDS) }
            assertEquals(1, admitted.size); assertTrue(f.operations.current(admitted.single(), f.native()))
            assertEquals(1, tokens.count { it.presentation.value.phase == RecoveryHandoff.Phase.ADMITTED })
            assertEquals(1, tokens.count { it.presentation.value.phase == RecoveryHandoff.Phase.REFUSED })
        } finally { go.countDown(); executor.shutdownNow() }
    }

    @Test fun queuedRecoveryCancelConsumesOnlyItsOriginalTokenAndNeverAllocatesOrRestartsCode() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); f.choose(); assertTrue(f.restore(fromInput)); val token = checkNotNull(f.handoff)
            f.observe(); val old = f.flow.control(f.first)
            assertTrue(f.back()); assertEquals(RecoveryHandoff.Phase.CANCELLED, token.presentation.value.phase)
            assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
            f.cleanup(); var allocations = 0
            assertNull(token.admit(f.owner) { allocations++; f.operations.begin(f.native()) })
            assertEquals(0, allocations); assertFalse(token.cancel(token.presentation.value))
            assertFalse(f.back(control = old)); assertEquals(1, f.starts); assertEquals(0, f.joined)
        }
    }

    @Test fun admittedCancelExcludesEveryReleasedSuccessErrorAndAutomaticCompletionEffect() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        val token = checkNotNull(f.handoff); val ticket = checkNotNull(f.admit()); f.observe()
        assertTrue(f.back()); assertEquals(RecoveryHandoff.Phase.CANCELLED, token.presentation.value.phase)
        var durable = 0; var errors = 0
        if (f.commit(ticket)) durable++
        if (token.committed(f.owner, ticket) || f.commit(ticket))
            if (token.outcome(f.owner, ticket, "Late error")) errors++
        assertEquals(0, durable); assertEquals(0, errors); assertFalse(token.outcome(f.owner, ticket))
        assertTrue(f.operations.idleSince(ticket.marker)); assertFalse(token.refuse(f.owner, ticket))
        f.automaticFailure!!(); val lease = SyncIdentityLease("late", "device", 8)
        f.source = TabletJoinPresentation.Source(lease, 8, true); f.automaticSuccess!!(lease)
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step); assertEquals(0, f.joined)
    }

    @Test fun committedOriginalRejectsBothSavedAndFreshCancelBeforeItsDurableWork() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        val token = checkNotNull(f.handoff); val ticket = checkNotNull(f.admit()); f.observe()
        val pending = token.presentation.value; val old = f.flow.control(f.first)
        assertTrue(f.commit(ticket)); var durable = 0
        assertFalse(token.cancel(pending)); assertFalse(token.cancel(token.presentation.value))
        assertFalse(f.back(control = old)); f.observe(); assertFalse(f.back())
        if (token.committed(f.owner, ticket)) durable++
        assertEquals(1, durable); assertTrue(token.outcome(f.owner, ticket)); assertFalse(token.outcome(f.owner, ticket))
        assertEquals(RecoveryHandoff.Phase.COMPLETE, token.presentation.value.phase)
    }

    @Test fun wrongOwnerAndCopiedSnapshotCannotFinishTheOriginalOrBorrowItsCancellation() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        val token = checkNotNull(f.handoff); val ticket = checkNotNull(f.admit()); val snapshot = token.presentation.value
        assertFalse(token.cancel(Any(), snapshot) { error("Foreign owner must never run cancellation") })
        assertFalse(token.cancel(snapshot.copy())); assertSame(snapshot, token.presentation.value)
        assertTrue(f.operations.current(ticket, f.native())); assertTrue(token.cancel(snapshot))
        val foreign = f.operations.begin(f.native())
        assertFalse(token.cancel(snapshot)); assertTrue(f.operations.current(foreign, f.native()))
    }

    @Test fun queuedSourceOrClosingLossRefusesPermanentlyWithoutAbaAdmission() {
        for (closing in listOf(false, true)) {
            val f = Fixture(); f.choose(); assertTrue(f.restore()); val token = checkNotNull(f.handoff)
            val original = f.source; val snapshot = token.presentation.value
            if (closing) f.closing = true else f.source = f.source.copy(epoch = 8)
            assertFalse(token.cancel(snapshot)); assertEquals(RecoveryHandoff.Phase.REFUSED, token.presentation.value.phase)
            f.closing = false; f.source = original; f.cleanup()
            assertNull(token.admit(f.owner) { error("Refused original must not revive") })
            assertFalse(token.cancel(snapshot)); assertEquals(0, f.joined)
        }
    }

    @Test fun replacedAdmittedTicketOnlyRefusesLocallyEvenAfterForeignBeginFinishAba() {
        for (finished in listOf(false, true)) {
            val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
            val token = checkNotNull(f.handoff); checkNotNull(f.admit()); val snapshot = token.presentation.value
            val foreign = f.operations.begin(f.native())
            if (finished) assertTrue(f.operations.finish(foreign, f.native()))
            assertFalse(token.cancel(snapshot)); assertEquals(RecoveryHandoff.Phase.REFUSED, token.presentation.value.phase)
            if (finished) assertTrue(f.operations.idleSince(foreign.marker)) else assertTrue(f.operations.current(foreign, f.native()))
            f.observe(); assertTrue(f.back()); assertEquals(1, f.starts)
            assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
        }
    }

    @Test fun freshHostNeedsExplicitObservationToCancelSameTokenAndNeverOwnsAutomaticJoined() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup(); val ticket = checkNotNull(f.admit()); f.observe()
        val old = f.flow.control(f.first); f.generation++; val fresh = f.host()
        assertNull(f.flow.control(fresh)); assertFalse(f.back(fresh))
        f.observe(fresh); assertFalse(f.back(f.first, old)); assertTrue(f.back(fresh))
        assertTrue(f.operations.idleSince(ticket.marker)); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
        val lease = SyncIdentityLease("late", "account", 8); f.source = TabletJoinPresentation.Source(lease, 8, true)
        f.automaticSuccess!!(lease); assertEquals(0, f.joined)
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
    }

    @Test fun terminalGuardedFailureBackNeverStartsCodeOverAnUnrelatedOperation() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup(); val ticket = checkNotNull(f.admit())
        assertTrue(f.commit(ticket)); assertTrue(f.handoff!!.outcome(f.owner, ticket, "Own failure"))
        f.automaticFailure!!(); f.observe(); val foreign = f.operations.begin(f.native())
        assertTrue(f.back()); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
        assertEquals(1, f.starts); assertTrue(f.operations.current(foreign, f.native()))
    }

    @Test fun postCommitFailureFinishesOnlyItsOwnDataAndCannotPublishAfterSourceOrMarkerLoss() {
        for (boundary in 0..2) {
            val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
            val token = checkNotNull(f.handoff); val ticket = checkNotNull(f.admit())
            assertTrue(f.commit(ticket)); val original = f.native()
            if (boundary == 1) f.source = f.source.copy(epoch = 8)
            if (boundary == 2) { val foreign = f.operations.begin(f.native()); assertTrue(f.operations.finish(foreign, f.native())) }
            var duplicateFinish = 0; var published = 0
            if (token.committed(f.owner, ticket) || token.commit(f.owner, ticket) { duplicateFinish++; true }) {
                if (token.outcome(f.owner, ticket, "Own post-commit failure") && f.native() == original && f.operations.idleSince(ticket.marker)) published++
            }
            assertEquals(0, duplicateFinish); assertEquals(if (boundary == 0) 1 else 0, published)
            assertEquals(RecoveryHandoff.Phase.FAILED, token.presentation.value.phase)
            assertFalse(token.cancel(token.presentation.value)); assertFalse(token.outcome(f.owner, ticket, "Duplicate"))
        }
    }

    @Test fun committedSourceObservationKeepsOnlyTheOriginalAutomaticCompletionWindow() {
        for (replaceHost in listOf(false, true)) {
            val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup(); val ticket = checkNotNull(f.admit())
            assertTrue(f.commit(ticket)); val lease = SyncIdentityLease("joined", "device", 8)
            f.source = TabletJoinPresentation.Source(lease, 8, true)
            if (replaceHost) f.generation++
            f.observe(if (replaceHost) f.host() else f.first)
            assertTrue(f.handoff!!.outcome(f.owner, ticket)); f.automaticSuccess!!(lease); f.automaticSuccess!!(lease)
            assertEquals(if (replaceHost) 0 else 1, f.joined)
            assertEquals(!replaceHost, f.flow.state.value.step == FirstRunPresentation.Step.JOINED)
        }
    }

    @Test fun partialSourceFailureClosesItsOriginalJourneyWithoutNeedingASuppressedObserver() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        val token = checkNotNull(f.handoff); val ticket = checkNotNull(f.admit())
        assertTrue(f.commit(ticket)); f.source = TabletJoinPresentation.Source(SyncIdentityLease("partial", "saved", 8), 8, true)
        val foreign = f.operations.begin(f.native()); assertTrue(f.operations.finish(foreign, f.native()))
        assertFalse(f.operations.idleSince(ticket.marker)); assertTrue(f.operations.idleSince(foreign.marker))
        assertTrue(token.outcome(f.owner, ticket, "Own failed attach"))
        f.observe(); assertEquals(FirstRunPresentation.Step.FINISHED, f.flow.state.value.step)
        assertEquals(0, f.joined); assertNull(f.flow.control(f.first)); assertFalse(token.cancel(token.presentation.value))
        f.automaticFailure!!(); assertEquals(FirstRunPresentation.Step.FINISHED, f.flow.state.value.step)
    }

    @Test fun cancellationAndCommitCompeteOnceWithoutHoldingDurableWorkInsideTheirLatch() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup()
        val token = checkNotNull(f.handoff); val ticket = checkNotNull(f.admit()); val snapshot = token.presentation.value
        val ready = java.util.concurrent.CountDownLatch(2); val go = java.util.concurrent.CountDownLatch(1)
        val executor = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val cancel = executor.submit<Boolean> { ready.countDown(); check(go.await(5, java.util.concurrent.TimeUnit.SECONDS)); token.cancel(snapshot) }
            val commit = executor.submit<Boolean> { ready.countDown(); check(go.await(5, java.util.concurrent.TimeUnit.SECONDS)); f.commit(ticket) }
            assertTrue(ready.await(5, java.util.concurrent.TimeUnit.SECONDS)); go.countDown()
            val cancelled = cancel.get(5, java.util.concurrent.TimeUnit.SECONDS); val committed = commit.get(5, java.util.concurrent.TimeUnit.SECONDS)
            assertTrue(cancelled.xor(committed)); assertTrue(f.operations.idleSince(ticket.marker))
            assertEquals(if (cancelled) RecoveryHandoff.Phase.CANCELLED else RecoveryHandoff.Phase.COMMITTED, token.presentation.value.phase)
            assertEquals(committed, token.outcome(f.owner, ticket)); assertFalse(token.cancel(snapshot))
        } finally { go.countDown(); executor.shutdownNow() }
    }

    @Test fun queuedSnapshotCancelCannotBorrowAnAdmissionThatWinsItsOwnDispatcherRace() {
        val f = Fixture(); f.choose(); assertTrue(f.restore()); f.cleanup(); val token = checkNotNull(f.handoff)
        val snapshot = token.presentation.value; val ticket = checkNotNull(f.admit())
        assertFalse(token.cancel(snapshot)); assertTrue(f.operations.current(ticket, f.native()))
        assertTrue(token.cancel(token.presentation.value)); assertTrue(f.operations.idleSince(ticket.marker))
    }

}

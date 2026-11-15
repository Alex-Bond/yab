package dev.yab.android

import dev.yab.sync.SyncIdentityLease
import org.junit.Assert.*
import org.junit.Test

class FirstRunPendingCodeTest {
    private class Fixture {
        var hostCurrent = true
        var code: String? = null
        val host = FirstRunPresentation.RenderedHost { hostCurrent }
        var source = TabletJoinPresentation.Source(null, 7, true)
        val flow = FirstRunPresentation({ source }, { code })
        var success: ((SyncIdentityLease) -> Unit)? = null
        var failure: (() -> Unit)? = null
        var cancellations = 0
        var starts = 0
        var cancelAccepted = true
        var joined = 0
        val start: ((SyncIdentityLease) -> Unit, () -> Unit) -> (() -> Boolean) = { done, failed ->
            starts++
            success = done; failure = failed
            var spent = false
            val cancel: () -> Boolean = { if (cancelAccepted && !spent) { cancellations++; spent = true; true } else false }
            cancel
        }
        init {
            check(flow.begin(flow.control(host)))
            check(flow.advance(checkNotNull(flow.timer(host, false)), FirstRunPresentation.DefaultBrowser(false, false), finish = { false }))
        }
        fun choose() = flow.chooseMacRequest(flow.control(host), start, joined = { joined++ })
        fun back(control: FirstRunPresentation.Control? = flow.control(host)) = flow.backRequest(control, code,
            cancel = { error("Owned request must not cancel by a visible latest code") }, restartCode = start)
    }
    @Test fun originalPendingCodeCancelReturnsChooseAndRefusesLateCompletionAndReplay() {
        val f = Fixture(); assertTrue(f.choose()); val old = f.flow.control(f.host)
        assertTrue(f.back(old)); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
        assertEquals(1, f.cancellations); assertFalse(f.back(old))
        f.success!!(SyncIdentityLease("late", "late-device", 8)); f.failure!!()
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step); assertEquals(0, f.joined)
    }
    @Test fun stoppedOriginalActivityCannotCancelItsRequestOrUseItsOldControlAfterReturn() {
        val f = Fixture(); assertTrue(f.choose()); val old = f.flow.control(f.host)
        f.hostCurrent = false; assertFalse(f.back(old)); f.hostCurrent = true
        assertFalse(f.back(old)); assertEquals(0, f.cancellations)
    }
    @Test fun aNewRequestCancelsItsOwnHandleEvenWhileAnOldGlobalCodeIsStillVisible() {
        val f = Fixture(); assertTrue(f.choose()); assertTrue(f.back())
        f.cancelAccepted = true; f.code = "OLD-CODE"; assertTrue(f.choose())
        f.flow.observeCode(f.host, f.code)
        assertTrue(f.back()); assertEquals(2, f.cancellations)
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
    }
    @Test fun anInFlightSuccessfulCommitRefusesCancelButAnOriginalTerminalFailureCanStillBack() {
        val f = Fixture(); assertTrue(f.choose()); f.cancelAccepted = false
        assertFalse(f.back()); assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        f.failure!!()
        assertTrue(f.back()); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
        assertEquals(0, f.cancellations)
    }
    @Test fun aSavedControlCannotBorrowANewlyPublishedCodeToCancelEvenItsOwnRequest() {
        val f = Fixture(); assertTrue(f.choose()); val old = f.flow.control(f.host)
        f.code = "FRESH-CODE"; f.flow.observeCode(f.host, f.code)
        assertFalse(f.back(old)); assertEquals(0, f.cancellations)
        assertTrue(f.back()); assertEquals(1, f.cancellations)
    }
    @Test fun aFreshHostControlCannotBorrowTheOldAttemptsRequestBeforePassiveObservation() {
        val f = Fixture(); assertTrue(f.choose())
        f.hostCurrent = false
        val freshHost = FirstRunPresentation.RenderedHost { true }
        val freshControl = f.flow.control(freshHost)
        assertNotNull(freshControl)
        assertFalse(f.flow.backRequest(freshControl, null, { error("No cancel latest") }, f.start))
        assertEquals(0, f.cancellations)
        assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
    }
    @Test fun recoveryBackRetainsTheSamePendingCodeRequestWithoutStartingAnother() {
        val f = Fixture(); assertTrue(f.choose()); assertTrue(f.flow.useRecovery(f.flow.control(f.host)))
        assertTrue(f.back()); assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        assertEquals(1, f.starts); assertEquals(0, f.cancellations)
        assertTrue(f.back()); assertEquals(1, f.cancellations)
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
    }
    @Test fun buttonAndReturnCancelOnlyTheirOriginalCodeBeforeStartingGenuineRecovery() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); assertTrue(f.choose()); assertTrue(f.flow.useRecovery(f.flow.control(f.host)))
            val input = checkNotNull(f.flow.input(f.host)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
            var submitted = 0; var done: ((SyncIdentityLease) -> Unit)? = null
            val restore: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit = { text, success, _ ->
                assertEquals("owned recovery", text); assertEquals(1, f.cancellations); submitted++; done = success
            }
            val accepted = if (fromInput) f.flow.restoreFromInputRequest(input, "owned recovery", restore)
                else f.flow.restoreRequest(f.flow.control(f.host, recoveryValue = true), "owned recovery", restore)
            assertTrue(accepted); assertEquals(1, submitted)
            assertFalse(f.back()); assertEquals(1, f.starts); assertEquals(FirstRunPresentation.Step.RECOVERY, f.flow.state.value.step)
            val lease = SyncIdentityLease("recovered", "device", 8)
            f.source = TabletJoinPresentation.Source(lease, 8, true); checkNotNull(done)(lease)
            assertEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step)
        }
    }
    @Test fun aCodeCommitThatAlreadyWonRefusesBothRecoverySubmissionRoutes() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); assertTrue(f.choose()); assertTrue(f.flow.useRecovery(f.flow.control(f.host)))
            val input = checkNotNull(f.flow.input(f.host)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
            f.cancelAccepted = false; var submitted = 0
            val restore: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit = { _, _, _ -> submitted++ }
            val accepted = if (fromInput) f.flow.restoreFromInputRequest(input, "owned recovery", restore)
                else f.flow.restoreRequest(f.flow.control(f.host, recoveryValue = true), "owned recovery", restore)
            assertFalse(accepted); assertEquals(0, submitted); assertEquals(0, f.cancellations)
            assertEquals(FirstRunPresentation.Step.RECOVERY, f.flow.state.value.step)
        }
    }
    @Test fun anOriginalTerminalHealthFailureStillPermitsButtonAndReturnRecovery() {
        for (fromInput in listOf(false, true)) {
            val f = Fixture(); assertTrue(f.choose()); f.cancelAccepted = false; f.failure!!()
            assertTrue(f.flow.useRecovery(f.flow.control(f.host)))
            val input = checkNotNull(f.flow.input(f.host)); assertTrue(f.flow.editRecovery(input, "owned recovery"))
            var submitted = 0
            val restore: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit = { _, _, _ -> submitted++ }
            assertTrue(if (fromInput) f.flow.restoreFromInputRequest(input, "owned recovery", restore)
                else f.flow.restoreRequest(f.flow.control(f.host, recoveryValue = true), "owned recovery", restore))
            assertEquals(1, submitted); assertEquals(0, f.cancellations)
        }
    }
}

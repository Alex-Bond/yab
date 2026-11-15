package dev.yab.android

import dev.yab.sync.SyncIdentityLease
import dev.yab.sync.SyncUiState
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

/** Actual immutable status-reference and original UI journey ownership, not backend qualification. */
class FirstRunJourneySourceTest {
    private class Fixture(saved: Boolean = true) {
        var native = TabletJoinPresentation.Source(if (saved) SyncIdentityLease("saved", "device", 4) else null, 4, true)
        val ui = MutableStateFlow(SyncUiState(if (saved) "live" else "off", native.identity?.account))
        var entry = true
        val originalUi = ui.value
        val source = FirstRunJourneySource(native, originalUi, { native }, { ui.value }, { entry })
        val host = FirstRunPresentation.RenderedHost { true }
        val role = FirstRunPresentation.DefaultBrowser(true, false)
        fun flow(): FirstRunPresentation {
            return checkNotNull(source.create { "owned-code" })
        }
        fun found(): FirstRunPresentation {
            val flow = flow(); assertTrue(flow.begin(flow.control(host)))
            assertTrue(flow.advance(checkNotNull(flow.timer(host, false)), role, finish = { false }))
            assertEquals(FirstRunPresentation.Step.FOUND, flow.state.value.step)
            assertTrue(flow.joinSaved(flow.control(host), FirstRunPresentation.FoundCounts(8, 1, 2)))
            return flow
        }
        fun tick(flow: FirstRunPresentation): Boolean = flow.advance(checkNotNull(flow.timer(host, false)), role, finish = { false })
    }
    @Test fun sameTurnLiveWaitingLiveHasANewActualStateFlowObjectAndCannotReviveASavedJourney() {
        val f = Fixture(); assertTrue(f.source.initialCurrent())
        f.ui.value = f.ui.value.copy(phase = "waiting")
        f.ui.value = f.ui.value.copy(phase = "live")
        assertEquals(f.originalUi, f.ui.value); assertNotSame(f.originalUi, f.ui.value)
        assertFalse(f.source.current().available)
        f.ui.value = f.originalUi
        assertFalse(f.source.current().available); assertFalse(f.source.initialCurrent())
        val fresh = FirstRunJourneySource(f.native, f.ui.value, { f.native }, { f.ui.value }, { true })
        assertTrue(fresh.initialCurrent()); assertTrue(fresh.current().available)
    }
    @Test fun losingLiveBeforeTheEighthSavedCountCannotProduceJoinedOrSuccessHaptics() {
        val f = Fixture(); val flow = f.found()
        repeat(7) { assertTrue(f.tick(flow)) }
        val eighth = checkNotNull(flow.timer(f.host, false))
        f.ui.value = f.ui.value.copy(phase = "waiting"); f.entry = false
        var joined = 0
        assertFalse(flow.advance(eighth, f.role, finish = { false }, savedJoined = { joined++ }))
        assertEquals(0, joined); assertEquals(7, flow.state.value.countTick)
        assertNotEquals(FirstRunPresentation.Step.JOINED, flow.state.value.step)
        flow.observe(f.host); assertEquals(FirstRunPresentation.Step.FINISHED, flow.state.value.step)
    }
    @Test fun aCoalescedStatusAbaAlsoRefusesTheOriginalJoinedContinuationBeforeLinksOrFinish() {
        val f = Fixture(); val flow = f.found(); repeat(8) { assertTrue(f.tick(flow)) }
        assertEquals(FirstRunPresentation.Step.JOINED, flow.state.value.step)
        val continuation = checkNotNull(flow.timer(f.host, false))
        f.ui.value = f.ui.value.copy(phase = "waiting"); f.ui.value = f.ui.value.copy(phase = "live")
        var finishes = 0
        assertFalse(flow.advance(continuation, f.role, finish = { finishes++; true }))
        assertEquals(0, finishes); assertNull(flow.control(f.host)); assertFalse(f.source.current().available)
    }
    @Test fun anUnchangedOriginalLiveStatusCanFinishAllEightSavedCountTicks() {
        val f = Fixture(); val flow = f.found(); var joined = 0
        repeat(8) {
            assertTrue(flow.advance(checkNotNull(flow.timer(f.host, false)), f.role, finish = { false }, savedJoined = { joined++ }))
        }
        assertEquals(1, joined); assertEquals(8, flow.state.value.countTick)
        assertEquals(FirstRunPresentation.Step.JOINED, flow.state.value.step)
        assertTrue(f.source.current().available)
    }
    @Test fun theOriginalUnpairedJourneyStillAcceptsItsOwnGenuineCompletionBeforeLive() {
        val f = Fixture(saved = false); val flow = f.flow()
        assertTrue(flow.begin(flow.control(f.host)))
        assertTrue(flow.advance(checkNotNull(flow.timer(f.host, false)), f.role, finish = { false }))
        var complete: ((SyncIdentityLease) -> Unit)? = null
        assertTrue(flow.chooseMac(flow.control(f.host), start = { done, _ -> complete = done }))
        val joined = SyncIdentityLease("actual-new", "new-device", 5)
        f.native = TabletJoinPresentation.Source(joined, 5, true)
        f.ui.value = SyncUiState("connecting", joined.account); f.entry = false
        assertEquals(f.native, f.source.current())
        checkNotNull(complete)(joined)
        assertEquals(FirstRunPresentation.Step.JOINED, flow.state.value.step)
    }
    @Test fun initialCaptureCannotBorrowAReplacementNativeSourceOrLiveStatus() {
        val native = Fixture(); native.native = native.native.copy(identity = SyncIdentityLease("other", "device", 5), epoch = 5)
        assertFalse(native.source.initialCurrent()); assertFalse(native.source.current().available)
        val status = Fixture(); status.ui.value = status.ui.value.copy(phase = "waiting")
        status.ui.value = status.ui.value.copy(phase = "live")
        assertFalse(status.source.initialCurrent()); assertFalse(status.source.current().available)
        val unavailable = Fixture(); unavailable.entry = false
        assertFalse(unavailable.source.initialCurrent()); unavailable.entry = true
        assertFalse(unavailable.source.initialCurrent())
    }
    @Test fun aSourceLostDuringTheActualConstructorIsClosedAndNeverReturnedForAssignment() {
        val native = TabletJoinPresentation.Source(SyncIdentityLease("saved", "device", 4), 4, true)
        val ui = MutableStateFlow(SyncUiState("live", "saved")); val originalUi = ui.value
        var nativeReads = 0
        val source = FirstRunJourneySource(native, originalUi, native = {
            nativeReads++
            // Initial admission reads twice. The third read is the model's actual bound-source constructor.
            if (nativeReads == 3) ui.value = ui.value.copy(phase = "waiting")
            native
        }, ui = { ui.value }, entryAvailable = { ui.value.phase == "live" })
        val assigned = source.create { null }
        assertNull(assigned); assertFalse(source.current().available)
        ui.value = originalUi
        assertNull(source.create { null }); assertFalse(source.current().available)
    }

}

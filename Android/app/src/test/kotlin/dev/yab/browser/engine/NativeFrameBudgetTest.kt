package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

class NativeFrameBudgetTest {
    private class Cell(var value: Any?) : WeakFrameReference<Any> { override fun get() = value }
    private class Fixture {
        val cells = mutableListOf<Cell>()
        val budget = NativeFrameBudget<Any> { Cell(it).also(cells::add) }
    }
    @Test fun pagerAndHistoryTogetherNeverReserveAThirdLogicalFrameIncludingPendingNativeWork() {
        val f = Fixture(); val pager = f.budget.reserve()!!; assertTrue(pager.startNative())
        val history = f.budget.reserve()!!; assertTrue(history.startNative())
        assertNull(f.budget.reserve()); assertEquals(32L * 1024 * 1024, f.budget.reservedBytes)
        pager.revoke(); history.revoke()
        assertNull(f.budget.reserve()) // Cancellation does not mean native work stopped.
        pager.unpublishedFinished(); assertNotNull(f.budget.reserve())
    }
    @Test fun ownerCloseCannotAuthorizeAThirdBitmapWhileTheRendererStillRetainsItsPixels() {
        val f = Fixture()
        val a = f.budget.reserve()!!.apply { startNative() }.publish(Any())!!
        val b = f.budget.reserve()!!.apply { startNative() }.publish(Any())!!
        a.close(); b.close(); assertNull(f.budget.reserve())
        // Deterministic weak-reference seam models real GC reachability, without forced GC.
        f.cells[0].value = null
        assertNotNull(f.budget.reserve()); assertEquals(2, f.budget.slots)
    }
    @Test fun ownerRevocationMakesEveryPublishedProjectionNullButKeepsUnfinishedNativeReservation() {
        val f = Fixture(); val pending = f.budget.reserve()!!.apply { startNative() }
        val ready = f.budget.reserve()!!.apply { startNative() }.publish(Any())!!
        assertNotNull(ready.valueIfCurrent())
        f.budget.revokeAll()
        assertNull(ready.valueIfCurrent()); assertNull(pending.publish(Any())); assertEquals(2, f.budget.slots)
        pending.unpublishedFinished(); assertEquals(1, f.budget.slots)
        f.cells.single().value = null; f.budget.collectReleased(); assertEquals(0, f.budget.slots)
    }
    @Test fun failedOrNotStartedReservationIsReleasedExactlyWithoutInvalidatingOtherFrames() {
        val f = Fixture(); val ready = f.budget.reserve()!!.apply { startNative() }.publish(Any())!!
        val notStarted = f.budget.reserve()!!; notStarted.revoke()
        assertEquals(1, f.budget.slots); assertNotNull(ready.valueIfCurrent())
        val failure = f.budget.reserve()!!.apply { startNative() }
        failure.unpublishedFinished(); assertEquals(1, f.budget.slots)
        assertNotNull(ready.valueIfCurrent())
    }
}

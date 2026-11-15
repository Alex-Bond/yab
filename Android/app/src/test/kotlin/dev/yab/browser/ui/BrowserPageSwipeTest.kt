package dev.yab.browser.ui

import org.junit.Assert.*
import org.junit.Test

class BrowserPageSwipeTest {
    private fun drain(model: BrowserPageSwipeModel): List<BrowserPageSwipeModel.Event> = buildList {
        repeat(600) { model.frame(1.0 / 120)?.let(::add) }
        assertFalse("Spring did not settle", model.moving)
    }

    @Test fun projectedThrowUsesPhoneBoundaryAndNeverWrapsAtFirstPage() {
        assertEquals(0, BrowserPageSwipeMath.destination(-150.0, true, true))
        assertEquals(1, BrowserPageSwipeMath.destination(-150.0, true, false))
        assertEquals(0, BrowserPageSwipeMath.destination(150.0, true, true))
        assertEquals(-1, BrowserPageSwipeMath.destination(150.01, true, true))
        val edge = BrowserPageSwipeModel(402.0, false, true)
        edge.down(); edge.move(600.0)
        assertTrue(edge.offset in 0.0..70.0)
        assertEquals(1, edge.edgeTicks)
        edge.up(600.0, 4_000.0)
        assertEquals(listOf(BrowserPageSwipeModel.Event.Settled(0)), drain(edge))
        val thrown = BrowserPageSwipeModel(402.0, true, true)
        thrown.down(); thrown.move(-40.0); thrown.up(-40.0, -600.0)
        assertEquals(listOf(BrowserPageSwipeModel.Event.Settled(1)), drain(thrown))
    }

    @Test fun catchMovingPagePreservesPoseAndCancellationCannotCommitPastThreshold() {
        val model = BrowserPageSwipeModel(402.0, true, true)
        model.down(); model.move(-170.0); model.up(-170.0, -1_000.0)
        repeat(4) { model.frame(1.0 / 120) }
        val caught = model.offset
        assertTrue(model.down())
        assertEquals(caught, model.offset, 0.0)
        model.move(25.0)
        assertEquals(caught + 25, model.offset, 1e-9)
        model.cancel()
        assertEquals(listOf(BrowserPageSwipeModel.Event.Settled(0)), drain(model))
        assertEquals(0.0, model.offset, 0.0)
    }

    @Test fun newTabOpensAtVisibleLandingAndDismissalReturnsWithoutEmptyTab() {
        val model = BrowserPageSwipeModel(402.0, true, false)
        model.down(); model.move(-700.0)
        assertTrue(model.offset < -model.slot && model.offset > -model.slot - 40)
        model.up(-700.0, 0.0)
        var blank: BrowserPageSwipeModel.Event? = null
        repeat(600) { if (blank == null) blank = model.frame(1.0 / 120) }
        assertEquals(BrowserPageSwipeModel.Event.Blank, blank)
        assertTrue(model.blank && model.active)
        assertTrue(model.offset <= -model.slot + 3)
        assertFalse(model.down())
        model.leaveBlank()
        assertEquals(listOf(BrowserPageSwipeModel.Event.Settled(0)), drain(model))
    }

    @Test fun revokedOrNonfiniteGestureCannotProduceSelectionOrBlank() {
        val model = BrowserPageSwipeModel(402.0, true, false)
        model.down(); model.move(-250.0)
        model.up(Double.NaN, Double.POSITIVE_INFINITY)
        assertEquals(listOf(BrowserPageSwipeModel.Event.Settled(0)), drain(model))
        val revoked = BrowserPageSwipeModel(402.0, true, false)
        revoked.down(); revoked.move(-250.0); revoked.up(-250.0, -500.0); revoked.revoke()
        assertTrue(drain(revoked).isEmpty())
        assertFalse(revoked.blank)
    }

    @Test fun reducedMotionLandsWithoutSlidingAndCancellationStillReturns() {
        val model = BrowserPageSwipeModel(402.0, true, false)
        model.down(); model.move(-160.0)
        assertEquals(BrowserPageSwipeModel.Event.Blank, model.up(-160.0, 0.0, reduced = true))
        assertEquals(-model.slot, model.offset, 0.0)
        assertFalse(model.moving)
        assertEquals(BrowserPageSwipeModel.Event.Settled(0), model.leaveBlank(reduced = true))
        assertEquals(0.0, model.offset, 0.0)
    }
}

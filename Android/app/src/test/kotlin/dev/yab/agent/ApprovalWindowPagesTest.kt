package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ApprovalWindowPagesTest {
    private val owner = ApprovalPresentationKey("account", 1, "mac", "question", "shown-facts", 1)
    private fun window(index: Int = 0) = ApprovalWindowPages().apply {
        open(owner, 3, index); measure(owner, index, 400.0, 600.0, 1600.0)
    }
    private fun settle(pages: ApprovalWindowPages) { repeat(360) { pages.advance(1.0 / 120) } }

    @Test fun aShortFlickPagesAndAQuarterWidthPullCommitsWithoutFakingAnotherMail() {
        val pages = window()
        pages.begin(owner); assertEquals(ApprovalWindowGesture.PAGE, pages.drag(owner, -20.0, 1.0))
        assertFalse(pages.end(owner, -501.0, 0.0)); assertEquals(1, pages.frame.value.selected)
        settle(pages); assertEquals(1.0, pages.frame.value.page, 0.0); assertEquals(0.0, pages.frame.value.scroll, 0.0)
        pages.begin(owner); pages.drag(owner, -104.0, 0.0); pages.end(owner, 0.0, 0.0)
        assertEquals(2, pages.frame.value.selected); settle(pages)
        pages.begin(owner); pages.drag(owner, -200.0, 0.0); pages.end(owner, -900.0, 0.0)
        settle(pages); assertEquals(2.0, pages.frame.value.page, 0.0)
    }
    @Test fun pageEndsRubberAndCancellationReturnsToTheOriginalMessage() {
        val pages = window()
        pages.begin(owner); pages.drag(owner, 100.0, 0.0)
        assertEquals(-ApprovalDetailGeometry.rubber(100.0, 120.0) / 400.0, pages.frame.value.page, 1e-12)
        pages.end(owner, 900.0, 0.0, cancelled = true); settle(pages)
        assertEquals(0.0, pages.frame.value.page, 0.0)
        pages.begin(owner); pages.drag(owner, -200.0, 0.0); pages.end(owner, -900.0, 0.0, cancelled = true)
        settle(pages); assertEquals(0.0, pages.frame.value.page, 0.0)
    }
    @Test fun wordsCoastWithinTheirMeasuredPageAndPullOnlyStartsAtTheTop() {
        val pages = window()
        pages.begin(owner); assertEquals(ApprovalWindowGesture.SCROLL, pages.drag(owner, 0.0, -100.0))
        assertEquals(100.0, pages.frame.value.scroll, 0.0)
        pages.end(owner, 0.0, -500.0); settle(pages)
        assertEquals(260.0, pages.frame.value.scroll, 0.0)
        pages.begin(owner); assertEquals(ApprovalWindowGesture.SCROLL, pages.drag(owner, 0.0, 20.0))
        assertFalse(pages.end(owner, 0.0, 50.0))
        pages.goTo(owner, 1); settle(pages)
        pages.begin(owner); assertEquals(ApprovalWindowGesture.PULL, pages.drag(owner, 0.0, 20.0))
        assertTrue(pages.end(owner, 0.0, 50.0))
    }
    @Test fun onlyTheCurrentPageCanMeasureItsScrollBoundsAndRetiredOwnersCannotDriveIt() {
        val pages = window(1)
        pages.measure(owner, 0, 400.0, 600.0, 20_000.0)
        pages.begin(owner); pages.drag(owner, 0.0, -5000.0); pages.end(owner, 0.0, -1000.0); settle(pages)
        assertEquals(1000.0, pages.frame.value.scroll, 0.0)
        val old = owner
        val next = owner.copy(epoch = 2)
        pages.reconcile(next); pages.open(next, 2, 0)
        pages.goTo(old, 1); pages.begin(old); assertNull(pages.drag(old, -300.0, 0.0))
        assertFalse(pages.end(old, -900.0, 0.0)); settle(pages)
        assertEquals(0.0, pages.frame.value.page, 0.0)
    }
    @Test fun measuredAnchorsAreScopedAndStaleDisposalCannotRemoveAReplacementFrame() {
        val anchors = ApprovalDetailAnchors(); anchors.reconcile(owner)
        val row = ApprovalRect(16.0, 500.0, 360.0, 64.0)
        anchors.put(owner, "row", row)
        anchors.put(owner, "row", row.copy(y = 490.0)); anchors.remove(owner, "row", row)
        assertEquals(490.0, anchors.frames.value.getValue("row").y, 0.0)
        anchors.put(owner, "bad", row.copy(width = Double.NaN)); assertFalse("bad" in anchors.frames.value)
        anchors.reconcile(owner.copy(facts = "changed"))
        anchors.put(owner, "row", row); assertTrue(anchors.frames.value.isEmpty())
    }

    @Test fun originalPageAndScrollCancellationUsesOnlyItsActiveTokenWithoutCommitting() {
        val pages = window()
        val page = checkNotNull(pages.begin(owner))
        pages.drag(owner, -200.0, 0.0, expected = page)
        assertTrue(pages.cancel(page)); assertFalse(pages.cancel(page))
        assertEquals(0, pages.frame.value.selected); settle(pages)
        assertEquals(0.0, pages.frame.value.page, 0.0)
        val scroll = checkNotNull(pages.begin(owner))
        pages.drag(owner, 0.0, -100.0, expected = scroll)
        assertEquals(ApprovalWindowGesture.SCROLL, pages.frame.value.gesture)
        assertTrue(pages.cancel(scroll)); assertNull(pages.frame.value.gesture)
        settle(pages); assertEquals(100.0, pages.frame.value.scroll, 0.0)
    }

    @Test fun sameOwnerRegrabPageSelectionAndResetRefuseOldCancelDragAndEnd() {
        val pages = window()
        val old = checkNotNull(pages.begin(owner)); pages.drag(owner, -120.0, 0.0, expected = old)
        val fresh = checkNotNull(pages.begin(owner)); pages.drag(owner, -40.0, 0.0, expected = fresh)
        val held = pages.frame.value
        assertFalse(pages.cancel(old))
        assertNull(pages.drag(owner, -1000.0, 0.0, expected = old))
        assertFalse(pages.end(owner, -900.0, 0.0, expected = old))
        assertEquals(held, pages.frame.value); assertTrue(pages.gestureCurrent(fresh))
        assertTrue(pages.cancel(fresh)); assertFalse(pages.gestureCurrent(fresh))
        val selected = checkNotNull(pages.begin(owner)); pages.goTo(owner, 2)
        assertFalse(pages.cancel(selected)); assertEquals(2, pages.frame.value.selected)
        val reset = checkNotNull(pages.begin(owner)); pages.open(owner, 3, 0)
        assertFalse(pages.cancel(reset)); assertEquals(0, pages.frame.value.selected)
        val revoked = checkNotNull(pages.begin(owner)); pages.reconcile(owner.copy(epoch = 2))
        assertFalse(pages.cancel(revoked))
    }
}

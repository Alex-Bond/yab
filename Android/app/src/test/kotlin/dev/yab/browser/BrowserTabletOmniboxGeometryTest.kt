package dev.yab.browser

import dev.yab.browser.model.*
import org.junit.Assert.*
import org.junit.Test

class BrowserTabletOmniboxGeometryTest {
    private fun viewport(window: BrowserWorkspaceWindow = BrowserWorkspaceWindow(1024.0, 1024.0),
        root: TabletOmniboxRoot = TabletOmniboxRoot(0.0, 0.0, window.width, window.height), keyboard: Double = 0.0) =
        TabletOmniboxViewport(window, root, 24.0, keyboard)

    @Test fun devicePolicyAndActualFullWindowBothRequiredIncludingSevenHundredBoundary() {
        for (size in listOf(BrowserWorkspaceWindow(411.0, 844.0), BrowserWorkspaceWindow(626.0, 900.0),
            BrowserWorkspaceWindow(1024.0, 699.999), BrowserWorkspaceWindow(Double.NaN, 900.0)))
            assertFalse(BrowserTabletOmniboxGeometry.eligible(size, 800))
        assertFalse(BrowserTabletOmniboxGeometry.eligible(BrowserWorkspaceWindow(1024.0, 768.0), 599))
        assertTrue(BrowserTabletOmniboxGeometry.eligible(BrowserWorkspaceWindow(700.0, 1024.0), 600))
        assertTrue(BrowserTabletOmniboxGeometry.eligible(BrowserWorkspaceWindow(1024.0, 700.0), 600))
    }

    @Test fun sourceTopKeepsNearestAwayHalfCasesOnEachBranchAndShortSpaceFloor() {
        // Phone .rounded(): 62.5 ->63, 112.5 ->113, 166.5 ->167.
        assertEquals(63.0, BrowserTabletOmniboxGeometry.top(600.0), 0.0)
        assertEquals(113.0, BrowserTabletOmniboxGeometry.top(700.0), 0.0)
        assertEquals(167.0, BrowserTabletOmniboxGeometry.top(925.0), 0.0)
        assertEquals(16.0, BrowserTabletOmniboxGeometry.top(475.0), 0.0)
        assertEquals(16.0, BrowserTabletOmniboxGeometry.top(0.0), 0.0)
    }

    @Test fun sourceWidthHeaderAndFiveRowsUseFullWindowInsteadOfFocusedPane() {
        val frame = BrowserTabletOmniboxGeometry.frame(viewport(BrowserWorkspaceWindow(1024.0, 768.0)),
            resting = false, rows = 8, answer = false, showsAddress = false, textScale = 1.0)
        assertEquals(242.0, frame.x, 0.0); assertEquals(187.0, frame.y, 0.0)
        assertEquals(540.0, frame.width, 0.0); assertEquals(52.0, frame.headerHeight, 0.0)
        assertEquals(212.0, frame.bodyHeight, 0.0); assertEquals(264.0, frame.height, 0.0)
        val narrow = BrowserTabletOmniboxGeometry.frame(viewport(BrowserWorkspaceWindow(560.0, 900.0)),
            false, 1, false, false, 1.0)
        assertEquals(528.0, narrow.width, 0.0); assertEquals(16.0, narrow.x, 0.0)
    }

    @Test fun adjustedRootAndActualWindowImeIntersectionDoNotSubtractKeyboardTwice() {
        val full = viewport(keyboard = 300.0)
        val resized = viewport(root = TabletOmniboxRoot(0.0, 0.0, 1024.0, 724.0), keyboard = 300.0)
        val offset = viewport(root = TabletOmniboxRoot(20.0, 30.0, 1004.0, 694.0), keyboard = 300.0)
        val a = BrowserTabletOmniboxGeometry.frame(full, false, 5, false, false, 1.0)
        val b = BrowserTabletOmniboxGeometry.frame(resized, false, 5, false, false, 1.0)
        val c = BrowserTabletOmniboxGeometry.frame(offset, false, 5, false, false, 1.0)
        assertEquals(a, b)
        assertEquals(a.x, c.x + 20.0, 0.0); assertEquals(a.y, c.y + 30.0, 0.0)
        assertEquals(300.0, BrowserTabletOmniboxGeometry.keyboardOverlap(full), 0.0)
        assertEquals(0.0, BrowserTabletOmniboxGeometry.keyboardOverlap(resized), 0.0)
        assertEquals(a.bodyHeight, c.bodyHeight, 0.0)
    }

    @Test fun selectedAddressEmptyAndAnswerCapsAreIndependentOfExistingWordRowDomain() {
        val v = viewport()
        assertEquals(0.0, BrowserTabletOmniboxGeometry.frame(v, false, 5, true, true, 1.0).bodyHeight, 0.0)
        assertEquals(0.0, BrowserTabletOmniboxGeometry.frame(v, false, 0, false, false, 1.0).bodyHeight, 0.0)
        assertEquals(212.0, BrowserTabletOmniboxGeometry.frame(v, false, 9, true, false, 1.0).bodyHeight, 0.0)
        assertEquals(52.0, BrowserTabletOmniboxGeometry.frame(v, false, 0, true, false, 1.0).bodyHeight, 0.0)
    }

    @Test fun largeTypeAndKeyboardBoundTheBodyToActualRootWhileRestKeepsSourceTop() {
        val v = viewport(keyboard = 750.0)
        val limited = BrowserTabletOmniboxGeometry.frame(v, false, 5, true, false, 2.0)
        assertEquals(80.0, limited.rowHeight, 0.0); assertEquals(110.0, limited.bodyHeight, 0.0)
        assertTrue(limited.y + limited.height + 16.0 <= 274.0)
        val resting = BrowserTabletOmniboxGeometry.frame(viewport(keyboard = 300.0), true, 5, false, false, 1.0)
        val noKeyboard = BrowserTabletOmniboxGeometry.frame(viewport(), true, 5, false, false, 1.0)
        assertEquals(noKeyboard, resting)
        val clipped = BrowserTabletOmniboxGeometry.frame(viewport(root = TabletOmniboxRoot(0.0, 0.0, 1024.0, 100.0)),
            false, 5, true, false, 1.0)
        assertEquals(0.0, clipped.bodyHeight, 0.0)
    }
}

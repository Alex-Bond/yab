package dev.yab.browser

import dev.yab.browser.model.*
import org.junit.Assert.*
import org.junit.Test

/** Phone 0.1.13 layout vectors. Native admission always remains the actual original window. */
class BrowserTabletWorkspaceGeometryTest {
    @Test fun deviceAndSevenHundredBoundaryRemainIndependentOfDrawing() {
        assertFalse(BrowserTabletWorkspaceGeometry.eligible(BrowserWorkspaceWindow(1024.0, 768.0), 599))
        assertFalse(BrowserTabletWorkspaceGeometry.eligible(BrowserWorkspaceWindow(699.999, 1024.0), 600))
        assertTrue(BrowserTabletWorkspaceGeometry.eligible(BrowserWorkspaceWindow(700.0, 1024.0), 600))
        val portrait = BrowserTabletWorkspaceGeometry.frame(BrowserWorkspaceWindow(700.0, 1024.0), 24.0, paired = true)
        assertFalse(portrait.drawnSplit); assertTrue(portrait.paired)
    }
    @Test fun iPadPortraitMatchesTheCurrentSidebarToolbarAndDocument() {
        val window = BrowserWorkspaceWindow(1032.0, 1376.0)
        val frame = BrowserTabletWorkspaceGeometry.frame(window, 24.0)
        assertSame(window, frame.originalWindow)
        assertEquals(TabletWorkspaceRect(0.0, 24.0, 1032.0, 44.0), frame.toolbar)
        assertEquals(TabletWorkspaceRect(0.0, 68.0, 264.0, 1308.0), frame.sidebar)
        assertEquals(TabletWorkspaceRect(272.0, 76.0, 752.0, 1292.0), frame.page)
        assertEquals(10.0, frame.pageCornerRadius, 0.0)
        assertNull(frame.divider)
    }
    @Test fun localFramePreferenceDoesNotChangeTheOriginalWindowOrHiddenPage() {
        val window = BrowserWorkspaceWindow(1280.0, 800.0)
        val framed = BrowserTabletWorkspaceGeometry.frame(window, 24.0)
        val plain = BrowserTabletWorkspaceGeometry.frame(window, 24.0, framed = false)
        assertEquals(TabletWorkspaceRect(272.0, 76.0, 1000.0, 716.0), framed.page)
        assertEquals(TabletWorkspaceRect(264.0, 68.0, 1016.0, 732.0), plain.page)
        assertEquals(framed.sidebar, plain.sidebar)
        assertEquals(0.0, plain.pageCornerRadius, 0.0)
        val hidden = BrowserTabletWorkspaceGeometry.frame(window, 24.0, sidebarShown = false)
        assertEquals(hidden, BrowserTabletWorkspaceGeometry.frame(window, 24.0, sidebarShown = false, framed = false))
        assertEquals(TabletWorkspaceRect(0.0, 68.0, 1280.0, 732.0), hidden.page)
        assertSame(window, hidden.originalWindow)
    }
    @Test fun aLandscapePairHidesSidebarBeforeItWouldSqueezeEitherDocument() {
        val window = BrowserWorkspaceWindow(900.0, 768.0)
        val frame = BrowserTabletWorkspaceGeometry.frame(window, 24.0, paired = true)
        assertTrue(frame.fullWindowCanSplit); assertTrue(frame.drawnSplit)
        assertNull(frame.sidebar); assertEquals(0.0, frame.rim, 0.0)
        assertEquals(TabletWorkspaceRect(0.0, 68.0, 900.0, 700.0), frame.page)
        assertEquals(446.0, frame.pane(false).width, 0.0)
        assertEquals(8.0, frame.divider!!.width, 0.0)
        assertSame(window, frame.pageLayout.window)
    }
    @Test fun rootLandscapeSurvivesATallInsetPage() {
        val frame = BrowserTabletWorkspaceGeometry.frame(BrowserWorkspaceWindow(960.0, 900.0), 24.0, paired = true)
        assertNotNull(frame.sidebar)
        assertEquals(680.0, frame.page.width, 0.0)
        assertEquals(816.0, frame.page.height, 0.0)
        assertTrue(frame.pageLayout.horizontal); assertTrue(frame.drawnSplit)
        assertEquals(336.0, frame.pane(false).width, 0.0)
    }
    @Test fun smallestSplitKeepsBothMinimumWidthsAndTheWholeGap() {
        val frame = BrowserTabletWorkspaceGeometry.frame(BrowserWorkspaceWindow(648.0, 600.0), 24.0, sidebarShown = false, paired = true)
        assertTrue(frame.drawnSplit)
        assertEquals(320.0, frame.pane(false).width, 0.0)
        assertEquals(320.0, frame.pane(true).width, 0.0)
        assertEquals(328.0, frame.pane(true).x, 0.0)
        val narrow = BrowserTabletWorkspaceGeometry.frame(BrowserWorkspaceWindow(647.9, 600.0), 24.0, sidebarShown = false, paired = true)
        assertFalse(narrow.drawnSplit); assertTrue(narrow.paired)
    }
    @Test fun resizedSplitClampsBothDocumentsAndPreservesFractionalRootCoordinates() {
        val frame = BrowserTabletWorkspaceGeometry.frame(BrowserWorkspaceWindow(1366.5, 1024.25), 24.5, paired = true, splitFraction = .65)
        assertEquals(TabletWorkspaceRect(272.0, 76.5, 1086.5, 939.75), frame.page)
        assertEquals(701.025, frame.pane(false).width, .000001)
        assertEquals(377.475, frame.pane(true).width, .000001)
        assertEquals(frame.page.x + frame.page.width, frame.pane(true).let { it.x + it.width }, .000001)
        val tiny = frame.copy(splitFraction = .01)
        assertEquals(320.0, tiny.pane(false).width, .000001)
        val huge = frame.copy(splitFraction = .99)
        assertEquals(320.0, huge.pane(true).width, .000001)
        assertEquals(.5, frame.copy(splitFraction = Double.NaN).effectiveSplitFraction, 0.0)
    }
    @Test fun sidebarExtentIsLocalClampedAndCannotInventASplit() {
        val window = BrowserWorkspaceWindow(1280.0, 800.0)
        assertEquals(220.0, BrowserTabletWorkspaceGeometry.frame(window, 24.0, sidebarExtent = 1.0).sidebar!!.width, 0.0)
        assertEquals(360.0, BrowserTabletWorkspaceGeometry.frame(window, 24.0, sidebarExtent = 900.0).sidebar!!.width, 0.0)
        val frame = BrowserTabletWorkspaceGeometry.frame(window, 24.0)
        assertFalse(frame.paired); assertFalse(frame.drawnSplit)
        assertEquals(frame.page, frame.pane(true)); assertNull(frame.divider)
    }
    @Test fun nonfiniteOriginalBoundsAndNegativeStatusAreRejected() {
        val valid = BrowserWorkspaceWindow(1024.0, 768.0)
        for (window in listOf(valid.copy(width = Double.NaN), valid.copy(height = Double.POSITIVE_INFINITY), valid.copy(width = 0.0))) {
            assertFalse(BrowserTabletWorkspaceGeometry.eligible(window, 600))
            assertThrows(IllegalArgumentException::class.java) { BrowserTabletWorkspaceGeometry.frame(window, 24.0) }
        }
        for (status in listOf(-1.0, Double.NaN, Double.POSITIVE_INFINITY))
            assertThrows(IllegalArgumentException::class.java) { BrowserTabletWorkspaceGeometry.frame(valid, status) }
    }
}

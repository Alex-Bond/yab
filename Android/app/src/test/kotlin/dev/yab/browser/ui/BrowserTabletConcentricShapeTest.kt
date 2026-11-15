package dev.yab.browser.ui

import dev.yab.browser.model.*
import org.junit.Assert.*
import org.junit.Test

class BrowserTabletConcentricShapeTest {
    @Test fun equalEightPointInsetsPreserveTheActualSharedCenterRatherThanSubtractingDiagonalDistance() {
        val child = TabletWorkspaceRect(8.0, 8.0, 984.0, 784.0)
        val result = TabletConcentricGeometry.resolve(child, 10.0,
            TabletCornerCircle(48.0, 48.0, 48.0), TabletCornerCircle(48.0, 952.0, 48.0),
            TabletCornerCircle(48.0, 952.0, 752.0), TabletCornerCircle(48.0, 48.0, 752.0))
        assertEquals(TabletCornerRadii(40.0, 40.0, 40.0, 40.0), result)
        assertEquals(48.0, child.x + result.topLeft, 0.0)
        assertEquals(752.0, child.y + child.height - result.bottomLeft, 0.0)
    }

    @Test fun actualSidebarPageKeepsFixedTopTenAndOnlyAdjacentBottomCornerFollowsItsWindow() {
        val original = BrowserWorkspaceWindow(1280.0, 800.0)
        val frame = BrowserTabletWorkspaceGeometry.frame(original, 24.0, paired = true)
        val result = TabletConcentricGeometry.page(frame,
            TabletCornerCircle(48.0, 48.0, 752.0), TabletCornerCircle(48.0, 1232.0, 752.0))
        assertEquals(TabletCornerRadii(10.0, 10.0, 40.0, 10.0), result)
        assertSame(original, frame.originalWindow)
        assertEquals(TabletWorkspaceRect(272.0, 76.0, 1000.0, 716.0), frame.page)
        assertTrue(frame.fullWindowCanSplit); assertTrue(frame.drawnSplit)
        assertEquals(frame.page.width, frame.pane(false).width + 8 + frame.pane(true).width, 0.0)
    }

    @Test fun frameOffAndSidebarHiddenUseZeroMinimumWithoutDiscardingRealBottomWindowCorners() {
        val window = BrowserWorkspaceWindow(1280.0, 800.0)
        val left = TabletCornerCircle(48.0, 48.0, 752.0); val right = TabletCornerCircle(48.0, 1232.0, 752.0)
        val unframed = BrowserTabletWorkspaceGeometry.frame(window, 24.0, framed = false)
        assertEquals(TabletCornerRadii(0.0, 0.0, 48.0, 0.0), TabletConcentricGeometry.page(unframed, left, right))
        val hidden = BrowserTabletWorkspaceGeometry.frame(window, 24.0, sidebarShown = false)
        assertEquals(TabletCornerRadii(0.0, 0.0, 48.0, 48.0), TabletConcentricGeometry.page(hidden, left, right))
        assertEquals(TabletCornerRadii(0.0, 0.0, 0.0, 0.0), TabletConcentricGeometry.page(hidden, null, null))
        val framed = BrowserTabletWorkspaceGeometry.frame(window, 24.0)
        assertEquals(TabletCornerRadii(10.0, 10.0, 10.0, 10.0), TabletConcentricGeometry.page(framed, null, null))
    }

    @Test fun asymmetricAndOffAxisCircularFallbackIsBoundedAndDoesNotBorrowAnotherCorner() {
        val child = TabletWorkspaceRect(8.0, 8.0, 984.0, 784.0)
        val result = TabletConcentricGeometry.resolve(child, 10.0,
            bottomLeft = TabletCornerCircle(64.0, 64.0, 736.0), bottomRight = TabletCornerCircle(32.0, 968.0, 768.0))
        assertEquals(56.0, result.bottomLeft, 0.0); assertEquals(24.0, result.bottomRight, 0.0)
        val shifted = child.copy(x = 28.0, width = 964.0)
        assertEquals(36.0, TabletConcentricGeometry.resolve(shifted, 10.0,
            bottomLeft = TabletCornerCircle(64.0, 64.0, 736.0)).bottomLeft, 0.0)
        assertEquals(10.0, TabletConcentricGeometry.resolve(shifted.copy(x = 100.0), 10.0,
            bottomLeft = TabletCornerCircle(64.0, 64.0, 736.0)).bottomLeft, 0.0)
    }

    @Test fun localSitePlatesResolveAgainstTheirActualThirtyTwoPointContainerAndKeepDistantCornersAtMinimum() {
        val container = TabletWorkspaceRect(400.0, 80.0, 280.0, 280.0)
        val first = TabletWorkspaceRect(408.0, 88.0, 64.0, 44.0)
        assertEquals(TabletCornerRadii(24.0, 12.0, 12.0, 12.0), TabletConcentricGeometry.inContainer(first, container, 12.0))
        val distant = first.copy(y = 180.0)
        assertEquals(TabletCornerRadii(12.0, 12.0, 12.0, 12.0), TabletConcentricGeometry.inContainer(distant, container, 12.0))
        val small = TabletWorkspaceRect(620.0, 180.0, 28.0, 28.0)
        assertEquals(TabletCornerRadii(8.0, 8.0, 8.0, 8.0), TabletConcentricGeometry.inContainer(small, container, 8.0))
    }

    @Test fun densityConvertsActualWindowPixelsExactlyOnceBeforeResolvingTheChildInWindowPoints() {
        val fromPixels = checkNotNull(TabletCornerCircle.pixels(96, 1904, 1504, 2f))
        assertEquals(TabletCornerCircle(48.0, 952.0, 752.0), fromPixels)
        val child = TabletWorkspaceRect(8.0, 8.0, 984.0, 784.0)
        val result = TabletConcentricGeometry.resolve(child, 10.0, bottomRight = fromPixels)
        assertEquals(TabletCornerRadii(10.0, 10.0, 40.0, 10.0), result)
        assertEquals(fromPixels.x, child.x + child.width - result.bottomRight, 0.0)
        assertEquals(fromPixels.y, child.y + child.height - result.bottomRight, 0.0)
    }

    @Test fun smallContentNormalizationAndInvalidGeometryNeverCreateOverlappingOrNonfiniteArcs() {
        assertEquals(TabletCornerRadii(22.0, 22.0, 22.0, 22.0), TabletCornerRadii(32.0, 32.0, 32.0, 32.0).fitted(280.0, 44.0))
        assertNull(TabletCornerCircle.pixels(48, 48, 752, Float.NaN))
        assertNull(TabletCornerCircle.pixels(48, 48, 752, 0f)); assertNull(TabletCornerCircle.pixels(0, 0, 0, 1f))
        assertThrows(IllegalArgumentException::class.java) { TabletConcentricGeometry.resolve(TabletWorkspaceRect(0.0, 0.0, Double.NaN, 44.0), 10.0) }
        assertThrows(IllegalArgumentException::class.java) { TabletConcentricGeometry.resolve(TabletWorkspaceRect(Double.MAX_VALUE, 0.0, Double.MAX_VALUE, 44.0), 10.0) }
        assertThrows(IllegalArgumentException::class.java) { TabletCornerRadii(-1.0, 10.0, 10.0, 10.0).fitted(100.0, 100.0) }
    }

    @Test fun replacingActualContainerOrDensityDropsBoundsAndLateOldLayoutCannotPopulateItsSuccessor() {
        val owner = TabletConcentricBounds(); val source = Any()
        val first = checkNotNull(owner.bind(source, 1f))
        val before = TabletWorkspaceRect(408.0, 88.0, 64.0, 44.0)
        assertTrue(first.positioned(before)); assertEquals(before, first.bounds)
        assertSame(first, owner.bind(source, 1f))
        val resized = checkNotNull(owner.bind(Any(), 1f))
        assertNull(first.bounds); assertNull(resized.bounds)
        assertFalse(first.positioned(before.copy(y = 180.0))); assertNull(resized.bounds)
        assertTrue(resized.positioned(before.copy(y = 100.0)))
        val denser = checkNotNull(owner.bind(resized.source, 2f))
        assertNull(resized.bounds); assertNull(denser.bounds)
        assertFalse(resized.positioned(before)); assertTrue(denser.positioned(before))
        assertNull(owner.bind(null, 2f)); assertNull(denser.bounds)
        val returned = checkNotNull(owner.bind(source, 1f))
        assertNotSame(first, returned); assertNull(returned.bounds)
        assertFalse(first.positioned(before)); assertTrue(returned.positioned(before))
        assertEquals(before, returned.bounds)
    }
}

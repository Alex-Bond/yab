package dev.yab.browser

import dev.yab.browser.ui.BrowserSpaceRowSwipeGeometry
import org.junit.Assert.*
import org.junit.Test

class BrowserSpaceRowSwipeGeometryTest {
    @Test fun edgesAlwaysBelongToThePager() {
        for (x in listOf(0f, 16f, 28f, 374f, 402f)) assertFalse(BrowserSpaceRowSwipeGeometry.owns(x, 402f))
        assertTrue(BrowserSpaceRowSwipeGeometry.owns(29f, 402f))
        assertTrue(BrowserSpaceRowSwipeGeometry.owns(201f, 402f))
        assertTrue(BrowserSpaceRowSwipeGeometry.owns(373f, 402f))
    }
}

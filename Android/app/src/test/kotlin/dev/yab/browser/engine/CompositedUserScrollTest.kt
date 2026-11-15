package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

class CompositedUserScrollTest {
    @Test fun cssCoordinatesUseActualZoomAndDisplayDensityRatherThanAssumingOneCssPixelIsOnePoint() {
        assertEquals(80f, compositedUserScroll(80f, 3f, 3f, true)!!, 0f)
        assertEquals(120f, compositedUserScroll(80f, 4.5f, 3f, true)!!, 0f)
        assertEquals(40f, compositedUserScroll(80f, 1.3125f, 2.625f, true)!!, 0f)
        assertEquals(0f, compositedUserScroll(-12f, 3f, 3f, true)!!, 0f)
    }

    @Test fun programmaticInvalidAndOverflowingUpdatesCannotDriveChrome() {
        assertNull(compositedUserScroll(80f, 3f, 3f, false))
        for (value in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            assertNull(compositedUserScroll(value, 3f, 3f, true))
            assertNull(compositedUserScroll(80f, value, 3f, true))
            assertNull(compositedUserScroll(80f, 3f, value, true))
        }
        for (value in listOf(0f, -1f)) {
            assertNull(compositedUserScroll(80f, value, 3f, true))
            assertNull(compositedUserScroll(80f, 3f, value, true))
        }
        assertNull(compositedUserScroll(Float.MAX_VALUE, Float.MAX_VALUE, 1f, true))
    }
}

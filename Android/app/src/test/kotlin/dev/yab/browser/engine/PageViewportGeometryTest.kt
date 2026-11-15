package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

class PageViewportGeometryTest {
    private fun numbers() = mutableMapOf<String, Any?>("clientHeight" to 914.0, "scrollHeight" to 960.433334,
        "innerHeight" to 914.285714, "dpr" to 2.625, "visualViewportHeight" to 914.285714)

    @Test fun preservesFractionalCssExtentAndDeviceScaleWithoutReadingOtherFields() {
        val values = numbers()
        val requested = mutableListOf<String>()
        val geometry = PageViewportGeometry.read { key -> requested.add(key); values[key] }!!
        assertEquals(46.433334, geometry.scrollHeight - geometry.clientHeight, 0.000001)
        assertEquals(2.625, geometry.dpr, 0.0)
        assertEquals(914.285714, geometry.visualViewportHeight!!, 0.0)
        assertEquals(setOf("clientHeight", "scrollHeight", "innerHeight", "dpr", "visualViewportHeight"), requested.toSet())
    }

    @Test fun invalidOrCoercedRequiredScalarsNeverBecomeTrustedGeometry() {
        for (key in listOf("clientHeight", "scrollHeight", "innerHeight", "dpr")) {
            for (bad in listOf(null, "914", true, Double.NaN, Double.POSITIVE_INFINITY, -1.0, 1_000_001.0)) {
                val values = numbers().apply { this[key] = bad }
                assertNull("$key accepted $bad", PageViewportGeometry.read(values::get))
            }
        }
        assertNull(PageViewportGeometry.read(numbers().apply { this["dpr"] = 0 }::get))
    }

    @Test fun unsupportedOrInvalidVisualViewportIsExplicitlyAbsentWithoutInventedFallback() {
        for (missing in listOf(null, "874", Double.NaN, -1.0, 1_000_001)) {
            val geometry = PageViewportGeometry.read(numbers().apply { this["visualViewportHeight"] = missing }::get)!!
            assertNull(geometry.visualViewportHeight)
            assertEquals(914.285714, geometry.innerHeight, 0.0)
        }
        assertNotNull(PageViewportGeometry.read(numbers().apply { this["scrollHeight"] = 1_000_000 }::get))
    }
}

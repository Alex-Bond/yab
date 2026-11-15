package dev.yab.browser.ui

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Vectors are emitted by pager-oracle.py executing current Phone function bodies on a farm Mac. */
class BrowserPagerSwiftParityTest {
    private fun resource(name: String) = checkNotNull(javaClass.getResourceAsStream("/pager/$name"))
        .bufferedReader().use { Json.parseToJsonElement(it.readText()).jsonObject }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.double
    private fun JsonObject.flag(key: String) = getValue(key).jsonPrimitive.boolean

    @Test fun everyOriginalSwiftEdgeNeighborAndProjectedReleaseMatches() {
        val source = resource("current-ios-vectors.json")
        assertTrue(source.flag("originalSwiftBodies"))
        assertFalse(source.flag("presentedFrameParityVerified"))
        assertFalse(source.flag("gestureVelocityVerified"))
        val pins = resource("current-ios-source-pins.json")
        assertTrue(pins.flag("originalSwiftBodies"))
        assertEquals(6, pins.getValue("inputs").jsonArray.size)
        val rows = source.getValue("geometry").jsonArray
        assertEquals(1024, rows.size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject
            val width = row.number("width"); val raw = row.number("raw")
            val slot = BrowserPageSwipeMath.slot(width)
            val beside = BrowserPageSwipeMath.beside(width, raw)
            val edge = BrowserPageSwipeMath.edge(raw, slot, row.flag("before"), row.flag("after"))
            assertEquals("row $index slot", row.number("slot"), slot, 1e-8)
            assertEquals("row $index left", row.number("left"), beside.first, 1e-8)
            assertEquals("row $index right", row.number("right"), beside.second, 1e-8)
            assertEquals("row $index edge", row.number("edge"), edge, 1e-8)
            assertEquals("row $index destination", row.getValue("destination").jsonPrimitive.int,
                BrowserPageSwipeMath.destination(edge + row.number("speed") * BrowserPageSwipeMath.projection,
                    row.flag("before"), row.flag("after")))
        }
    }

    @Test fun everyOriginalSwiftFrameIntegrationMatchesAt120And60HzAndAfterStalls() {
        val rows = resource("current-ios-vectors.json").getValue("steps").jsonArray
        assertEquals(50, rows.size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject
            val initial = row.getValue("initial").jsonArray.map { it.jsonPrimitive.double }
            val expected = row.getValue("state").jsonArray.map { it.jsonPrimitive.double }
            val actual = browserStepSpring(initial[0], initial[1], initial[2], row.number("response"), 1.0, row.number("dt"))
            assertEquals("step $index position", expected[0], actual.value, 1e-8)
            assertEquals("step $index speed", expected[1], actual.velocity, 1e-8)
            assertEquals("step $index settled", expected[2] == 1.0, actual.settled)
        }
    }
}

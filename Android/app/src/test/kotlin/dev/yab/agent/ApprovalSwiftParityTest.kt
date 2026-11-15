package dev.yab.agent

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Actual current production Swift geometry and numerical loop, emitted by approval-oracle.py. */
class ApprovalSwiftParityTest {
    private val vectors by lazy {
        checkNotNull(javaClass.getResourceAsStream("/approvals/current-ios-vectors.json"))
            .bufferedReader().use { Json.parseToJsonElement(it.readText()).jsonObject }
    }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.double
    private val motions = mapOf("approvalIn" to ApprovalTiming.arrive, "approvalOut" to ApprovalTiming.leave,
        "approvalBack" to ApprovalTiming.back, "approvalStep" to ApprovalTiming.step, "approvalHeight" to ApprovalTiming.height,
        "approvalWindow" to ApprovalTiming.window, "approvalPage" to ApprovalTiming.page, "approvalScroll" to ApprovalTiming.scroll,
        "approvalPicture" to ApprovalTiming.picture, "approvalPictureBack" to ApprovalTiming.pictureBack,
        "approvalFold" to ApprovalTiming.fold, "approvalIsland" to ApprovalTiming.island, "approvalKeyboard" to ApprovalTiming.keyboard)

    @Test fun currentSwiftTrayAndNoIslandGeometryMatchAcrossCompactWideAndTallContent() {
        val rows = vectors.getValue("layouts").jsonArray
        assertEquals(144, rows.size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject
            val geometry = ApprovalGeometry(row.number("width"), row.number("height"), row.number("safeTop"),
                row.number("body"), rise = row.number("rise"), fold = row.number("fold"))
            mapOf("rect" to geometry.rect, "island" to geometry.island).forEach { (name, rect) ->
                val actual = listOf(rect.x, rect.y, rect.width, rect.height)
                row.getValue(name).jsonArray.forEachIndexed { channel, number ->
                    assertEquals("layout $index $name[$channel]", number.jsonPrimitive.double, actual[channel], 1e-8)
                }
            }
            assertEquals("layout $index bodyCap", row.number("bodyCap"), geometry.bodyCap, 1e-8)
            assertEquals("layout $index dim", row.number("dim"), geometry.dim, 1e-8)
            assertEquals("layout $index words", row.number("words"), geometry.wordsOpacity, 1e-8)
        }
    }

    @Test fun allThirteenActualSwiftSpringLoopsMatchIncludingVelocityAndCappedLongFrames() {
        val rows = vectors.getValue("steps").jsonArray
        assertEquals(702, rows.size)
        assertEquals(motions.keys, rows.map { it.jsonObject.getValue("motion").jsonPrimitive.content }.toSet())
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject
            val name = row.getValue("motion").jsonPrimitive.content
            val timing = motions.getValue(name)
            assertEquals("$name response", row.number("response"), timing.response, 0.0)
            assertEquals("$name damping", row.number("damping"), timing.damping, 0.0)
            val spring = ApprovalSpringValue(row.number("from"))
            spring.animate(row.number("target"), timing, row.number("velocity"))
            spring.advance(row.number("elapsed"))
            val expected = row.getValue("expected").jsonArray
            assertEquals("step $index $name position", expected[0].jsonPrimitive.double, spring.value, 1e-8)
            assertEquals("step $index $name velocity", expected[1].jsonPrimitive.double, spring.velocity, 1e-8)
            assertEquals("step $index $name settled", expected[2].jsonPrimitive.double == 1.0, !spring.moving)
        }
    }
}

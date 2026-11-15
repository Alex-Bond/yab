package dev.yab.agent

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** The production Phone geometry and picture-fit body emitted by approval-oracle.py. No font/frame claim. */
class ApprovalDetailSwiftParityTest {
    private val vectors by lazy {
        checkNotNull(javaClass.getResourceAsStream("/approvals/current-ios-vectors.json"))
            .bufferedReader().use { Json.parseToJsonElement(it.readText()).jsonObject }
    }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.double
    private fun JsonObject.rect(key: String) = getValue(key).jsonArray.map { it.jsonPrimitive.double }.let {
        check(it.size == 4); ApprovalRect(it[0], it[1], it[2], it[3])
    }
    private fun rectEquals(label: String, expected: ApprovalRect, actual: ApprovalRect) {
        listOf(expected.x to actual.x, expected.y to actual.y, expected.width to actual.width, expected.height to actual.height)
            .forEachIndexed { index, (a, b) -> assertEquals("$label[$index]", a, b, 1e-8) }
    }
    @Test fun actualSwiftWindowMorphGroundGhostAndWordsMatchForFixedMeasuredFrames() {
        val rows = vectors.getValue("windowLayouts").jsonArray
        assertEquals(60, rows.size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject; val progress = row.number("progress"); val pull = row.number("pull")
            val open = ApprovalGeometry(row.number("width"), row.number("height"), row.number("safeTop"), 300.0).windowRect
            rectEquals("window $index open", row.rect("open"), open)
            rectEquals("window $index morph", row.rect("now"), ApprovalDetailGeometry.window(row.rect("from"), open, progress, pull))
            assertEquals(row.number("scale"), ApprovalDetailGeometry.windowScale(pull), 1e-8)
            assertEquals(row.number("words"), ApprovalDetailGeometry.windowWords(progress), 1e-8)
            assertEquals(row.number("ghost"), ApprovalDetailGeometry.windowGhost(progress), 1e-8)
            assertEquals(row.number("ground"), ApprovalDetailGeometry.windowGround(progress), 1e-8)
        }
    }
    @Test fun actualSwiftOriginalDimensionFitAndPictureMorphBlackHeaderMatch() {
        val rows = vectors.getValue("pictureLayouts").jsonArray
        assertEquals(216, rows.size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject; val progress = row.number("progress"); val drag = row.number("drag")
            val fit = ApprovalDetailGeometry.fitPicture(row.number("width"), row.number("height"), row.number("safeTop"),
                row.getValue("image").jsonPrimitive.boolean, row.getValue("originalWidth").jsonPrimitive.intOrNull,
                row.getValue("originalHeight").jsonPrimitive.intOrNull)
            rectEquals("picture $index fit", row.rect("fit"), fit)
            rectEquals("picture $index morph", row.rect("now"), ApprovalDetailGeometry.picture(row.rect("from"), fit, progress, drag))
            assertEquals(row.number("black"), ApprovalDetailGeometry.pictureBlack(progress, drag), 1e-8)
            assertEquals(row.number("header"), ApprovalDetailGeometry.pictureHeader(progress, drag), 1e-8)
        }
    }
}

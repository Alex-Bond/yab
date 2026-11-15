package dev.yab.browser.ui

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Vectors were emitted by actual current Phone production Swift, not a second expected-value port. */
class BrowserTabGalleryGeometryTest {
    private val vectors by lazy {
        val resource = checkNotNull(javaClass.getResourceAsStream("/gallery/current-ios-vectors.json"))
        resource.bufferedReader().use { Json.parseToJsonElement(it.readText()).jsonObject }
    }
    private fun JsonObject.number(name: String) = getValue(name).jsonPrimitive.double
    private fun JsonObject.integer(name: String) = getValue(name).jsonPrimitive.int
    private fun JsonObject.layout() = GalleryLayout(number("width"), number("height"), integer("count"))
    private fun compare(expected: JsonObject, actual: GalleryPose, context: String) {
        val rect = expected.getValue("rect").jsonArray.map { it.jsonPrimitive.double }
        listOf(actual.rect.x, actual.rect.y, actual.rect.width, actual.rect.height).forEachIndexed { i, value ->
            assertEquals("$context rect[$i]", rect[i], value, 1e-8)
        }
        val values = mapOf("angle" to actual.angle, "radius" to actual.radius, "cropTop" to actual.cropTop,
            "opacity" to actual.opacity, "veil" to actual.veil, "icon" to actual.icon, "title" to actual.title,
            "labelScale" to actual.labelScale, "titleWidth" to actual.titleWidth, "rim" to actual.rim, "z" to actual.z)
        values.forEach { (key, value) -> assertEquals("$context $key", expected.number(key), value, 1e-8) }
    }
    @Test fun currentSwiftLayoutDepthHitTestingAndRubberMatchAcrossThreePhoneSizes() {
        val rows = vectors.getValue("layouts").jsonArray
        assertEquals(630, rows.size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject
            val layout = row.layout()
            val focus = row.number("focus")
            val card = row.integer("index")
            val pose = GalleryMotion.rest(card, layout, focus)
            compare(row.getValue("rest").jsonObject, pose, "layout $index")
            assertEquals(row.number("resisted"), layout.resisted(focus), 1e-8)
            assertEquals(row.getValue("draws").jsonPrimitive.boolean, layout.draws(card, focus))
            assertEquals(row.integer("hit"), layout.hit(pose.rect.x + pose.rect.width / 2, pose.rect.y + pose.rect.height / 2, focus) ?: -1)
        }
    }
    @Test fun everyCurrentSwiftOpeningAndClosingPoseMatchesAtItsActualFrameTime() {
        val opening = vectors.getValue("openings").jsonArray
        val closing = vectors.getValue("closings").jsonArray
        assertEquals(390, opening.size)
        assertEquals(630, closing.size)
        opening.forEachIndexed { index, value ->
            val row = value.jsonObject
            compare(row.getValue("pose").jsonObject, GalleryMotion.opening(row.integer("index"), row.layout(), row.number("seconds")), "opening $index")
        }
        closing.forEachIndexed { index, value ->
            val row = value.jsonObject
            val layout = row.layout()
            val plan = GalleryClosing(layout.count, row.integer("chosen"))
            val role = plan.role(row.integer("index"))
            assertEquals(row.getValue("role").jsonPrimitive.content, role.name)
            assertEquals(row.getValue("rises").jsonPrimitive.boolean, plan.rises)
            compare(row.getValue("pose").jsonObject,
                GalleryMotion.closing(role, GalleryMotion.rest(row.integer("index"), layout, layout.initialFocus), layout, row.number("seconds")), "closing $index")
        }
    }
    @Test fun swiftHalfAwayRoundingAndShortFlickThresholdsDoNotBecomeKotlinBankersRounding() {
        vectors.getValue("settle").jsonArray.forEach { value ->
            val row = value.jsonObject
            assertEquals(row.number("expected"), GalleryLayout.settle(row.number("from"), row.number("moved"), row.number("thrown")), 1e-12)
        }
    }
    @Test fun lowerStackCardsAreSeatedAndTheNewestSelectionRaisesTheirActualMeasuredButton() {
        val layout = GalleryLayout(874.0, 402.0, 4, stackButton = GalleryRect(12.0, 100.0, 48.0, 48.0))
        val newest = GalleryClosing(4, 3)
        assertEquals(listOf(2 to GalleryRole.FRONT, 1 to GalleryRole.BACK), newest.seated)
        val begin = GalleryMotion.seated(GalleryRole.FRONT, newest.rises, layout, 0.0)
        assertEquals(104.0, begin.rect.y - layout.front.y, 1e-12)
        assertEquals(1.0, begin.opacity, 1e-12)
        val older = GalleryClosing(4, 1)
        assertTrue(older.seated.isEmpty())
        assertEquals(0.0, GalleryMotion.seated(GalleryRole.FRONT, false, layout, 0.0).opacity, 1e-12)
        // CGRect max edges are outside; overlapping cards hit the newer one.
        assertFalse(layout.front.contains(layout.front.right, layout.front.y))
    }

    // Source-authored mask cases. These are separate from the captured Swift pose vectors above.
    @Test fun groundIsOpaqueThroughContentAndOnlyTheChromeBandFollowsTheExistingBar() {
        val layout = GalleryLayout(402.0, 874.0, 4)
        val beginning = layout.groundMask(GalleryTiming.bar(0.0))
        assertEquals(798.0, beginning.contentBottom, 1e-12)
        assertEquals(76.0, beginning.lowerHeight, 1e-12)
        assertEquals(0.0, beginning.lowerOpacity, 1e-12)
        val opening = layout.groundMask(GalleryTiming.bar(.08))
        assertTrue(opening.lowerOpacity > 0.0 && opening.lowerOpacity < 1.0)
        assertEquals(beginning.contentBottom, opening.contentBottom, 1e-12)
        assertEquals(1.0, layout.groundMask(GalleryTiming.bar(.19)).lowerOpacity, 1e-12)
        val interruptedBar = .43
        val closingStart = layout.groundMask(interruptedBar * (1 - GalleryTiming.bar(0.0)))
        assertEquals(interruptedBar, closingStart.lowerOpacity, 1e-12)
        val closing = layout.groundMask(interruptedBar * (1 - GalleryTiming.bar(.08)))
        assertTrue(closing.lowerOpacity > 0.0 && closing.lowerOpacity < interruptedBar)
        assertEquals(0.0, layout.groundMask(interruptedBar * (1 - GalleryTiming.bar(.19))).lowerOpacity, 1e-12)
    }

    @Test fun groundMaskClipsToActualViewportWithVariableSystemInsetsAndCompressedHeight() {
        val landscape = GalleryLayout(874.0, 402.0, 2, statusBar = 0.0, chromeBottom = 38.0)
        assertEquals(316.0, landscape.groundMask(.5).contentBottom, 1e-12)
        assertEquals(86.0, landscape.groundMask(.5).lowerHeight, 1e-12)
        val compressed = GalleryLayout(402.0, 30.0, 0)
        assertEquals(30.0, compressed.groundMask(-.5).contentBottom, 1e-12)
        assertEquals(0.0, compressed.groundMask(-.5).lowerHeight, 1e-12)
        assertEquals(0.0, compressed.groundMask(-.5).lowerOpacity, 1e-12)
        assertEquals(1.0, compressed.groundMask(1.5).lowerOpacity, 1e-12)
        assertEquals(0.0, GalleryLayout(402.0, 0.0, 0).groundMask(.5).contentBottom, 1e-12)
    }
}

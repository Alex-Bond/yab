package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI

class BrowserSpaceLookTest {
    private fun raw(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun color(value: String) = requireNotNull(BrowserSpaceLook.parseHex(value))
    private fun oracle(): JsonObject = Json.parseToJsonElement(requireNotNull(
        javaClass.getResourceAsStream("/space-look/swift-oracle.json")).bufferedReader().use { it.readText() }).jsonObject

    @Test fun actualCurrentPhoneColorVectorsMatchIncludingDarkWashGroundAndGamutReach() {
        val rows = oracle()["colors"]!!.jsonArray
        assertEquals(12, rows.size)
        var chromaticHues = 0
        rows.forEach { value ->
            val row = value.jsonObject
            val label = row["input"]!!.jsonPrimitive.content
            val input = color(label)
            val actual = SpaceLookColor.fromRgb(input)
            assertEquals("$label lightness", row["lightness"]!!.jsonPrimitive.double, actual.lightness, 1e-10)
            assertEquals("$label reach", row["reach"]!!.jsonPrimitive.double, actual.reach, 1e-10)
            val r = (input shr 16) and 255; val g = (input shr 8) and 255; val b = input and 255
            // A neutral's near-zero chroma has no stable direction by itself. Its residual
            // reach, Cartesian handle point and every displayed RGB still match the oracle.
            if (r != g || g != b) {
                chromaticHues++
                assertEquals("$label hue", SpaceLookColor.turn(row["hue"]!!.jsonPrimitive.double), actual.hue, 1e-10)
            }
            assertEquals("$label pointX", row["pointX"]!!.jsonPrimitive.double, actual.pointX, 1e-10)
            assertEquals("$label pointY", row["pointY"]!!.jsonPrimitive.double, actual.pointY, 1e-10)
            assertEquals("$label rgb", color(row["rgb"]!!.jsonPrimitive.content), actual.rgb)
            assertEquals("$label deepened", color(row["deepened"]!!.jsonPrimitive.content), SpaceLookColor.deepened(input))
            assertEquals("$label filled", color(row["filled"]!!.jsonPrimitive.content), SpaceLookColor.filled(input))
            val look = BrowserSpaceLook.from(null, input)
            assertEquals(color(row["wash"]!!.jsonPrimitive.content), look.wash)
            assertEquals(color(row["ground"]!!.jsonPrimitive.content), look.ground)
        }
        assertEquals(9, chromaticHues)
    }

    @Test fun actualCurrentPhoneFieldVectorsMatchAtBlackWhiteGrayAndGamutEdges() {
        val rows = oracle()["field"]!!.jsonArray
        assertEquals(75, rows.size)
        rows.forEach { value ->
            val row = value.jsonObject
            val actual = SpaceLookColor(row["lightness"]!!.jsonPrimitive.double,
                row["reach"]!!.jsonPrimitive.double, row["hue"]!!.jsonPrimitive.double)
            assertEquals(row.toString(), color(row["rgb"]!!.jsonPrimitive.content), actual.rgb)
            assertEquals(row["pointX"]!!.jsonPrimitive.double, actual.pointX, 1e-10)
            assertEquals(row["pointY"]!!.jsonPrimitive.double, actual.pointY, 1e-10)
        }
    }

    @Test fun paletteEditMergesOntoRemoteGrainDrawingsAndUnknownEffectsWithoutOverwritingThem() {
        val opened = BrowserSpaceLook.from(raw("""{"swatch":"custom","color":"#A8C3A0","colors":["#8DB6E6","#EEA2C4"],"grain":true,"grainAmount":0.35,"transparency":0.2,"drawings":"flowers","futureEffect":{"version":3,"enabled":true}}"""))
        val edited = opened.palette(color("#F2837C"), listOf(color("#74BFD6")))
        val latest = BrowserSpaceLook.from(JsonObject(opened.raw + mapOf(
            "grainAmount" to JsonPrimitive(.88), "transparency" to JsonPrimitive(.67),
            "drawings" to JsonPrimitive("future-set"), "futureEffect" to raw("""{"version":4,"enabled":false}"""))))
        val merged = edited.mergingChanges(opened, latest)
        assertEquals(color("#F2837C"), merged.primary)
        assertEquals(listOf(color("#74BFD6")), merged.colors)
        assertEquals(.88, merged.grain, 0.0); assertEquals(.67, merged.transparency, 0.0)
        assertEquals("future-set", merged.drawings)
        assertEquals(latest.raw["futureEffect"], merged.raw["futureEffect"])
        assertEquals("#A8C3A0", opened.raw["color"]!!.jsonPrimitive.content)
    }

    @Test fun oneLocalAmountEditPreservesRemotePaletteAndDeletionHasDifferentMeaningFromNull() {
        val opened = BrowserSpaceLook.from(raw("""{"swatch":"custom","color":"#A8C3A0","grain":true,"grainAmount":0.35,"future":null}"""))
        val latest = opened.palette(color("#EEA2C4"), listOf(color("#8DB6E6"))).drawings("browser")
        val merged = opened.grain(.7).mergingChanges(opened, latest)
        assertEquals(latest.primary, merged.primary); assertEquals(latest.colors, merged.colors)
        assertEquals("browser", merged.drawings); assertEquals(.7, merged.grain, 0.0)
        val deleted = BrowserSpaceLook.from(JsonObject(opened.raw - "grainAmount"))
            .mergingChanges(opened, latest.grain(.9))
        assertFalse(deleted.raw.containsKey("grainAmount")); assertEquals(.35, deleted.grain, 0.0)
        assertTrue(deleted.raw.containsKey("future")); assertEquals(JsonNull, deleted.raw["future"])
    }

    @Test fun paintTypesAreStrictAmountsAreFiniteAndUnknownRawValuesAreKept() {
        val payload = raw("""{"swatch":"future","color":"a8c3a0","colors":["#8DB6E6",true,"#abc","#EEA2C4"],"grain":"true","grainAmount":"0.8","drawingsStrength":"0.9","custom":[1,{"x":null}]}""")
        val look = BrowserSpaceLook.from(payload)
        assertEquals(payload, look.raw); assertEquals(0.0, look.grain, 0.0)
        assertEquals(.45, look.drawingsStrength, 0.0)
        assertEquals(listOf(color("#8DB6E6"), color("#EEA2C4")), look.colors)
        val changed = look.grain(Double.NaN).drawingsStrength(2.0).transparency(-1.0)
        assertEquals(0.0, changed.grain, 0.0); assertEquals(1.0, changed.drawingsStrength, 0.0)
        assertEquals(0.0, changed.transparency, 0.0); assertEquals(payload["custom"], changed.raw["custom"])
        assertNull(BrowserSpaceLook.parseHex("#12345678")); assertNull(BrowserSpaceLook.parseHex(" #A8C3A0"))
        assertEquals(color("#123456"), BrowserSpaceLook.from(raw("""{"swatch":true,"color":"#FFFFFF"}"""), color("#123456")).primary)
        assertEquals(color("#EFF4EE"), BrowserSpaceLook.from(null).wash)
        assertEquals(color("#9E9E9E"), BrowserSpaceLook.readable(color("#000000")))
        val plain = BrowserSpaceLook.from(raw("""{"swatch":"plain","color":"#FFFFFF"}"""))
        assertEquals(listOf(color("#0F0F0F")), plain.displayColors(true))
    }

    @Test fun linkedHandlesKeepTheirLightnessAndOffsetWhileThePrimaryMoves() {
        val primary = SpaceLookColor(.7, .4, PI / 3)
        val linked = SpaceLookColor(.6, .5, PI)
        val harmony = SpaceLookHarmony(primary, listOf(linked.rgb))
        val original = harmony.links.single()
        val moved = harmony.move(0, .92, .5, primary)
        assertEquals(original.lightness, moved.links.single().lightness, 0.0)
        assertEquals(primary.lightness + original.lightness, moved.colors(primary).single().lightness, 1e-12)
        assertEquals(0.92, moved.colors(primary).single().pointX, 1e-12)
        assertEquals(.5, moved.colors(primary).single().pointY, 1e-12)
        assertEquals(original, harmony.links.single())
        assertSame(harmony, harmony.move(7, .3, .3, primary))
        assertEquals(2, SpaceLookHarmony.suggested(2).colors(primary).size)
        val center = primary.move(.5, .5)
        assertEquals(0.0, center.reach, 0.0); assertEquals(primary.hue, center.hue, 0.0)
        assertEquals(1.0, primary.move(7.0, 7.0).reach, 0.0)
    }
}

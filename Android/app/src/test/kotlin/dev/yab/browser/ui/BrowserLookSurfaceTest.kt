package dev.yab.browser.ui

import dev.yab.browser.model.BrowserSpace
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class BrowserLookSurfaceTest {
    private fun raw(swatch: JsonElement? = JsonPrimitive("custom"), color: JsonElement? = JsonPrimitive("#000000")) = buildJsonObject {
        swatch?.let { put("swatch", it) }; color?.let { put("color", it) }
        put("grain", true); put("grainAmount", .8); put("future", buildJsonObject { put("mode", "opaque") })
    }

    @Test fun nullOrInvalidPaintUsesExactLegacyTintAndNeverInventsDefaultGrain() {
        val invalid = listOf(null, raw(swatch = null), raw(swatch = JsonPrimitive(1)), raw(swatch = JsonPrimitive(true)),
            raw(color = null), raw(color = JsonNull), raw(color = JsonPrimitive(16711680)),
            raw(color = JsonPrimitive("16711680")), raw(color = JsonPrimitive("blue")))
        invalid.forEach { look ->
            val space = BrowserSpace("legacy", "Legacy", color = 0xFF112233, look = look)
            val before = space.copy()
            assertNull(browserSurfaceLook(space))
            assertEquals(BrowserLookSurfacePaint(BrowserSpacesRgb(17.0, 34.0, 51.0), 0.0), browserSpaceSurface(space))
            assertEquals(before, space)
        }
    }

    @Test fun validPaintUsesReadableGroundAndItsOwnGrainWithoutRewritingOpaqueJson() {
        val look = raw()
        val space = BrowserSpace("picked", "Picked", color = 0xFF112233, look = look)
        val paint = browserSpaceSurface(space)
        assertEquals(BrowserSpacesRgb(158.0, 158.0, 158.0), paint.tint)
        assertEquals(.8, paint.grain, 0.0)
        assertEquals(look, space.look); assertEquals(look, browserSurfaceLook(space)!!.raw)
        val wash = BrowserSpacesWash.at(listOf(paint.tint), 0.0, null, true)
        assertEquals(.45, wash.darkOverlay, 0.0)
        assertEquals(paint.tint, wash.foot)
    }

    @Test fun privateNeverUsesAPublicLookOrTintAndHasNoLighteningDarkOverlayOrGrain() {
        val space = BrowserSpace("private", "Private", color = 0xFF112233, isPrivate = true, look = raw())
        assertNull(browserSurfaceLook(space))
        val paint = browserSpaceSurface(space)
        assertEquals(BrowserLookSurfacePaint(BrowserSpacesRgb(28.0, 28.0, 32.0), 0.0), paint)
        val wash = BrowserSpacesWash.at(listOf(paint.tint), 0.0, 0, true)
        assertEquals(paint.tint, wash.head); assertEquals(paint.tint, wash.foot)
        assertEquals(0.0, wash.darkOverlay, 0.0)
        assertEquals(0xFF112233L, space.color); assertEquals(raw(), space.look)
    }
}

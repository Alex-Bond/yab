package dev.yab.browser

import dev.yab.browser.model.BrowserLookTexture
import java.math.BigInteger
import kotlin.math.*
import org.junit.Assert.*
import org.junit.Test

/** Pure source contracts, not raster/CoreGraphics/Swift runtime or presented-frame acceptance. */
class BrowserLookTextureTest {
    @Test fun grainRetainsUInt32WrappingPremultipliedRgbaAndIndependentFreshTiles() {
        // Standard xorshift32 seed1: 0x00042021, hence odd white and alpha0x20.
        assertEquals(270369, BrowserLookTexture.nextGrain(1))
        val one = BrowserLookTexture.grain(1)
        assertArrayEquals(byteArrayOf(32, 32, 32, 32), one.copyOfRange(0, 4))
        assertEquals(128 * 128 * 4, one.size)
        val first = BrowserLookTexture.grain(); val second = BrowserLookTexture.grain()
        assertArrayEquals(first, second); assertNotSame(first, second)
        var black = 0; var white = 0; val alphas = mutableSetOf<Int>()
        for (offset in first.indices step 4) {
            val r = first[offset].toInt() and 255; val a = first[offset + 3].toInt() and 255
            assertEquals(first[offset], first[offset + 1]); assertEquals(first[offset], first[offset + 2])
            assertTrue(r == 0 || r == a); alphas += a
            if (r == 0 && a > 0) black++
            if (r == a && a > 0) white++
        }
        assertTrue(black > 0 && white > 0 && alphas.size > 200)
        first[0] = (first[0].toInt() xor 255).toByte()
        assertArrayEquals(second, BrowserLookTexture.grain())
        assertEquals(64.0, BrowserLookTexture.GRAIN_POINTS, 0.0)
    }

    @Test fun firstDrawingItemUsesFullUnsigned64SeedAgainstUnboundedIntegerReference() {
        val mask = BigInteger.ONE.shiftLeft(64) - BigInteger.ONE
        val multiplier = BigInteger("6364136223846793005")
        val increment = BigInteger("1442695040888963407")
        var seed = BigInteger("51A7E5ED", 16)
        fun next(): Double {
            seed = seed.multiply(multiplier).add(increment).and(mask)
            return seed.shiftRight(33).toDouble() / 2147483648.0
        }
        val big = next() < .62
        val size = if (big) 8.5 + next() * 5.5 else 3.6 + next() * 2.6
        val x = next() * 320; val y = next() * 320
        val pool = if (big) listOf(BrowserLookTexture.Glyph.GLOBE, BrowserLookTexture.Glyph.CURSOR,
            BrowserLookTexture.Glyph.MAIL, BrowserLookTexture.Glyph.BOOKMARK, BrowserLookTexture.Glyph.KEY,
            BrowserLookTexture.Glyph.LOCK, BrowserLookTexture.Glyph.SEARCH, BrowserLookTexture.Glyph.COMMAND,
            BrowserLookTexture.Glyph.TAB, BrowserLookTexture.Glyph.DOWNLOAD, BrowserLookTexture.Glyph.PUZZLE,
            BrowserLookTexture.Glyph.COMPASS, BrowserLookTexture.Glyph.BOLT, BrowserLookTexture.Glyph.PENCIL,
            BrowserLookTexture.Glyph.STAR) else listOf(BrowserLookTexture.Glyph.SQUIGGLE,
            BrowserLookTexture.Glyph.PLUS, BrowserLookTexture.Glyph.SPARKLE)
        val glyph = pool[min(pool.lastIndex, (next() * pool.size).toInt())]
        val angle = (next() - .5) * 1.1
        val actual = BrowserLookTexture.layout(BrowserLookTexture.Set.BROWSER).first()
        assertEquals(size, actual.size, 0.0); assertEquals(x, actual.x, 0.0); assertEquals(y, actual.y, 0.0)
        assertEquals(angle, actual.angle, 0.0); assertEquals(glyph, actual.glyph)
    }

    @Test fun eachFixedSetIsRepeatableAndCollisionFreeAcrossTheTileSeam() {
        for (set in BrowserLookTexture.Set.entries) {
            val items = BrowserLookTexture.layout(set)
            assertEquals(items, BrowserLookTexture.layout(set)); assertTrue(items.size in 2..140)
            assertTrue(items.any { it.size < 8.5 }); assertTrue(items.any { it.size >= 8.5 })
            for ((index, item) in items.withIndex()) {
                assertTrue(item.x >= 0 && item.x < 320 && item.y >= 0 && item.y < 320)
                assertTrue(item.size in 3.6..6.2 || item.size in 8.5..14.0)
                assertTrue(item.angle >= -.55 && item.angle < .55)
                for (other in items.take(index)) {
                    val dx = min(abs(other.x - item.x), 320 - abs(other.x - item.x))
                    val dy = min(abs(other.y - item.y), 320 - abs(other.y - item.y))
                    val room = (other.size + item.size) * 1.15 + 5
                    assertTrue("Seam collision in $set", dx * dx + dy * dy >= room * room)
                }
            }
        }
        assertNotEquals(BrowserLookTexture.layout(BrowserLookTexture.Set.BROWSER), BrowserLookTexture.layout(BrowserLookTexture.Set.LIFE))
    }

    @Test fun wrappedCopiesPreserveGeometryAndTouchTheOppositeCornersBeforeClipping() {
        val original = BrowserLookTexture.Item(BrowserLookTexture.Glyph.MAIL, 0.0, 0.0, 10.0, .1)
        val copies = BrowserLookTexture.copies(original)
        assertEquals(setOf(0.0 to 0.0, 0.0 to 320.0, 320.0 to 0.0, 320.0 to 320.0), copies.map { it.x to it.y }.toSet())
        assertTrue(copies.all { it.glyph == original.glyph && it.size == original.size && it.angle == original.angle })
        assertEquals(listOf(original.copy(x = 160.0, y = 160.0)), BrowserLookTexture.copies(original.copy(x = 160.0, y = 160.0)))
    }

    @Test fun sourceStrengthAndGroundContrastDoNotDependOnGlobalThemeOrFabricateUnknownSets() {
        assertEquals(.02, BrowserLookTexture.drawingOpacity(0.0, false), 0.0)
        assertEquals(.22, BrowserLookTexture.drawingOpacity(1.0, false), 1e-15)
        assertEquals(.015, BrowserLookTexture.drawingOpacity(0.0, true), 0.0)
        assertEquals(.185, BrowserLookTexture.drawingOpacity(1.0, true), 1e-15)
        assertEquals(.11, BrowserLookTexture.drawingOpacity(.45, false), 1e-15)
        assertEquals(.0915, BrowserLookTexture.drawingOpacity(.45, true), 1e-15)
        assertEquals(0.0, BrowserLookTexture.grainOpacity(-1.0), 0.0)
        assertEquals(.2, BrowserLookTexture.grainOpacity(2.0), 0.0)
        assertEquals(0.0, BrowserLookTexture.grainOpacity(Double.NaN), 0.0)
        assertTrue(BrowserLookTexture.whiteInk(0xFF333333)); assertFalse(BrowserLookTexture.whiteInk(0xFFCCCCCC))
        assertEquals(BrowserLookTexture.Set.BROWSER, BrowserLookTexture.set("browser"))
        assertEquals(BrowserLookTexture.Set.LIFE, BrowserLookTexture.set("life"))
        for (raw in listOf("", "Browser", "flowers", "future")) assertNull(BrowserLookTexture.set(raw))
    }

    @Test fun sourceArcDirectionsRotatedPlanetAndDistinctOpenContoursRemainIntact() {
        val lock = BrowserLookTexture.path(BrowserLookTexture.Glyph.LOCK).filterIsInstance<BrowserLookTexture.Part.Arc>().single()
        assertEquals(PI, BrowserLookTexture.arcSweep(lock), 0.0)
        val moon = BrowserLookTexture.path(BrowserLookTexture.Glyph.MOON).filterIsInstance<BrowserLookTexture.Part.Arc>()
        assertEquals(PI * 1.3, BrowserLookTexture.arcSweep(moon[0]), 1e-15)
        assertEquals(-PI * .9, BrowserLookTexture.arcSweep(moon[1]), 1e-15)
        val planet = BrowserLookTexture.path(BrowserLookTexture.Glyph.PLANET).filterIsInstance<BrowserLookTexture.Part.Oval>()
        assertEquals(2, planet.size); assertEquals(-.35, planet[1].rotation, 0.0)
        assertEquals(11, BrowserLookTexture.path(BrowserLookTexture.Glyph.STAR).size)
        assertEquals(17, BrowserLookTexture.path(BrowserLookTexture.Glyph.SQUIGGLE).size)
        assertFalse(BrowserLookTexture.path(BrowserLookTexture.Glyph.HEART).contains(BrowserLookTexture.Part.Close))
        assertEquals(27, BrowserLookTexture.Glyph.entries.size)
        assertTrue(BrowserLookTexture.Glyph.entries.all { BrowserLookTexture.path(it).isNotEmpty() })
    }
}

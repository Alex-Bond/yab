package dev.yab.browser.ui

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.roundToInt

class BrowserFieldWashGeometryTest {
    @Test fun theKeyboardFootStartsBelowTheMainWashAndDoesNotResizeTheOriginalBody() {
        val input = BrowserFieldGeometry(402.0, 874.0, 308.0)
        val g = BrowserFieldWashGeometry(input.width, input.height, input.cardBottom, input.spacesBottom, 0.0)
        assertEquals(500.0, input.cardBottom, 0.0)
        assertEquals(566.0, g.mainHeight, 0.0)
        assertEquals(600.0, g.footHeight, 0.0)
        assertEquals(308.0, g.visibleFootHeight, 0.0)
        assertEquals(874.0, g.layerHeight, 0.0)
        assertEquals(input.cardBottom, g.layerHeight - g.innerBottomPadding, 0.0)
        assertEquals(1.0, g.fullness, 0.0)
    }

    @Test fun restingPaintReachesTheScreenBottomWhileTheInputKeepsIts32ptFoot() {
        val input = BrowserFieldGeometry(402.0, 874.0, 32.0)
        val g = BrowserFieldWashGeometry(input.width, input.height, input.cardBottom, 874.0, 0.0)
        assertEquals(776.0, input.cardBottom, 0.0)
        assertEquals(842.0, input.keyboardTop, 0.0)
        assertEquals(874.0, g.mainHeight, 0.0)
        assertEquals(600.0, g.footHeight, 0.0)
        assertEquals(0.0, g.visibleFootHeight, 0.0)
        assertEquals(98.0, g.innerBottomPadding, 0.0)
        assertEquals(776.0, g.layerHeight - g.innerBottomPadding, 0.0)
    }

    @Test fun aNoPublicSpaceBranchKeepsItsExistingCardSizedLayerInsteadOfInventingASpacesFoot() {
        val input = BrowserFieldGeometry(402.0, 874.0, 308.0)
        val g = BrowserFieldWashGeometry(input.width, input.height, input.cardBottom, input.spacesBottom, 0.0, extended = false)
        assertEquals(input.cardBottom, g.layerHeight, 0.0)
        assertEquals(0.0, g.innerBottomPadding, 0.0)
        assertEquals(0.0, g.visibleFootHeight, 0.0)
    }

    @Test fun largerTextChangesTheMeasuredBodyButCannotMoveTheWashKeyboardAnchor() {
        val input = BrowserFieldGeometry(402.0, 874.0, 308.0, textScale = 1.5)
        val g = BrowserFieldWashGeometry(input.width, input.height, input.cardBottom, input.spacesBottom, 0.0)
        assertEquals(476.0, input.cardBottom, 0.0)
        assertEquals(566.0, g.mainHeight, 0.0)
        assertEquals(398.0, g.innerBottomPadding, 0.0)
        assertEquals(476.0, g.layerHeight - g.innerBottomPadding, 0.0)
    }

    @Test fun paddingPreservesTheOriginalBodyPixelHeightWhenDpRoundingWouldOtherwiseLoseAPixel() {
        val g = BrowserFieldWashGeometry(402.0, 874.2, 500.1, 566.0, 0.0)
        val density = 3f
        val oldBody = (g.cardBottom.toFloat() * density).roundToInt()
        val layer = (g.layerHeight.toFloat() * density).roundToInt()
        val naivePadding = (g.innerBottomPadding.toFloat() * density).roundToInt()
        assertNotEquals(oldBody, layer - naivePadding)
        assertEquals(oldBody, layer - g.innerBottomPaddingPixels(density))
    }

    @Test fun actualStatusPaddingIsCancelledAndClosingDropStillClipsToTheOwningPane() {
        val g = BrowserFieldWashGeometry(402.0, 874.0, 500.0, 566.0, 10.0)
        // The actual Pages origin contains both the consumed54pt inset and10pt rows drop.
        val p = g.projection(0.0, 64.0)
        assertEquals(-54.0, p.translateY, 0.0)
        assertEquals(10.0, 64.0 + p.translateY, 0.0)
        assertEquals(874.0, 64.0 + p.clipBottom, 0.0)
        assertEquals(0.0, 64.0 + p.clipTop, 0.0)
        assertEquals(576.0, 64.0 + p.translateY + g.mainHeight, 0.0)
        // The old inner body clip still moves with the original cards, not the viewport.
        assertEquals(10.0, 64.0 + p.bodyClipTop, 0.0)
        assertEquals(510.0, 64.0 + p.bodyClipBottom, 0.0)
        assertEquals(874.0, g.layerHeight, 0.0)
    }

    @Test fun aSplitPaneUsesItsOwnMeasuredViewportAndNeverAllocatesTheLogical600ptFoot() {
        val g = BrowserFieldWashGeometry(320.0, 360.0, 260.0, 300.0, 7.0)
        val p = g.projection(0.0, 31.0, measuredWidth = 320.0, measuredHeight = 360.0)
        assertEquals(360.0, g.layerHeight, 0.0)
        assertEquals(60.0, g.visibleFootHeight, 0.0)
        assertEquals(360.0, 31.0 + p.clipBottom, 0.0)
        assertEquals(320.0, p.clipRight, 0.0)
        assertEquals(267.0, 31.0 + p.bodyClipBottom, 0.0)
        val short = BrowserFieldWashGeometry(80.0, 30.0, 0.0, 0.0, 10.0)
        assertEquals(600.0, short.footHeight, 0.0)
        assertEquals(30.0, short.decorationHeight, 0.0)
        assertEquals(30.0, short.layerHeight, 0.0)
    }

    @Test fun actualLayerCoordinatesWinOverTheUnroundedLogicalDrop() {
        val g = BrowserFieldWashGeometry(402.0, 874.0, 500.0, 566.0, 6.25)
        // Modifier.offset rounds to a pixel. The draw projection uses that measured layer
        // origin, not an assumed addition of the model's unrounded6.25pt displacement.
        val layerTop = 19.0 / 3.0
        val pageTop = 54.0 + layerTop
        val p = g.projection(0.0, pageTop, layerY = layerTop)
        assertEquals(-54.0, p.translateY, 1e-12)
        assertEquals(layerTop, pageTop + p.translateY, 1e-12)
        assertEquals(874.0, pageTop + p.clipBottom, 0.0)
        assertEquals(layerTop + 500.0, pageTop + p.bodyClipBottom, 1e-12)
    }

    @Test fun keyboardFollowReversalRetainsTheCurrentSampleAndReachesTheNewTargetAt300ms() {
        val track = BrowserFieldWashMotion(566.0)
        track.target(874.0, 0L, reduced = false, animations = true)
        assertEquals(566.0, track.advance(0L), 0.0)
        val held = track.advance(120_000_000L)
        assertTrue(held > 566 && held < 874)
        track.target(566.0, 120_000_000L, reduced = false, animations = true)
        assertEquals(held, track.value, 0.0)
        assertEquals(held, track.advance(120_000_000L), 0.0)
        assertTrue(track.advance(270_000_000L) < held)
        assertEquals(566.0, track.advance(420_000_000L), 0.0)
        assertFalse(track.running)
        // A settled idle period and an identical target cannot replay a previous transition.
        track.target(566.0, 8_000_000_000L, reduced = false, animations = true)
        assertFalse(track.running)
    }

    @Test fun reducedKeyboardFollowUsesTheSource200msPolicyAndDisabledAnimatorsSnapWithoutReplay() {
        val track = BrowserFieldWashMotion(566.0)
        track.target(874.0, 0L, reduced = true, animations = true)
        assertEquals(720.0, track.advance(100_000_000L), 1e-8)
        assertEquals(874.0, track.advance(200_000_000L), 0.0)
        track.target(566.0, 210_000_000L, reduced = false, animations = false)
        assertEquals(566.0, track.value, 0.0)
        assertFalse(track.running)
        track.target(566.0, 220_000_000L, reduced = false, animations = true)
        assertFalse(track.running)
    }
}

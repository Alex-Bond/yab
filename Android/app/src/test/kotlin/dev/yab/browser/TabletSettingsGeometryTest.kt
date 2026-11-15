package dev.yab.browser

import dev.yab.browser.ui.*
import org.junit.Assert.*
import org.junit.Test

class TabletSettingsGeometryTest {
    @Test fun existingDeviceClassificationAndBothActualViewportSidesAreRequired() {
        for ((width, height) in listOf(402 to 874, 874 to 402, 626 to 890, 890 to 626, 500 to 900)) {
            val frame = BrowserTabletSettingsGeometry.frame(width, height, 1.0, 800)
            assertEquals(SettingsSheetFrame(false, 0, 0, width, height), frame)
        }
        assertFalse(BrowserTabletSettingsGeometry.frame(900, 1000, 1.0, 599).tablet)
        assertTrue(BrowserTabletSettingsGeometry.frame(700, 700, 1.0, 600).tablet)
        assertFalse(BrowserTabletSettingsGeometry.frame(2100, 2099, 3.0, 800).tablet)
    }

    @Test fun centeredCapsAndSmallRegularWindowUseTheActualSheetHeight() {
        assertEquals(SettingsSheetFrame(true, 120, 210, 600, 760),
            BrowserTabletSettingsGeometry.frame(840, 1180, 1.0, 600))
        assertEquals(SettingsSheetFrame(true, 50, 40, 600, 620),
            BrowserTabletSettingsGeometry.frame(700, 700, 1.0, 600))
        assertEquals(SettingsSheetFrame(true, 150, 40, 600, 620),
            BrowserTabletSettingsGeometry.frame(900, 700, 1.0, 600))
    }

    @Test fun physicalPlacementRoundsOnceWithoutInflatingTheMeasuredBody() {
        val frame = BrowserTabletSettingsGeometry.frame(2101, 2101, 3.0, 700)
        assertEquals(SettingsSheetFrame(true, 151, 120, 1800, 1861), frame)
        assertTrue(frame.x + frame.width <= 2101 && frame.y + frame.height <= 2101)
        assertEquals(frame.height.toDouble(), 2101.0 - 80 * 3, 0.0)
    }

    @Test fun imeUsesWindowBottomAndNonzeroRootOriginRatherThanPaneBottom() {
        val frame = BrowserTabletSettingsGeometry.frame(840, 1180, 1.0, 600)
        val overlap = BrowserTabletSettingsGeometry.keyboardOverlap(frame, SettingsRootOrigin(42f, 100f), 1500, 450)
        assertEquals(20.0, overlap, 0.0) // sheet bottom1070, actual keyboard top1050.
        assertEquals(170.0, BrowserTabletSettingsGeometry.keyboardOverlap(frame, SettingsRootOrigin(42f, 250f), 1500, 450), 0.0)
    }

    @Test fun zeroUnknownAndNonintersectingKeyboardNeverAddAnInset() {
        val frame = BrowserTabletSettingsGeometry.frame(840, 1180, 1.0, 600)
        assertEquals(0.0, BrowserTabletSettingsGeometry.keyboardOverlap(frame, SettingsRootOrigin(0f, 0f), 1180, 0), 0.0)
        assertEquals(0.0, BrowserTabletSettingsGeometry.keyboardOverlap(frame, null, 1180, 400), 0.0)
        assertEquals(0.0, BrowserTabletSettingsGeometry.keyboardOverlap(frame, SettingsRootOrigin(0f, 0f), 0, 400), 0.0)
        assertEquals(0.0, BrowserTabletSettingsGeometry.keyboardOverlap(frame, SettingsRootOrigin(0f, 0f), 1500, 200), 0.0)
        val compact = BrowserTabletSettingsGeometry.frame(402, 874, 1.0, 600)
        assertEquals(0.0, BrowserTabletSettingsGeometry.keyboardOverlap(compact, SettingsRootOrigin(0f, 0f), 874, 400), 0.0)
    }

    @Test fun aKeyboardCoveringTheEntireSheetIsClampedToThatSheetOnly() {
        val frame = BrowserTabletSettingsGeometry.frame(840, 1180, 1.0, 600)
        assertEquals(760.0, BrowserTabletSettingsGeometry.keyboardOverlap(frame, SettingsRootOrigin(0f, 100f), 1500, 1400), 0.0)
    }

    @Test fun gestureIdentityChangesOnOriginSizeOrModeButNotOnlyImeOverlap() {
        val frame = BrowserTabletSettingsGeometry.frame(840, 1180, 1.0, 600)
        val original = SettingsSheetInputFrame(frame, SettingsRootOrigin(0f, 0f))
        assertEquals(original, SettingsViewport(original, 0.0).frame)
        assertEquals(original, SettingsViewport(original, 250.0).frame)
        assertNotEquals(original, original.copy(root = SettingsRootOrigin(24f, 0f)))
        assertNotEquals(original, original.copy(sheet = BrowserTabletSettingsGeometry.frame(1180, 840, 1.0, 600)))
        assertNotEquals(original, original.copy(sheet = BrowserTabletSettingsGeometry.frame(640, 1180, 1.0, 600)))
    }

    @Test fun pullPresenceUsesSheetExtentAndCancellationKeepsTheExistingRoute() {
        val height = BrowserTabletSettingsGeometry.frame(840, 1180, 1.0, 600).height.toDouble()
        val model = SettingsPresentation().apply { showSettled(0, false, true); push("General", 0); advance(600_000_000) }
        model.pullSheet(110.0, height, 600_000_000)
        assertEquals(1 - 110.0 / 760, model.frame.value.presence, .000001)
        assertFalse(model.releaseSheet(2000.0, 600_000_000, cancelled = true))
        model.advance(2_000_000_000)
        assertEquals("General", model.frame.value.title)
        assertEquals(0.0, model.frame.value.drag, .000001)
        assertTrue(model.frame.value.canBack)
    }
}

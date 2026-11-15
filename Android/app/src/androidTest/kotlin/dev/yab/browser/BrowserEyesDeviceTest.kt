package dev.yab.browser

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.*
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** App-owned component pixels and controlled timelines, not presented-frame or iOS acceptance. */
class BrowserEyesDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private val button get() = compose.onNodeWithTag("browser.field.eyes")
    private fun pose() = button.fetchSemanticsNode().config[BrowserEyesPoseKey]

    @Test fun lidsAndWordReverseFromTheLivePoseWithoutChangingThePrivateAction() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val shut = mutableStateOf(false)
        val enabled = mutableStateOf(true)
        var calls = 0
        compose.mainClock.autoAdvance = false
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
            BrowserEyesButton(shut.value, enabled.value, Color.Black, { calls++; shut.value = !shut.value }, animationsEnabled = true)
        } }
        val original = button.fetchSemanticsNode().boundsInRoot
        button.assertIsOff().assertContentDescriptionEquals("Search privately")
        shot("eyes-open.png")
        button.performClick()
        compose.mainClock.advanceTimeByFrame(); compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(80)
        assertTrue(pose()[0] in .01f.. .99f)
        assertTrue(pose()[1] in .01f.. .99f)
        button.assertIsOn().assertContentDescriptionEquals("Turn off private input")
        val middle = button.fetchSemanticsNode().boundsInRoot
        assertTrue(middle.width > original.width)
        assertEquals(original.height, middle.height, .01f)
        shot("eyes-entering.png")
        button.performClick()
        compose.mainClock.advanceTimeByFrame(); compose.mainClock.advanceTimeByFrame()
        assertTrue("Reversal snapped to an endpoint", pose()[0] > 0f && pose()[0] < 1f)
        compose.mainClock.advanceTimeBy(320)
        assertEquals(listOf(0f, 0f), pose())
        assertEquals(original, button.fetchSemanticsNode().boundsInRoot)
        button.assertIsOff()
        compose.runOnIdle { assertEquals(2, calls); enabled.value = false }
        compose.mainClock.advanceTimeByFrame()
        button.assertIsNotEnabled().performTouchInput { click() }
        compose.runOnIdle { assertEquals(2, calls) }
    }

    @Test fun reducedPreferenceAndDisabledAnimatorsRemainDistinctInputs() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val shut = mutableStateOf(false)
        val animations = mutableStateOf(true)
        compose.mainClock.autoAdvance = false
        compose.setContent { CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduceMotion = true)) {
            BrowserTheme(BrowserAppearance.LIGHT) {
                BrowserEyesButton(shut.value, true, Color.Black, { shut.value = !shut.value }, animationsEnabled = animations.value)
            }
        } }
        button.performClick()
        compose.mainClock.advanceTimeByFrame(); compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(80)
        assertTrue(pose()[0] > 0f && pose()[0] < 1f)
        val entering = button.captureToImage().asAndroidBitmap()
        try {
            compose.mainClock.advanceTimeBy(320)
            assertEquals(listOf(1f, 1f), pose())
            val arrived = button.captureToImage().asAndroidBitmap()
            try { assertLeadingWordUnchanged(entering, arrived) } finally { arrived.recycle() }
        } finally { entering.recycle() }
        shot("eyes-shut.png")
        compose.runOnIdle { animations.value = false; shut.value = false }
        compose.mainClock.advanceTimeByFrame(); compose.mainClock.advanceTimeByFrame()
        assertEquals(listOf(0f, 0f), pose())
        button.assertIsOff().assertContentDescriptionEquals("Search privately")
    }

    @Test fun nativeTouchDoesNotPaintAnAndroidPressPlateBehindThePlainEyesButton() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val shut = mutableStateOf(false)
        var calls = 0
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
            Box(Modifier.background(Color.White)) {
                BrowserEyesButton(shut.value, true, Color.Black, { calls++; shut.value = !shut.value }, animationsEnabled = true)
            }
        } }
        button.assertIsOff()
        button.performTouchInput { down(center) }
        try {
            // Actual held press, with the ordinary real Android indication clock.
            // The hold exposes a settled press plate before the release toggles Eyes.
            android.os.SystemClock.sleep(300)
            assertWhiteTopAndBottomBands()
            compose.runOnIdle { assertEquals(0, calls) }
        } finally { button.performTouchInput { up() } }
        compose.waitForIdle()
        button.assertIsOn()
        compose.runOnIdle { assertEquals(1, calls) }
        assertWhiteTopAndBottomBands()
    }

    private fun assertWhiteTopAndBottomBands() {
        val bitmap = button.captureToImage().asAndroidBitmap()
        try {
            val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
            val band = (2 * density).toInt().coerceAtLeast(1)
            assertTrue(bitmap.height > band * 2 && bitmap.width > band * 2)
            // These actual button pixels lie outside the word and oval outlines.
            for (x in 0 until bitmap.width) for (row in 0 until band) {
                assertEquals("Press painted the top button background", android.graphics.Color.WHITE, bitmap.getPixel(x, row))
                assertEquals("Press painted the bottom button background", android.graphics.Color.WHITE, bitmap.getPixel(x, bitmap.height - 1 - row))
            }
        } finally { bitmap.recycle() }
    }

    /** Phone clips a leading-aligned fixed-size word. Its visible prefix must not slide
     * sideways as the frame grows; compare actual native glyph pixels at both poses. */
    private fun assertLeadingWordUnchanged(entering: Bitmap, arrived: Bitmap) {
        assertEquals(arrived.height, entering.height)
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val first = kotlin.math.ceil(6 * density).toInt()
        val end = kotlin.math.ceil(24 * density).toInt()
        assertTrue("The entering word has no visible prefix", minOf(entering.width, arrived.width) > end)
        var ink = 0
        var changed = 0
        for (y in 0 until arrived.height) for (x in first until end) {
            val expected = arrived.getPixel(x, y)
            if (android.graphics.Color.red(expected) + android.graphics.Color.green(expected) +
                android.graphics.Color.blue(expected) < 600) ink++
            if (entering.getPixel(x, y) != expected) changed++
        }
        assertTrue("The prefix assertion must include actual native word glyphs", ink > 0)
        assertEquals("The revealed word moved instead of retaining its leading prefix", 0, changed)
    }

    private fun shot(name: String) {
        require(name in setOf("eyes-open.png", "eyes-entering.png", "eyes-shut.png"))
        val bitmap = button.captureToImage().asAndroidBitmap()
        try {
            val root = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "instrumentation")
            check(root.isDirectory || root.mkdirs())
            File(root, name).outputStream().use { check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { bitmap.recycle() }
    }
}

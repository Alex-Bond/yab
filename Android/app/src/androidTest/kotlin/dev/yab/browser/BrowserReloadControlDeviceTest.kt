package dev.yab.browser

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual control/Screen consumers under an explicit clock, never presentation-cadence proof. */
class BrowserReloadControlDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private val button get() = compose.onNodeWithTag("browser.chrome.reload", useUnmergedTree = true)
    private fun pose() = button.fetchSemanticsNode().config[ChromeReloadPoseKey]

    @Test fun delayedGlyphKeepsTheActualStopActionAndAQuickLoadCannotPublishItsCancelledCross() {
        fixture { browser, _, calls ->
            val original = button.fetchSemanticsNode().boundsInRoot
            fun loading(value: Boolean) {
                compose.runOnIdle { browser.pageChanged("reload-tab", browser.state.value.page.copy(loading = value)) }
                compose.mainClock.advanceTimeByFrame(); compose.mainClock.advanceTimeByFrame()
            }
            loading(true)
            compose.mainClock.advanceTimeBy(380)
            assertEquals(0f, pose()[0], 0f)
            button.assertContentDescriptionEquals("Stop loading").performClick()
            compose.runOnIdle { assertEquals(1, calls[1]); assertEquals(0, calls[0]) }
            record("01-stop-action-before-delayed-glyph")
            loading(false)
            compose.mainClock.advanceTimeBy(700)
            assertEquals(0f, pose()[0], 0f)
            loading(true)
            compose.mainClock.advanceTimeBy(470)
            val entering = pose()[0]
            assertTrue("No delayed crossfade was sampled", entering > 0f && entering < 1f)
            record("02-transient-glyph")
            compose.mainClock.advanceTimeBy(150)
            assertEquals(1f, pose()[0], 0f)
            assertEquals(original, button.fetchSemanticsNode().boundsInRoot)
            loading(false)
            compose.mainClock.advanceTimeBy(150)
            button.assertContentDescriptionEquals("Reload").performClick()
            compose.runOnIdle { assertEquals(1, calls[0]); assertEquals(1, calls[1]) }
            assertEquals(0f, pose()[0], 0f)
            record("03-returned-reload")
        }
    }

    @Test fun realPressTurnsReloadAndReducedOrStopPressOnlyDimsInsideTheSameBounds() {
        fixture { browser, reduced, _ ->
            val original = button.fetchSemanticsNode().boundsInRoot
            button.performTouchInput { down(center) }
            compose.mainClock.advanceTimeBy(140)
            assertEquals(90f, pose()[1], .01f); assertEquals(1f, pose()[2], 0f)
            record("04-quarter-turn-held")
            button.performTouchInput { cancel() }
            compose.mainClock.advanceTimeBy(180)
            assertEquals(0f, pose()[1], 0f)
            compose.runOnIdle { reduced.value = true }
            compose.mainClock.advanceTimeByFrame()
            button.performTouchInput { down(center) }
            compose.mainClock.advanceTimeBy(140)
            assertEquals(0f, pose()[1], 0f); assertEquals(.6f, pose()[2], .001f)
            record("05-reduced-press")
            button.performTouchInput { cancel() }
            compose.mainClock.advanceTimeBy(180)
            compose.runOnIdle { reduced.value = false; browser.pageChanged("reload-tab", browser.state.value.page.copy(loading = true)) }
            compose.mainClock.advanceTimeBy(700)
            button.performTouchInput { down(center) }
            compose.mainClock.advanceTimeBy(140)
            assertEquals(1f, pose()[0], 0f); assertEquals(0f, pose()[1], 0f)
            assertEquals(.6f, pose()[2], .001f)
            assertEquals(original, button.fetchSemanticsNode().boundsInRoot)
            record("06-stop-press")
            button.performTouchInput { cancel() }
        }
    }

    private fun fixture(block: (BrowserController, androidx.compose.runtime.MutableState<Boolean>, IntArray) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val reduced = mutableStateOf(false)
        val calls = intArrayOf(0, 0)
        val tab = BrowserTab("reload-tab", "https://reload.fixture.invalid/article", createdAt = 1)
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("reload-space", "Reload fixture", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "reload-space")
        val repository = object : BrowserRepository { override suspend fun load() = snapshot; override suspend fun save(snapshot: BrowserSnapshot) {} }
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}; override fun goForward(tabId: String) {}
            override fun reload(tabId: String) { calls[0]++ }; override fun stop(tabId: String) { calls[1]++ }; override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(repository, engine, scope)
        try {
            compose.setContent {
                CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduced.value),
                    LocalReloadAnimationsEnabled provides true) {
                    BrowserScreen(browser) { _, _, modifier -> Box(modifier.fillMaxSize().background(Color.White)) }
                }
            }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            button.assertExists()
            compose.mainClock.autoAdvance = false
            block(browser, reduced, calls)
        } finally { compose.mainClock.autoAdvance = true; scope.cancel() }
    }

    private fun record(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val folder = File(context.getExternalFilesDir(null), "instrumentation/reload-controlled").apply { check(isDirectory || mkdirs()) }
        File(folder, "$name.json").writeText(JSONObject().put("clockKind", "compose-controlled")
            .put("clockMillis", compose.mainClock.currentTime).put("pose", JSONArray(pose()))
            .put("appLocalAnimationFixture", true).put("globalAnimationSettingsChanged", false)
            .put("pageEngine", "explicit-fixture-fake").put("frameParityVerified", false)
            .put("physicalDeviceSmoothnessVerified", false).toString(2))
        val image = compose.onRoot().captureToImage()
        File(folder, "$name.png").outputStream().use { assertTrue(image.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)) }
    }
}

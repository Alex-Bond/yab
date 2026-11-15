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
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserAccessibilityPreferences
import dev.yab.browser.ui.BrowserScreen
import dev.yab.browser.ui.LocalBrowserAccessibility
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

/** Controlled-clock geometry proof. These frames do not measure device presentation or smoothness. */
class BrowserMotionDeviceTest {
    @get:Rule val compose = createComposeRule()

    @Test fun sideShadowsRemainOutsideTheOriginalTouchBoundsDuringTransientGroupOpacity() {
        fixture { browser, _ ->
            compose.mainClock.autoAdvance = false
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val density = context.resources.displayMetrics.density
            val folder = File(context.getExternalFilesDir(null), "instrumentation/chrome-shadow-controlled").apply { mkdirs() }
            val frames = JSONArray()
            fun bounds(tag: String) = compose.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            val originalBack = bounds("browser.chrome.back")
            val originalStack = bounds("browser.chrome.stack")
            assertEquals(48f, originalBack.width / density, 0.2f)
            assertEquals(48f, originalStack.width / density, 0.2f)
            assertEquals(50f, originalBack.center.x / density, 0.5f)
            assertEquals(compose.onRoot().fetchSemanticsNode().boundsInRoot.width / density - 50f,
                originalStack.center.x / density, 0.5f)
            try {
                compose.runOnIdle { browser.pageChanged("motion-tab", browser.state.value.page.copy(scrollY = 120f, userScrollY = 120f)) }
                compose.mainClock.advanceTimeBy(400)
                compose.runOnIdle { browser.pageChanged("motion-tab", browser.state.value.page.copy(scrollY = 100f, userScrollY = 100f)) }
                var sampled = 0
                repeat(24) { index ->
                    compose.mainClock.advanceTimeByFrame()
                    val capsule = bounds("browser.chrome.capsule")
                    val progress = ((48f - capsule.height / density) / 17f).coerceIn(0f, 1f)
                    if (progress > 0.15f && progress < 0.85f) {
                        val image = compose.onRoot().captureToImage()
                        val pixels = image.toPixelMap()
                        val row = JSONObject().put("clockMillis", compose.mainClock.currentTime).put("foldProgress", progress.toDouble())
                        frames.put(row)
                        File(folder, "${index.toString().padStart(2, '0')}.png").outputStream().use {
                            assertTrue(image.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it))
                        }
                        for ((side, original, sign) in listOf(Triple("back", originalBack, 1), Triple("stack", originalStack, -1))) {
                            val touch = bounds("browser.chrome.$side")
                            val fade = bounds("browser.chrome.$side.fade")
                            val scale = 1f - progress * 0.2f
                            assertEquals("$side touch size changed", 48f * scale, touch.width / density, 0.6f)
                            assertEquals("$side touch moved with the shadow outset", original.center.x + sign * 26f * progress * density, touch.center.x, density * 0.6f)
                            assertEquals("$side vertical placement changed", original.center.y, touch.center.y, density * 0.5f)
                            assertTrue("$side fade layer still clips at the button edge", fade.bottom - touch.bottom >= 10f * scale * density)
                            var shadow = 0
                            val left = (touch.center.x - 6f * density).toInt().coerceAtLeast(0)
                            val right = (touch.center.x + 6f * density).toInt().coerceAtMost(pixels.width)
                            val top = kotlin.math.ceil(touch.bottom + 0.5f * density).toInt()
                            val bottom = kotlin.math.ceil(touch.bottom + 2.5f * density).toInt().coerceAtMost(pixels.height)
                            for (y in top until bottom) for (x in left until right) {
                                val color = pixels[x, y]
                                if (color.red < 0.998f && color.green < 0.998f && color.blue < 0.998f) shadow++
                            }
                            row.put(side, JSONObject().put("touch", JSONArray(listOf(touch.left, touch.top, touch.width, touch.height)))
                                .put("fade", JSONArray(listOf(fade.left, fade.top, fade.width, fade.height))).put("shadowPixels", shadow))
                            assertTrue("$side transient shadow is cut off outside the original 48 dp touch rectangle", shadow >= 3)
                        }
                        sampled++
                    }
                }
                assertTrue("No group-opacity transient frames were checked", sampled >= 3)
                assertEquals(originalBack.width, bounds("browser.chrome.back").width, density * 0.2f)
                assertEquals(originalStack.center.x, bounds("browser.chrome.stack").center.x, density * 0.2f)
            } finally {
                File(folder, "frames.json").writeText(JSONObject().put("clockKind", "compose-controlled")
                    .put("presentedFrameProof", false).put("physicalDeviceSmoothnessVerified", false).put("frames", frames).toString(2))
                compose.mainClock.autoAdvance = true
            }
        }
    }

    @Test fun chromeFoldsContinuouslyAndAReverseKeepsTheCurrentPose() {
        fixture { browser, reduce ->
            compose.mainClock.autoAdvance = false
            val frames = JSONArray()
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val folder = File(context.getExternalFilesDir(null), "instrumentation/motion-controlled").apply { mkdirs() }
            val density = context.resources.displayMetrics.density
            fun sample(label: String, image: Boolean = true): Float {
                val draw = compose.onNodeWithTag("browser.chrome.capsule", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val touch = compose.onNodeWithTag("browser.chrome.plate", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                frames.put(JSONObject().put("label", label).put("clockMillis", compose.mainClock.currentTime)
                    .put("capsule", JSONArray(listOf(draw.left / density, draw.top / density, draw.width / density, draw.height / density)))
                    .put("touchHeight", touch.height / density))
                if (image) File(folder, "${frames.length().toString().padStart(3, '0')}.png").outputStream().use {
                    compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                assertTrue("The mounted plate lost its touch height", touch.height / density >= 47f)
                return draw.width / density
            }
            try {
                val open = sample("open")
                compose.runOnIdle { browser.pageChanged("motion-tab", browser.state.value.page.copy(scrollY = 120f)) }
                repeat(4) { compose.mainClock.advanceTimeByFrame() }
                assertEquals("DOM/programmatic scrolling cannot fold Chrome", open, sample("programmatic-scroll"), 1f)
                compose.runOnIdle { browser.pageChanged("motion-tab", browser.state.value.page.copy(scrollY = 120f, userScrollY = 120f)) }
                compose.mainClock.advanceTimeByFrame()
                repeat(6) { compose.mainClock.advanceTimeByFrame(); sample("fold-$it") }
                val halfway = sample("before-reverse", image = false)
                assertTrue("No intermediate fold pose was drawn", halfway < open - 1f && halfway > 62f)
                compose.runOnIdle { browser.pageChanged("motion-tab", browser.state.value.page.copy(scrollY = 100f, userScrollY = 100f)) }
                compose.mainClock.advanceTimeByFrame()
                val reverse = sample("reverse")
                assertTrue("Reversing snapped straight to the unfolded pose", reverse < open - 1f)
                assertTrue("Reversing jumped more than a frame", kotlin.math.abs(reverse - halfway) < 24f)
                repeat(20) { compose.mainClock.advanceTimeByFrame(); sample("unfold-$it", image = it % 2 == 0) }
                assertEquals(open, sample("unfolded"), 1f)
                compose.runOnIdle { browser.pageChanged("motion-tab", browser.state.value.page.copy(scrollY = 200f, userScrollY = 200f)) }
                compose.mainClock.advanceTimeBy(400)
                val folded = compose.onNodeWithTag("browser.chrome.capsule", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                assertEquals(31f, folded.height / density, 1f)
                assertTrue("Folded capsule did not hug its words", sample("folded") <= 159f)
                val labelLayouts = mutableListOf<TextLayoutResult>()
                compose.onNodeWithTag("browser.chrome.label", useUnmergedTree = true)
                    .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { action -> assertTrue(action(labelLayouts)) }
                assertTrue("No actual folded label layout", labelLayouts.isNotEmpty())
                assertFalse("A short native host was ellipsized by a differently styled width measurement",
                    labelLayouts.last().hasVisualOverflow)
                // Change the app input only. The device's actual animator setting is untouched.
                compose.runOnIdle { reduce.value = true; browser.pageChanged("motion-tab", browser.state.value.page.copy(scrollY = 180f, userScrollY = 180f)) }
                // Allow the state collector, direction effect and animation target to
                // consume the input. The controlled scheduler is not a presentation clock.
                repeat(4) { compose.mainClock.advanceTimeByFrame() }
                assertEquals(open, sample("reduced-unfold"), 1f)
                compose.mainClock.advanceTimeByFrame()
                assertEquals(open, sample("reduced-unfold-stable", image = false), 1f)
            } finally {
                File(folder, "frames.json").writeText(JSONObject().put("schemaVersion", 1)
                    .put("clockKind", "compose-controlled").put("presentedFrameProof", false)
                    .put("frames", frames).toString(2))
                compose.mainClock.autoAdvance = true
            }
        }
    }

    private fun fixture(block: (BrowserController, androidx.compose.runtime.MutableState<Boolean>) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("motion-tab", "https://motion.test", createdAt = 1)
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("motion-space", "Motion", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "motion-space")
        val repository = object : BrowserRepository {
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}
            override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}
            override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(repository, engine, scope)
        val reduced = mutableStateOf(false)
        try {
            compose.setContent {
                CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduceMotion = reduced.value)) {
                    BrowserScreen(browser) { _, _, modifier -> Box(modifier.fillMaxSize().background(Color.White)) }
                }
            }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.waitForIdle()
            block(browser, reduced)
        } finally { scope.cancel() }
    }
}

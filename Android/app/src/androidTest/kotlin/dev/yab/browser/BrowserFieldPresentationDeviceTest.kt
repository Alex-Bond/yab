package dev.yab.browser

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject

/** Controlled Compose presentation and supplied-inset proof, not OS IME or presented-frame parity. */
class BrowserFieldPresentationDeviceTest {
    @get:Rule val compose = createComposeRule()

    @Test fun anInterruptedCloseRetainsItsPoseAndTheOldCompletionCannotRemoveAReopenedField() {
        fixture { browser, _ ->
            compose.mainClock.autoAdvance = false
            val frames = JSONArray()
            var completed = false
            data class Sample(val progress: Float, val closing: Boolean, val pill: List<Float>)
            fun mark(phase: String) {
                frames.put(JSONObject().put("phase", phase).put("clockMillis", compose.mainClock.currentTime))
            }
            fun sample(phase: String): Sample {
                val beforeClock = compose.mainClock.currentTime
                val config = compose.onNodeWithTag("browser.field.motion").fetchSemanticsNode().config
                val pill = config[FieldPillPoseKey]
                assertEquals(4, pill.size)
                assertTrue(pill.all(Float::isFinite))
                frames.put(JSONObject().put("phase", phase).put("clockBeforeMillis", beforeClock)
                    .put("clockAfterMillis", compose.mainClock.currentTime).put("progress", config[FieldProgressKey].toDouble())
                    .put("closing", config[FieldClosingKey]).put("pillDp", JSONArray(pill)))
                return Sample(config[FieldProgressKey], config[FieldClosingKey], pill.toList())
            }
            try {
                mark("before-open-dispatch")
                compose.runOnIdle { browser.openField(newTab = false) }
                mark("after-open-dispatch")
                repeat(6) { compose.mainClock.advanceTimeByFrame() }
                val before = sample("opening-six-frames")
                assertTrue(before.progress > 0f && before.progress < 1f)
                val epoch = browser.state.value.surfaceEpoch
                compose.runOnIdle { assertTrue(browser.dismissField(epoch)) }
                mark("after-close-dispatch")
                repeat(3) { compose.mainClock.advanceTimeByFrame() }
                val closing = sample("closing-three-frames")
                assertTrue(closing.progress < before.progress)
                assertTrue(closing.closing)
                // Retained words cannot expose an editor or actions to accessibility after logical close.
                compose.onNodeWithTag("browser.field.input").assertDoesNotExist()
                mark("before-reopen-dispatch")
                compose.runOnIdle { browser.openField(newTab = false) }
                mark("after-reopen-dispatch")
                compose.mainClock.advanceTimeByFrame()
                val reversed = sample("reopened-one-frame")
                // The shared scalar may finish an old-close clock step while the
                // new effect awaits its frame. The retained segment owns the
                // drawn shape, so compare its actual consumer geometry.
                assertFalse(reversed.closing)
                for (axis in 0..3) assertEquals("Reopening changed retained pill coordinate $axis",
                    closing.pill[axis], reversed.pill[axis], .001f)
                compose.mainClock.advanceTimeBy(500)
                compose.waitForIdle()
                val settled = sample("reopened-rest")
                assertEquals(1f, settled.progress, .0001f)
                assertFalse(settled.closing)
                val motionBounds = compose.onNodeWithTag("browser.field.motion").fetchSemanticsNode().boundsInRoot
                val inputBounds = compose.onNodeWithTag("browser.field.pill").fetchSemanticsNode().boundsInRoot
                val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
                val target = listOf((inputBounds.left - motionBounds.left) / density,
                    (inputBounds.top - motionBounds.top) / density, inputBounds.width / density, inputBounds.height / density)
                for (axis in 0..3) assertEquals("Reopened pill did not settle at input coordinate $axis",
                    target[axis], settled.pill[axis], 1.01f / density)
                compose.onNodeWithTag("browser.field.input").assertIsEnabled()
                assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
                compose.runOnIdle { assertFalse(browser.dismissField(epoch)) }
                completed = true
            } finally {
                try {
                    val folder = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null),
                        "instrumentation/field-controlled").apply { check(mkdirs() || isDirectory) }
                    folder.resolve("interrupted-reopen.json").writeText(JSONObject().put("schema", 1)
                        .put("clockKind", "compose-controlled").put("bodyCompleted", completed)
                        .put("presentedFrameParityVerified", false).put("samples", frames).toString(2))
                } finally { compose.mainClock.autoAdvance = true }
            }
        }
    }

    @Test fun suppliedKeyboardChangesRestTheSameDraftAndOwnerReplacementDropsPrivateExitContentImmediately() {
        fixture(directHost = true) { browser, keyboard ->
            compose.runOnIdle { browser.openField(); browser.fieldText("owned draft") }
            compose.waitForIdle()
            val raised = compose.onNodeWithTag("browser.field.pill").fetchSemanticsNode().boundsInRoot.bottom
            compose.runOnIdle { browser.restField(browser.state.value.surfaceEpoch) }
            compose.waitForIdle()
            val resting = compose.onNodeWithTag("browser.field.pill").fetchSemanticsNode().boundsInRoot.bottom
            val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
            assertEquals((302f - 32f) * density, resting - raised, 2f)
            assertEquals("owned draft", browser.state.value.fieldText)
            compose.runOnIdle { keyboard.value = 350.0; browser.restField(browser.state.value.surfaceEpoch, false) }
            compose.waitForIdle()
            val taller = compose.onNodeWithTag("browser.field.pill").fetchSemanticsNode().boundsInRoot.bottom
            assertEquals(48f * density, raised - taller, 2f)
            compose.runOnIdle { browser.openField(privately = true); browser.fieldText("PRIVATE-FIELD-CANARY") }
            compose.waitForIdle()
            compose.onNodeWithTag("browser.field.input").assertTextContains("PRIVATE-FIELD-CANARY")
            compose.runOnIdle { browser.invalidateLocalOwnership() }
            compose.waitForIdle()
            compose.onNodeWithTag("browser.field.motion").assertDoesNotExist()
            compose.onNodeWithText("PRIVATE-FIELD-CANARY").assertDoesNotExist()
            assertEquals("", browser.state.value.fieldText)
        }
    }

    private fun progress() = compose.onNodeWithTag("browser.field.motion").fetchSemanticsNode().config[FieldProgressKey]

    private fun fixture(directHost: Boolean = false, block: (BrowserController, MutableState<Double>) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("field-presentation-tab", "https://field-presentation.example/", createdAt = 1)
        val repository = object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("field-presentation-space", "Field",
                tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "field-presentation-space")
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
        val keyboard = mutableStateOf(302.0)
        try {
            compose.setContent {
                CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences()) {
                    if (!directHost) BrowserScreen(browser) { _, _, modifier -> Box(modifier.fillMaxSize().background(Color.White)) }
                    else {
                        val state by browser.state.collectAsState()
                        Box(Modifier.requiredSize(402.dp, 874.dp)) {
                            val host = rememberBrowserFieldHost(state, browser, true, 402.0, 874.0, null, null, null)
                            if (host != null) BrowserFieldHost(state, browser, host, 402.0, 874.0, keyboard.value, false, {}) { retained, motion ->
                                BrowserField(retained, browser, false, null, null, null, null, fieldPresentation = motion)
                            }
                        }
                    }
                }
            }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.waitForIdle()
            block(browser, keyboard)
        } finally { scope.cancel() }
    }
}

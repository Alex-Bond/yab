package dev.yab.browser

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.runtime.CompositionLocalProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real BrowserScreen consumers and touch dispatch under a controlled clock, never smoothness proof. */
class BrowserSpacesDeviceTest {
    @get:Rule val compose = createComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val inputs = CopyOnWriteArrayList<BrowserSpacesInputFrame>()

    @Test fun measuredOriginIsRetainedAndAnActualVerticalFingerCanReverseAClosingCard() {
        fixture { browser ->
            compose.mainClock.autoAdvance = false
            val density = instrumentation.targetContext.resources.displayMetrics.density
            val original = compose.onNodeWithTag("browser.chrome.capsule", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            val frames = JSONArray()
            fun sample(label: String): Float {
                val node = compose.onNodeWithTag("browser.spaces.motion").fetchSemanticsNode()
                val reveal = node.config[SpacesRevealKey]
                val origin = node.config[SpacesOriginKey]
                assertEquals(4, origin.size)
                assertEquals(original.left / density, origin[0], 1f); assertEquals(original.top / density, origin[1], 1f)
                assertEquals(original.width / density, origin[2], 1f); assertEquals(original.height / density, origin[3], 1f)
                frames.put(JSONObject().put("label", label).put("reveal", reveal.toDouble())
                    .put("clockMillis", compose.mainClock.currentTime).put("origin", JSONArray(origin)))
                return reveal
            }
            try {
                compose.runOnIdle { browser.show(BrowserSurface.SPACES) }
                repeat(4) { compose.mainClock.advanceTimeByFrame() }
                var previous = sample("opening")
                repeat(20) { compose.mainClock.advanceTimeByFrame(); val next = sample("open-$it"); assertTrue(next >= previous); previous = next }
                repeat(100) { compose.mainClock.advanceTimeByFrame() }
                assertEquals(1f, sample("open"), 0.0001f)
                val capsule = compose.onNodeWithTag("browser.spaces.capsule").fetchSemanticsNode().boundsInRoot
                record("01-spaces-open")
                compose.onNodeWithContentDescription("Close").performClick()
                compose.runOnIdle { assertEquals(BrowserSurface.SPACES, browser.state.value.surface) }
                repeat(5) { compose.mainClock.advanceTimeByFrame() }
                val closing = sample("closing")
                assertTrue(closing in 0f..0.99f)
                val lift = requireNotNull(BrowserSpacesLiftFrame.at(closing.toDouble(),
                    compose.onRoot().fetchSemanticsNode().boundsInRoot.width / density.toDouble(),
                    compose.onRoot().fetchSemanticsNode().boundsInRoot.height / density.toDouble(),
                    SpacesRect(original.left / density.toDouble(), original.top / density.toDouble(), original.width / density.toDouble(), original.height / density.toDouble())))
                val start = capsule.center + Offset(0f, (lift.drop * density).toFloat())
                frames.put(JSONObject().put("label", "regrab-input").put("startPx", JSONArray(listOf(start.x, start.y)))
                    .put("expectedDropDp", lift.drop).put("clockMillis", compose.mainClock.currentTime))
                record("01a-closing-before-regrab")
                val inputStart = inputs.size
                compose.onRoot().performTouchInput {
                    down(start); advanceEventTime(16); moveTo(start + Offset(0f, -50f * density))
                }
                compose.mainClock.advanceTimeByFrame()
                val firstMove = inputs.drop(inputStart)
                val down = firstMove.single { it.kind == "capsule-down" }
                val moved = firstMove.single { it.kind == "capsule-vertical-move" }
                val beforeMove = firstMove.single { it.kind == "lower-before-move" }
                val afterMove = firstMove.single { it.kind == "lower-after-move" }
                assertEquals(start.x.toDouble(), down.x, 1.0); assertEquals(start.y.toDouble(), down.y, 1.0)
                assertEquals(-50.0, moved.dy, 0.01)
                assertEquals(moved.dy, beforeMove.dy, 0.0); assertEquals(moved.dy, afterMove.dy, 0.0)
                assertTrue("The actual upward MOVE did not increase its own interrupted pose", afterMove.reveal > beforeMove.reveal)
                assertTrue("The held pointer ended before its reversal could be inspected", firstMove.none {
                    it.kind in setOf("capsule-up", "capsule-cancel", "lower-before-end")
                })
                frames.put(JSONObject().put("label", "same-move-reversal").put("beforeReveal", beforeMove.reveal)
                    .put("afterReveal", afterMove.reveal).put("dyDp", moved.dy))
                // Semantics/screenshots can advance a closing controlled clock
                // between the earlier sample and input dispatch. Compare this
                // MOVE with its own live before/after pose, then prove it holds.
                assertEquals(afterMove.reveal.toFloat(), sample("held-regrab"), 0.0001f)
                repeat(2) { compose.mainClock.advanceTimeByFrame(); assertEquals(afterMove.reveal.toFloat(), sample("held-regrab-$it"), 0.0001f) }
                record("01b-held-regrab")
                // A slow release below .75 closes in the actual Phone model.
                // The old fixed -130 dp left this viewport at .649, so expecting
                // an open destination was wrong. Finish the same real pointer
                // above the source threshold and pause to avoid relying on a fling.
                val measuredSpan = -moved.dy / (afterMove.reveal - beforeMove.reveal)
                val reopenDy = moved.dy - (.90 - afterMove.reveal) * measuredSpan
                val releasePoint = start + Offset(0f, (reopenDy * density).toFloat())
                assertTrue("The source-matching reopen drag left the fixture viewport", releasePoint.y > 0)
                frames.put(JSONObject().put("label", "reopen-input").put("targetReveal", .90)
                    .put("cumulativeDyDp", reopenDy).put("measuredLiftSpanDp", measuredSpan))
                val releaseStart = inputs.size
                compose.onRoot().performTouchInput {
                    advanceEventTime(16); moveTo(releasePoint)
                    advanceEventTime(200); moveTo(releasePoint)
                    advanceEventTime(8); up()
                }
                val release = inputs.drop(releaseStart).single { it.kind == "lower-before-end" }
                assertTrue("The genuine slow release did not reach the Phone reopen threshold", release.reveal > .75)
                assertTrue("The positional reopen unexpectedly depended on fling velocity", kotlin.math.abs(release.velocity) < 600)
                repeat(120) { compose.mainClock.advanceTimeByFrame() }
                assertEquals(1f, sample("reversed-open"), 0.0001f)
                compose.runOnIdle { assertEquals(BrowserSurface.SPACES, browser.state.value.surface) }
                record("02-canceled-fold-reopened")
                val cancelStart = inputs.size
                compose.onNodeWithTag("browser.spaces.capsule").performTouchInput {
                    down(center); advanceEventTime(16); moveBy(Offset(0f, 40f * density)); cancel()
                }
                repeat(120) { compose.mainClock.advanceTimeByFrame() }
                assertEquals(1f, sample("explicit-cancel-reopened"), 0.0001f)
                val cancelled = inputs.drop(cancelStart)
                assertTrue("The actual cancellation was mistaken for a release", cancelled.any { it.kind == "capsule-cancel" })
                assertTrue("A cancelled finger committed the lower gesture", cancelled.none { it.kind == "lower-before-end" })
                compose.onNodeWithContentDescription("Close").performClick()
                repeat(120) { compose.mainClock.advanceTimeByFrame() }
                compose.runOnIdle { assertEquals(BrowserSurface.PAGE, browser.state.value.surface) }
                compose.onNodeWithTag("browser.spaces.motion").assertDoesNotExist()
                record("03-fold-landed")
            } finally {
                folder().resolve("controlled-frames.json").writeText(JSONObject().put("clockKind", "compose-controlled")
                    .put("presentedFrameProof", false).put("physicalDeviceSmoothnessVerified", false).put("frames", frames).toString(2))
                folder().resolve("reversal-inputs.json").writeText(JSONArray(inputs.map { value -> JSONObject()
                    .put("kind", value.kind).put("xPx", value.x).put("yPx", value.y).put("dyDp", value.dy)
                    .put("velocityDpPerSecond", value.velocity).put("reveal", value.reveal) }).toString(2))
                compose.mainClock.autoAdvance = true
            }
        }
    }

    @Test fun theNativeLensOpensTheActualAboutRouteAndReplacementDropsTheOldSource() {
        fixture { browser ->
            compose.runOnIdle { browser.show(BrowserSurface.SPACES) }
            compose.onNodeWithTag("browser.spaces.name.5", useUnmergedTree = true).assertDoesNotExist()
            val actions = compose.onNodeWithContentDescription("Spaces").fetchSemanticsNode().config[SemanticsActions.CustomActions]
            compose.runOnIdle { assertTrue(actions.single { it.label == "Switch to Planning" }.action()) }
            compose.runOnIdle { assertEquals("spaces-e", browser.state.value.selectedSpaceId) }
            compose.onNodeWithContentDescription("About Yab").performClick()
            compose.onNodeWithTag("settings.header").assertIsDisplayed()
            compose.onNodeWithTag("settings.hero.title").assertTextEquals("About").assertIsDisplayed()
            compose.onNodeWithTag("browser.spaces.motion").assertDoesNotExist()
            record("04-lens-opens-about")
            compose.waitUntil(5_000) {
                compose.onNodeWithTag("settings.motion").fetchSemanticsNode().config[SettingsPhaseKey] == SettingsPhase.OPEN.name
            }
            // A direct About entry is its own sheet root, as in
            // SettingsPresentationTest. The page's Back remains underneath it.
            compose.onNode(hasContentDescription("Close") and hasAnyAncestor(hasTestTag("settings.header")),
                useUnmergedTree = true).performClick()
            compose.waitUntil(5_000) {
                compose.onAllNodesWithTag("settings.motion").fetchSemanticsNodes().isEmpty()
            }
            compose.runOnIdle { assertEquals(BrowserSurface.PAGE, browser.state.value.surface) }
            compose.runOnIdle { browser.show(BrowserSurface.SPACES); browser.openField(privately = true) }
            compose.onNodeWithTag("browser.spaces.motion").assertDoesNotExist()
            compose.runOnIdle { assertTrue(browser.state.value.fieldIsPrivate) }
        }
    }
    @Test fun accountRevocationDropsThePreviouslyDrawnSourceInTheNextControlledFrame() {
        fixture { browser ->
            compose.mainClock.autoAdvance = false
            try {
                compose.runOnIdle { browser.show(BrowserSurface.SPACES) }
                repeat(40) { compose.mainClock.advanceTimeByFrame() }
                compose.onNodeWithTag("browser.spaces.motion").assertExists()
                record("05-before-account-revocation")
                compose.runOnIdle { browser.invalidateLocalOwnership() }
                compose.mainClock.advanceTimeByFrame()
                compose.onNodeWithTag("browser.spaces.motion").assertDoesNotExist()
                compose.runOnIdle { assertEquals(BrowserSurface.PAGE, browser.state.value.surface); assertEquals("", browser.state.value.fieldText) }
                record("06-next-controlled-frame-after-revocation")
            } finally { compose.mainClock.autoAdvance = true }
        }
    }
    @Test fun originalPlateFingerFollowsCancelsAndFoldedHorizontalNeverChangesPages() {
        fixture { browser ->
            compose.mainClock.autoAdvance = false
            val density = instrumentation.targetContext.resources.displayMetrics.density
            fun plate() = compose.onNodeWithTag("browser.chrome.plate", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.center
            try {
                val short = plate()
                compose.onRoot().performTouchInput { down(short); advanceEventTime(16); moveTo(short + Offset(0f, -20f * density)); cancel() }
                repeat(140) { compose.mainClock.advanceTimeByFrame() }
                compose.runOnIdle { assertEquals(BrowserSurface.PAGE, browser.state.value.surface) }
                compose.onNodeWithTag("browser.spaces.motion").assertDoesNotExist()
                record("07-short-original-lift-canceled")
                val start = plate()
                val viewport = compose.onRoot().fetchSemanticsNode().boundsInRoot.height
                val heldDistance = minOf(80f * density, viewport * 0.1f)
                compose.onRoot().performTouchInput { down(start); advanceEventTime(32); moveTo(start + Offset(0f, -heldDistance)) }
                repeat(4) { compose.mainClock.advanceTimeByFrame() }
                val held = compose.onNodeWithTag("browser.spaces.motion").fetchSemanticsNode().config[SpacesRevealKey]
                assertTrue("Card did not follow the held finger: $held", held > 0.01f && held < 0.25f)
                record("08-held-original-lift")
                compose.onRoot().performTouchInput { moveTo(start + Offset(0f, -viewport * 0.5f)); advanceEventTime(300); up() }
                repeat(140) { compose.mainClock.advanceTimeByFrame() }
                assertEquals(1f, compose.onNodeWithTag("browser.spaces.motion").fetchSemanticsNode().config[SpacesRevealKey], 0.0001f)
                compose.onNodeWithContentDescription("Close").performClick()
                repeat(140) { compose.mainClock.advanceTimeByFrame() }
                compose.runOnIdle { browser.pageChanged("spaces-tab", browser.state.value.page.copy(scrollY = 150f, userScrollY = 150f)) }
                compose.mainClock.advanceTimeBy(500)
                val capsule = compose.onNodeWithTag("browser.chrome.capsule", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                assertEquals(31f, capsule.height / density, 1f)
                val epoch = browser.state.value.surfaceEpoch
                val folded = plate()
                compose.onRoot().performTouchInput { down(folded); advanceEventTime(32); moveTo(folded + Offset(-90f * density, 0f)); advanceEventTime(300); up() }
                repeat(4) { compose.mainClock.advanceTimeByFrame() }
                compose.runOnIdle { assertEquals(BrowserSurface.PAGE, browser.state.value.surface); assertEquals(epoch, browser.state.value.surfaceEpoch); assertEquals("spaces-tab", browser.state.value.tab?.id) }
                record("09-folded-horizontal-suppressed")
            } finally { compose.mainClock.autoAdvance = true }
        }
    }
    private fun folder() = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/spaces-controlled").apply { mkdirs() }
    private fun record(name: String) {
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { folder().resolve("$name.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        folder().resolve("$name-semantics.txt").writeText(compose.onRoot(useUnmergedTree = true).printToString())
    }
    private fun fixture(block: (BrowserController) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("spaces-tab", "https://owned.test/article", createdAt = 1)
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("spaces-a", "Ordinary", color = 0xFFEEE9E2, tabs = listOf(tab), currentTabId = tab.id),
            BrowserSpace("spaces-b", "Research", color = 0xFFE3EAF3), BrowserSpace("spaces-c", "Writing"),
            BrowserSpace("spaces-d", "Reading"), BrowserSpace("spaces-e", "Planning")), selectedSpaceId = "spaces-a")
        val repository = object : BrowserRepository { override suspend fun load() = snapshot; override suspend fun save(snapshot: BrowserSnapshot) {} }
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}; override fun goForward(tabId: String) {}; override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}; override fun close(tabId: String) {}; override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(repository, engine, scope)
        try {
            compose.setContent { CompositionLocalProvider(LocalBrowserSpacesInputObserver provides { frame -> if (inputs.size < 256) inputs.add(frame) }) {
                BrowserScreen(browser) { _, _, modifier -> Box(modifier.fillMaxSize().background(Color.White)) }
            } }
            compose.waitUntil(10_000) { !browser.state.value.loading }; compose.waitForIdle()
            block(browser)
        } finally { scope.cancel() }
    }
}

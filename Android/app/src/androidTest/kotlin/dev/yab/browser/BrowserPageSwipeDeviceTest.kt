package dev.yab.browser

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import dev.yab.browser.engine.PagingCaptureResult
import dev.yab.browser.engine.PagingCaptureOutcome
import dev.yab.browser.engine.PagingFrame
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual chrome touch, page-slot lifetime and controller handoff under a controlled Compose clock.
 * The page bodies are composable fixtures, not a Gecko compositor/performance acceptance claim. */
class BrowserPageSwipeDeviceTest {
    @get:Rule val compose = createComposeRule()
    private val density get() = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density

    @Test fun liveCardsFollowTheFingerAndCancellationCannotCommitBeyondTheThreshold() {
        fixture { f ->
            compose.mainClock.autoAdvance = false
            try {
                val front = f.browser.state.value.tab!!.id
                val before = pagePosition("front")
                drag(-250f)
                compose.mainClock.advanceTimeByFrame()
                val moving = pagePosition("front")
                assertEquals(-250f, moving[0] - before[0], 1f)
                val pose = pose()
                assertEquals(-250f, pose[0], .5f)
                val next = pagePosition("after")
                assertEquals(pose[3], next[0] - before[0], 1f)
                assertEquals(front, f.browser.state.value.tab!!.id)
                compose.onNodeWithTag("browser.chrome.plate").performTouchInput { cancel() }
                compose.mainClock.advanceTimeBy(2000)
                compose.waitForIdle()
                assertEquals(front, f.browser.state.value.tab!!.id)
                assertFalse(compose.onNodeWithTag("browser.paging.deck", useUnmergedTree = true).fetchSemanticsNode().config.contains(PageSwipePhaseKey))
                assertEquals(1, f.instances[front])
            } finally { compose.mainClock.autoAdvance = true }
        }
    }

    @Test fun committingTheVisibleNeighborRetainsItsActualCompositionAndGateRevocationCancelsAPendingTurn() {
        fixture { f ->
            compose.mainClock.autoAdvance = false
            try {
                val front = f.browser.state.value.tab!!.id
                val next = f.browser.state.value.space!!.tabs.last().id
                drag(-250f)
                compose.onNodeWithTag("browser.chrome.plate").performTouchInput { advanceEventTime(200); up() }
                compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
                assertEquals(next, f.browser.state.value.tab!!.id)
                assertEquals("The neighbor was destroyed and rebuilt when it became selected", 1, f.instances[next])
                drag(240f)
                compose.mainClock.advanceTimeByFrame()
                compose.runOnIdle { f.allowed.value = false }
                compose.mainClock.advanceTimeByFrame()
                assertFalse(compose.onNodeWithTag("browser.paging.deck", useUnmergedTree = true).fetchSemanticsNode().config.contains(PageSwipePhaseKey))
                compose.onNodeWithTag("browser.chrome.plate").performTouchInput { up() }
                compose.mainClock.advanceTimeBy(2000)
                assertEquals("A revoked turn changed selection", next, f.browser.state.value.tab!!.id)
                assertNotEquals(front, f.browser.state.value.tab!!.id)
            } finally { compose.mainClock.autoAdvance = true }
        }
    }

    @Test fun newTabLandsInPlaceAndItsCancelledFieldReturnsWhileTheFieldExitIsStillMounted() {
        fixture(twoPages = false) { f ->
            compose.mainClock.autoAdvance = false
            try {
                val front = f.browser.state.value.tab!!.id
                drag(-300f)
                compose.onNodeWithTag("browser.chrome.plate").performTouchInput { advanceEventTime(200); up() }
                compose.mainClock.advanceTimeBy(1000); compose.waitForIdle()
                assertEquals(BrowserSurface.FIELD, f.browser.state.value.surface)
                assertTrue(f.browser.state.value.fieldIsNewTab)
                assertTrue(f.browser.state.value.fieldInPlace)
                assertEquals(front, f.browser.state.value.tab!!.id)
                assertEquals(1, f.browser.state.value.space!!.tabs.size)
                assertEquals("BLANK", phase())
                compose.runOnIdle { f.browser.dismissField(f.browser.state.value.surfaceEpoch) }
                repeat(2) { compose.mainClock.advanceTimeByFrame() }
                assertEquals("SETTLING", phase())
                assertTrue(pose()[0] < 0)
                compose.onNodeWithTag("browser.field.motion").assertExists()
                compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
                assertEquals(BrowserSurface.PAGE, f.browser.state.value.surface)
                assertEquals(front, f.browser.state.value.tab!!.id)
                assertEquals(1, f.browser.state.value.space!!.tabs.size)
                assertFalse(compose.onNodeWithTag("browser.paging.deck", useUnmergedTree = true).fetchSemanticsNode().config.contains(PageSwipePhaseKey))
            } finally { compose.mainClock.autoAdvance = true }
        }
    }

    @Test fun reducedNeighborSelectionUsesAReadonlyCrossfadeAndAccountReplacementRemovesItImmediately() {
        fixture(reduced = true) { f ->
            compose.mainClock.autoAdvance = false
            try {
                val next = f.browser.state.value.space!!.tabs.last().id
                drag(-250f)
                compose.onNodeWithTag("browser.chrome.plate").performTouchInput { advanceEventTime(200); up() }
                repeat(3) { compose.mainClock.advanceTimeByFrame() }
                assertEquals(next, f.browser.state.value.tab!!.id)
                assertEquals("CROSSFADE", phase())
                assertEquals(1, f.instances[next])
                compose.runOnIdle { f.browser.invalidateLocalOwnership() }
                compose.mainClock.advanceTimeByFrame()
                assertFalse(compose.onNodeWithTag("browser.paging.deck", useUnmergedTree = true).fetchSemanticsNode().config.contains(PageSwipePhaseKey))
                compose.mainClock.advanceTimeBy(500)
                assertEquals(next, f.browser.state.value.tab!!.id)
            } finally { compose.mainClock.autoAdvance = true }
        }
    }

    @Test fun dismissingTheOwnedBlankDuringItsReducedLandingCannotLeaveAnOldFadeMounted() {
        fixture(twoPages = false, reduced = true) { f ->
            compose.mainClock.autoAdvance = false
            try {
                val front = f.browser.state.value.tab!!.id
                drag(-250f)
                compose.onNodeWithTag("browser.chrome.plate").performTouchInput { advanceEventTime(200); up() }
                repeat(3) { compose.mainClock.advanceTimeByFrame() }
                assertEquals(BrowserSurface.FIELD, f.browser.state.value.surface)
                assertEquals("CROSSFADE", phase())
                compose.runOnIdle { f.browser.dismissField(f.browser.state.value.surfaceEpoch) }
                repeat(3) { compose.mainClock.advanceTimeByFrame() }
                assertFalse(compose.onNodeWithTag("browser.paging.deck", useUnmergedTree = true).fetchSemanticsNode().config.contains(PageSwipePhaseKey))
                compose.mainClock.advanceTimeBy(500); compose.waitForIdle()
                assertEquals(BrowserSurface.PAGE, f.browser.state.value.surface)
                assertEquals(front, f.browser.state.value.tab!!.id)
                assertEquals(1, f.browser.state.value.space!!.tabs.size)
                assertEquals(1, f.instances[front])
            } finally { compose.mainClock.autoAdvance = true }
        }
    }

    @Test fun reducedCancellationUsesTheLeasedOldPoseAndNeverCreatesAnotherSelectedPage() {
        fixture(reduced = true, frameFixture = true) { f ->
            compose.mainClock.autoAdvance = false
            try {
                val selected = f.browser.state.value.tab!!.id
                drag(-100f)
                compose.onNodeWithTag("browser.chrome.plate").performTouchInput { cancel() }
                repeat(3) { compose.mainClock.advanceTimeByFrame() }
                assertEquals("CROSSFADE", phase())
                assertEquals("READY", captureOutcome())
                compose.onNodeWithTag("browser.paging.ram-frame", useUnmergedTree = true).assertExists()
                assertEquals(selected, f.browser.state.value.tab!!.id)
                compose.mainClock.advanceTimeBy(100)
                compose.onNodeWithTag("browser.paging.ram-frame", useUnmergedTree = true).assertExists()
                compose.mainClock.advanceTimeBy(300); compose.waitForIdle()
                compose.onNodeWithTag("browser.paging.ram-frame", useUnmergedTree = true).assertDoesNotExist()
                assertEquals(selected, f.browser.state.value.tab!!.id)
                assertEquals(1, f.instances[selected])
            } finally { compose.mainClock.autoAdvance = true }
        }
    }

    @Test fun aLateUncancellableCaptureCannotReappearAfterAnAccountOwnerReplacement() {
        val pending = CompletableDeferred<PagingCaptureResult>()
        fixture(reduced = true, capture = { withContext(NonCancellable) { pending.await() } }) { f ->
            compose.mainClock.autoAdvance = false
            val frame = PagingFrame(Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888), { true })
            try {
                drag(-100f)
                compose.onNodeWithTag("browser.chrome.plate").performTouchInput { cancel() }
                repeat(3) { compose.mainClock.advanceTimeByFrame() }
                assertEquals("CAPTURE_PENDING", phase())
                compose.runOnIdle { f.browser.invalidateLocalOwnership() }
                repeat(2) { compose.mainClock.advanceTimeByFrame() }
                compose.runOnIdle { pending.complete(PagingCaptureResult(PagingCaptureOutcome.READY, frame)) }
                repeat(3) { compose.mainClock.advanceTimeByFrame() }
                compose.onNodeWithTag("browser.paging.ram-frame", useUnmergedTree = true).assertDoesNotExist()
                assertNull("The cancelled UI callback retained its published pixels", frame.bitmapIfCurrent())
                assertNotEquals("READY", captureOutcome())
            } finally { pending.complete(PagingCaptureResult(PagingCaptureOutcome.REVOKED)); frame.close(); compose.mainClock.autoAdvance = true }
        }
    }

    private fun pagePosition(role: String): List<Float> = compose.onNodeWithTag("browser.paging.page.$role", useUnmergedTree = true)
        .fetchSemanticsNode().config[PageSwipePagePositionKey].also { assertEquals(4, it.size) }
    private fun phase() = compose.onNodeWithTag("browser.paging.deck", useUnmergedTree = true).fetchSemanticsNode().config[PageSwipePhaseKey]
    private fun pose() = compose.onNodeWithTag("browser.paging.deck", useUnmergedTree = true).fetchSemanticsNode().config[PageSwipePoseKey]
    private fun captureOutcome() = compose.onNodeWithTag("browser.paging.deck", useUnmergedTree = true).fetchSemanticsNode().config[PageSwipeCaptureKey]
    private fun drag(dx: Float) {
        compose.onNodeWithTag("browser.chrome.plate").performTouchInput {
            down(center); advanceEventTime(16); moveBy(Offset(dx * density, 0f))
        }
        repeat(2) { compose.mainClock.advanceTimeByFrame() }
    }
    private class Fixture(val browser: BrowserController, val allowed: MutableState<Boolean>, val instances: ConcurrentHashMap<String, Int>)
    private fun fixture(twoPages: Boolean = true, reduced: Boolean = false, frameFixture: Boolean = false,
        capture: (suspend (PageSwipeLease) -> PagingCaptureResult)? = null, block: (Fixture) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val first = BrowserTab("paging-first", "https://paging-first.example/", title = "Paging first", createdAt = 1)
        val after = BrowserTab("paging-after", "https://paging-after.example/", title = "Paging after", createdAt = 1)
        val repository = object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("paging-space", "Paging",
                tabs = if (twoPages) listOf(first, after) else listOf(first), currentTabId = first.id)), selectedSpaceId = "paging-space")
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
        val fixture = Fixture(browser, mutableStateOf(true), ConcurrentHashMap())
        try {
            compose.setContent {
                CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduceMotion = reduced)) {
                    BrowserScreen(browser, pagingAllowed = fixture.allowed.value,
                        capturePagingFrame = capture ?: if (!frameFixture) null else { lease ->
                            PagingCaptureResult(PagingCaptureOutcome.READY,
                                PagingFrame(Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888), { browser.pageSwipeCurrent(lease) }))
                        }) { tab, _, modifier ->
                        remember(tab.id) { fixture.instances.merge(tab.id, 1, Int::plus) }
                        Box(modifier.fillMaxSize().background(if (tab.id == first.id) Color(0xFF7DB6E8) else Color(0xFFECC475))) { Text(tab.title) }
                    }
                }
            }
            compose.waitUntil(10_000) { !browser.state.value.loading }; compose.waitForIdle()
            block(fixture)
        } finally { scope.cancel() }
    }
}

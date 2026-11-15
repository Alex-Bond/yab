package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@OptIn(ExperimentalCoroutinesApi::class)
class HistorySwipeOwnershipTest {
    private val first = BrowserTab("first", "https://fixture.invalid/same", createdAt = 1)
    private val page = BrowserTab("page", "https://fixture.invalid/same", openerId = first.id, createdAt = 2)
    private class Repository(private val initial: BrowserSnapshot) : BrowserRepository {
        var saved: BrowserSnapshot? = null
        override suspend fun load() = initial
        override suspend fun save(snapshot: BrowserSnapshot) { saved = snapshot }
    }
    private class Engine : BrowserEngine {
        var token: NativeHistorySwipeTarget? = null
        val committed = mutableListOf<NativeHistorySwipeTarget>()
        override fun captureHistorySwipe(tabId: String, direction: HistorySwipeDirection) =
            NativeHistorySwipeTarget("opaque", direction).also { token = it }
        override fun historySwipeCurrent(target: NativeHistorySwipeTarget) = token === target
        override fun commitHistorySwipe(target: NativeHistorySwipeTarget): Boolean {
            if (token !== target) return false
            token = null; committed += target; return true
        }
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) = error("History swipe must use captured absolute native target")
        override fun goForward(tabId: String) = error("History swipe must use captured absolute native target")
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun snapshot() = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Space", tabs = listOf(first, page),
        currentTabId = page.id)), selectedSpaceId = "s")

    @Test fun exactNativeTargetIsConsumedOnceWithoutChangingTabOrUrlAndForwardRemainsNative() = runTest {
        val engine = Engine(); val controller = BrowserController(Repository(snapshot()), engine, backgroundScope)
        runCurrent()
        controller.pageChanged(page.id, EnginePageState(url = page.url, canGoBack = true, canGoForward = true))
        val lease = controller.captureHistorySwipe(HistorySwipeDirection.FORWARD)!!
        assertTrue(controller.historySwipeCurrent(lease))
        assertTrue(controller.commitHistorySwipe(lease)); assertFalse(controller.commitHistorySwipe(lease))
        assertEquals(1, engine.committed.size); assertEquals(page.id, controller.state.value.tab?.id)
        assertEquals(page.url, controller.state.value.tab?.url)
    }

    @Test fun accountBackgroundSettingToggleSurfaceOrDocumentReplacementCannotReviveCapturedOwnership() = runTest {
        for (revoke in listOf<(BrowserController) -> Unit>(
            { it.invalidateLocalOwnership() }, { it.backgrounded(); it.foregrounded() },
            { val original = it.state.value.settings; it.updateSettings(original.copy(swipeAnywhere = false)); it.updateSettings(original) },
            { it.openField(); it.dismissSurface() },
            { it.selectTab(first.id); it.selectTab(page.id) },
            { it.pageChanged(page.id, EnginePageState(url = "https://fixture.invalid/new", canGoBack = true)) })) {
            val engine = Engine(); val controller = BrowserController(Repository(snapshot()), engine, backgroundScope)
            runCurrent(); controller.pageChanged(page.id, EnginePageState(url = page.url, canGoBack = true))
            val lease = controller.captureHistorySwipe(HistorySwipeDirection.BACK)!!
            revoke(controller)
            assertFalse(controller.historySwipeCurrent(lease)); assertFalse(controller.commitHistorySwipe(lease))
            assertTrue(engine.committed.isEmpty())
        }
    }

    @Test fun firstPageBackClosesOnlyCapturedSameProfileOpenerAndOffSettingDisablesCapture() = runTest {
        val engine = Engine(); val controller = BrowserController(Repository(snapshot()), engine, backgroundScope)
        runCurrent(); controller.pageChanged(page.id, EnginePageState(url = page.url))
        assertTrue(BrowserSettings().swipeAnywhere)
        val lease = controller.captureHistorySwipe(HistorySwipeDirection.BACK)!!
        assertTrue(controller.commitHistorySwipe(lease)); assertEquals(first.id, controller.state.value.tab?.id)
        assertTrue(engine.committed.isEmpty()); assertFalse(controller.commitHistorySwipe(lease))
        controller.updateSettings(controller.state.value.settings.copy(swipeAnywhere = false))
        assertNull(controller.captureHistorySwipe(HistorySwipeDirection.BACK))
        assertNull(controller.captureHistorySwipe(HistorySwipeDirection.FORWARD))
    }

    @Test fun legacySettingsDefaultOnWhileExplicitOffSurvivesRealSnapshotSerializationAndSearchRemainsReachable() {
        val json = Json { encodeDefaults = true }
        val legacy = json.decodeFromString<BrowserSnapshot>("""{"spaces":[],"selectedSpaceId":"s","settings":{}}""")
        assertTrue(legacy.settings.swipeAnywhere)
        val off = snapshot().copy(settings = BrowserSettings(swipeAnywhere = false))
        assertFalse(json.decodeFromString<BrowserSnapshot>(json.encodeToString(off)).settings.swipeAnywhere)
        val catalog = SettingsSearchIndex.pages(off.settings, off.spaces, SettingsSearchAvailability())
        assertEquals(SettingsRowId.SWIPE_ANYWHERE, SettingsSearchIndex.matches("swipe", catalog).single().row?.id)
    }
}

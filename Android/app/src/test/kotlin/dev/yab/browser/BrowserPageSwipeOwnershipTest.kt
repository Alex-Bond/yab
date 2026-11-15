package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserPageSwipeOwnershipTest {
    private val tabs = listOf("first", "middle", "last").map { BrowserTab(it, "https://$it.example/", createdAt = 1) }
    private class Repository(private val snapshot: BrowserSnapshot) : BrowserRepository {
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }
    private class Engine : BrowserEngine {
        val activated = mutableListOf<String>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { activated += tab.id }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }

    @Test fun pageOrderUsesColumnTreeAndSelectedClosedFolderPageInsteadOfRecency() {
        val kept = BrowserTab("kept", "https://kept.example/", place = TabPlace.KEPT, createdAt = 1)
        val child = kept.copy(id = "child", folderId = "closed")
        val pin = kept.copy(id = "pin", place = TabPlace.PINNED)
        val owner = BrowserSpace("s", "Space", tabs = tabs + child + pin + kept,
            folders = listOf(BrowserFolder("closed", "Closed", open = false)), currentTabId = child.id)
        val state = BrowserState(loading = false, spaces = listOf(owner), selectedSpaceId = "s", recency = mapOf("s" to listOf("last", "first")))
        assertEquals(listOf("kept", "child", "first", "middle", "last"), state.pagingOrder().map { it.id })
        assertEquals(listOf("pin", "kept", "first", "middle", "last"), state.copy(spaces = listOf(owner.copy(currentTabId = pin.id))).pagingOrder().map { it.id })
    }

    @Test fun onlyCapturedNeighborCanSettleAndOldLeaseCannotTurnAgain() = runTest {
        val owner = BrowserSpace("s", "Space", tabs = tabs, currentTabId = "middle")
        val engine = Engine()
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(owner), selectedSpaceId = "s")), engine, backgroundScope)
        runCurrent()
        val lease = controller.capturePageSwipe()!!
        assertEquals("first", lease.before?.id); assertEquals("last", lease.after?.id)
        assertFalse(controller.settlePageSwipe(lease, 2))
        assertTrue(controller.settlePageSwipe(lease, 1))
        assertEquals("last", controller.state.value.tab?.id)
        assertFalse(controller.settlePageSwipe(lease, -1))
        assertEquals(listOf("middle", "last"), engine.activated)
    }

    @Test fun reusedIdsAfterAccountTransitionAndBackgroundedGestureAreRevoked() = runTest {
        val owner = BrowserSpace("s", "Space", tabs = tabs, currentTabId = "middle")
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(owner), selectedSpaceId = "s")), Engine(), backgroundScope)
        runCurrent()
        val oldAccount = controller.capturePageSwipe()!!
        controller.invalidateLocalOwnership()
        assertFalse(controller.pageSwipeCurrent(oldAccount))
        val oldForeground = controller.capturePageSwipe()!!
        controller.backgrounded(); controller.foregrounded()
        assertFalse(controller.settlePageSwipe(oldForeground, 1))
        assertEquals("middle", controller.state.value.tab?.id)
    }

    @Test fun sourceNavigationOrRemovedNeighborCannotFinishAnOldSwipe() = runTest {
        val owner = BrowserSpace("s", "Space", tabs = tabs, currentTabId = "middle")
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(owner), selectedSpaceId = "s")), Engine(), backgroundScope)
        runCurrent()
        val removed = controller.capturePageSwipe()!!
        controller.closeTab("last")
        assertFalse(controller.settlePageSwipe(removed, 1))
        val navigated = controller.capturePageSwipe()!!
        controller.pageChanged("middle", EnginePageState(url = "https://middle.example/new", title = "New"))
        assertFalse(controller.pageSwipeCurrent(navigated))
    }

    @Test fun newTabLandingOnlyOwnsItsExactFieldAndDismissalNeverCreatesATab() = runTest {
        val owner = BrowserSpace("s", "Space", tabs = tabs, currentTabId = "last")
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(owner), selectedSpaceId = "s")), Engine(), backgroundScope)
        runCurrent()
        val lease = controller.capturePageSwipe()!!
        val fieldEpoch = controller.openPageSwipeField(lease, null)!!
        assertTrue(controller.pageSwipeCurrent(lease, fieldEpoch))
        assertFalse(controller.pageSwipeCurrent(lease))
        controller.dismissSurface()
        assertTrue(controller.pageSwipeCurrent(lease, fieldEpoch))
        assertEquals(3, controller.state.value.space?.tabs?.size)
        controller.openField(privately = true)
        assertFalse(controller.pageSwipeCurrent(lease, fieldEpoch))
    }
}

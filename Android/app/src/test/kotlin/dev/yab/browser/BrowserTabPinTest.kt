package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserTabPinTest {
    private class Store(var value: BrowserSnapshot) : BrowserRepository {
        override suspend fun load() = value
        override suspend fun save(snapshot: BrowserSnapshot) { value = snapshot }
    }
    private class Engine : BrowserEngine {
        var activations = 0
        var closes = 0
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { activations++ }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) = Unit
        override fun goBack(tabId: String) = Unit
        override fun goForward(tabId: String) = Unit
        override fun reload(tabId: String) = Unit
        override fun stop(tabId: String) = Unit
        override fun close(tabId: String) { closes++ }
        override suspend fun clearWebsiteData(profileIds: Set<String>) = Unit
    }
    @Test fun pinDetachesTheOriginalFolderTabAndUnpinLeadsTodayWithoutReplacingItsPage() = runTest {
        val prior = BrowserTab("prior", "https://example.test/prior", "Prior pin", TabPlace.PINNED, createdAt = 1)
        val tab = BrowserTab("page", "https://example.test/page", "Custom title", TabPlace.KEPT, createdAt = 2, folderId = "folder", shared = true)
        val today = BrowserTab("today", "https://example.test/today", "Today", createdAt = 3)
        val space = BrowserSpace("work", "Work", tabs = listOf(prior, tab, today), currentTabId = tab.id, folders = listOf(BrowserFolder("folder", "Folder")))
        val store = Store(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id))
        val engine = Engine(); val browser = BrowserController(store, engine, backgroundScope)
        runCurrent(); val activations = engine.activations
        browser.pinTab(tab.id); runCurrent()
        assertEquals(listOf(prior.id, tab.id), browser.state.value.space!!.tabs.filter { it.place == TabPlace.PINNED }.map { it.id })
        assertEquals(tab.copy(place = TabPlace.PINNED, folderId = null), browser.state.value.space!!.tabs.single { it.id == tab.id })
        assertEquals(tab.id, browser.state.value.tab?.id)
        browser.unpinTab(tab.id); runCurrent()
        assertEquals(listOf(tab.id, today.id), browser.state.value.space!!.tabs.filter { it.place == TabPlace.TODAY }.map { it.id })
        assertEquals(tab.id, store.value.spaces.single().currentTabId)
        assertEquals(activations, engine.activations); assertEquals(0, engine.closes)
        browser.unpinTab(tab.id); runCurrent()
        assertEquals(listOf(tab.id, today.id), browser.state.value.space!!.tabs.filter { it.place == TabPlace.TODAY }.map { it.id })
    }
    @Test fun privateAndAmbiguousTabIdentitiesCannotBePinned() = runTest {
        val tab = BrowserTab("same", "https://example.test", "Page", createdAt = 1)
        val first = BrowserSpace("one", "One", tabs = listOf(tab), currentTabId = tab.id)
        val second = BrowserSpace("two", "Two", tabs = listOf(tab), currentTabId = tab.id)
        val store = Store(BrowserSnapshot(spaces = listOf(first, second), selectedSpaceId = first.id))
        val browser = BrowserController(store, Engine(), backgroundScope); runCurrent()
        browser.pinTab(tab.id); runCurrent()
        assertTrue(browser.state.value.spaces.flatMap { it.tabs }.all { it.place == TabPlace.TODAY })
        browser.openUrl("https://private.example", privately = true)
        val original = browser.state.value.tab ?: error("Private tab missing")
        browser.pinTab(original.id); runCurrent()
        assertEquals(original, browser.state.value.tab)
        assertTrue(store.value.spaces.none { it.isPrivate || it.tabs.any { tab -> tab.isPrivate } })
    }
}

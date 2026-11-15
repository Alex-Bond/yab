package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserGalleryReturnTest {
    private class Store : BrowserRepository {
        override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("public", "Public",
            tabs = listOf(BrowserTab("first", "https://first.test", createdAt = 1), BrowserTab("second", "https://second.test", createdAt = 2)),
            currentTabId = "first")), selectedSpaceId = "public")
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }
    private class Engine : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }

    @Test fun aChangedDestinationRevokesOnlyItsOldReturnPresentation() = runTest {
        val browser = BrowserController(Store(), Engine(), backgroundScope)
        runCurrent()
        browser.show(BrowserSurface.GALLERY)
        val epoch = browser.state.value.surfaceEpoch
        val chosen = browser.state.value.space!!.tabs.first { it.id == "second" }
        val profile = browser.state.value.space!!.websiteProfile
        assertTrue(browser.selectGalleryTab(chosen.id, epoch))
        assertFalse(browser.cancelGalleryReturn("public", epoch, chosen, profile))
        browser.pageChanged(chosen.id, EnginePageState(url = "https://second.test/changed", progress = 1f))
        assertTrue(browser.cancelGalleryReturn("public", epoch, chosen, profile))
        assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
        assertFalse(browser.state.value.galleryClosing)
        assertNotEquals(epoch, browser.state.value.surfaceEpoch)
        assertEquals("https://second.test/changed", browser.state.value.tab!!.url)
        val current = browser.state.value
        assertFalse(browser.finishGallery("public", epoch, chosen.id))
        assertFalse(browser.cancelGalleryReturn("public", epoch, chosen, profile))
        assertEquals(current, browser.state.value)
    }

    @Test fun aCancelledReturnCannotReplaceSettingsANewerGalleryOrLockedPrivate() = runTest {
        val browser = BrowserController(Store(), Engine(), backgroundScope)
        runCurrent()
        browser.show(BrowserSurface.GALLERY)
        val epoch = browser.state.value.surfaceEpoch
        val chosen = browser.state.value.space!!.tabs.first { it.id == "second" }
        val profile = browser.state.value.space!!.websiteProfile
        assertTrue(browser.selectGalleryTab(chosen.id, epoch))
        browser.show(BrowserSurface.SETTINGS)
        var current = browser.state.value
        assertFalse(browser.cancelGalleryReturn("public", epoch, chosen, profile))
        assertEquals(current, browser.state.value)
        browser.show(BrowserSurface.GALLERY)
        current = browser.state.value
        assertFalse(browser.cancelGalleryReturn("public", epoch, chosen, profile))
        assertEquals(current, browser.state.value)

        browser.openUrl("https://private.test", privately = true); browser.unlockPrivate(true)
        browser.show(BrowserSurface.GALLERY)
        val privateTab = browser.state.value.tab!!
        val privateSpace = browser.state.value.space!!
        val privateEpoch = browser.state.value.surfaceEpoch
        assertTrue(browser.selectGalleryTab(privateTab.id, privateEpoch))
        browser.lockPrivate()
        current = browser.state.value
        assertFalse(browser.cancelGalleryReturn(privateSpace.id, privateEpoch, privateTab, privateSpace.websiteProfile))
        assertEquals(current, browser.state.value)
    }
}

package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PopupReturnTest {
    private class Store(val initial: BrowserSnapshot) : BrowserRepository {
        override suspend fun load() = initial
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }
    private class Engine : BrowserEngine {
        val closed = mutableListOf<String>()
        val active = mutableListOf<String>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { active += tab.id }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) { closed += tabId }
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private val source = BrowserTab("source", "https://fixture.example/source", createdAt = 1)
    private val popup = BrowserTab("popup", "https://fixture.example/auth", openerId = source.id, createdAt = 2)
    private val other = BrowserTab("other", "https://fixture.example/other", createdAt = 3)
    private fun snapshot(front: String = popup.id, tabs: List<BrowserTab> = listOf(other, popup, source)) = BrowserSnapshot(
        spaces = listOf(BrowserSpace("public", "Public", tabs = tabs, currentTabId = front)), selectedSpaceId = "public")

    @Test fun foregroundCallbackReturnsToItsOpenerWithoutOfferingUndo() = runTest {
        val engine = Engine()
        val browser = BrowserController(Store(snapshot()), engine, backgroundScope)
        runCurrent()
        assertTrue(browser.closeEnginePopup(popup.id, source.id, browser.state.value.space!!.websiteProfile))
        assertEquals(source.id, browser.state.value.tab!!.id)
        assertEquals(source.id, engine.active.last())
        assertEquals(listOf(popup.id), engine.closed)
        assertFalse(browser.state.value.undoAvailable)
        assertFalse(browser.closeEnginePopup(popup.id, source.id, browser.state.value.space!!.websiteProfile))
    }

    @Test fun backgroundCallbackAndClosedOpenerNeverStealTheNewerSelection() = runTest {
        val engine = Engine()
        val browser = BrowserController(Store(snapshot(other.id)), engine, backgroundScope)
        runCurrent()
        val calls = engine.active.size
        assertTrue(browser.closeEnginePopup(popup.id, source.id, browser.state.value.space!!.websiteProfile))
        assertEquals(other.id, browser.state.value.tab!!.id)
        assertEquals(calls, engine.active.size)

        val missing = BrowserController(Store(snapshot(tabs = listOf(other, popup))), Engine(), backgroundScope)
        runCurrent()
        assertTrue(missing.closeEnginePopup(popup.id, source.id, missing.state.value.space!!.websiteProfile))
        assertEquals(other.id, missing.state.value.tab!!.id)
    }

    @Test fun ordinaryOrChangedProfileCannotClaimPopupCloseAuthority() = runTest {
        val engine = Engine()
        val browser = BrowserController(Store(snapshot()), engine, backgroundScope)
        runCurrent()
        val original = browser.state.value
        assertFalse(browser.closeEnginePopup(source.id, other.id, original.space!!.websiteProfile))
        assertFalse(browser.closeEnginePopup(popup.id, other.id, original.space!!.websiteProfile))
        assertFalse(browser.closeEnginePopup(popup.id, source.id, WebsiteProfile("other-profile", false)))
        assertEquals(original, browser.state.value)
        assertTrue(engine.closed.isEmpty())
    }

    @Test fun lockedPrivateCallbackRemovesOnlyItsWindowWithoutActivatingAnything() = runTest {
        val engine = Engine()
        val browser = BrowserController(Store(snapshot()), engine, backgroundScope)
        runCurrent()
        browser.openUrl("https://fixture.example/private", privately = true)
        browser.unlockPrivate(true)
        val opener = browser.state.value.tab!!
        val reserved = browser.createEngineTab("https://fixture.example/auth", opener.id)!!
        browser.lockPrivate()
        val calls = engine.active.size
        assertTrue(browser.closeEnginePopup(reserved.first.id, opener.id, reserved.second))
        assertTrue(browser.state.value.privateContentBlocked)
        assertEquals(calls, engine.active.size)
        assertTrue(browser.state.value.spaces.filter(BrowserSpace::isPrivate).flatMap { it.tabs }.none { it.id == reserved.first.id })
        assertFalse(browser.publicSnapshot().toString().contains("/private"))
    }
}

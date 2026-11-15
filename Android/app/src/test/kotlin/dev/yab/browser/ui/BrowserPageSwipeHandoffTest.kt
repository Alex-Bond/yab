package dev.yab.browser.ui

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** Exercise the actual UI host with independent controller/collected-UI state domains. */
@OptIn(ExperimentalCoroutinesApi::class)
class BrowserPageSwipeHandoffTest {
    private val first = BrowserTab("handoff-first", "https://first.example/", createdAt = 1)
    private val after = BrowserTab("handoff-after", "https://after.example/", createdAt = 1)
    private val repository = object : BrowserRepository {
        override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("handoff-space", "Handoff",
            tabs = listOf(first, after), currentTabId = first.id)), selectedSpaceId = "handoff-space")
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }
    private val engine = object : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }

    @Test fun keyedIncomingPageRemainsUntilTheCollectedConsumerAcknowledgesTheSelectedTarget() = runTest {
        val browser = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        val stale = browser.state.value
        val host = BrowserPageSwipeHostState(browser, { true }, { true }) { _, _ -> }
        host.configure(402.0, 874.0, null, false, stale)
        assertTrue(host.begin(browser.capturePageSwipe()))
        host.move(-220.0); host.end(-220.0, 0.0)
        repeat(240) { host.frame((it + 1) * 16_666_667L, 1.0 / 60) }
        assertEquals(after.id, browser.state.value.tab?.id)
        assertEquals("HANDOFF", host.scene?.phase)
        assertEquals(after.id, host.scene?.lease?.after?.id)
        // A local snapshot can recompose before collectAsState delivers its next StateFlow row.
        host.configure(402.0, 874.0, null, false, stale)
        assertEquals("HANDOFF", host.scene?.phase)
        host.configure(402.0, 874.0, null, false, browser.state.value)
        assertNull(host.scene)
        assertEquals(after.id, browser.state.value.tab?.id)
        host.wake.close()
    }

    @Test fun anAccountRevocationCannotKeepOrReinstateThePendingPresentationHandoff() = runTest {
        val browser = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        val stale = browser.state.value
        val host = BrowserPageSwipeHostState(browser, { true }, { true }) { _, _ -> }
        host.configure(402.0, 874.0, null, false, stale)
        assertTrue(host.begin(browser.capturePageSwipe()))
        host.move(-220.0); host.end(-220.0, 0.0)
        repeat(240) { host.frame((it + 1) * 16_666_667L, 1.0 / 60) }
        assertEquals("HANDOFF", host.scene?.phase)
        browser.invalidateLocalOwnership()
        assertNull(host.scene)
        host.configure(402.0, 874.0, null, false, stale)
        host.configure(402.0, 874.0, null, false, browser.state.value)
        assertNull(host.scene)
        assertEquals(after.id, browser.state.value.tab?.id)
        host.wake.close()
    }
}

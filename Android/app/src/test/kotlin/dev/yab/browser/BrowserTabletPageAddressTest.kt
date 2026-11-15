package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserTabletPageAddressControl
import dev.yab.browser.ui.BrowserTabletPageAddressEntry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserTabletPageAddressTest {
    private val tabs = listOf("a", "b").map { BrowserTab(it, "https://$it.test", it, createdAt = 1) }
    private val space = BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a")
    private val snapshot = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)
    private val anchor = FieldAnchor(114.0, 28.0, 516.0, 44.0)
    private class Engine : BrowserEngine {
        val navigated = mutableListOf<String>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated += tab.id }
        override fun close(tabId: String) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun newBrowser(scope: CoroutineScope, initial: BrowserSnapshot = snapshot, engine: Engine = Engine()): BrowserController =
        BrowserController(object : BrowserRepository {
            override suspend fun load() = initial
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope, now = { 1 }, newId = { "new" })
    private fun register(browser: BrowserController, width: Double = 768.0, height: Double = 1024.0) {
        if (!browser.workspaceWindow.value.registered) browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }
    private fun entry(browser: BrowserController, current: () -> Boolean = { true }) =
        BrowserTabletPageAddressEntry(browser, browser.captureTabletPageEntry(600)!!, current)

    @Test fun actualPageEntryKeepsItsDraftPairAndMeasuredAnchorAndConsumesOnlyOnce() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine = engine); runCurrent(); register(browser, 1280.0, 800.0)
        browser.openBeside("b")
        browser.openField(newTab = false); browser.fieldText("retained draft"); browser.dismissSurface()
        val pair = browser.state.value.workspace
        val original = entry(browser)
        val control = BrowserTabletPageAddressControl(original) { true }
        assertTrue(control.open(anchor))
        val opened = browser.state.value
        assertEquals(BrowserSurface.FIELD, opened.surface); assertFalse(opened.fieldIsNewTab)
        assertEquals("b", opened.fieldOriginTab); assertEquals("retained draft", opened.fieldText)
        assertEquals(anchor, opened.fieldAnchor); assertEquals(pair, opened.workspace)
        assertEquals(tabs, opened.space!!.tabs); assertTrue(engine.navigated.isEmpty())
        assertFalse(control.open(anchor)); assertFalse(original.current())
    }

    @Test fun aboutBlankStillNeedsItsOriginalNativeAdmissionButGenuineEmptyIsLocalNewTab() = runTest {
        val blank = space.copy(tabs = listOf(tabs.first().copy(url = "about:blank")))
        val browser = newBrowser(backgroundScope, snapshot.copy(spaces = listOf(blank))); runCurrent(); register(browser)
        var nativeCurrent = false
        val refused = entry(browser) { nativeCurrent }
        assertFalse(refused.open(anchor)); assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertEquals("a", browser.state.value.tab!!.id)
        nativeCurrent = true
        assertFalse(refused.open(anchor)) // A successful later lookup cannot replace its refused original.
        assertTrue(entry(browser) { nativeCurrent }.open(anchor)); assertFalse(browser.state.value.fieldIsNewTab)

        val empty = newBrowser(backgroundScope, snapshot.copy(spaces = listOf(space.copy(tabs = emptyList(), currentTabId = null))))
        runCurrent(); register(empty)
        assertTrue(entry(empty).open(anchor))
        assertTrue(empty.state.value.fieldIsNewTab); assertNull(empty.state.value.fieldOriginTab)
        assertTrue(empty.state.value.space!!.tabs.isEmpty())
    }

    @Test fun retainedOriginalEnvironmentCannotBorrowANewAccountNativeDocumentOrEntrance() = runTest {
        for (changed in listOf("account", "native", "entrance")) {
            val browser = newBrowser(backgroundScope); runCurrent(); register(browser)
            val originalAccount = Any(); val originalNative = Any(); val originalEntrance = Any()
            var account = originalAccount; var native = originalNative; var entrance = originalEntrance
            val original = entry(browser) { account === originalAccount && native === originalNative && entrance === originalEntrance }
            val saved = BrowserTabletPageAddressControl(original) { true }
            when (changed) { "account" -> account = Any(); "native" -> native = Any(); else -> entrance = Any() }
            val before = browser.state.value
            assertFalse(saved.open(anchor)); assertEquals(before, browser.state.value)
            account = originalAccount; native = originalNative; entrance = originalEntrance
            assertFalse(saved.open(anchor))
            assertTrue(entry(browser).open(anchor))
        }
    }

    @Test fun configurationStopAndUrlAbaRetireSavedControlsWhileFreshCurrentSourceOpens() = runTest {
        for (changed in listOf("configuration", "stop", "url")) {
            val browser = newBrowser(backgroundScope); runCurrent(); register(browser)
            val original = entry(browser); val saved = BrowserTabletPageAddressControl(original) { true }
            when (changed) {
                "configuration" -> { browser.invalidateWorkspaceWindow(); register(browser) }
                "stop" -> { browser.backgrounded(); browser.foregrounded() }
                else -> {
                    browser.applySyncedSnapshot(snapshot.copy(spaces = listOf(space.copy(tabs = tabs.map {
                        if (it.id == "a") it.copy(url = "https://changed.test") else it
                    }))))
                    browser.applySyncedSnapshot(snapshot)
                }
            }
            assertFalse(saved.open(anchor)); assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
            assertTrue(entry(browser).open(anchor))
        }
    }

    @Test fun metadataAndKeepPreserveOriginalEntryAndDoNotRewriteDraftOrNativeTarget() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine = engine); runCurrent(); register(browser)
        browser.openField(newTab = false); browser.fieldText("draft before Keep"); browser.dismissSurface()
        val model = browser.captureTabletPageEntry(600)!!
        val original = BrowserTabletPageAddressEntry(browser, model) { true }
        val saved = BrowserTabletPageAddressControl(original) { true }
        browser.keepTab("a")
        val current = browser.publicSnapshot()!!
        browser.applySyncedSnapshot(current.copy(spaces = current.spaces.map { it.copy(tabs = it.tabs.map { tab ->
            if (tab.id == "a") tab.copy(title = "A newer title", lastActiveAt = 7) else tab
        }) }))
        assertSame(model, browser.captureTabletPageEntry(600)); assertTrue(saved.open(anchor))
        assertEquals("draft before Keep", browser.state.value.fieldText)
        assertEquals("a", browser.state.value.fieldOriginTab); assertTrue(engine.navigated.isEmpty())
    }

    @Test fun screenDisposalAndCoverRetireOnlyOriginalActualControlsWithoutRetiringFreshControl() = runTest {
        val browser = newBrowser(backgroundScope); runCurrent(); register(browser)
        val original = entry(browser)
        var uncovered = true
        val old = BrowserTabletPageAddressControl(original) { uncovered }
        uncovered = false; assertFalse(old.current()); uncovered = true
        assertFalse(old.open(anchor)); assertTrue(original.current())
        val disposed = BrowserTabletPageAddressControl(original) { true }
        val fresh = BrowserTabletPageAddressControl(original) { true }
        disposed.retire(); disposed.retire()
        assertFalse(disposed.open(anchor)); assertTrue(fresh.open(anchor))
        browser.dismissSurface()
        assertFalse(fresh.open(anchor)); assertFalse(old.open(anchor))
        assertTrue(entry(browser).open(anchor))
    }

    @Test fun invalidAnchorDoesNotConsumeSourceAndFinalControllerAdmissionStillRunsAfterEnvironment() = runTest {
        val browser = newBrowser(backgroundScope); runCurrent(); register(browser)
        var reads = 0
        val original = entry(browser) { reads++; true }
        assertFalse(original.open(anchor.copy(width = Double.NaN))); assertEquals(0, reads)
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface); assertTrue(original.current())
        original.retire()
        val revokedDuringRead = entry(browser) { browser.invalidateLocalOwnership(); true }
        assertFalse(revokedDuringRead.open(anchor))
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertTrue(entry(browser).open(anchor))
    }

    @Test fun unlockedPrivateAddressUsesExistingPrivateFieldAndLockAbaNeverRevivesOldEntry() = runTest {
        val browser = newBrowser(backgroundScope); runCurrent(); register(browser)
        browser.showPrivate(); browser.unlockPrivate(true); browser.openUrl("about:blank", privately = true)
        val original = entry(browser)
        browser.lockPrivate(); browser.unlockPrivate(true)
        assertFalse(original.open(anchor))
        assertTrue(entry(browser).open(anchor)); assertTrue(browser.state.value.fieldIsPrivate)
        assertFalse(browser.state.value.fieldIsNewTab)
    }
}

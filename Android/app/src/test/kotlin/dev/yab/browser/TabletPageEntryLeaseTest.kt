package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TabletPageEntryLeaseTest {
    private val tabs = listOf("a", "b").map { BrowserTab(it, "https://$it.test", it, createdAt = 1) }
    private val space = BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a")
    private val initial = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)
    private class Engine : BrowserEngine {
        val navigated = mutableListOf<String>()
        val closed = mutableListOf<String>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated += tab.id }
        override fun close(tabId: String) { closed += tabId }
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun browser(scope: CoroutineScope, snapshot: BrowserSnapshot = initial, engine: Engine = Engine()): BrowserController {
        var next = 0
        return BrowserController(object : BrowserRepository {
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope, now = { 1 }, newId = { "new-${++next}" })
    }
    private fun window(browser: BrowserController, width: Double = 768.0, height: Double = 1024.0) {
        if (!browser.workspaceWindow.value.registered) browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }
    private fun denied(browser: BrowserController, lease: TabletPageEntryLease) {
        val before = browser.state.value
        assertFalse(browser.tabletPageEntryCurrent(lease))
        assertFalse(browser.openTabletAddress(lease, FieldAnchor(12.0, 70.0, 540.0, 52.0)))
        assertEquals(before, browser.state.value)
    }

    @Test fun portraitBlankTabUsesOneOriginalLeaseAcrossTitleKeepAndUnrelatedRefresh() = runTest {
        val blank = tabs.first().copy(url = "about:blank", title = "New Tab")
        val snapshot = initial.copy(spaces = listOf(space.copy(tabs = listOf(blank, tabs.last()))))
        val engine = Engine(); val browser = browser(backgroundScope, snapshot, engine); runCurrent(); window(browser)
        assertNull(browser.captureWorkspaceEntry()) // Portrait tablet is not split authority.
        val held = browser.captureTabletPageEntry(600)!!
        assertEquals(TabletPageTarget.Tab("a", "about:blank", false), held.target)
        assertSame(held, browser.captureTabletPageEntry(600))
        browser.keepTab("a")
        val kept = browser.publicSnapshot()!!
        browser.applySyncedSnapshot(kept.copy(spaces = kept.spaces.map { owner -> owner.copy(tabs = owner.tabs.map {
            if (it.id == "a") it.copy(title = "Fresh title", lastActiveAt = 9) else it.copy(title = "Other title")
        }) }))
        assertSame(held, browser.captureTabletPageEntry(600))
        assertTrue(browser.openTabletAddress(held))
        assertFalse(browser.state.value.fieldIsNewTab)
        assertEquals("a", browser.state.value.fieldOriginTab)
        assertEquals("", browser.state.value.fieldText)
        assertFalse(browser.openTabletAddress(held))
        assertTrue(engine.navigated.isEmpty()); assertTrue(engine.closed.isEmpty())
    }

    @Test fun emptySourceOpensOnlyLocalNewTabWithoutCreatingOrNavigatingAPage() = runTest {
        val empty = initial.copy(spaces = listOf(space.copy(tabs = emptyList(), currentTabId = "missing")))
        // Actual loading sanitizes a dangling repository selection before any PAGE entry can
        // be captured. This is then a legitimate Empty source, not a failed Tab fallback.
        assertEquals("missing", empty.spaces.single().currentTabId)
        val engine = Engine(); val browser = browser(backgroundScope, empty, engine); runCurrent(); window(browser)
        assertNull(browser.state.value.tab); assertNull(browser.state.value.space!!.currentTabId)
        val held = browser.captureTabletPageEntry(600)!!
        assertEquals(TabletPageTarget.Empty, held.target)
        assertSame(held, browser.captureTabletPageEntry(600))
        assertTrue(browser.openTabletAddress(held))
        val after = browser.state.value
        assertEquals(BrowserSurface.FIELD, after.surface)
        assertTrue(after.fieldIsNewTab); assertNull(after.fieldOriginTab)
        assertTrue(after.space!!.tabs.isEmpty()); assertEquals("", after.fieldText)
        denied(browser, held)
        assertTrue(engine.navigated.isEmpty()); assertTrue(engine.closed.isEmpty())
    }

    @Test fun currentAddressRetainsItsDraftAndAnAnchorCannotReplaceSourceOrConsumeOnInvalidGeometry() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine = engine); runCurrent(); window(browser)
        browser.openField(newTab = false); browser.fieldText("kept address draft"); browser.dismissSurface()
        val held = browser.captureTabletPageEntry(600)!!
        val before = browser.state.value
        assertFalse(browser.openTabletAddress(held, FieldAnchor(Double.NaN, 0.0, 540.0, 52.0)))
        assertEquals(before, browser.state.value); assertTrue(browser.tabletPageEntryCurrent(held))
        val anchor = FieldAnchor(40.0, 70.0, 540.0, 52.0)
        assertTrue(browser.openTabletAddress(held, anchor))
        assertEquals(anchor, browser.state.value.fieldAnchor)
        assertEquals("kept address draft", browser.state.value.fieldText)
        assertFalse(browser.state.value.fieldIsNewTab)
        assertEquals(before.space!!.tabs, browser.state.value.space!!.tabs)
        denied(browser, held)
        assertTrue(engine.navigated.isEmpty()); assertTrue(engine.closed.isEmpty())
    }

    @Test fun headlessUnknownCompactNonTabletAndInvalidWindowCannotMintAnEntry() = runTest {
        val browser = browser(backgroundScope); runCurrent()
        browser.resizeWorkspace(true)
        assertNull(browser.captureTabletPageEntry(600))
        browser.invalidateWorkspaceWindow(); assertNull(browser.captureTabletPageEntry(600))
        window(browser, 699.9, 1024.0); assertNull(browser.captureTabletPageEntry(600))
        window(browser); assertNull(browser.captureTabletPageEntry(599))
        val held = browser.captureTabletPageEntry(600)!!
        assertFalse(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(Double.NaN, 1024.0)))
        denied(browser, held); assertNull(browser.captureTabletPageEntry(600))
        window(browser); denied(browser, held)
        assertNotNull(browser.captureTabletPageEntry(600))
    }

    @Test fun configurationAbaRejectsTheOldCommitAndLeaseButKeepsPairForFreshPortraitEntry() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine = engine); runCurrent(); window(browser, 1366.0, 1024.0)
        browser.openBeside("b")
        val pair = browser.state.value.workspace!!
        val held = browser.captureTabletPageEntry(600)!!
        val original = browser.workspaceWindow.value
        browser.invalidateWorkspaceWindow(); browser.invalidateWorkspaceWindow()
        assertFalse(browser.commitWorkspaceWindow(original.configuration, original.geometry!!))
        assertNull(browser.captureTabletPageEntry(600))
        window(browser); denied(browser, held)
        assertEquals(pair, browser.state.value.workspace)
        val fresh = browser.captureTabletPageEntry(600)!!
        assertNotSame(held, fresh)
        assertTrue(browser.openTabletAddress(fresh))
        assertEquals(pair, browser.state.value.workspace)
        assertEquals("b", browser.state.value.fieldOriginTab)
        assertTrue(engine.navigated.isEmpty()); assertTrue(engine.closed.isEmpty())
    }

    @Test fun restoredUrlRemovalAndProfileNeverReviveTheOriginalEntry() = runTest {
        for (change in listOf("url", "remove", "profile")) {
            val browser = browser(backgroundScope); runCurrent(); window(browser)
            val held = browser.captureTabletPageEntry(600)!!
            val changed = when (change) {
                "url" -> space.copy(tabs = tabs.map { if (it.id == "a") it.copy(url = "https://changed.test") else it })
                "remove" -> space.copy(tabs = tabs.drop(1))
                else -> space.copy(ownSignIns = true)
            }
            browser.applySyncedSnapshot(initial.copy(spaces = listOf(changed)))
            browser.applySyncedSnapshot(initial)
            if (browser.state.value.tab?.id != "a") browser.selectTab("a")
            assertEquals("https://a.test", browser.state.value.tab!!.url)
            assertEquals(space.websiteProfile, browser.state.value.space!!.websiteProfile)
            denied(browser, held)
            val fresh = browser.captureTabletPageEntry(600)!!
            assertTrue(browser.openTabletAddress(fresh))
        }
    }

    @Test fun findAndPairChangesRetireTheSlotBeforeAHistoryGenerationWouldBeNeeded() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser, 1366.0, 1024.0)
        val find = browser.captureTabletPageEntry(600)!!
        val source = browser.historyPresentationLifetime.value
        val epoch = browser.state.value.surfaceEpoch
        browser.beginFind(); browser.dismissFind()
        assertEquals(source, browser.historyPresentationLifetime.value)
        assertEquals(epoch, browser.state.value.surfaceEpoch)
        denied(browser, find)
        browser.openBeside("b")
        val paired = browser.captureTabletPageEntry(600)!!
        val pairedSource = browser.historyPresentationLifetime.value
        browser.fullSpread()
        assertEquals(pairedSource, browser.historyPresentationLifetime.value)
        denied(browser, paired)
        assertNotNull(browser.captureTabletPageEntry(600))
    }

    @Test fun stopReturnAndLocalAccountOwnershipChangeRequireAFreshEntry() = runTest {
        for (stop in listOf(false, true)) {
            val browser = browser(backgroundScope); runCurrent(); window(browser)
            val held = browser.captureTabletPageEntry(600)!!
            if (stop) {
                browser.backgrounded(); assertNull(browser.captureTabletPageEntry(600)); browser.foregrounded()
            } else browser.invalidateLocalOwnership()
            denied(browser, held)
            val fresh = browser.captureTabletPageEntry(600)!!
            assertNotSame(held, fresh); assertTrue(browser.openTabletAddress(fresh))
        }
    }

    @Test fun privateLockBoundaryCannotLendAnOldSourceAfterUnlock() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser)
        browser.showPrivate()
        assertTrue(browser.state.value.privateContentBlocked)
        assertNull(browser.captureTabletPageEntry(600))
        browser.unlockPrivate(true); browser.openUrl("about:blank", privately = true)
        val held = browser.captureTabletPageEntry(600)!!
        assertTrue(held.profile.isPrivate)
        browser.lockPrivate(); assertNull(browser.captureTabletPageEntry(600)); browser.unlockPrivate(true)
        denied(browser, held)
        assertTrue(browser.openTabletAddress(browser.captureTabletPageEntry(600)!!))
        assertTrue(browser.state.value.fieldIsPrivate)
        assertFalse(browser.state.value.fieldIsNewTab)
    }

    @Test fun emptyToRealPageAndBackCannotTurnAnOldEmptySourceIntoANativeFallback() = runTest {
        val empty = initial.copy(spaces = listOf(space.copy(tabs = emptyList(), currentTabId = null)))
        val browser = browser(backgroundScope, empty); runCurrent(); window(browser)
        val held = browser.captureTabletPageEntry(600)!!
        browser.applySyncedSnapshot(initial); browser.applySyncedSnapshot(empty)
        assertNull(browser.state.value.tab); assertNull(browser.state.value.space!!.currentTabId)
        denied(browser, held)
        val fresh = browser.captureTabletPageEntry(600)!!
        assertEquals(TabletPageTarget.Empty, fresh.target)
        assertTrue(browser.openTabletAddress(fresh)); assertTrue(browser.state.value.fieldIsNewTab)
    }
}

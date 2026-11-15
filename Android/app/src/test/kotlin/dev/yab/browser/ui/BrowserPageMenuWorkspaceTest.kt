package dev.yab.browser.ui

import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserPageMenuWorkspaceTest {
    private val tabs = listOf("a", "b", "c").map { BrowserTab(it, "https://$it.test", it, createdAt = 1) }
    private val initial = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a")), selectedSpaceId = "s")
    private class Engine : BrowserEngine {
        val closed = mutableListOf<String>()
        val navigated = mutableListOf<String>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated += tab.id }
        override fun close(tabId: String) { closed += tabId }
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun browser(scope: CoroutineScope, engine: Engine = Engine()): BrowserController {
        var sequence = 0
        return BrowserController(object : BrowserRepository {
            override suspend fun load() = initial
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope, now = { 1 }, newId = { "new-${++sequence}" })
    }
    private fun window(browser: BrowserController, width: Double = 1366.0, height: Double = 1024.0) {
        if (!browser.workspaceWindow.value.registered) browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }
    private fun pair(browser: BrowserController) {
        val entry = browser.captureWorkspaceEntry()!!
        val target = browser.state.value.space!!.tabs.single { it.id == "b" }
        browser.openBeside(target.id, browser.captureWorkspaceActions(entry, target)!!)
    }

    /** Existing production Scope/Entry/presentation, with the caller's native/account boundary.
     * Landing uses the same one-shot completion order as BrowserPageMenuHost. No UI fake clock,
     * replacement capability or Context-dependent menu action is needed. */
    private class Menu(val browser: BrowserController) {
        private val geometry = BrowserPageMenuGeometry(1366.0, 1024.0, 54.0,
            PageMenuRect(560.0, 950.0, 228.0, 48.0), 600.0)
        private val originalNative = Any()
        var native: Any = originalNative
        var accountEpoch = 3L
        private val originalEpoch = accountEpoch
        private val source = browser.state.value
        private val tab = source.tab!!
        private val lease = PageMenuLease("menu-account", originalEpoch, tab.id, source.space!!.id,
            source.space!!.websiteProfile, originalNative, source.surfaceEpoch, 1, url = tab.url,
            windowGeneration = browser.workspaceWindow.value.generation)
        val current = { native === originalNative && accountEpoch == originalEpoch &&
            browser.workspaceWindow.value.let { it.geometry?.valid == true && it.generation == lease.windowGeneration } &&
            lease.ownsSource(browser.state.value, tab.url) }
        val actions = PageMenuWorkspaceActions.capture(browser, current)
        var closes = 0
        val releases = mutableListOf<PageMenuRelease>()
        private var clock = System.nanoTime()
        val entry = BrowserPageMenuEntry(lease, current, { closes++ }, { _, reason -> releases += reason },
            { y, _ -> y }, { _, _ -> }, { _, _ -> }, {}, {}, {})
        init {
            assertTrue(entry.layoutLease.accept(geometry))
            entry.presentation.open(clock, false, false)
        }
        fun scope() = BrowserPageMenuScope(geometry.pose(entry.presentation.frame.value, false), true,
            PageMenuPage.MENU, entry, false, true, PageMenuPage.MENU)
        fun advance(nanos: Long) {
            clock = maxOf(clock, nanos)
            entry.presentation.advance(clock)
        }
        fun land(): PageMenuCompletion? {
            advance(maxOf(clock, System.nanoTime()) + 2_000_000_000L)
            val completion = entry.presentation.claimCompletion { it == lease && entry.drawingOwned() } ?: return null
            entry.released(lease, completion.reason)
            if (completion.reason == PageMenuRelease.LANDED && entry.owned()) completion.action?.invoke()
            return completion
        }
    }

    @Test fun openBesideQueuesOriginalCapabilityAndCreatesExactlyOneFieldOnlyAfterLanding() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser)
        val menu = Menu(browser); val actions = menu.actions!!
        assertEquals(listOf(PageMenuWorkspaceAction.OPEN_BESIDE), actions.available())
        val before = browser.state.value
        assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
        assertEquals(before, browser.state.value); assertEquals(1, menu.closes)
        assertFalse(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
        assertEquals(PageMenuRelease.LANDED, menu.land()!!.reason)
        val after = browser.state.value
        assertEquals(BrowserSurface.FIELD, after.surface)
        assertEquals("new-1", after.tab!!.id)
        assertEquals(BrowserWorkspace("a", "new-1", "new-1", newPage = "new-1"), after.workspace)
        assertEquals(tabs.size + 1, after.space!!.tabs.size)
        assertEquals(1, after.space!!.tabs.count { it.isBlank })
        assertNull(menu.land())
        assertFalse(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
        assertTrue(engine.closed.isEmpty()); assertTrue(engine.navigated.isEmpty())
    }

    @Test fun pairedFullSpreadLandsWithoutClosingOrNavigatingEitherRetainedPage() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser); pair(browser)
        val menu = Menu(browser); val actions = menu.actions!!
        assertEquals(PageMenuWorkspaceAction.entries, actions.available())
        val before = browser.state.value
        assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.FULL_SPREAD))
        assertEquals(before, browser.state.value)
        assertEquals(PageMenuRelease.LANDED, menu.land()!!.reason)
        assertNull(browser.state.value.workspace)
        assertEquals(before.tab, browser.state.value.tab)
        assertEquals(before.space!!.tabs, browser.state.value.space!!.tabs)
        assertTrue(engine.closed.isEmpty()); assertTrue(engine.navigated.isEmpty())
    }

    @Test fun closePageLandsOnOriginalCompanionAndNeverClosesItTwice() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser); pair(browser)
        val menu = Menu(browser); val actions = menu.actions!!
        assertEquals("b", browser.state.value.tab!!.id)
        assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.CLOSE_PAGE))
        assertEquals(listOf("a", "b", "c"), browser.state.value.space!!.tabs.map { it.id })
        menu.land()
        assertEquals("a", browser.state.value.tab!!.id)
        assertNull(browser.state.value.workspace)
        assertEquals(listOf("a", "c"), browser.state.value.space!!.tabs.map { it.id })
        assertEquals(listOf("b"), engine.closed)
        assertNull(menu.land())
        assertFalse(actions.perform(menu.scope(), PageMenuWorkspaceAction.CLOSE_PAGE))
        assertEquals(listOf("b"), engine.closed)
    }

    @Test fun unavailableRowsNeverCloseTheMenuOrMintAuthorityFromHeadlessPortraitUnknownOrPrivate() = runTest {
        val browser = browser(backgroundScope); runCurrent()
        browser.resizeWorkspace(true)
        assertNull(PageMenuWorkspaceActions.capture(browser) { true })
        browser.invalidateWorkspaceWindow()
        assertNull(PageMenuWorkspaceActions.capture(browser) { true })
        window(browser, 768.0, 1024.0)
        assertNull(PageMenuWorkspaceActions.capture(browser) { true })
        window(browser)
        val menu = Menu(browser); val actions = menu.actions!!
        assertFalse(actions.perform(menu.scope(), PageMenuWorkspaceAction.FULL_SPREAD))
        assertFalse(actions.perform(menu.scope(), PageMenuWorkspaceAction.CLOSE_PAGE))
        assertEquals(0, menu.closes)
        assertEquals(PageMenuPhase.OPEN, menu.entry.presentation.frame.value.phase)
        assertNull(PageMenuWorkspaceActions.capture(browser) { false })
        browser.showPrivate(); browser.openUrl("https://private.test", newTab = true)
        assertTrue(browser.state.value.tab!!.isPrivate)
        assertNull(PageMenuWorkspaceActions.capture(browser) { true })
    }

    @Test fun configurationAbaRevokesSavedRowsBeforeClickAndWhileQueuedWithoutRecapture() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser)
        for (queued in listOf(false, true)) {
            val menu = Menu(browser); val actions = menu.actions!!
            if (queued) assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            val before = browser.state.value
            browser.invalidateWorkspaceWindow(); browser.invalidateWorkspaceWindow(); window(browser)
            assertTrue(actions.available().isEmpty())
            if (queued) assertEquals(PageMenuRelease.REVOKED, menu.land()!!.reason)
            else assertFalse(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            assertEquals(before, browser.state.value)
        }
        val fresh = Menu(browser)
        assertTrue(fresh.actions!!.perform(fresh.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
        fresh.land(); assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
    }

    @Test fun stopAndLocalOwnerChangePermanentlyDenyOriginalQueuedActionButFreshMenuWorks() = runTest {
        for (stop in listOf(false, true)) {
            val browser = browser(backgroundScope); runCurrent(); window(browser)
            val menu = Menu(browser); val actions = menu.actions!!
            assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            if (stop) { browser.backgrounded(); browser.foregrounded() } else browser.invalidateLocalOwnership()
            val before = browser.state.value
            menu.land()
            assertEquals(before, browser.state.value)
            assertTrue(actions.available().isEmpty())
            val fresh = Menu(browser)
            assertTrue(fresh.actions!!.perform(fresh.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            fresh.land(); assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        }
    }

    @Test fun nativeOwnerAndAtomicAccountReplacementRefuseBothSavedPressAndLateLanding() = runTest {
        for (account in listOf(false, true)) for (queued in listOf(false, true)) {
            val browser = browser(backgroundScope); runCurrent(); window(browser)
            val menu = Menu(browser); val actions = menu.actions!!
            if (queued) assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            if (account) menu.accountEpoch++ else menu.native = Any()
            val before = browser.state.value
            if (queued) assertEquals(PageMenuRelease.REVOKED, menu.land()!!.reason)
            else assertFalse(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            assertEquals(before, browser.state.value)
            assertTrue(actions.available().isEmpty())
        }
    }

    @Test fun eightyAndOneSixtyMillisecondCloseReversalCancelsOriginalActionUntilANewPress() = runTest {
        for (elapsed in listOf(80L, 160L)) {
            val browser = browser(backgroundScope); runCurrent(); window(browser)
            val menu = Menu(browser); val actions = menu.actions!!
            assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            val before = browser.state.value
            val now = System.nanoTime() + elapsed * 1_000_000L
            menu.advance(now)
            menu.entry.reopen(now, false, true)
            menu.advance(now + 2_000_000_000L)
            assertEquals(PageMenuPhase.OPEN, menu.entry.presentation.frame.value.phase)
            assertNull(menu.land()); assertEquals(before, browser.state.value)
            assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            assertEquals(before, browser.state.value)
            menu.land(); assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
            assertEquals(tabs.size + 1, browser.state.value.space!!.tabs.size)
        }
    }

    @Test fun frontKeepTitleAndActivityKeepOriginalRowsBeforePressAndWhileLanding() = runTest {
        for (afterPress in listOf(false, true)) for (unkeep in listOf(false, true)) {
            val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser)
            browser.applySyncedSnapshot(initial.copy(spaces = initial.spaces.map { space ->
                space.copy(tabs = space.tabs.map { if (it.id == "a") it.copy(lastActiveAt = 0) else it })
            }))
            val menu = Menu(browser); val actions = menu.actions!!
            val original = actions.lease
            fun metadata() {
                browser.keepTab("a")
                if (unkeep) browser.unkeepTab("a")
                browser.pageChanged("a", EnginePageState(url = "https://a.test", title = "Updated front"))
                browser.pageActivity("a")
                assertEquals(if (unkeep) TabPlace.TODAY else TabPlace.KEPT, browser.state.value.tab!!.place)
                assertEquals("Updated front", browser.state.value.tab!!.title)
                assertEquals(1L, browser.state.value.tab!!.lastActiveAt)
                assertNotEquals(original.entry.front, browser.state.value.tab)
                assertSame(original, actions.lease)
                assertTrue(browser.workspaceActionsCurrent(original))
            }
            if (!afterPress) metadata()
            assertEquals(listOf(PageMenuWorkspaceAction.OPEN_BESIDE), actions.available())
            assertTrue(actions.perform(menu.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
            if (afterPress) metadata()
            val front = browser.state.value.tab!!
            assertEquals(1, menu.closes)
            assertNull(browser.state.value.workspace)
            assertEquals(PageMenuRelease.LANDED, menu.land()!!.reason)
            assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
            assertEquals(BrowserWorkspace("a", "new-1", "new-1", newPage = "new-1"), browser.state.value.workspace)
            assertEquals(front, browser.state.value.space!!.tabs.single { it.id == "a" })
            assertEquals(tabs.size + 1, browser.state.value.space!!.tabs.size)
            assertEquals(1, browser.state.value.space!!.tabs.count { it.isBlank })
            assertNull(menu.land())
            assertTrue(engine.closed.isEmpty()); assertTrue(engine.navigated.isEmpty())
        }
    }

    @Test fun pairedActionsLandOnUpdatedKeptFrontWithoutReplacingTheirOriginalCapability() = runTest {
        for (action in listOf(PageMenuWorkspaceAction.FULL_SPREAD, PageMenuWorkspaceAction.CLOSE_PAGE)) {
            for (afterPress in listOf(false, true)) {
                val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser); pair(browser)
                val snapshot = browser.publicSnapshot()!!
                browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { space ->
                    space.copy(tabs = space.tabs.map { if (it.id == "b") it.copy(lastActiveAt = 0) else it })
                }))
                val menu = Menu(browser); val actions = menu.actions!!
                val original = actions.lease
                val companion = browser.state.value.workspace!!.companion
                fun metadata() {
                    browser.keepTab("b")
                    browser.pageChanged("b", EnginePageState(url = "https://b.test", title = "Updated kept front"))
                    browser.pageActivity("b")
                    assertEquals(TabPlace.KEPT, browser.state.value.tab!!.place)
                    assertEquals("Updated kept front", browser.state.value.tab!!.title)
                    assertEquals(1L, browser.state.value.tab!!.lastActiveAt)
                    assertSame(original, actions.lease)
                    assertTrue(browser.workspaceActionsCurrent(original))
                }
                if (!afterPress) metadata()
                assertTrue(actions.perform(menu.scope(), action))
                if (afterPress) metadata()
                val beforeLanding = browser.state.value
                assertEquals("b", beforeLanding.tab!!.id)
                assertEquals(1, menu.closes)
                assertEquals(PageMenuRelease.LANDED, menu.land()!!.reason)
                assertNull(browser.state.value.workspace)
                if (action == PageMenuWorkspaceAction.FULL_SPREAD) {
                    assertEquals(beforeLanding.tab, browser.state.value.tab)
                    assertEquals(beforeLanding.space!!.tabs, browser.state.value.space!!.tabs)
                    assertTrue(engine.closed.isEmpty())
                } else {
                    assertEquals(companion, browser.state.value.tab!!.id)
                    assertFalse(browser.state.value.space!!.tabs.any { it.id == "b" })
                    assertEquals(beforeLanding.space!!.tabs.filterNot { it.id == "b" }, browser.state.value.space!!.tabs)
                    assertEquals(listOf("b"), engine.closed)
                }
                assertNull(menu.land())
                assertFalse(actions.perform(menu.scope(), action))
                assertTrue(engine.navigated.isEmpty())
            }
        }
    }

    @Test fun frontMetadataCannotRefreshOriginalCapabilityAfterSameValueUrlAba() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser)
        val fresh = Menu(browser); val queued = fresh.actions!!
        browser.keepTab("a")
        browser.pageChanged("a", EnginePageState(url = "https://a.test", title = "Kept front"))
        assertTrue(fresh.current())
        assertEquals(listOf(PageMenuWorkspaceAction.OPEN_BESIDE), queued.available())
        assertTrue(queued.perform(fresh.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
        val original = browser.publicSnapshot()!!
        browser.applySyncedSnapshot(original.copy(spaces = original.spaces.map { space ->
            space.copy(tabs = space.tabs.map { if (it.id == "a") it.copy(url = "https://changed.test") else it })
        }))
        browser.applySyncedSnapshot(original)
        assertTrue(fresh.current())
        assertTrue(queued.available().isEmpty())
        fresh.land()
        assertNull(browser.state.value.workspace)
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        val latest = Menu(browser)
        assertTrue(latest.actions!!.perform(latest.scope(), PageMenuWorkspaceAction.OPEN_BESIDE))
        latest.land(); assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
    }
}

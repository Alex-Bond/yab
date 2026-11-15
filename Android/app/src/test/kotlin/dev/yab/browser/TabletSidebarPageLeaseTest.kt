package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserTabletPageEnvironment
import dev.yab.browser.ui.BrowserTabletSidebarEntry
import dev.yab.browser.ui.BrowserTabletSidebarControl
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TabletSidebarPageLeaseTest {
    private val tabs = listOf("a", "b").map { BrowserTab(it, "https://$it.test", it, createdAt = 1) }
    private val folder = BrowserFolder("f", "Folder")
    private val space = BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a", folders = listOf(folder))
    private val other = BrowserSpace("other", "Other", tabs = listOf(BrowserTab("x", "https://x.test", "X", createdAt = 1)), currentTabId = "x")
    private val snapshot = BrowserSnapshot(spaces = listOf(space, other), selectedSpaceId = space.id)
    private class Engine : BrowserEngine {
        val activated = mutableListOf<String>()
        val closed = mutableListOf<String>()
        val navigated = mutableListOf<String>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { activated += tab.id }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated += tab.id }
        override fun close(tabId: String) { closed += tabId }
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun browser(scope: CoroutineScope, initial: BrowserSnapshot = snapshot, engine: Engine = Engine()): BrowserController {
        var next = 0
        return BrowserController(object : BrowserRepository {
            override suspend fun load() = initial
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope, now = { 1 }, newId = { "new-${++next}" })
    }
    private fun register(browser: BrowserController, width: Double = 768.0, height: Double = 1024.0) {
        if (!browser.workspaceWindow.value.registered) browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }
    private fun entry(browser: BrowserController, environment: BrowserTabletPageEnvironment = BrowserTabletPageEnvironment { true }) =
        BrowserTabletSidebarEntry(browser, checkNotNull(browser.captureTabletSidebarPage(600)), environment)

    @Test fun portraitSelectsCapturedNonfrontPublicTabThroughExistingNativeActivationOnlyOnce() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine = engine); runCurrent(); register(browser)
        assertNull(browser.captureWorkspaceEntry()) // No full-window split permission in portrait.
        val original = entry(browser)
        val select = checkNotNull(original.tab(tabs.last()))
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertTrue(select.perform())
        assertEquals("b", browser.state.value.tab!!.id)
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertEquals("b", engine.activated.last())
        assertEquals(space.id, browser.state.value.selectedSpaceId)
        assertFalse(select.perform()); assertFalse(original.current())
    }

    @Test fun targetMustBeExactUniqueAndInTheOriginalSelectedPublicSpace() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val original = entry(browser)
        assertNull(original.tab(tabs.last().copy(url = "https://changed.test")))
        assertNull(original.tab(other.tabs.single()))
        assertNull(original.tab(tabs.last().copy(isPrivate = true)))
        assertNull(original.folder(folder.copy(open = false)))
        assertNull(original.folder(BrowserFolder("foreign", "Folder")))
        assertEquals(space.tabs, browser.state.value.space!!.tabs)
        val duplicateFolders = snapshot.copy(spaces = listOf(space.copy(folders = listOf(folder, folder.copy(name = "Other"))), other))
        browser.applySyncedSnapshot(duplicateFolders)
        assertNull(entry(browser).folder(folder))
    }

    @Test fun folderToggleUsesOriginalFolderAndCannotRepeatOrRetargetAfterMetadataChanges() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val original = entry(browser)
        val select = checkNotNull(original.tab(tabs.last()))
        val toggle = checkNotNull(original.folder(folder))
        assertTrue(toggle.perform())
        assertEquals(folder.copy(open = false), browser.state.value.space!!.folders.single())
        assertEquals("a", browser.state.value.tab!!.id)
        assertEquals(space.tabs, browser.state.value.space!!.tabs)
        assertFalse(toggle.perform()); assertFalse(select.perform())
        val fresh = entry(browser)
        assertTrue(checkNotNull(fresh.folder(folder.copy(open = false))).perform())
        assertEquals(folder, browser.state.value.space!!.folders.single())
    }

    @Test fun clearTodayDelegatesExistingProtectionAndUndoInsteadOfClearingTheSelectedOrKeptPages() = runTest {
        val safe = BrowserTab("safe", "https://safe.test", "Safe", createdAt = 1)
        val kept = safe.copy(id = "kept", place = TabPlace.KEPT)
        val task = safe.copy(id = "task", hasTask = true)
        val draft = safe.copy(id = "draft", hasDraft = true)
        val initial = snapshot.copy(spaces = listOf(space.copy(tabs = listOf(tabs.first(), safe, kept, task, draft)), other))
        val engine = Engine(); val browser = browser(backgroundScope, initial, engine); runCurrent(); register(browser)
        val clear = checkNotNull(entry(browser).clearToday())
        assertTrue(clear.perform())
        assertEquals(listOf("a", "kept", "task", "draft"), browser.state.value.space!!.tabs.map { it.id })
        assertEquals(listOf("safe"), engine.closed)
        assertEquals("a", browser.state.value.tab!!.id)
        assertTrue(browser.state.value.undoAvailable)
        assertFalse(clear.perform())
    }

    @Test fun newTabEntersExistingSingleFieldAndPreservesPairDraftAndActualTabs() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser, 1280.0, 800.0)
        browser.openBeside("b")
        browser.openField(); browser.fieldText("retained new-tab draft"); browser.dismissSurface()
        val before = browser.state.value
        val open = checkNotNull(entry(browser).newTab())
        assertTrue(open.perform())
        val after = browser.state.value
        assertEquals(BrowserSurface.FIELD, after.surface); assertTrue(after.fieldIsNewTab); assertFalse(after.fieldIsPrivate)
        assertEquals("retained new-tab draft", after.fieldText)
        assertEquals(before.workspace, after.workspace); assertEquals(before.space!!.tabs, after.space!!.tabs)
        assertEquals(before.surfaceEpoch + 1, after.surfaceEpoch)
        assertFalse(open.perform())
    }

    @Test fun nonfrontTabFolderAndPublicSpaceMetadataAbaPermanentlyRetireAllOriginalCommands() = runTest {
        val variants = listOf(
            space.copy(tabs = listOf(tabs.first(), tabs.last().copy(title = "Changed"))),
            space.copy(tabs = listOf(tabs.first(), tabs.last().copy(url = "https://changed.test"))),
            space.copy(tabs = listOf(tabs.first(), tabs.last().copy(place = TabPlace.KEPT, folderId = folder.id))),
            space.copy(tabs = tabs.take(1)),
            space.copy(folders = emptyList()),
            space.copy(folders = listOf(folder.copy(name = "Renamed"))),
            space.copy(folders = listOf(folder.copy(open = false))),
            space.copy(name = "Renamed"),
            space.copy(ownSignIns = true),
        )
        for (changed in variants) {
            val browser = browser(backgroundScope); runCurrent(); register(browser)
            val original = entry(browser)
            val select = checkNotNull(original.tab(tabs.last()))
            val clear = checkNotNull(original.clearToday())
            val open = checkNotNull(original.newTab())
            val oldRevision = browser.tabletSidebarRevision.value
            browser.applySyncedSnapshot(snapshot.copy(spaces = listOf(changed, other)))
            browser.applySyncedSnapshot(snapshot)
            assertEquals(space, browser.state.value.space)
            assertTrue(browser.tabletSidebarRevision.value > oldRevision)
            assertFalse(original.current()); assertFalse(select.perform()); assertFalse(clear.perform()); assertFalse(open.perform())
            assertTrue(checkNotNull(entry(browser).tab(tabs.last())).perform())
        }
    }

    @Test fun frontKeepAndTitleRetireSidebarWithoutChangingExistingAddressOrHistoryAuthority() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val address = checkNotNull(browser.captureTabletPageEntry(600))
        val original = entry(browser)
        val generation = browser.historyPresentationLifetime.value
        browser.keepTab("a")
        val kept = browser.publicSnapshot()!!
        browser.applySyncedSnapshot(kept.copy(spaces = kept.spaces.map { owner -> owner.copy(tabs = owner.tabs.map {
            if (it.id == "a") it.copy(title = "New title", lastActiveAt = 12) else it
        }) }))
        assertFalse(original.current())
        assertEquals(generation, browser.historyPresentationLifetime.value)
        assertTrue(browser.tabletPageEntryCurrent(address))
        assertSame(address, browser.captureTabletPageEntry(600))
        assertTrue(checkNotNull(entry(browser).folder(folder)).perform())
    }

    @Test fun unrelatedSpaceHistoryAndProgressDoNotRetireSelectedPublicRows() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val original = entry(browser)
        val open = checkNotNull(original.newTab())
        val revision = browser.tabletSidebarRevision.value
        browser.applySyncedSnapshot(snapshot.copy(spaces = listOf(space, other.copy(name = "Fresh other")),
            history = listOf(BrowserVisit("https://history.test", "History", 2))))
        browser.pageChanged("a", EnginePageState(loading = true, progress = .5f))
        assertEquals(revision, browser.tabletSidebarRevision.value)
        assertTrue(original.current()); assertTrue(open.current()); assertTrue(open.perform())
    }

    @Test fun sourceStopAccountConfigPrivateAndFindAbaCannotReviveAnOldPage() = runTest {
        for (change in listOf("stop", "account", "config", "private", "find", "space")) {
            val browser = browser(backgroundScope); runCurrent(); register(browser)
            val original = entry(browser)
            val open = checkNotNull(original.newTab())
            when (change) {
                "stop" -> { browser.backgrounded(); browser.foregrounded() }
                "account" -> browser.invalidateLocalOwnership()
                "config" -> { browser.invalidateWorkspaceWindow(); register(browser) }
                "private" -> { browser.showPrivate(); assertNull(browser.captureTabletSidebarPage(600)); browser.selectSpace(space.id) }
                "find" -> { browser.beginFind(); browser.dismissFind() }
                else -> { browser.selectSpace(other.id); browser.selectSpace(space.id) }
            }
            assertFalse(original.current()); assertFalse(open.perform())
            assertTrue(checkNotNull(entry(browser).newTab()).perform())
        }
    }

    @Test fun originalEnvironmentRefusalIsPermanentAndNeverTurnsFailedNativeAdmissionIntoEmpty() = runTest {
        val blank = snapshot.copy(spaces = listOf(space.copy(tabs = listOf(tabs.first().copy(url = "about:blank"))), other))
        for (change in listOf("account", "native", "intent")) {
            val blankBrowser = browser(backgroundScope, blank); runCurrent(); register(blankBrowser)
            val originalAccount = Any(); val originalNative = Any(); val originalIntent = Any()
            var account = originalAccount; var native = originalNative; var intent = originalIntent
            val context = BrowserTabletPageEnvironment { account === originalAccount && native === originalNative && intent === originalIntent }
            val original = entry(blankBrowser, context)
            val open = checkNotNull(original.newTab())
            when (change) { "account" -> account = Any(); "native" -> native = Any(); else -> intent = Any() }
            assertFalse(open.perform())
            account = originalAccount; native = originalNative; intent = originalIntent
            assertFalse(original.current()); assertFalse(open.perform())
            assertEquals("about:blank", blankBrowser.state.value.tab!!.url)
            assertEquals(BrowserSurface.PAGE, blankBrowser.state.value.surface)
            assertTrue(checkNotNull(entry(blankBrowser).newTab()).perform())
        }

        val empty = browser(backgroundScope, snapshot.copy(spaces = listOf(space.copy(tabs = emptyList(), currentTabId = null), other)))
        runCurrent(); register(empty)
        assertNull(empty.state.value.tab)
        assertTrue(checkNotNull(entry(empty).newTab()).perform())
        assertTrue(empty.state.value.space!!.tabs.isEmpty())
    }

    @Test fun environmentChangeDuringFinalReadIsCaughtByActualControllerBeforeDispatch() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        var revoke = false
        val original = entry(browser, BrowserTabletPageEnvironment {
            if (revoke) browser.invalidateLocalOwnership()
            true
        })
        val select = checkNotNull(original.tab(tabs.last()))
        revoke = true
        assertFalse(select.perform())
        assertEquals("a", browser.state.value.tab!!.id)
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
    }

    @Test fun sameSelectedRowAndNoopClearStillConsumeTheirExactCommandsOnlyOnce() = runTest {
        val initial = snapshot.copy(spaces = listOf(space.copy(tabs = listOf(tabs.first(), tabs.last().copy(place = TabPlace.KEPT))), other))
        val engine = Engine(); val browser = browser(backgroundScope, initial, engine); runCurrent(); register(browser)
        val page = checkNotNull(browser.captureTabletSidebarPage(600))
        val select = checkNotNull(browser.captureTabletSidebarTab(page, tabs.first()))
        val revision = browser.tabletSidebarRevision.value
        assertTrue(browser.selectTabletSidebarTab(select))
        assertEquals(revision, browser.tabletSidebarRevision.value)
        assertTrue(browser.tabletSidebarPageCurrent(page))
        val activations = engine.activated.size
        assertFalse(browser.selectTabletSidebarTab(select))
        assertEquals(activations, engine.activated.size)
        val clear = checkNotNull(browser.captureTabletSidebarClearToday(page))
        assertTrue(browser.clearTabletSidebarToday(clear))
        assertEquals(revision, browser.tabletSidebarRevision.value)
        assertTrue(engine.closed.isEmpty())
        assertTrue(browser.tabletSidebarPageCurrent(page))
        assertFalse(browser.clearTabletSidebarToday(clear))
        assertFalse(browser.newTabletSidebarTab(clear)) // A command cannot be swapped to another action.
    }

    @Test fun callerRetirementAndInvalidOrNonTabletWindowsCannotMintOrBorrowCommands() = runTest {
        val browser = browser(backgroundScope); runCurrent()
        assertNull(browser.captureTabletSidebarPage(600))
        register(browser, 699.9, 1024.0); assertNull(browser.captureTabletSidebarPage(600))
        register(browser); assertNull(browser.captureTabletSidebarPage(599))
        val original = entry(browser)
        val select = checkNotNull(original.tab(tabs.last()))
        select.retire(); assertFalse(select.perform())
        val open = checkNotNull(original.newTab())
        original.retire(); assertFalse(open.perform())
        assertEquals("a", browser.state.value.tab!!.id)
        val context = BrowserTabletPageEnvironment { true }
        val fresh = entry(browser, context)
        val current = checkNotNull(fresh.newTab())
        context.retire(); assertFalse(current.perform())
        assertTrue(checkNotNull(entry(browser).newTab()).perform())
    }

    @Test fun originalLayoutRevisionAbaRetiresEverySavedControlActionWithoutRetiringTheMainEntry() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val original = entry(browser)
        var layoutRevision = 0L
        val capturedRevision = layoutRevision
        val control = BrowserTabletSidebarControl(original) { layoutRevision == capturedRevision }
        val select = checkNotNull(control.tab(tabs.last()))
        val toggle = checkNotNull(control.folder(folder))
        val clear = checkNotNull(control.clearToday())
        val open = checkNotNull(control.newTab())
        layoutRevision++ // shown -> hidden
        layoutRevision++ // hidden -> shown, possibly one conflated UI rendering
        assertFalse(select.perform()); assertFalse(toggle.perform()); assertFalse(clear.perform()); assertFalse(open.perform())
        assertFalse(control.current()); assertTrue(original.current())
        assertEquals("a", browser.state.value.tab!!.id)
        assertEquals(folder, browser.state.value.space!!.folders.single())
        val freshRevision = layoutRevision
        val fresh = BrowserTabletSidebarControl(original) { layoutRevision == freshRevision }
        assertTrue(checkNotNull(fresh.tab(tabs.last())).perform())
        assertEquals("b", browser.state.value.tab!!.id)
    }
}

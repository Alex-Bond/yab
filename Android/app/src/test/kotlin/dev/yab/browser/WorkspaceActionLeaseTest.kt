package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class WorkspaceActionLeaseTest {
    private val tabs = listOf("a", "b", "c").map { BrowserTab(it, "https://$it.test", it, createdAt = 1) }
    private val initial = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a")), selectedSpaceId = "s")
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
    private fun browser(scope: CoroutineScope, engine: Engine = Engine()): BrowserController {
        var id = 0
        val repo = object : BrowserRepository {
            override suspend fun load() = initial
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }
        return BrowserController(repo, engine, scope, now = { 1 }, newId = { "new-${++id}" })
    }
    private fun window(browser: BrowserController, width: Double = 1366.0, height: Double = 1024.0) {
        if (!browser.workspaceWindow.value.registered) browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }
    private fun menu(browser: BrowserController, target: String? = null): WorkspaceActionLease =
        browser.captureWorkspaceActions(browser.captureWorkspaceEntry()!!,
            target?.let { id -> browser.state.value.space!!.tabs.single { it.id == id } })!!

    @Test fun landscapeUsesUntruncatedWindowAndBothSourceThresholds() {
        assertFalse(BrowserWorkspaceWindow(599.9, 400.0).expanded)
        assertTrue(BrowserWorkspaceWindow(600.0, 400.0).expanded)
        assertFalse(BrowserWorkspaceWindow(640.999, 400.0).canSplit)
        assertTrue(BrowserWorkspaceWindow(641.0, 400.0).canSplit)
        assertFalse(BrowserWorkspaceWindow(768.0, 1024.0).canSplit)
        assertFalse(BrowserWorkspaceWindow(700.0, 700.0).canSplit)
        assertTrue(BrowserWorkspaceWindow(700.9, 700.1).canSplit)
        assertFalse(BrowserWorkspaceWindow(700.1, 700.9).canSplit)
        for (size in listOf(BrowserWorkspaceWindow(0.0, 100.0), BrowserWorkspaceWindow(800.0, -1.0),
            BrowserWorkspaceWindow(Double.NaN, 500.0), BrowserWorkspaceWindow(800.0, Double.POSITIVE_INFINITY))) assertFalse(size.canSplit)
    }

    @Test fun imeResizedContentCannotTurnPortraitIntoSplitOrRevokeLandscapeSource() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser)
        val source = browser.workspaceWindow.value
        val held = menu(browser, "b")
        val landscape = BrowserWorkspaceLayout(1366, 500, true, source.geometry!!)
        assertTrue(landscape.split); assertEquals(682, landscape.paneWidth)
        val portrait = BrowserWorkspaceLayout(768, 300, true, BrowserWorkspaceWindow(768.0, 1024.0))
        assertTrue(portrait.expanded); assertFalse(portrait.split); assertEquals(768, portrait.paneWidth)
        window(browser)
        assertEquals(source, browser.workspaceWindow.value)
        assertTrue(browser.workspaceActionsCurrent(held))
        browser.openBeside("b", held)
        assertEquals(BrowserWorkspace("a", "b", "b"), browser.state.value.workspace)
    }

    @Test fun coalescedConfigurationAbaAndOldCommitCannotReadmitAnyOriginalAction() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser)
        browser.openBeside("b")
        val opening = browser.captureWorkspaceEntry()!!
        val held = menu(browser)
        val old = browser.workspaceWindow.value
        val original = browser.state.value
        browser.invalidateWorkspaceWindow(); browser.invalidateWorkspaceWindow()
        assertFalse(browser.commitWorkspaceWindow(old.configuration, old.geometry!!))
        browser.resizeWorkspace(true) // A legacy caller cannot authorize the unknown registered window.
        browser.newTabBeside(); browser.closeWorkspacePage(); browser.fullSpread(); browser.openBeside("c")
        assertEquals(original, browser.state.value)
        window(browser)
        browser.newTabBeside(held); browser.closeWorkspacePage(held); browser.fullSpread(held)
        assertEquals(original, browser.state.value)
        assertFalse(browser.workspaceActionsCurrent(held))
        assertFalse(browser.workspaceEntryCurrent(opening))
        assertNull(browser.captureWorkspaceActions(opening))
        browser.fullSpread(menu(browser))
        assertNull(browser.state.value.workspace)
        assertTrue(engine.closed.isEmpty()); assertTrue(engine.navigated.isEmpty())
    }

    @Test fun portraitRoundTripKeepsOriginalPairNewPageAndTypedDraftWithoutNavigation() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser)
        browser.newTabBeside(menu(browser)); browser.fieldText("https://typed.test/path")
        val before = browser.state.value
        val pair = before.workspace!!
        val front = before.tab!!.id
        window(browser, 768.0, 1024.0)
        assertNull(browser.captureWorkspaceEntry())
        browser.newTabBeside(); browser.closeWorkspacePage(); browser.fullSpread(); browser.openBeside("c")
        assertEquals(before, browser.state.value)
        assertFalse(BrowserWorkspaceLayout(768, 500, true, browser.workspaceWindow.value.geometry!!).split)
        window(browser)
        assertEquals(pair, browser.state.value.workspace)
        assertEquals(front, browser.state.value.tab!!.id)
        assertEquals("https://typed.test/path", browser.state.value.fieldText)
        assertTrue(engine.closed.isEmpty()); assertTrue(engine.navigated.isEmpty())
        browser.submitField()
        assertEquals(front, browser.state.value.tab!!.id)
        assertEquals(pair.copy(newPage = null), browser.state.value.workspace)
        assertEquals(listOf(front), engine.navigated)
    }

    @Test fun openedTargetRevokesOnValueAndRemovalAbaButUnrelatedRowDoesNot() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser)
        val unrelated = menu(browser, "b")
        browser.applySyncedSnapshot(initial.copy(spaces = listOf(initial.spaces.single().copy(tabs = tabs.map { if (it.id == "c") it.copy(title = "Changed C") else it }))))
        assertTrue(browser.workspaceActionsCurrent(unrelated))
        browser.openBeside("b", unrelated)
        assertEquals(BrowserWorkspace("a", "b", "b"), browser.state.value.workspace)
        browser.fullSpread(menu(browser)); browser.selectTab("a")
        for (remove in listOf(false, true)) {
            val held = menu(browser, "b")
            val changed = if (remove) tabs.filterNot { it.id == "b" } else tabs.map { if (it.id == "b") it.copy(url = "https://changed.test") else it }
            browser.applySyncedSnapshot(initial.copy(spaces = listOf(initial.spaces.single().copy(tabs = changed))))
            browser.applySyncedSnapshot(initial)
            assertFalse(browser.workspaceActionsCurrent(held))
            browser.openBeside("b", held)
            assertNull(browser.state.value.workspace)
        }
        browser.openBeside("b", menu(browser, "b"))
        assertEquals(BrowserWorkspace("a", "b", "b"), browser.state.value.workspace)
    }

    @Test fun originalFrontProfileForegroundAccountAndSurfaceNeverReviveAfterAba() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser)
        fun rejected(held: WorkspaceActionLease) {
            assertFalse(browser.workspaceActionsCurrent(held))
            val before = browser.state.value
            browser.newTabBeside(held)
            assertEquals(before, browser.state.value)
        }
        val url = menu(browser)
        browser.applySyncedSnapshot(initial.copy(spaces = listOf(initial.spaces.single().copy(tabs = tabs.map { if (it.id == "a") it.copy(url = "https://other.test") else it }))))
        browser.applySyncedSnapshot(initial); rejected(url)
        val profile = menu(browser)
        browser.applySyncedSnapshot(initial.copy(spaces = listOf(initial.spaces.single().copy(ownSignIns = true))))
        browser.applySyncedSnapshot(initial); rejected(profile)
        val stopped = menu(browser); browser.backgrounded(); browser.foregrounded(); rejected(stopped)
        val surface = menu(browser); browser.openField(); browser.dismissSurface(); rejected(surface)
        browser.openField()
        val privateField = menu(browser, "b")
        browser.fieldPrivacy(true); assertNull(browser.captureWorkspaceEntry())
        browser.fieldPrivacy(false); rejected(privateField); browser.dismissSurface()
        val account = menu(browser); browser.invalidateLocalOwnership(); rejected(account)
        browser.newTabBeside(menu(browser))
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertNotNull(browser.state.value.workspace!!.newPage)
    }

    @Test fun unknownInvalidAndHeadlessGeometryCannotMintUiAuthority() = runTest {
        val browser = browser(backgroundScope); runCurrent()
        browser.resizeWorkspace(true)
        assertNull(browser.captureWorkspaceEntry())
        browser.invalidateWorkspaceWindow(); browser.resizeWorkspace(true)
        assertNull(browser.captureWorkspaceEntry())
        browser.newTabBeside(); assertNull(browser.state.value.workspace)
        window(browser)
        val original = browser.captureWorkspaceEntry()!!
        assertFalse(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(Double.NaN, 100.0)))
        assertNull(browser.workspaceWindow.value.geometry)
        assertFalse(browser.workspaceEntryCurrent(original))
        assertNull(browser.captureWorkspaceEntry())
        window(browser)
        assertFalse(browser.workspaceEntryCurrent(original))
        assertNotNull(browser.captureWorkspaceEntry())
    }

    @Test fun frontMetadataAdmissionNeverWeakensExplicitTargetValueAndRestorationGuards() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser)
        val opening = browser.captureWorkspaceEntry()!!
        val target = browser.state.value.space!!.tabs.single { it.id == "b" }
        browser.keepTab("a")
        browser.pageChanged("a", EnginePageState(url = "https://a.test", title = "Updated front"))
        assertTrue(browser.workspaceEntryCurrent(opening))
        val held = browser.captureWorkspaceActions(opening, target)!!
        val original = browser.publicSnapshot()!!
        browser.pageChanged("b", EnginePageState(url = "https://b.test", title = "Changed target"))
        assertTrue(browser.workspaceEntryCurrent(opening))
        assertFalse(browser.workspaceActionsCurrent(held))
        assertNull(browser.captureWorkspaceActions(opening, target))
        browser.openBeside("b", held)
        assertNull(browser.state.value.workspace)
        browser.applySyncedSnapshot(original)
        assertFalse(browser.workspaceActionsCurrent(held))
        browser.openBeside("b", held)
        assertNull(browser.state.value.workspace)
        browser.openBeside("b", menu(browser, "b"))
        assertEquals(BrowserWorkspace("a", "b", "b"), browser.state.value.workspace)
        assertEquals(TabPlace.KEPT, browser.state.value.space!!.tabs.single { it.id == "a" }.place)
        assertTrue(engine.closed.isEmpty()); assertTrue(engine.navigated.isEmpty())
    }
}

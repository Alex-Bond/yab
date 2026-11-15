package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserTabletWorkspacePresentationTest {
    private val tabs = listOf("a", "b").map { BrowserTab(it, "https://$it.test", it, createdAt = 1) }
    private val folder = BrowserFolder("f", "Folder")
    private val space = BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a", folders = listOf(folder))
    private val window = WorkspaceWindowState(true, 2, 3, BrowserWorkspaceWindow(900.0, 768.0))
    private class Engine : BrowserEngine {
        val calls = mutableListOf<String>()
        val sessions = mutableMapOf<String, Any>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { sessions.getOrPut(tab.id) { Any() }; calls += "activate:${tab.id}" }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { calls += "navigate:${tab.id}" }
        override fun close(tabId: String) { calls += "close:$tabId"; sessions.remove(tabId) }
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun browser(scope: CoroutineScope, initial: BrowserSpace = space, engine: Engine = Engine()): BrowserController =
        BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(initial), selectedSpaceId = initial.id)
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope, now = { 1 }, newId = { "new" })
    private fun register(browser: BrowserController) {
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, window.geometry!!))
    }
    private fun entry(browser: BrowserController) = BrowserTabletSidebarEntry(browser,
        checkNotNull(browser.captureTabletSidebarPage(600)), BrowserTabletPageEnvironment { true })
    private fun frame(state: BrowserTabletWorkspaceState, source: Any, current: () -> Boolean = { true },
        original: WorkspaceWindowState = window, statusTop: Double = 24.0, paired: Boolean = true): BrowserTabletWorkspacePresentation =
        checkNotNull(state.capture(original, 600, statusTop, paired, source, current))

    @Test fun toggleAbaRejectsOldToggleAndActualRowWhilePairDraftAndEngineSessionsStayOriginal() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine = engine); runCurrent(); register(browser)
        browser.openBeside("b")
        browser.openField(); browser.fieldText("kept draft"); browser.dismissSurface()
        val original = entry(browser)
        val source = browser.state.value
        val sessions = engine.sessions.toMap(); val calls = engine.calls.toList()
        val state = BrowserTabletWorkspaceState()
        val first = frame(state, original, original::current, browser.workspaceWindow.value)
        val row = checkNotNull(BrowserTabletSidebarControl(original, first::current).tab(tabs.first()))
        val oldToggle = first.toggleControl { true }
        assertTrue(oldToggle.perform()); assertFalse(state.sidebarShown)
        val hidden = frame(state, original, original::current, browser.workspaceWindow.value)
        assertTrue(hidden.toggleControl { true }.perform()); assertTrue(state.sidebarShown)
        val fresh = frame(state, original, original::current, browser.workspaceWindow.value)
        assertFalse(oldToggle.perform()); assertFalse(row.perform())
        assertSame(source, browser.state.value)
        assertEquals(calls, engine.calls)
        for ((id, session) in sessions) assertSame(session, engine.sessions[id])
        assertTrue(original.current())
        val newTab = checkNotNull(BrowserTabletSidebarControl(original, fresh::current).newTab())
        assertTrue(newTab.perform())
        assertEquals("kept draft", browser.state.value.fieldText)
        assertEquals(source.workspace, browser.state.value.workspace)
        assertEquals(source.space!!.tabs, browser.state.value.space!!.tabs)
    }

    @Test fun observedWindowGeometryGenerationStatusAndPairAbaPermanentlyRetireOriginalRows() = runTest {
        val variants = listOf(window.copy(configuration = 4), window.copy(generation = 5),
            window.copy(geometry = BrowserWorkspaceWindow(1024.0, 768.0)))
        for (changed in variants) {
            val browser = browser(backgroundScope); runCurrent(); register(browser)
            val original = entry(browser); val state = BrowserTabletWorkspaceState()
            val first = frame(state, original)
            val row = checkNotNull(BrowserTabletSidebarControl(original, first::current).tab(tabs.last()))
            frame(state, original, original = changed)
            val restored = frame(state, original)
            assertFalse(first.current()); assertFalse(row.perform())
            assertTrue(checkNotNull(BrowserTabletSidebarControl(original, restored::current).tab(tabs.last())).perform())
        }
        for (change in listOf("status", "pair")) {
            val state = BrowserTabletWorkspaceState(); val source = Any()
            val first = frame(state, source)
            if (change == "status") frame(state, source, statusTop = 40.0) else frame(state, source, paired = false)
            val restored = frame(state, source)
            assertFalse(first.current()); assertTrue(restored.current())
        }
    }

    @Test fun unchangedCaptureIsStableAndDoesNotWriteVisibleLayoutOrRevokeTheOriginalScope() {
        val state = BrowserTabletWorkspaceState(); val source = Any()
        val first = frame(state, source)
        val revision = state.layoutRevision
        repeat(20) { assertSame(first, frame(state, source)) }
        assertEquals(revision, state.layoutRevision)
        assertTrue(first.current()); assertTrue(state.sidebarShown)
        assertSame(first.frame, frame(state, source).frame)
    }

    @Test fun invalidLayoutAndDifferentOriginalSourceNeverReviveAnOldCapture() {
        val state = BrowserTabletWorkspaceState(); val source = Any()
        val first = frame(state, source)
        assertNull(state.capture(window.copy(geometry = null), 600, 24.0, true, source) { true })
        val restored = frame(state, source)
        assertFalse(first.current()); assertTrue(restored.current())
        frame(state, Any())
        assertFalse(restored.current())
        val fresh = frame(state, source)
        assertTrue(fresh.current())
        assertNull(state.capture(window, 599, 24.0, true, source) { true })
        assertFalse(fresh.current())
    }

    @Test fun originalSceneRefusalAndDisposedToggleStayRefusedWhileFreshRenderingCanRecover() {
        val state = BrowserTabletWorkspaceState(); val source = Any()
        var current = true
        val first = frame(state, source, { current })
        val old = first.toggleControl { true }
        current = false
        assertFalse(old.perform())
        current = true
        assertFalse(first.current()); assertFalse(old.perform())
        val fresh = frame(state, source, { current })
        assertNotSame(first, fresh); assertTrue(fresh.current())
        val disposed = fresh.toggleControl { true }; disposed.retire()
        assertFalse(disposed.perform()); assertTrue(state.sidebarShown)
        assertTrue(fresh.toggleControl { true }.perform())
    }

    @Test fun sceneReadThatChangesTheOriginalLayoutCannotAuthorizeItsOldToggle() {
        val state = BrowserTabletWorkspaceState(); val source = Any()
        var replace = false
        val first = frame(state, source, {
            if (replace) frame(state, source, statusTop = 40.0)
            true
        })
        replace = true
        assertFalse(first.toggleControl { true }.perform())
        assertTrue(state.sidebarShown)
        assertFalse(first.current())
    }

    @Test fun stoppedOrReplacedPageIsStillRefusedEvenWithCurrentUiLayoutScope() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val original = entry(browser); val state = BrowserTabletWorkspaceState()
        val presentation = frame(state, original, original::current, browser.workspaceWindow.value)
        val row = checkNotNull(BrowserTabletSidebarControl(original, presentation::current).tab(tabs.last()))
        browser.backgrounded(); browser.foregrounded()
        assertFalse(presentation.current()); assertFalse(row.perform())
        assertEquals("a", browser.state.value.tab!!.id)
        val fresh = entry(browser)
        val restored = frame(state, fresh, fresh::current, browser.workspaceWindow.value)
        assertTrue(checkNotNull(BrowserTabletSidebarControl(fresh, restored::current).tab(tabs.last())).perform())
    }

    @Test fun acceptedNoopSelectedRowAndClearRedrawCaptureFreshActionsWithoutRetargetingOldCallbacks() = runTest {
        val initial = space.copy(tabs = listOf(tabs.first(), tabs.last().copy(place = TabPlace.KEPT)))
        val browser = browser(backgroundScope, initial); runCurrent(); register(browser)
        val original = entry(browser)
        val presentation = frame(BrowserTabletWorkspaceState(), original, original::current, browser.workspaceWindow.value)
        val control = BrowserTabletSidebarControl(original, presentation::current)
        val render = BrowserTabletSidebarRenderState(control)
        val old = checkNotNull(render.tab(tabs.first())) // Original render capture, before click.
        val before = browser.tabletSidebarRevision.value
        assertTrue(old.perform()); assertEquals(1L, render.revision)
        assertEquals(before, browser.tabletSidebarRevision.value); assertTrue(control.current())
        assertFalse(old.perform()); assertEquals(1L, render.revision)
        val fresh = checkNotNull(render.tab(tabs.first())) // The subsequent rendering, not old.perform().
        assertTrue(fresh.perform()); assertEquals(2L, render.revision)
        val clear = checkNotNull(render.clearToday())
        assertTrue(clear.perform()); assertEquals(3L, render.revision)
        assertEquals(before, browser.tabletSidebarRevision.value); assertTrue(control.current())
        assertFalse(clear.perform()); assertEquals(3L, render.revision)
        assertTrue(checkNotNull(render.clearToday()).perform()); assertEquals(4L, render.revision)
    }

    @Test fun refusedOrDisposedRenderedActionDoesNotAcknowledgeOrMintAReplacement() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val original = entry(browser); val state = BrowserTabletWorkspaceState()
        val presentation = frame(state, original, original::current, browser.workspaceWindow.value)
        val control = BrowserTabletSidebarControl(original, presentation::current)
        val render = BrowserTabletSidebarRenderState(control)
        val disposed = checkNotNull(render.tab(tabs.last())); disposed.retire()
        assertFalse(disposed.perform()); assertEquals(0L, render.revision)
        val old = checkNotNull(render.newTab())
        assertTrue(presentation.toggleControl { true }.perform())
        assertFalse(old.perform()); assertEquals(0L, render.revision)
        assertNull(render.newTab())
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
    }

    @Test fun publicKeptProjectionKeepsClosedChildrenHiddenAndOrphansVisibleWithoutPrivateRows() {
        val closed = BrowserFolder("closed", "Closed", open = false)
        val child = BrowserFolder("child", "Child", parentId = closed.id)
        val hidden = tabs.first().copy(place = TabPlace.KEPT, folderId = child.id)
        val orphan = tabs.last().copy(place = TabPlace.KEPT, folderId = "missing")
        val privateTab = tabs.last().copy(id = "private", place = TabPlace.KEPT, isPrivate = true)
        val rows = browserTabletSidebarRows(space.copy(tabs = listOf(hidden, orphan, privateTab), folders = listOf(closed, child)))
        assertEquals(listOf(closed.id), rows.mapNotNull { it.folder?.id })
        assertEquals(listOf(orphan.id), rows.mapNotNull { it.tab?.id })
        val cycle = browserTabletSidebarRows(space.copy(tabs = listOf(orphan),
            folders = listOf(BrowserFolder("x", "X", "y"), BrowserFolder("y", "Y", "x"))))
        assertEquals(listOf(orphan.id), cycle.mapNotNull { it.tab?.id })
        val deep = List(24) { index -> BrowserFolder("depth-$index", "Depth",
            parentId = if (index == 0) null else "depth-${index - 1}") }
        val visible = tabs.first().copy(place = TabPlace.KEPT, folderId = deep[19].id)
        val beyondLimit = tabs.last().copy(place = TabPlace.KEPT, folderId = deep.last().id)
        val bounded = browserTabletSidebarRows(space.copy(tabs = listOf(visible, beyondLimit), folders = deep))
        assertEquals(deep.take(21).map { it.id }, bounded.mapNotNull { it.folder?.id })
        assertEquals(listOf(visible.id), bounded.mapNotNull { it.tab?.id })
        assertEquals(20, bounded.maxOf { it.depth })
    }

    @Test fun lazyKeysSeparateStaticSectionsRawIdsAndDuplicateOrdinalsWhileUniqueRowsSurviveReorder() {
        val ids = listOf("new-tab", "pins", "tab:a", "a", "a:0", "a|D0", "", "1:x|N", "\uD83D\uDE00")
        val sections = listOf(BrowserTabletSidebarSection.KEPT_FOLDER,
            BrowserTabletSidebarSection.KEPT_TAB, BrowserTabletSidebarSection.TODAY_TAB)
        val targets = sections.flatMap { section -> ids.map { section to it } }
        val static = listOf(BrowserTabletSidebarSection.PINS, BrowserTabletSidebarSection.KEPT_CAPTION,
            BrowserTabletSidebarSection.TODAY_CAPTION, BrowserTabletSidebarSection.TODAY_EMPTY,
            BrowserTabletSidebarSection.NEW_TAB).map { browserTabletSidebarKey(it) }
        val keys = browserTabletSidebarKeys(targets)
        assertEquals(static.size + targets.size, (static + keys).toSet().size)
        val original = targets.zip(keys).toMap()
        assertEquals(original, targets.reversed().zip(browserTabletSidebarKeys(targets.reversed())).toMap())

        // The former "$id:$index" fallback collided with a distinct real ID "a:0".
        val duplicates = listOf("a", "a", "a:0", "a:1", "a|D0", "I1:a|D0", "new-tab")
            .map { BrowserTabletSidebarSection.TODAY_TAB to it }
        val duplicateKeys = browserTabletSidebarKeys(duplicates)
        assertEquals(duplicates.size + static.size, (duplicateKeys + static).toSet().size)
        assertNotEquals(duplicateKeys[0], duplicateKeys[1])
        assertEquals(original[BrowserTabletSidebarSection.TODAY_TAB to "a:0"], duplicateKeys[2])
        assertNotEquals(browserTabletSidebarKey(BrowserTabletSidebarSection.TODAY_TAB),
            browserTabletSidebarKey(BrowserTabletSidebarSection.TODAY_TAB, ""))
    }
}

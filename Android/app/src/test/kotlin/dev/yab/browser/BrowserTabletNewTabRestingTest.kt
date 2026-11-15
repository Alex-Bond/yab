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
class BrowserTabletNewTabRestingTest {
    private val tabs = listOf("a", "b").map { BrowserTab(it, "https://$it.test", it, createdAt = 1) }
    private val initial = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a")), selectedSpaceId = "s")
    private class Engine : BrowserEngine {
        val calls = mutableListOf<String>()
        val sessions = mutableMapOf<String, Any>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { sessions.getOrPut(tab.id) { Any() }; calls += "activate:${tab.id}" }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { calls += "navigate:${tab.id}" }
        override fun close(tabId: String) { sessions.remove(tabId); calls += "close:$tabId" }
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun browser(scope: CoroutineScope, engine: Engine = Engine()): BrowserController = BrowserController(object : BrowserRepository {
        override suspend fun load() = initial
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }, engine, scope, now = { 1 }, newId = { "new" })
    private fun window(browser: BrowserController, width: Double = 900.0, height: Double = 768.0) {
        if (!browser.workspaceWindow.value.registered) browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }
    private fun hidden(browser: BrowserController): BrowserTabletWorkspaceState {
        val ui = BrowserTabletWorkspaceState()
        val frame = checkNotNull(ui.capture(browser.workspaceWindow.value, 600, 24.0, false, Any()) { true })
        assertTrue(frame.toggleSidebar()); assertFalse(ui.sidebarShown)
        return ui
    }
    private fun capture(browser: BrowserController, ui: BrowserTabletWorkspaceState, current: () -> Boolean = { true }) =
        checkNotNull(BrowserTabletNewTabRestingEntry.capture(browser, ui, 600, current))
    private fun control(browser: BrowserController, entry: BrowserTabletNewTabRestingEntry, tablet: Boolean = true,
        current: () -> Boolean = { true }) = entry.bind(BrowserFieldPlacementLease.capture(browser, tablet), current)

    @Test fun restingPublicNewTabClosesOriginalFieldShowsSidebarAndPreservesPairDraftAndSessions() = runTest {
        val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser)
        browser.openBeside("b")
        val ui = hidden(browser)
        browser.openField(); browser.fieldText("retained public draft")
        val entry = capture(browser, ui); val action = control(browser, entry)
        val before = browser.state.value; val sessions = engine.sessions.toMap(); val calls = engine.calls.toList()
        assertTrue(browser.restField(before.surfaceEpoch))
        assertTrue(action.perform()); assertTrue(ui.sidebarShown)
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertEquals(before.workspace, browser.state.value.workspace)
        assertEquals(before.space!!.tabs, browser.state.value.space!!.tabs)
        assertEquals(calls, engine.calls)
        sessions.forEach { (id, session) -> assertSame(session, engine.sessions[id]) }
        assertFalse(action.perform())
        browser.openField(); assertEquals("retained public draft", browser.state.value.fieldText)
    }

    @Test fun privateNewTabAlsoCompletesWithoutInventingTabsOrChangingItsOriginalProfile() = runTest {
        for (privateSpace in listOf(false, true)) {
            val engine = Engine(); val browser = browser(backgroundScope, engine); runCurrent(); window(browser)
            if (privateSpace) browser.showPrivate()
            browser.unlockPrivate(true)
            val ui = hidden(browser)
            browser.openField(privately = true)
            assertTrue(browser.state.value.fieldIsPrivate); assertTrue(browser.state.value.fieldIsNewTab)
            val entry = capture(browser, ui); val action = control(browser, entry)
            val before = browser.state.value; val calls = engine.calls.toList()
            assertTrue(browser.restField(before.surfaceEpoch)); assertTrue(action.perform())
            val after = browser.state.value
            assertTrue(ui.sidebarShown); assertEquals(BrowserSurface.PAGE, after.surface)
            assertEquals(before.selectedSpaceId, after.selectedSpaceId)
            assertEquals(before.space!!.websiteProfile, after.space!!.websiteProfile)
            assertEquals(before.space!!.tabs, after.space!!.tabs); assertEquals(calls, engine.calls)
            assertFalse(action.perform())
            if (privateSpace) {
                assertTrue(browser.state.value.space!!.isPrivate)
                browser.openField(privately = true)
                val locked = control(browser, capture(browser, ui))
                browser.restField(browser.state.value.surfaceEpoch); browser.lockPrivate()
                val blocked = browser.state.value; val revision = ui.layoutRevision
                assertTrue(blocked.privateContentBlocked); assertFalse(locked.perform())
                assertNull(BrowserTabletNewTabRestingEntry.capture(browser, ui, 600) { true })
                assertEquals(blocked, browser.state.value); assertEquals(revision, ui.layoutRevision)
            }
        }
    }

    @Test fun editAddressCompactTypingAndCoveredBodiesCannotUseTheRestingCommand() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); val ui = hidden(browser)
        browser.openField(newTab = false)
        assertNull(BrowserTabletNewTabRestingEntry.capture(browser, ui, 600) { true })
        browser.dismissSurface(); browser.openField()
        val entry = capture(browser, ui)
        val typing = control(browser, entry)
        assertFalse(typing.perform()); assertFalse(ui.sidebarShown); assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertTrue(browser.restField(browser.state.value.surfaceEpoch))
        assertFalse(control(browser, entry, tablet = false).perform())
        var uncovered = false
        val covered = control(browser, entry) { uncovered }
        assertFalse(covered.perform()); uncovered = true; assertFalse(covered.perform())
        assertFalse(ui.sidebarShown); assertTrue(control(browser, entry).perform())
        browser.openField(); browser.invalidateWorkspaceWindow(); window(browser, 600.0, 1000.0)
        assertNull(BrowserTabletNewTabRestingEntry.capture(browser, ui, 600) { true })
    }

    @Test fun stopWindowPrivacyAndAccountAbaPermanentlyRefuseOldOriginalInput() = runTest {
        for (boundary in listOf("stop", "window", "privacy", "account")) {
            val browser = browser(backgroundScope); runCurrent(); window(browser); val ui = hidden(browser)
            browser.openField(); val entry = capture(browser, ui); val action = control(browser, entry)
            val originalEpoch = browser.state.value.surfaceEpoch
            when (boundary) {
                "stop" -> { browser.backgrounded(); browser.foregrounded() }
                "window" -> { browser.invalidateWorkspaceWindow(); window(browser) }
                "privacy" -> { browser.fieldPrivacy(true); browser.fieldPrivacy(false) }
                "account" -> { browser.invalidateLocalOwnership(); browser.openField() }
            }
            browser.restField(browser.state.value.surfaceEpoch)
            val before = browser.state.value
            assertFalse(action.perform()); assertEquals(before, browser.state.value); assertFalse(ui.sidebarShown)
            if (boundary != "account") assertEquals(originalEpoch, before.surfaceEpoch)
            assertTrue(control(browser, capture(browser, ui)).perform()); assertTrue(ui.sidebarShown)
        }
    }

    @Test fun refusedDismissalDoesNotPublishAndEnsureShownNeverTogglesAnAlreadyShownSidebar() {
        val ui = BrowserTabletWorkspaceState()
        val window = WorkspaceWindowState(true, 2, 3, BrowserWorkspaceWindow(900.0, 768.0))
        val source = Any()
        val first = checkNotNull(ui.capture(window, 600, 24.0, false, source) { true })
        assertTrue(first.toggleSidebar())
        val hidden = checkNotNull(ui.capture(window, 600, 24.0, false, source) { true })
        val revision = ui.layoutRevision
        var attempts = 0
        assertFalse(ui.ensureShownAfter { attempts++; false })
        assertEquals(1, attempts); assertFalse(ui.sidebarShown); assertEquals(revision, ui.layoutRevision); assertTrue(hidden.current())
        assertTrue(ui.ensureShownAfter { attempts++; true }); assertTrue(ui.sidebarShown)
        assertEquals(revision + 1, ui.layoutRevision); assertFalse(hidden.current())
        val shownRevision = ui.layoutRevision
        assertTrue(ui.ensureShownAfter { attempts++; true }); assertTrue(ui.sidebarShown)
        assertEquals(shownRevision, ui.layoutRevision); assertEquals(3, attempts)
    }

    @Test fun originalSceneRefusalDisposalAndReentrantSourceReplacementNeverBorrowFreshField() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); val ui = hidden(browser)
        browser.openField()
        var sceneCurrent = true
        val entry = capture(browser, ui) { sceneCurrent }
        val action = control(browser, entry)
        sceneCurrent = false; browser.restField(browser.state.value.surfaceEpoch)
        assertFalse(action.perform()); sceneCurrent = true; assertFalse(action.perform())
        assertFalse(control(browser, entry).perform()); assertFalse(ui.sidebarShown)
        val fresh = capture(browser, ui); val disposed = control(browser, fresh); disposed.retire()
        assertFalse(disposed.perform())
        val replaced = control(browser, fresh) { browser.invalidateWorkspaceWindow(); window(browser); true }
        assertFalse(replaced.perform()); assertFalse(ui.sidebarShown); assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertTrue(control(browser, capture(browser, ui)).perform()); assertTrue(ui.sidebarShown)
    }
}

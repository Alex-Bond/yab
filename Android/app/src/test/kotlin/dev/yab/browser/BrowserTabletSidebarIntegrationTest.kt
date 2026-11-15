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
class BrowserTabletSidebarIntegrationTest {
    private val tab = BrowserTab("a", "https://a.test", "A", createdAt = 1)
    private val space = BrowserSpace("s", "Personal", tabs = listOf(tab), currentTabId = tab.id)
    private val window = WorkspaceWindowState(true, 2, 3, BrowserWorkspaceWindow(900.0, 768.0))
    private class Engine : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun close(tabId: String) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun browser(scope: CoroutineScope) = BrowserController(object : BrowserRepository {
        override suspend fun load() = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }, Engine(), scope, now = { 1 }, newId = { "new" })

    @Test fun footerSpacesRetainTheirOriginalPublicTargetAndCoverageScope() = runTest {
        val target = BrowserSpace("work", "Work", emoji = "💼")
        val browser = BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(space, target), selectedSpaceId = space.id)
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, Engine(), backgroundScope)
        runCurrent()
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, window.geometry!!))
        var covered = false
        fun control() = BrowserTabletSidebarControl(BrowserTabletSidebarEntry(browser,
            checkNotNull(browser.captureTabletSidebarPage(600)), BrowserTabletPageEnvironment { !covered })) { true }
        val stale = checkNotNull(control().space(target))
        covered = true
        assertFalse(stale.perform())
        covered = false
        assertFalse(stale.perform())
        assertEquals(space.id, browser.state.value.selectedSpaceId)
        val fresh = control()
        assertNull(fresh.space(target.copy(isPrivate = true)))
        assertNull(fresh.space(target.copy(name = "Replacement")))
        assertTrue(checkNotNull(fresh.space(target)).perform())
        assertEquals(target.id, browser.state.value.selectedSpaceId)
        assertFalse(stale.perform())
    }

    @Test fun menuCoverageCanRetireActionsAndReplaceControlsWithoutRetiringTheOriginalDrawingLayout() = runTest {
        val browser = browser(backgroundScope)
        runCurrent()
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, window.geometry!!))
        val page = checkNotNull(browser.captureTabletSidebarPage(600))
        var covered = false
        val oldEntry = BrowserTabletSidebarEntry(browser, page, BrowserTabletPageEnvironment { !covered })
        val owner = BrowserTabletWorkspaceState(); val source = Any()
        val original = checkNotNull(owner.capture(browser.workspaceWindow.value, 600, 24.0, false, source) { true })
        val oldRow = checkNotNull(BrowserTabletSidebarControl(oldEntry, original::current).tab(tab))
        val before = browser.state.value
        covered = true
        assertFalse(oldRow.perform()) // The original78 environment still denies covered input.
        original.retire() // A covered/removed control cannot be reused after return.
        val replacement = checkNotNull(owner.capture(browser.workspaceWindow.value, 600, 24.0, false, source) { true })
        assertNotSame(original, replacement)
        assertFalse(original.current()); assertTrue(original.layoutCurrent())
        assertEquals(original.frame, replacement.frame)
        covered = false
        assertFalse(oldRow.perform()); assertSame(before, browser.state.value)
        val fresh = BrowserTabletSidebarEntry(browser, page, BrowserTabletPageEnvironment { !covered })
        assertTrue(checkNotNull(BrowserTabletSidebarControl(fresh, replacement::current).tab(tab)).perform())
        val accepted = browser.state.value
        assertEquals(BrowserSurface.PAGE, accepted.surface)
        assertEquals(space.id, accepted.selectedSpaceId)
        assertEquals(space.websiteProfile, accepted.space?.websiteProfile)
        assertEquals(tab, accepted.tab)
        assertEquals(mapOf(space.id to listOf(tab.id)), accepted.recency)
        assertTrue(original.layoutCurrent())
    }

    @Test fun genuinePublicFieldKeepsOnlyDrawingIdentityWhilePageActionsRefuseAndFreshPageOrContextCannotReviveThem() = runTest {
        val browser = browser(backgroundScope); runCurrent()
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, window.geometry!!))
        val page = checkNotNull(browser.captureTabletSidebarPage(600))
        val entry = BrowserTabletSidebarEntry(browser, page, BrowserTabletPageEnvironment { true })
        val sources = BrowserTabletWorkspaceDrawingSource(); val context = Any()
        val owner = BrowserTabletWorkspaceState()
        fun drawing(source: Any) = checkNotNull(owner.capture(browser.workspaceWindow.value, 600, 24.0, false, source) { true })
        val pageSource = sources.capture(context, browser.historyPresentationLifetime.value, false)
        val original = drawing(pageSource)
        val row = checkNotNull(BrowserTabletSidebarControl(entry, original::current).tab(tab))
        browser.openField(newTab = false)
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        val fieldSource = sources.capture(context, browser.historyPresentationLifetime.value, true)
        assertSame(pageSource, fieldSource); assertTrue(sources.current(pageSource))
        assertSame(original, drawing(fieldSource))
        assertTrue(original.layoutCurrent()); assertFalse(row.perform())
        assertEquals(tab, browser.state.value.tab)
        browser.dismissSurface()
        val returnedSource = sources.capture(context, browser.historyPresentationLifetime.value, false)
        assertNotSame(pageSource, returnedSource); assertFalse(sources.current(pageSource))
        val returned = drawing(returnedSource)
        assertFalse(original.layoutCurrent()); assertFalse(row.perform()); assertTrue(returned.layoutCurrent())
        // A different account/space/profile context during Field must not reuse that drawing.
        val foreign = sources.capture(Any(), browser.historyPresentationLifetime.value, true)
        drawing(foreign)
        val restored = drawing(sources.capture(context, browser.historyPresentationLifetime.value, true))
        assertFalse(returned.layoutCurrent()); assertTrue(restored.layoutCurrent())
    }

    @Test fun originalMenuLayoutCannotSurviveObservedSourceStatusWindowOrToggleAbaEvenAfterControlReplacement() {
        for (change in listOf("source", "status", "window", "toggle")) {
            val owner = BrowserTabletWorkspaceState(); val source = Any()
            fun capture(key: Any = source, status: Double = 24.0, originalWindow: WorkspaceWindowState = window) =
                checkNotNull(owner.capture(originalWindow, 600, status, false, key) { true })
            val original = capture()
            original.retire()
            val coveredReplacement = capture()
            assertTrue(original.layoutCurrent())
            when (change) {
                "source" -> capture(Any())
                "status" -> capture(status = 40.0)
                "window" -> capture(originalWindow = window.copy(configuration = 4, generation = 5))
                else -> {
                    assertTrue(coveredReplacement.toggleControl { true }.perform())
                    assertTrue(capture().toggleControl { true }.perform())
                }
            }
            val restored = capture()
            assertFalse(original.layoutCurrent()); assertFalse(coveredReplacement.layoutCurrent())
            assertTrue(restored.layoutCurrent()); assertTrue(restored.current())
            assertFalse(original.layoutCurrent())
        }
    }

    @Test fun originalDrawingBoundaryStaysRevokedAfterReturnAndCannotReplaceAnOldPageAction() = runTest {
        val browser = browser(backgroundScope); runCurrent()
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, window.geometry!!))
        val originalPage = checkNotNull(browser.captureTabletSidebarPage(600))
        val originalEntry = BrowserTabletSidebarEntry(browser, originalPage, BrowserTabletPageEnvironment { true })
        val originalAction = checkNotNull(BrowserTabletSidebarControl(originalEntry) { true }.tab(tab))
        var nativeContextCurrent = true
        val pixels = BrowserTabletSidebarDrawingContext { nativeContextCurrent }
        val before = browser.state.value
        assertTrue(pixels.current())
        nativeContextCurrent = false
        assertFalse(pixels.current())
        nativeContextCurrent = true
        assertFalse(pixels.current()) // Returning account/native identity cannot revive the old pixels.
        browser.backgrounded(); browser.foregrounded()
        assertFalse(originalAction.perform())
        assertSame(before, browser.state.value)
        val freshPixels = BrowserTabletSidebarDrawingContext { nativeContextCurrent }
        assertTrue(freshPixels.current())
        assertFalse(originalAction.perform()) // Drawing currentness grants no new PAGE action.
        val freshEntry = BrowserTabletSidebarEntry(browser, checkNotNull(browser.captureTabletSidebarPage(600)),
            BrowserTabletPageEnvironment { true })
        assertTrue(checkNotNull(BrowserTabletSidebarControl(freshEntry) { true }.tab(tab)).perform())
    }
    @Test fun footerSettingsKeepsTheOriginalSceneAndIsConsumedBeforeOpening() = runTest {
        val browser = browser(backgroundScope); runCurrent()
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, window.geometry!!))
        val page = checkNotNull(browser.captureTabletSidebarPage(600))
        var covered = false
        val entry = BrowserTabletSidebarEntry(browser, page, BrowserTabletPageEnvironment { !covered })
        val old = checkNotNull(BrowserTabletSidebarControl(entry) { !covered }.settings())
        covered = true
        assertFalse(old.perform())
        covered = false
        assertFalse(old.perform()); assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        val fresh = BrowserTabletSidebarEntry(browser, page, BrowserTabletPageEnvironment { true })
        val action = checkNotNull(BrowserTabletSidebarControl(fresh) { true }.settings())
        assertTrue(action.perform()); assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
        assertFalse(action.perform())
    }

}

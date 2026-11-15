package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserWorkspaceTest {
    private val tabs = listOf("c", "a", "b").map { BrowserTab(it, "https://$it.example", it.uppercase(), createdAt = 1) }
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
    private fun controller(scope: CoroutineScope, engine: Engine = Engine()): BrowserController {
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a")), selectedSpaceId = "s")
        val repository = object : BrowserRepository {
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }
        return BrowserController(repository, engine, scope)
    }

    private fun window(controller: BrowserController, width: Double, height: Double) {
        if (!controller.workspaceWindow.value.registered) controller.invalidateWorkspaceWindow()
        assertTrue(controller.commitWorkspaceWindow(controller.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }
    private fun landscape(controller: BrowserController) = window(controller, 1366.0, 1024.0)

    @Test fun spreadUsesFullWindowGeometryAndShowsOnlyTheFocusedPageInPortrait() {
        assertTrue(BrowserWorkspaceLayout(1366, 1024, true).let { it.split && it.horizontal })
        assertTrue(BrowserWorkspaceLayout(768, 1024, true).let { !it.split && !it.horizontal && it.expanded })
        assertFalse(BrowserWorkspaceLayout(599, 1200, true).split)
        assertFalse(BrowserWorkspaceLayout(600, 640, true).split)
        assertFalse(BrowserWorkspaceLayout(1366, 1024, false).split)
    }

    @Test fun conversationUsesOnlyTheFocusedPaneAndKeepsTheIosMinimumPageWidth() {
        val full = BrowserWorkspaceLayout(1024, 768, false)
        assertTrue(full.reservesConversation)
        assertEquals(360, full.conversationWidth)
        val spread = BrowserWorkspaceLayout(1366, 1024, true)
        assertEquals(682, spread.paneWidth)
        assertTrue(spread.reservesConversation)
        val small = BrowserWorkspaceLayout(1024, 768, true)
        assertEquals(511, small.paneWidth)
        assertFalse(small.reservesConversation)
        assertTrue(small.pageVisibleWithConversation)
        val phone = BrowserWorkspaceLayout(411, 891, false)
        assertEquals(411, phone.conversationWidth)
        assertFalse(phone.pageVisibleWithConversation)
    }

    @Test fun focusingKeepsPhysicalOrderAndSelectionReplacesFocusedPane() = runTest {
        val controller = controller(backgroundScope)
        runCurrent(); landscape(controller); controller.openBeside("b")
        assertEquals(BrowserWorkspace("a", "b", "b"), controller.state.value.workspace)
        controller.selectTab("a")
        assertEquals(BrowserWorkspace("a", "b", "a"), controller.state.value.workspace)
        controller.selectTab("c")
        assertEquals(BrowserWorkspace("c", "b", "c"), controller.state.value.workspace)
        controller.selectTab("b")
        assertEquals(BrowserWorkspace("c", "b", "b"), controller.state.value.workspace)
    }

    @Test fun resizeRemembersPairButSelectingDifferentTabOnCoverEndsIt() = runTest {
        val controller = controller(backgroundScope)
        runCurrent(); landscape(controller); controller.openBeside("b")
        window(controller, 411.0, 891.0)
        assertNotNull(controller.state.value.workspace)
        controller.selectTab("b")
        assertNotNull(controller.state.value.workspace)
        controller.selectTab("a")
        assertNull(controller.state.value.workspace)
        landscape(controller)
        assertNull(controller.state.value.workspace)
    }

    @Test fun choosingOriginalFromNewTabBesideRemovesOnlyThePlaceholder() = runTest {
        val engine = Engine(); val controller = controller(backgroundScope, engine)
        runCurrent(); landscape(controller); controller.newTabBeside()
        val placeholder = controller.state.value.workspace!!.newPage!!
        assertEquals(BrowserSurface.FIELD, controller.state.value.surface)
        controller.selectTab("a")
        assertNull(controller.state.value.workspace)
        assertEquals("a", controller.state.value.tab!!.id)
        assertEquals(tabs.map { it.id }.toSet(), controller.state.value.space!!.tabs.map { it.id }.toSet())
        assertEquals(listOf(placeholder), engine.closed)
        assertTrue(engine.navigated.isEmpty())
        assertFalse(controller.state.value.undoAvailable)
        assertTrue(controller.state.value.history.isEmpty())
    }

    @Test fun choosingExistingTabFromNewTabBesideKeepsOnlyRequestedPair() = runTest {
        val controller = controller(backgroundScope)
        runCurrent(); landscape(controller); controller.newTabBeside()
        controller.selectTab("b")
        assertEquals(BrowserWorkspace("a", "b", "b"), controller.state.value.workspace)
        assertEquals(tabs.map { it.id }.toSet(), controller.state.value.space!!.tabs.map { it.id }.toSet())
        assertTrue(controller.state.value.history.isEmpty())
    }

    @Test fun typingIntoNewTabBesideNavigatesTheExistingPlaceholder() = runTest {
        val engine = Engine(); val controller = controller(backgroundScope, engine)
        runCurrent(); landscape(controller); controller.newTabBeside()
        val placeholder = controller.state.value.tab!!.id
        controller.fieldText("https://new.example/path"); controller.submitField()
        assertEquals(placeholder, controller.state.value.tab!!.id)
        assertEquals("https://new.example/path", controller.state.value.tab!!.url)
        assertEquals(BrowserWorkspace("a", placeholder, placeholder), controller.state.value.workspace)
        assertEquals(tabs.size + 1, controller.state.value.space!!.tabs.size)
        assertEquals(listOf(placeholder), engine.navigated)
        assertTrue(controller.state.value.history.isEmpty())
    }

    @Test fun closingPageSelectsItsCompanionInsteadOfUnrelatedFirstTab() = runTest {
        val controller = controller(backgroundScope)
        runCurrent(); landscape(controller); controller.openBeside("b")
        controller.closeWorkspacePage()
        assertEquals("a", controller.state.value.tab!!.id)
        assertNull(controller.state.value.workspace)
        assertTrue(controller.state.value.undoAvailable)
        controller.undoClose()
        assertEquals(tabs.map { it.id }.toSet(), controller.state.value.space!!.tabs.map { it.id }.toSet())
    }

    @Test fun privateAndCompactPagesCannotCreateASpread() = runTest {
        val controller = controller(backgroundScope)
        runCurrent(); controller.openBeside("b"); assertNull(controller.state.value.workspace)
        landscape(controller); controller.openUrl("https://private.example", privately = true)
        controller.unlockPrivate(true); val count = controller.state.value.space!!.tabs.size
        controller.newTabBeside()
        assertNull(controller.state.value.workspace)
        assertEquals(count, controller.state.value.space!!.tabs.size)
    }
}

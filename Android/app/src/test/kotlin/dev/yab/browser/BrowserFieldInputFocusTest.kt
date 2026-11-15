package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserFieldInputFocus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserFieldInputFocusTest {
    private val tab = BrowserTab("a", "https://a.test", "A", createdAt = 1)
    private val initial = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "s")
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
        override suspend fun load() = initial
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }, Engine(), scope, now = { 1 }, newId = { "new" })

    @Test fun configReplacementRejectsOldCleanupAndLateBlurWhileOriginalInputIsRetired() = runTest {
        val browser = browser(backgroundScope); runCurrent()
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(1280.0, 800.0)))
        browser.openField()
        val oldSource = BrowserFieldPlacementLease.capture(browser, true)
        val owner = BrowserFieldInputFocus()
        val old = owner.bind()
        if (oldSource.current()) old.acquired()
        var clears = 0; var hides = 0
        val oldCleanup = { old.clear({ clears++ }, { hides++ }) }

        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(480.0, 1000.0)))
        val freshSource = BrowserFieldPlacementLease.capture(browser, false)
        val fresh = owner.bind()
        assertFalse(oldSource.current()); assertTrue(freshSource.current())
        fresh.acquired()
        assertFalse(oldCleanup())
        old.released() // A queued old blur/dispose must not clear the new editor.
        assertTrue(fresh.ownsFocus); assertEquals(0, clears); assertEquals(0, hides)
    }

    @Test fun stopStillCleansItsOwnFocusedEditorButCannotHideFreshForegroundInput() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val oldSource = BrowserFieldPlacementLease.capture(browser, false)
        val owner = BrowserFieldInputFocus(); val old = owner.bind()
        assertTrue(oldSource.current()); old.acquired()
        val calls = mutableListOf<String>()
        browser.backgrounded()
        assertFalse(oldSource.current())
        assertTrue(old.clear({ calls += "clear"; old.released() }, { calls += "hide" }))
        assertEquals(listOf("clear", "hide"), calls)

        browser.foregrounded()
        val freshSource = BrowserFieldPlacementLease.capture(browser, false)
        val fresh = owner.bind()
        assertTrue(freshSource.current()); fresh.acquired()
        assertFalse(old.clear({ calls += "stale clear" }, { calls += "stale hide" }))
        assertTrue(fresh.ownsFocus)
        assertTrue(browser.fieldText("fresh draft", checkNotNull(freshSource.input)))
        assertEquals(listOf("clear", "hide"), calls)
    }

    @Test fun synchronousSuccessorAcquisitionDuringClearSuppressesOldHide() {
        val owner = BrowserFieldInputFocus(); val old = owner.bind(); val fresh = owner.bind()
        old.acquired()
        var hides = 0
        assertTrue(old.clear({ fresh.acquired() }, { hides++ }))
        assertTrue(fresh.ownsFocus); assertEquals(0, hides)
        old.released()
        assertTrue(fresh.ownsFocus)
    }

    @Test fun reentrantAcquireThenBlurStillCannotAuthorizeTheOldHide() {
        val owner = BrowserFieldInputFocus(); val old = owner.bind(); val fresh = owner.bind()
        old.acquired()
        var hides = 0
        assertTrue(old.clear({ fresh.acquired(); fresh.released() }, { hides++ }))
        assertFalse(old.ownsFocus); assertFalse(fresh.ownsFocus); assertEquals(0, hides)
    }

    @Test fun originalClearConsumesFocusExactlyOnceBeforeItsSynchronousBlur() {
        val owner = BrowserFieldInputFocus(); val input = owner.bind()
        input.acquired()
        val calls = mutableListOf<String>()
        assertTrue(input.clear({
            assertFalse(input.ownsFocus)
            input.released()
            calls += "clear"
        }, { calls += "hide" }))
        assertFalse(input.clear({ calls += "second clear" }, { calls += "second hide" }))
        assertEquals(listOf("clear", "hide"), calls)
    }

    @Test fun cancelledBindingDoesNotHideOrReleaseAReplacement() {
        val owner = BrowserFieldInputFocus(); val cancelled = owner.bind(); val fresh = owner.bind()
        cancelled.acquired(); cancelled.released(); fresh.acquired()
        cancelled.released()
        assertFalse(cancelled.clear({ fail("cancelled clear") }, { fail("cancelled hide") }))
        assertTrue(fresh.ownsFocus)
    }

    @Test fun replacementMustObserveItsOwnVisibleKeyboardBeforeAcceptingDismissal() {
        val owner = BrowserFieldInputFocus(); val old = owner.bind(); val fresh = owner.bind()
        old.acquired(); old.keyboardShown()
        fresh.acquired()
        assertFalse(old.takeKeyboardDismissal())
        assertFalse(fresh.takeKeyboardDismissal())
        fresh.keyboardShown()
        assertTrue(fresh.takeKeyboardDismissal())
        assertFalse(fresh.takeKeyboardDismissal())
    }

    @Test fun anUnfocusedVisibilitySampleCannotSeedLaterInputDismissal() {
        val input = BrowserFieldInputFocus().bind()
        input.keyboardShown()
        input.acquired()
        assertFalse(input.takeKeyboardDismissal())
        input.keyboardShown(); input.released()
        assertFalse(input.takeKeyboardDismissal())
    }
}

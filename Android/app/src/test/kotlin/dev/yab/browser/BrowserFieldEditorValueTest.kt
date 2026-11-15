package dev.yab.browser

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserFieldEditorOwner
import dev.yab.browser.ui.BrowserFieldEditorValue
import dev.yab.browser.ui.BrowserFieldEditorValues
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserFieldEditorValueTest {
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
    private fun browser(scope: CoroutineScope): BrowserController {
        var id = 0
        return BrowserController(object : BrowserRepository {
            override suspend fun load() = initial
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, Engine(), scope, now = { 1 }, newId = { "new-${++id}" })
    }
    private fun owner(browser: BrowserController) = BrowserFieldEditorOwner.from(browser.state.value,
        browser.settingsPresentationLifetime.value.privateBoundary)
    private fun window(browser: BrowserController, width: Double, height: Double) {
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }
    /** Distinct consumers model actual input recreation, with the production shared cell/node owner. */
    private class Consumer(private val browser: BrowserController, private val source: BrowserFieldPlacementLease,
        private val shared: BrowserFieldEditorValue) {
        private val input = checkNotNull(source.input)
        private val node = shared.nodes.bind()
        fun change(next: TextFieldValue): Boolean = node.change({ source.current() && browser.fieldInputCurrent(input) }) {
            shared.value.value = next
            assertTrue(browser.fieldText(next.text, input))
        }
        fun dispose() = node.retire()
    }

    @Test fun recreatedConsumerUsesSameLogicalValueAndRetiresOldSameSourceBlurBeforeDispose() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val source = BrowserFieldPlacementLease.capture(browser, false)
        val words = TextFieldValue("tablet selection retained", TextRange(4, 13))
        val shared = BrowserFieldEditorValue(words)
        val first = Consumer(browser, source, shared)
        assertTrue(first.change(words))
        val recreated = Consumer(browser, source, shared)
        assertFalse(first.change(words.copy(selection = TextRange(words.text.length))))
        first.dispose()
        assertEquals(words, shared.value.value)
        assertTrue(recreated.change(words.copy(selection = TextRange(5, 12))))
        assertEquals(TextRange(5, 12), shared.value.value.selection)
    }

    @Test fun actualConfigurationAbaChangesPlacementButNotLogicalValueDomainOrSelection() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser, 1280.0, 800.0); browser.openField()
        val originalOwner = owner(browser)
        val words = TextFieldValue("tablet selection retained", TextRange(4, 13))
        val shared = BrowserFieldEditorValue(words)
        val first = Consumer(browser, BrowserFieldPlacementLease.capture(browser, true), shared)
        assertTrue(first.change(words))
        window(browser, 480.0, 1000.0)
        assertEquals(originalOwner, owner(browser))
        val compact = Consumer(browser, BrowserFieldPlacementLease.capture(browser, false), shared)
        assertFalse(first.change(TextFieldValue("stale tablet")))
        assertEquals(words, shared.value.value)
        window(browser, 1280.0, 800.0)
        assertEquals(originalOwner, owner(browser))
        val returned = Consumer(browser, BrowserFieldPlacementLease.capture(browser, true), shared)
        assertFalse(compact.change(TextFieldValue("stale compact")))
        assertTrue(returned.change(words.copy(selection = TextRange(7, 11))))
        assertEquals("tablet selection retained", browser.state.value.fieldText)
        assertEquals(TextRange(7, 11), shared.value.value.selection)
    }

    @Test fun publicStopDoesNotEraseDraftRangeButOldForegroundCallbackStillRefuses() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val originalOwner = owner(browser)
        val foreground = browser.settingsPresentationLifetime.value.generation
        val words = TextFieldValue("public draft", TextRange(2, 8))
        val shared = BrowserFieldEditorValue(words)
        val first = Consumer(browser, BrowserFieldPlacementLease.capture(browser, false), shared)
        assertTrue(first.change(words))
        browser.backgrounded(); browser.foregrounded()
        assertTrue(browser.settingsPresentationLifetime.value.generation > foreground)
        assertEquals(originalOwner, owner(browser))
        val returned = Consumer(browser, BrowserFieldPlacementLease.capture(browser, false), shared)
        assertFalse(first.change(TextFieldValue("old foreground")))
        assertEquals(words, shared.value.value)
        assertTrue(returned.change(words.copy(selection = TextRange(3, 7))))
    }

    @Test fun newFieldAndAccountOwnersHaveSeparateValuesAndOldReferencesCannotWriteCurrentCell() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val originalOwner = owner(browser)
        val oldValue = BrowserFieldEditorValue(TextFieldValue("old account draft", TextRange(1, 6)))
        val old = Consumer(browser, BrowserFieldPlacementLease.capture(browser, false), oldValue)
        assertTrue(old.change(oldValue.value.value))
        browser.invalidateLocalOwnership(); browser.openField()
        assertNotEquals(originalOwner, owner(browser))
        val freshValue = BrowserFieldEditorValue(TextFieldValue(browser.state.value.fieldText, TextRange(browser.state.value.fieldText.length)))
        val fresh = Consumer(browser, BrowserFieldPlacementLease.capture(browser, false), freshValue)
        assertNotSame(oldValue.value, freshValue.value); assertNotSame(oldValue.nodes, freshValue.nodes)
        assertFalse(old.change(TextFieldValue("stale account")))
        oldValue.value.value = TextFieldValue("an old UI reference owns only its old state")
        assertEquals("", freshValue.value.value.text)
        assertTrue(fresh.change(TextFieldValue("fresh account", TextRange(2, 5))))
        assertEquals("fresh account", browser.state.value.fieldText)
    }

    @Test fun privateProfileAndBlockedBoundaryBelongToLogicalDomainWhileWindowDoesNot() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val publicOwner = owner(browser)
        browser.fieldPrivacy(true)
        assertNotEquals(publicOwner, owner(browser))
        browser.fieldPrivacy(false)
        val beforeProfile = owner(browser)
        val public = checkNotNull(browser.publicSnapshot())
        browser.applySyncedSnapshot(public.copy(spaces = public.spaces.map { it.copy(ownSignIns = true) }))
        assertNotEquals(beforeProfile, owner(browser))
        browser.dismissSurface(); browser.showPrivate(); browser.openUrl("https://private.test", newTab = true)
        browser.updateSettings(browser.state.value.settings.copy(lockPrivate = true)); browser.unlockPrivate(true)
        browser.openField(newTab = false)
        val privateOwner = owner(browser)
        browser.lockPrivate(); browser.unlockPrivate(true)
        assertTrue(browser.settingsPresentationLifetime.value.privateBoundary > privateOwner.privateBoundary)
        assertNotEquals(privateOwner, owner(browser))
    }

    @Test fun freshUnfocusedAccessibilityAndCompositionUpdatesSurviveAnotherConsumer() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField(); browser.restField(browser.state.value.surfaceEpoch)
        val shared = BrowserFieldEditorValue(TextFieldValue("accessible text"))
        val source = BrowserFieldPlacementLease.capture(browser, false)
        val first = Consumer(browser, source, shared)
        assertTrue(browser.state.value.fieldResting)
        val range = TextFieldValue("accessible text", TextRange(1, 8))
        assertTrue(first.change(range))
        val recreated = Consumer(browser, source, shared)
        assertEquals(range, shared.value.value)
        assertTrue(recreated.change(range.copy(selection = TextRange(8))))
        val composing = TextFieldValue("composing", TextRange(9), TextRange(0, 9))
        assertTrue(recreated.change(composing))
        assertEquals(composing, shared.value.value)
        assertTrue(recreated.change(composing.copy(composition = null)))
        assertEquals("composing", browser.state.value.fieldText)
    }

    @Test fun retainedSessionCacheSurvivesDistinctScreenConsumersAndRealWindowAba() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser, 1280.0, 800.0); browser.openField()
        val values = BrowserFieldEditorValues()
        var initializations = 0
        fun rendered() = checkNotNull(values.retain(browser, owner(browser)) {
            initializations++; TextFieldValue(browser.state.value.fieldText)
        })
        val firstValue = rendered()
        val original = Consumer(browser, BrowserFieldPlacementLease.capture(browser, true), firstValue)
        val words = TextFieldValue("retained Activity draft", TextRange(4, 13), TextRange(0, 3))
        assertTrue(original.change(words))
        window(browser, 480.0, 1000.0)
        val compactValue = rendered()
        assertSame(firstValue, compactValue)
        val compact = Consumer(browser, BrowserFieldPlacementLease.capture(browser, false), compactValue)
        assertFalse(original.change(words.copy(selection = TextRange(words.text.length))))
        assertEquals(words, compactValue.value.value)
        browser.backgrounded(); browser.foregrounded()
        window(browser, 1280.0, 800.0)
        val returnedValue = rendered()
        assertSame(firstValue, returnedValue); assertEquals(1, initializations)
        val returned = Consumer(browser, BrowserFieldPlacementLease.capture(browser, true), returnedValue)
        assertFalse(compact.change(TextFieldValue("stale compact")))
        assertTrue(returned.change(words.copy(selection = TextRange(6, 12))))
    }

    @Test fun cacheReplacesLogicalAccountAndPrivateDomainsBeforeTheirOldNodesCanWrite() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val values = BrowserFieldEditorValues()
        val first = checkNotNull(values.retain(browser, owner(browser)) { TextFieldValue("public", TextRange(1, 4)) })
        val oldNode = first.nodes.bind()
        browser.fieldPrivacy(true)
        val privately = checkNotNull(values.retain(browser, owner(browser)) { TextFieldValue("private") })
        assertNotSame(first, privately)
        assertFalse(oldNode.change({ true }) { fail("Cache replacement must retire the old actual node") })
        val privateNode = privately.nodes.bind()
        browser.invalidateLocalOwnership(); browser.openField()
        val account = checkNotNull(values.retain(browser, owner(browser)) { TextFieldValue(browser.state.value.fieldText) })
        assertNotSame(privately, account)
        assertFalse(privateNode.change({ true }) { fail("Old account UI node must already be retired") })
        first.value.value = TextFieldValue("old reference")
        assertEquals("", account.value.value.text)
    }

    @Test fun differentControllerAndSessionClearCannotBorrowOrReviveOldUiValue() = runTest {
        val firstBrowser = browser(backgroundScope); val secondBrowser = browser(backgroundScope)
        runCurrent(); firstBrowser.openField(); secondBrowser.openField()
        assertEquals(owner(firstBrowser), owner(secondBrowser))
        val values = BrowserFieldEditorValues()
        val first = checkNotNull(values.retain(firstBrowser, owner(firstBrowser)) { TextFieldValue("first") })
        val old = first.nodes.bind()
        val second = checkNotNull(values.retain(secondBrowser, owner(secondBrowser)) { TextFieldValue("second", TextRange(1, 4)) })
        assertNotSame(first, second)
        assertFalse(old.change({ true }) { fail("Equal logical facts cannot borrow another Controller") })
        val current = second.nodes.bind()
        values.close()
        assertFalse(current.change({ true }) { fail("Cleared retained session must retire its actual node") })
        assertNull(values.retain(secondBrowser, owner(secondBrowser)) { fail("Closed cache cannot initialize again"); TextFieldValue() })
    }
}

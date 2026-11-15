package dev.yab.browser

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserFieldEditorNode
import dev.yab.browser.ui.BrowserFieldInputFocus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserFieldEditorNodeTest {
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

    private fun window(browser: BrowserController, width: Double = 1280.0, height: Double = 800.0) {
        if (!browser.workspaceWindow.value.registered) browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(width, height)))
    }

    private class Draft(var value: TextFieldValue) {
        fun callback(browser: BrowserController, source: BrowserFieldPlacementLease, node: BrowserFieldEditorNode.Binding): (TextFieldValue) -> Boolean {
            val input = checkNotNull(source.input)
            return { next -> node.change({ source.current() && browser.fieldInputCurrent(input) }) {
                value = next
                assertTrue(browser.fieldText(next.text, input))
            } }
        }
    }

    @Test fun replacementRetiresOldBlurBeforeOldNodeDisposalWithoutDroppingLogicalSelection() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val source = BrowserFieldPlacementLease.capture(browser, false)
        val editor = BrowserFieldEditorNode(); val old = editor.bind()
        val draft = Draft(TextFieldValue("retained selection", TextRange(2, 10)))
        val oldChange = draft.callback(browser, source, old)
        assertTrue(oldChange(draft.value))
        val fresh = editor.bind() // Replacement render retires old callback before onDispose/blur.
        assertTrue(source.current()); assertTrue(browser.fieldInputCurrent(source.input!!))
        assertFalse(oldChange(draft.value.copy(selection = TextRange(10), composition = null)))
        assertEquals(TextRange(2, 10), draft.value.selection)
        old.retire() // A late old dispose cannot retire the fresh node.
        assertTrue(fresh.current())
        assertTrue(draft.callback(browser, source, fresh)(draft.value.copy(selection = TextRange(3, 9))))
    }

    @Test fun freshAccessibilitySelectionDoesNotRequireFocusAndAcceptsCollapsedRanges() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        browser.restField(browser.state.value.surfaceEpoch)
        val source = BrowserFieldPlacementLease.capture(browser, false)
        val draft = Draft(TextFieldValue("accessible text"))
        val change = draft.callback(browser, source, BrowserFieldEditorNode().bind())
        assertTrue(browser.state.value.fieldResting) // No focus acquisition is part of change admission.
        assertTrue(change(draft.value.copy(selection = TextRange(1, 8))))
        assertEquals(TextRange(1, 8), draft.value.selection)
        assertTrue(change(draft.value.copy(selection = TextRange(8))))
        assertEquals(TextRange(8), draft.value.selection)
    }

    @Test fun currentImeTextAndCompositionUpdatesRemainAccepted() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val draft = Draft(TextFieldValue(""))
        val change = draft.callback(browser, BrowserFieldPlacementLease.capture(browser, false), BrowserFieldEditorNode().bind())
        val composing = TextFieldValue("compose", TextRange(7), TextRange(0, 7))
        assertTrue(change(composing)); assertEquals(composing, draft.value)
        assertEquals("compose", browser.state.value.fieldText)
        val committed = composing.copy(composition = null)
        assertTrue(change(committed)); assertEquals(committed, draft.value)
    }

    @Test fun coalescedConfigurationAbaRejectsOldCallbackAndFreshNodeKeepsSelection() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); browser.openField()
        val editor = BrowserFieldEditorNode(); val oldSource = BrowserFieldPlacementLease.capture(browser, true)
        val draft = Draft(TextFieldValue("tablet selection retained", TextRange(4, 13)))
        val oldChange = draft.callback(browser, oldSource, editor.bind())
        assertTrue(oldChange(draft.value))
        browser.invalidateWorkspaceWindow(); window(browser, 480.0, 1000.0)
        browser.invalidateWorkspaceWindow(); window(browser) // No rendered intermediate binding.
        assertTrue(browser.fieldInputCurrent(oldSource.input!!)); assertFalse(oldSource.current())
        val freshChange = draft.callback(browser, BrowserFieldPlacementLease.capture(browser, true), editor.bind())
        assertFalse(oldChange(TextFieldValue("stale")))
        assertEquals(TextRange(4, 13), draft.value.selection)
        assertTrue(freshChange(draft.value.copy(selection = TextRange(5, 12))))
        assertEquals("tablet selection retained", browser.state.value.fieldText)
    }

    @Test fun unrenderedPrivacyAbaNeverRevivesOldInputNodeButFreshPublicSelectionWorks() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); browser.openField()
        val editor = BrowserFieldEditorNode(); val source = BrowserFieldPlacementLease.capture(browser, true)
        val draft = Draft(TextFieldValue("public text", TextRange(1, 6)))
        val oldChange = draft.callback(browser, source, editor.bind())
        assertTrue(oldChange(draft.value))
        browser.fieldPrivacy(true); browser.fieldPrivacy(false)
        assertTrue(browser.fieldInputCurrent(source.input!!)); assertFalse(source.current())
        val fresh = draft.callback(browser, BrowserFieldPlacementLease.capture(browser, true), editor.bind())
        assertFalse(oldChange(TextFieldValue("old privacy")))
        assertEquals("", browser.state.value.fieldText)
        assertTrue(fresh(TextFieldValue("fresh public", TextRange(2, 7))))
        assertEquals(TextRange(2, 7), draft.value.selection)
    }

    @Test fun accountAndStopRetireOriginalChangesWhileFreshRenderedNodesCanEdit() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.openField()
        val editor = BrowserFieldEditorNode(); val draft = Draft(TextFieldValue("kept", TextRange(1, 3)))
        val beforeStop = draft.callback(browser, BrowserFieldPlacementLease.capture(browser, false), editor.bind())
        assertTrue(beforeStop(draft.value))
        browser.backgrounded(); browser.foregrounded()
        val afterStop = draft.callback(browser, BrowserFieldPlacementLease.capture(browser, false), editor.bind())
        assertFalse(beforeStop(TextFieldValue("old foreground")))
        assertTrue(afterStop(draft.value))
        browser.invalidateLocalOwnership(); browser.openField()
        val afterAccount = draft.callback(browser, BrowserFieldPlacementLease.capture(browser, false), editor.bind())
        assertFalse(afterStop(TextFieldValue("old account")))
        assertTrue(afterAccount(TextFieldValue("new account", TextRange(3, 8))))
        assertEquals("new account", browser.state.value.fieldText)
    }

    @Test fun lateOldRetirementCannotDisableSuccessorAndDisposedNodeCannotBecomeCurrent() {
        val editor = BrowserFieldEditorNode(); val old = editor.bind(); val fresh = editor.bind()
        old.retire(); old.retire()
        assertFalse(old.current()); assertTrue(fresh.current())
        fresh.retire()
        assertFalse(fresh.current())
        val returned = editor.bind()
        assertTrue(returned.current()); assertFalse(fresh.current()); assertFalse(old.current())
        val sharedFocus = BrowserFieldInputFocus().bind()
        assertTrue(returned.acquired()); sharedFocus.acquired()
        val replacement = editor.bind()
        assertTrue(replacement.acquired()); sharedFocus.acquired()
        assertFalse(returned.released { sharedFocus.released() }) // Same host binding, newer actual node.
        assertTrue(sharedFocus.ownsFocus)
        replacement.retire()
        assertTrue(replacement.released { sharedFocus.released() }) // STOP/disposal still cleans its own claim.
        assertFalse(sharedFocus.ownsFocus)
        val blurred = editor.bind(); assertTrue(blurred.acquired()); sharedFocus.acquired()
        editor.bind() // Replacement not focused yet; the old blur may still release its own claim.
        assertTrue(blurred.released { sharedFocus.released() })
        assertFalse(sharedFocus.ownsFocus)
    }

    @Test fun retiredNodeDoesNotReadOrBorrowFreshInputAndCurrentNodeStillRequiresOriginalPredicate() {
        val editor = BrowserFieldEditorNode(); val old = editor.bind(); val fresh = editor.bind()
        var reads = 0; var writes = 0
        assertFalse(old.change({ reads++; true }, { writes++ }))
        assertEquals(0, reads); assertEquals(0, writes)
        assertFalse(fresh.change({ reads++; false }, { writes++ }))
        assertEquals(1, reads); assertEquals(0, writes)
        assertTrue(fresh.change({ reads++; true }, { writes++ }))
        assertEquals(2, reads); assertEquals(1, writes)
        assertFalse(fresh.change({ reads++; editor.bind(); true }, { writes++ }))
        assertEquals(3, reads); assertEquals(1, writes)
    }
}

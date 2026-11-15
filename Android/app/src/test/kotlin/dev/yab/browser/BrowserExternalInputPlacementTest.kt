package dev.yab.browser

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserFieldEditorOwner
import dev.yab.browser.ui.BrowserFieldEditorValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserExternalInputPlacementTest {
    private val tab = BrowserTab("a", "https://a.test", "A", createdAt = 1)
    private val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal",
        tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "s")
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
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }, Engine(), scope, now = { 1 }, newId = { "new" })

    private class Editor(private val browser: BrowserController, private val placement: BrowserFieldPlacementLease,
        private val value: BrowserFieldEditorValue) {
        private val input = checkNotNull(placement.input)
        private val node = value.nodes.bind()
        fun change(next: TextFieldValue): Boolean = node.change({ placement.current() && browser.fieldInputCurrent(input) }) {
            value.value.value = next
            assertTrue(browser.fieldText(next.text, input))
        }
        fun close(): Boolean = placement.current() && browser.dismissField(input.epoch)
    }

    @Test fun fastCoverOpenCloseRetiresOriginalCompactAndTabletInputWithoutChangingRetainedDraft() = runTest {
        for (tablet in listOf(false, true)) {
            val browser = browser(backgroundScope); runCurrent(); browser.openField()
            var revision = 0L
            var covered = false
            val originalRevision = revision
            val placement = BrowserFieldPlacementLease.capture(browser, tablet,
                originalCurrent = { revision == originalRevision && !covered })
            val words = TextFieldValue("retained Field draft", TextRange(3, 12))
            val value = BrowserFieldEditorValue(words)
            val old = Editor(browser, placement, value)
            assertTrue(old.change(words))
            val originalState = browser.state.value
            val originalOwner = BrowserFieldEditorOwner.from(originalState,
                browser.settingsPresentationLifetime.value.privateBoundary)
            covered = true; revision++
            covered = false; revision++ // No composition or old-current read between these writes.
            assertTrue(browser.fieldInputCurrent(checkNotNull(placement.input)))
            assertFalse(old.change(TextFieldValue("stale write")))
            assertFalse(old.close())
            assertEquals(originalState, browser.state.value)
            assertEquals(words, value.value.value)
            assertEquals(originalOwner, BrowserFieldEditorOwner.from(browser.state.value,
                browser.settingsPresentationLifetime.value.privateBoundary))
            val freshRevision = revision
            val fresh = Editor(browser, BrowserFieldPlacementLease.capture(browser, tablet,
                originalCurrent = { revision == freshRevision && !covered }), value)
            assertEquals(words, value.value.value)
            assertTrue(fresh.change(words.copy(text = "fresh Field draft", selection = TextRange(1, 5))))
            assertFalse(old.change(TextFieldValue("old editor blur")))
            assertEquals("fresh Field draft", browser.state.value.fieldText)
            assertEquals(TextRange(1, 5), value.value.value.selection)
            assertTrue(fresh.close())
            assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        }
    }

    @Test fun falseOrThrowingOriginalPredicatePermanentlyRetiresWhileDefaultPlacementKeepsLegacyAdmission() = runTest {
        for (throws in listOf(false, true)) {
            val browser = browser(backgroundScope); runCurrent(); browser.openField()
            var allowed = true
            val source = BrowserFieldPlacementLease.capture(browser, false, originalCurrent = {
                if (!allowed && throws) error("fixed original-source refusal") else allowed
            })
            val old = Editor(browser, source, BrowserFieldEditorValue(TextFieldValue("kept")))
            assertTrue(old.change(TextFieldValue("kept")))
            allowed = false
            assertFalse(source.current())
            allowed = true
            assertFalse(old.change(TextFieldValue("revived")))
            assertFalse(old.close())
            assertEquals("kept", browser.state.value.fieldText)
            val legacy = Editor(browser, BrowserFieldPlacementLease.capture(browser, false),
                BrowserFieldEditorValue(TextFieldValue("kept")))
            assertTrue(legacy.change(TextFieldValue("legacy default remains live")))
            assertTrue(legacy.close())
        }
    }

    @Test fun directSpacesPlacementRefusesCoveredCallbacksAndRequiresFreshOriginalSource() = runTest {
        val browser = browser(backgroundScope); runCurrent(); browser.show(BrowserSurface.SPACES)
        var revision = 1L
        val originalRevision = revision
        val old = BrowserFieldPlacementLease.capture(browser, false, originalCurrent = { revision == originalRevision })
        val input = checkNotNull(old.input)
        assertTrue(old.current())
        assertTrue(browser.fieldText("spaces draft", input))
        val before = browser.state.value
        revision++
        assertFalse(old.current() && browser.fieldText("covered spaces", input))
        assertFalse(old.current() && browser.dismissSpaces(input.epoch))
        assertEquals(before, browser.state.value)
        val freshRevision = revision
        val fresh = BrowserFieldPlacementLease.capture(browser, false, originalCurrent = { revision == freshRevision })
        assertTrue(fresh.current())
        assertTrue(browser.fieldText("fresh spaces", checkNotNull(fresh.input)))
        assertEquals("fresh spaces", browser.state.value.fieldText)
        assertTrue(fresh.current() && browser.dismissSpaces(checkNotNull(fresh.input).epoch))
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
    }
}

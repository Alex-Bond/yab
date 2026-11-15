package dev.yab.browser.ui

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserFieldPresentationTest {
    private class Repository : BrowserRepository {
        override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("field", "Field",
            tabs = listOf(BrowserTab("page", "https://field.example/", createdAt = 1)), currentTabId = "page")), selectedSpaceId = "field")
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }
    private class Engine : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }

    @Test fun keyboardAndLargerTextKeepTheCloseCircleAndCardAttachedToTheActualField() {
        // Concrete default Phone FieldGeometry case; the separate Swift oracle covers the wider corpus.
        val phone = BrowserFieldGeometry(402.0, 874.0, 302.0)
        assertEquals(FieldRect(8.0, 516.0, 331.0, 48.0), phone.field)
        assertEquals(FieldRect(346.0, 516.0, 48.0, 48.0), phone.close)
        assertEquals(506.0, phone.cardBottom, 0.0)
        val large = BrowserFieldGeometry(320.0, 640.0, 308.0, textScale = 2.0, lineHeight = 48.0)
        assertEquals(96.0, large.field.height, 0.0)
        assertEquals(large.field.bottom, large.close.bottom, 0.0)
        assertEquals(8.0, large.keyboardTop - large.field.bottom, 0.0)
        val resting = large.copy(keyboard = 0.0, resting = true)
        assertEquals(32.0 + 8.0, resting.height - resting.field.bottom, 0.0)
        assertEquals(resting.height, resting.spacesBottom, 0.0)
    }

    @Test fun reversedPoseUsesItsCurrentProgressAndInputAlwaysKeepsTheFinalFrame() {
        val g = BrowserFieldGeometry(402.0, 874.0, 302.0)
        val origin = FieldRect(89.0, 798.0, 224.0, 48.0)
        val before = BrowserFieldPose(g, origin, g.stack, .37, .4, .8)
        val after = before.copy(cards = .5)
        assertEquals(before.pill, after.pill)
        assertEquals(g.field, after.geometry.field)
        assertEquals(6.0, before.rowsDrop, 1e-10)
        assertEquals(0.112, before.closeGlyph, 1e-10)
        assertEquals(0.0, before.eyes, 0.0)
        assertEquals(g.field, after.copy(progress = 1.0).pill)
        assertEquals(origin, after.copy(progress = 0.0).pill)
        val closing = FieldMorphSegment(before.pill, .37, 0.0)
        assertEquals(before.pill, closing.at(g.plate, .37))
        assertEquals(g.plate, closing.at(g.plate, 0.0))
        val halfway = closing.at(g.plate, .18)
        val reversal = FieldMorphSegment(halfway, .18, 1.0)
        assertEquals(halfway, reversal.at(g.field, .18))
        assertEquals(g.field, reversal.at(g.field, 1.0))
    }

    @Test fun aRestingDraftKeepsItsWordsAndAnOldCloseCannotDismissTheReopenedField() = runTest {
        val browser = BrowserController(Repository(), Engine(), backgroundScope)
        runCurrent()
        browser.openField(newTab = false)
        val first = requireNotNull(browser.captureFieldPresentation())
        assertTrue(browser.state.value.fieldShowsAddress)
        val input = requireNotNull(browser.captureFieldInput())
        assertTrue(browser.fieldText(browser.state.value.fieldText, input))
        assertTrue(browser.state.value.fieldShowsAddress)
        assertTrue(browser.fieldText("draft words", input))
        assertFalse(browser.state.value.fieldShowsAddress)
        assertTrue(browser.restField(first.surfaceEpoch))
        assertEquals("draft words", browser.state.value.fieldText)
        assertTrue(browser.state.value.fieldResting)
        assertTrue(browser.dismissField(first.surfaceEpoch))
        assertTrue(browser.fieldPresentationCurrent(first)) // Exit content may land after logical close.
        browser.openField(newTab = false)
        val next = requireNotNull(browser.captureFieldPresentation())
        assertEquals("draft words", browser.state.value.fieldText)
        assertFalse(browser.state.value.fieldResting)
        assertFalse(browser.fieldPresentationCurrent(first))
        assertFalse(browser.dismissField(first.surfaceEpoch))
        assertFalse(browser.fieldText("stale IME", input))
        assertFalse(browser.focusFieldInput(input, null))
        assertEquals("draft words", browser.state.value.fieldText)
        assertTrue(browser.fieldPresentationCurrent(next))
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
    }

    @Test fun replacingSettingsCanFadeTheFieldButAccountInvalidationRevokesItSynchronously() = runTest {
        val browser = BrowserController(Repository(), Engine(), backgroundScope)
        runCurrent(); browser.openField()
        val old = requireNotNull(browser.captureFieldPresentation())
        browser.show(BrowserSurface.SETTINGS)
        assertTrue(browser.fieldPresentationCurrent(old))
        browser.invalidateLocalOwnership()
        assertFalse(browser.fieldPresentationCurrent(old))
        assertFalse(browser.fieldPresentationOwned(old))
        assertNull(browser.state.value.fieldAnchor)
        assertEquals("", browser.state.value.fieldText)
    }

    @Test fun sequentialImeEditsUseTheSameLeaseButAccountAndPrivacyReplacementRejectQueuedCallbacks() = runTest {
        val browser = BrowserController(Repository(), Engine(), backgroundScope)
        runCurrent(); browser.openField()
        val input = requireNotNull(browser.captureFieldInput())
        assertTrue(browser.fieldText("a", input))
        assertTrue(browser.fieldText("", input))
        assertEquals("", browser.state.value.fieldText)
        assertTrue(browser.fieldText("a", input))
        assertTrue(browser.fieldText("ab", input))
        assertEquals("ab", browser.state.value.fieldText)
        browser.fieldPrivacy(true)
        assertFalse(browser.fieldText("old public IME", input))
        assertEquals("", browser.state.value.fieldText)
        val privateInput = requireNotNull(browser.captureFieldInput())
        browser.invalidateLocalOwnership(); browser.openField()
        assertFalse(browser.fieldText("old private IME", privateInput))
        assertFalse(browser.focusFieldInput(privateInput, null))
        assertEquals("", browser.state.value.fieldText)
    }

    @Test fun lockingPrivateImmediatelyRevokesTheRetainedPresentationAndInvalidAnchorsAreRejected() = runTest {
        val browser = BrowserController(Repository(), Engine(), backgroundScope)
        runCurrent()
        browser.openUrl("https://private.example/", privately = true); browser.unlockPrivate(true)
        browser.openField(origin = FieldAnchor(Double.NaN, 0.0, 10.0, 48.0))
        val old = requireNotNull(browser.captureFieldPresentation())
        browser.fieldText("private draft")
        assertNull(browser.state.value.fieldAnchor)
        browser.lockPrivate()
        assertFalse(browser.fieldPresentationCurrent(old))
        assertFalse(browser.restField(old.surfaceEpoch))
        browser.unlockPrivate(true); browser.openField()
        assertEquals("", browser.state.value.fieldText)
    }
}

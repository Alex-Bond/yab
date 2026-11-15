package dev.yab.browser.ui

import dev.yab.browser.model.*
import org.junit.Assert.*
import org.junit.Test

class BrowserPageMenuFieldHandoffTest {
    private val tab = BrowserTab("handoff-tab", "https://handoff.fixture.invalid/original", "Original", createdAt = 1)
    private val space = BrowserSpace("handoff-space", "Personal", ownSignIns = true, tabs = listOf(tab), currentTabId = tab.id)
    private val owner = PageMenuLease("account", 3, tab.id, space.id, space.websiteProfile, Any(), 7, 1, url = tab.url)
    private val input = FieldInputLease(11, 8, BrowserSurface.FIELD, space.id, space.websiteProfile, tab.id, tab.url, false, false)
    private val source = BrowserState(loading = false, spaces = listOf(space), selectedSpaceId = space.id, surfaceEpoch = 7)
    private val field = source.copy(surface = BrowserSurface.FIELD, surfaceEpoch = 8, fieldIsNewTab = false,
        fieldOriginTab = tab.id, fieldOriginSpace = space.id, fieldOriginProfile = space.websiteProfile)
    private val ms = 1_000_000L
    private val target = FieldRect(8.0, 510.0, 331.0, 48.0)
    private fun opened() = BrowserPageMenuPresentation(owner).apply { open(0, false, false) }

    @Test fun onlyTheImmediateOriginalAddressFieldCanRetainDrawingAndNeverTheOldPageActions() {
        assertTrue(owner.ownsSource(source, tab.url))
        assertFalse(owner.ownsSource(field, tab.url))
        assertTrue(owner.ownsDrawnField(field, input, tab.url))
        for (changed in listOf(field.copy(surfaceEpoch = 9), field.copy(fieldIsNewTab = true),
            field.copy(surface = BrowserSurface.PAGE), field.copy(fieldPrivate = true), field.copy(loading = true),
            field.copy(fieldOriginTab = "other"), field.copy(fieldOriginSpace = "other"),
            field.copy(find = BrowserFindState(tab.id, space.websiteProfile, tab.url)),
            field.copy(spaces = listOf(space.copy(ownSignIns = false))),
            field.copy(spaces = listOf(space.copy(tabs = listOf(tab.copy(url = "https://handoff.fixture.invalid/replaced"))))))) {
            assertFalse(owner.ownsDrawnField(changed, input, tab.url))
        }
        assertFalse(owner.copy(surfaceEpoch = 6).ownsDrawnField(field, input, tab.url))
        assertFalse(owner.copy(nativeOwner = Any(), tab = "other").ownsDrawnField(field, input, tab.url))
    }

    @Test fun sourceLayerGatesKeepTheBodyFirstThenCardsAndTheRealFieldAtTheEnd() {
        assertEquals(PageMenuFieldFactors(0f, 0f, 0f), PageMenuFieldFactors.at(0.0))
        assertEquals(PageMenuFieldFactors(.6f, 0f, 0f), PageMenuFieldFactors.at(.6))
        val middle = PageMenuFieldFactors.at(.75)
        assertEquals(.75f, middle.backdrop, 0f); assertEquals(.5f, middle.cards, .000001f)
        assertEquals(.375f, middle.pill, .000001f)
        val late = PageMenuFieldFactors.at(.9)
        assertEquals(1f, late.cards, .000001f); assertEquals(.75f, late.pill, .000001f)
        assertEquals(PageMenuFieldFactors(1f, 1f, 1f), PageMenuFieldFactors.at(1.0))
    }

    @Test fun fieldStartsFromTheLiveMenuAndNeverClosesBackToThePlateOrRunsALandingAction() {
        val p = opened()
        assertTrue(p.toField(100 * ms, false))
        assertEquals(PageMenuPhase.HANDING_OFF, p.frame.value.phase)
        assertEquals(1.0, p.frame.value.progress, 0.0); assertEquals(0.0, p.frame.value.toField, 0.0)
        assertFalse(p.frame.value.interactive)
        val entering = p.advance(180 * ms)
        assertTrue(entering.toField > 0 && entering.toField < 1)
        assertFalse(p.close(180 * ms, false, afterLanding = { fail("Old PAGE action") }))
        p.open(180 * ms, false)
        assertEquals(entering.toField, p.frame.value.toField, 0.0)
        assertEquals(PageMenuPhase.HANDING_OFF, p.frame.value.phase)
        p.advance(2_000 * ms)
        assertEquals(PageMenuPhase.HANDED_OFF, p.frame.value.phase)
        val done = p.claimCompletion { true }!!
        assertEquals(PageMenuRelease.HANDED_OFF, done.reason); assertNull(done.action)
        assertNull(p.claimCompletion { true })
    }

    @Test fun measuredKeyboardDestinationKeepsTheOriginalTapTimeAndCannotRestartOrBorrowAnUnmeasuredFrame() {
        val p = opened()
        val handoff = BrowserPageMenuFieldHandoff(input, 100 * ms, false, true) { true }
        assertFalse(handoff.start(p, 150 * ms))
        assertTrue(handoff.measure(target)); assertTrue(handoff.start(p, 180 * ms))
        val expected = opened().apply { toField(100 * ms, false); advance(180 * ms) }
        assertEquals(expected.frame.value.toField, p.frame.value.toField, 0.0)
        assertTrue(p.frame.value.toField > 0)
        assertTrue(handoff.measure(target.copy(y = 420.0)))
        assertEquals(420.0, handoff.destination!!.y, 0.0)
        assertFalse(handoff.start(p, 200 * ms))
        assertEquals(expected.frame.value.toField, p.frame.value.toField, 0.0)
    }

    @Test fun revocationAtEightyOrOneSixtyIsPermanentAndCannotBecomeANewAccountOrField() {
        for (at in listOf(80L, 160L)) {
            var current = true
            val p = opened()
            val handoff = BrowserPageMenuFieldHandoff(input, ms, false, true) { current }
            handoff.measure(target); handoff.start(p, at * ms)
            assertTrue(p.frame.value.toField in 0.0..1.0)
            current = false; assertFalse(handoff.owned())
            current = true; assertFalse(handoff.owned())
            assertFalse(handoff.measure(target.copy(y = 300.0)))
            p.revoke()
            assertEquals(PageMenuRelease.REVOKED, p.claimCompletion { handoff.owned() }!!.reason)
            assertFalse(p.toField(2_000 * ms, false))
        }
    }

    @Test fun reducedHandoffUsesTheSourceFadeAndDisabledCompletionIsOneShotWithoutAPlateExit() {
        val reduced = opened()
        reduced.toField(0, true)
        assertEquals(.5, reduced.advance(100 * ms).toField, .00000001)
        assertEquals(PageMenuPhase.HANDED_OFF, reduced.advance(200 * ms).phase)
        val disabled = opened()
        assertTrue(disabled.toField(ms, false, false))
        assertEquals(PageMenuPhase.HANDED_OFF, disabled.frame.value.phase)
        assertEquals(1.0, disabled.frame.value.toField, 0.0)
        assertEquals(PageMenuRelease.HANDED_OFF, disabled.claimCompletion { true }!!.reason)
        assertNull(disabled.claimCompletion { true })
    }
}

package dev.yab.browser.ui

import dev.yab.browser.model.PageMenuLease
import dev.yab.browser.model.WebsiteProfile
import org.junit.Assert.*
import org.junit.Test

/** Logical route decisions use Phone's page target, never the painted spring midpoint. */
class BrowserPageMenuNavigationTest {
    private val ms = 1_000_000L
    private fun owner() = PageMenuLease("menu-navigation", 3, "tab", "space", WebsiteProfile("shared"), Any(), 7, 1)
    private fun site() = BrowserPageMenuPresentation(owner()).apply {
        open(0, reduced = false, animations = false)
        navigate(PageMenuPage.SITE, ms, reduced = false, animations = false)
    }

    @Test fun certificateBackBeforeItsFirstFrameReturnsToSiteInsteadOfSkippingToMenu() {
        val p = site()
        assertTrue(p.navigate(PageMenuPage.CERTIFICATE, 10 * ms, reduced = false))
        assertEquals(PageMenuPage.CERTIFICATE, p.frame.value.targetPage)
        assertEquals(0.0, p.frame.value.certificate, 0.0)
        assertEquals(1.0, p.frame.value.site, 0.0)
        assertTrue(p.back(10 * ms, reduced = false))
        assertEquals(PageMenuPage.SITE, p.frame.value.targetPage)
        assertEquals(1.0, p.advance(2_000 * ms).site, 0.0)
        assertEquals(0.0, p.frame.value.certificate, 0.0)
    }

    @Test fun eightyAndOneSixtyMillisecondInterruptionsBothReturnToSiteFromTheCurrentPose() {
        for (elapsed in listOf(80L, 160L)) {
            val p = site()
            p.navigate(PageMenuPage.CERTIFICATE, 10 * ms, reduced = false)
            val at = (10 + elapsed) * ms
            val entering = p.advance(at)
            assertTrue(entering.certificate > 0 && entering.certificate < 1)
            if (elapsed == 80L) assertTrue(entering.certificate < .5)
            else assertTrue(entering.certificate > .5)
            assertTrue(p.back(at, reduced = false))
            assertEquals(PageMenuPage.SITE, p.frame.value.targetPage)
            assertEquals(entering.site, p.frame.value.site, 0.0)
            assertEquals(entering.certificate, p.frame.value.certificate, 0.0)
            // Retained incoming velocity may carry the certificate slightly farther first;
            // the destination is still Site and its already-open sheet never goes to Menu.
            for (delta in listOf(16L, 80L, 160L, 600L)) assertEquals(1.0, p.advance(at + delta * ms).site, 0.0)
            assertEquals(0.0, p.advance(at + 2_000 * ms).certificate, 0.0)
            assertEquals(PageMenuPage.SITE, p.frame.value.targetPage)
        }
    }

    @Test fun aSecondBackBeforeRecompositionUsesTheNewLogicalTargetAndKeepsTheDrawnPose() {
        val p = site()
        p.navigate(PageMenuPage.CERTIFICATE, 10 * ms, reduced = false)
        val at = 90 * ms
        val entering = p.advance(at)
        assertTrue(p.back(at, reduced = false))
        assertEquals(PageMenuPage.SITE, p.frame.value.targetPage)
        assertTrue(p.back(at, reduced = false))
        assertEquals(PageMenuPage.MENU, p.frame.value.targetPage)
        assertEquals(entering.site, p.frame.value.site, 0.0)
        assertEquals(entering.certificate, p.frame.value.certificate, 0.0)
        p.advance(2_000 * ms)
        assertEquals(0.0, p.frame.value.site, 0.0)
        assertEquals(0.0, p.frame.value.certificate, 0.0)
    }

    @Test fun closeAndReopenKeepTheLogicalPageButFieldHandoffAndRevocationRejectBack() {
        val p = site()
        p.navigate(PageMenuPage.CERTIFICATE, 10 * ms, reduced = false)
        val entering = p.advance(90 * ms)
        assertTrue(p.close(90 * ms, reduced = false))
        assertFalse(p.back(91 * ms, reduced = false))
        p.open(100 * ms, reduced = false)
        assertEquals(PageMenuPage.CERTIFICATE, p.frame.value.targetPage)
        p.advance(2_000 * ms)
        assertTrue(p.back(2_000 * ms, reduced = false))
        assertEquals(PageMenuPage.SITE, p.frame.value.targetPage)
        assertTrue(entering.certificate > 0)
        p.advance(4_000 * ms)
        assertTrue(p.toField(4_000 * ms, reduced = false))
        assertFalse(p.back(4_001 * ms, reduced = false))
        assertEquals(PageMenuPhase.HANDING_OFF, p.frame.value.phase)
        p.revoke()
        assertFalse(p.back(5_000 * ms, reduced = false))
        assertEquals(PageMenuFrame(PageMenuPhase.REVOKED), p.frame.value)
    }

    @Test fun reducedAndDisabledCertificateBackKeepTheSameLogicalDestination() {
        for (animations in listOf(true, false)) {
            val p = site()
            p.navigate(PageMenuPage.CERTIFICATE, 10 * ms, reduced = true, animations = animations)
            val at = if (animations) 90 * ms else 10 * ms
            val before = p.advance(at)
            assertTrue(p.back(at, reduced = true, animations = animations))
            assertEquals(PageMenuPage.SITE, p.frame.value.targetPage)
            if (animations) assertEquals(before.certificate, p.frame.value.certificate, 0.0)
            assertEquals(1.0, p.advance(at + 200 * ms).site, 0.0)
            assertEquals(0.0, p.frame.value.certificate, 0.0)
        }
    }

    @Test fun retainedHeaderScopeCannotBorrowAReplacedOwnerOrANoninteractiveHandoff() {
        var current = true
        val entry = BrowserPageMenuEntry(owner(), { current }, {}, { _, _ -> }, { y, _ -> y },
            { _, _ -> }, { _, _ -> }, {}, {}, {})
        val g = BrowserPageMenuGeometry(402.0, 874.0, 54.0, PageMenuRect(81.0, 798.0, 240.0, 48.0), 408.0)
        entry.layoutLease.accept(g)
        val now = System.nanoTime()
        entry.presentation.open(now, reduced = false, animations = false)
        entry.presentation.navigate(PageMenuPage.SITE, now, reduced = false, animations = false)
        val captured = BrowserPageMenuScope(g.pose(entry.presentation.frame.value, false), true,
            PageMenuPage.SITE, entry, false, false)
        entry.presentation.navigate(PageMenuPage.CERTIFICATE, now, reduced = false, animations = false)
        assertTrue(captured.back())
        assertEquals(PageMenuPage.SITE, entry.presentation.frame.value.targetPage)
        current = false
        assertFalse(captured.back())
        assertEquals(PageMenuPage.SITE, entry.presentation.frame.value.targetPage)
        current = true
        entry.presentation.toField(System.nanoTime(), reduced = false)
        assertFalse(captured.back())
    }
}

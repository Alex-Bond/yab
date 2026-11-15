package dev.yab.browser.ui

import dev.yab.browser.model.PageMenuLease
import dev.yab.browser.model.WebsiteProfile
import org.junit.Assert.*
import org.junit.Test

class BrowserPageMenuTest {
    private fun owner(account: String? = "menu-fixture", epoch: Long = 1, tab: String = "tab",
        profile: WebsiteProfile = WebsiteProfile("shared"), native: Any = Any(), surface: Long = 7, generation: Long = 1) =
        PageMenuLease(account, epoch, tab, "space", profile, native, surface, generation)
    private fun geometry() = BrowserPageMenuGeometry(390.0, 844.0, 54.0,
        PageMenuRect(81.0, 768.0, 228.0, 48.0), 408.0, hostTitleWidth = 112.0, certificateTitleWidth = 95.0)
    private val ms get() = 1_000_000L

    @Test fun capturedPlateAndMeasuredBodiesUseTheCurrentPhoneLayoutAndSafeTop() {
        val g = geometry()
        val plate = g.pose(PageMenuFrame(), false)
        assertEquals(g.plate, plate.sheet); assertEquals(g.plate, plate.row)
        assertEquals(24.0, plate.radius, 0.0); assertEquals(0.0, plate.scrim, 0.0)
        val open = g.pose(PageMenuFrame(shown = true, progress = 1.0), false)
        assertEquals(PageMenuRect(8.0, 350.0, 374.0, 486.0), open.sheet)
        assertEquals(PageMenuRect(22.0, 364.0, 346.0, 48.0), open.row)
        assertEquals(404.0, open.travel, 0.0); assertEquals(38.0, open.radius, 0.0)
        assertEquals(.22, open.scrim, 1e-12)
        val capped = g.copy(menuBody = 2000.0).pose(PageMenuFrame(shown = true, progress = 1.0), false)
        assertEquals(78.0, capped.sheet.y, 0.0); assertEquals(758.0, capped.sheet.height, 0.0)
        assertEquals(680.0, capped.bodyRoom, 0.0)
    }

    @Test fun siteCertificateFieldAndReducedDropPreserveTheSourceGeometryRules() {
        val g = geometry()
        val site = g.pose(PageMenuFrame(shown = true, progress = 1.0, site = 1.0), false)
        assertEquals(598.0, site.sheet.height, 0.0)
        assertEquals(150.0, site.row.width, 0.0); assertEquals(120.0, site.row.x, 0.0)
        assertEquals(138.0, site.hostRoom, 0.0)
        assertEquals(PageMenuRect(24.0, 254.0, 44.0, 44.0), site.headerBack)
        assertEquals(1.0, site.headerBackOpacity, 0.0)
        val cert = g.pose(PageMenuFrame(shown = true, progress = 1.0, site = 1.0, certificate = 1.0), false)
        assertEquals(378.0, cert.sheet.height, 0.0)
        val field = PageMenuRect(8.0, 480.0, 319.0, 48.0)
        val destination = g.copy(field = field).pose(PageMenuFrame(shown = true, progress = 1.0, toField = 1.0), false)
        assertEquals(field, destination.sheet); assertEquals(field, destination.row)
        assertEquals(0.0, destination.opacity, 0.0); assertEquals(0.0, destination.rowOpacity, 0.0)
        val drop = g.pose(PageMenuFrame(progress = .25), true)
        assertEquals(1.0, drop.progress, 0.0); assertEquals(.25, drop.fade, 0.0)
        assertEquals(30.0, drop.sink, 0.0); assertEquals(.055, drop.scrim, 1e-12)
        assertEquals(1.0, drop.block(7), 0.0)
    }

    @Test fun openingClosingAndReopeningRetainTheLivePoseAndCancelTheOldAction() {
        val p = BrowserPageMenuPresentation(owner())
        var actions = 0
        p.open(0, false); val rising = p.advance(90 * ms)
        assertTrue(rising.progress in 0.0..1.0); assertTrue(rising.running)
        p.close(90 * ms, false, afterLanding = { actions++ })
        assertEquals(rising.progress, p.frame.value.progress, 1e-12)
        assertFalse(p.frame.value.interactive)
        val falling = p.advance(150 * ms)
        p.open(150 * ms, false)
        assertEquals(falling.progress, p.frame.value.progress, 1e-12)
        p.advance(2_000 * ms)
        assertEquals(PageMenuPhase.OPEN, p.frame.value.phase)
        assertNull(p.claimCompletion { true }); assertEquals(0, actions)
        assertTrue(p.close(2_000 * ms, false, afterLanding = { actions++ }))
        assertFalse(p.close(2_010 * ms, false, afterLanding = { actions += 10 }))
        assertNull(p.claimCompletion { true })
        p.advance(2_320 * ms)
        p.claimCompletion { true }!!.action!!.invoke()
        assertNull(p.claimCompletion { true }); assertEquals(1, actions)
    }

    @Test fun revokedAccountEpochNativeDocumentPrivateProfileAndSurfaceNeverRunALateAction() {
        val original = owner()
        val replacements = listOf(original.copy(account = "other"), original.copy(accountEpoch = 2), original.copy(device = "other-device"),
            original.copy(tab = "other"), original.copy(profile = WebsiteProfile("private", true)),
            original.copy(nativeOwner = Any()), original.copy(surfaceEpoch = 8), original.copy(generation = 2))
        replacements.forEach { replacement ->
            val p = BrowserPageMenuPresentation(original)
            var actions = 0
            p.open(0, false, false)
            p.close(ms, false, afterLanding = { actions++ })
            p.advance(400 * ms)
            val completion = p.claimCompletion { it == replacement }!!
            assertEquals(PageMenuRelease.REVOKED, completion.reason)
            assertNull(completion.action); assertEquals(0, actions)
            assertNull(p.claimCompletion { true })
        }
        val privateOwner = owner(profile = WebsiteProfile("private", true))
        val privateMenu = BrowserPageMenuPresentation(privateOwner)
        privateMenu.open(0, false, false)
        privateMenu.close(ms, false, afterLanding = { fail("Revoked Private action") })
        privateMenu.revoke(); privateMenu.advance(500 * ms)
        assertFalse(privateMenu.frame.value.running)
        assertEquals(PageMenuFrame(PageMenuPhase.REVOKED), privateMenu.frame.value)
        assertNull(privateMenu.claimCompletion { true }!!.action)
    }

    @Test fun cancelledDragAndRegrabUseTheCurrentOffsetAndExplicitPredictionWithoutInventedDecay() {
        val p = BrowserPageMenuPresentation(owner())
        p.open(0, false, false)
        assertTrue(p.beginDrag(ms)); p.drag(90.0)
        p.cancelDrag(2 * ms, false)
        val returning = p.advance(30 * ms).drag
        assertTrue(returning in 0.0..90.0)
        assertTrue(p.beginDrag(30 * ms)); p.drag(2.0)
        assertEquals(returning + 2, p.frame.value.drag, 1e-9)
        assertFalse(p.release(0.0, 400.0, 31 * ms, false))
        p.advance(2_000 * ms)
        assertTrue(p.beginDrag(2_001 * ms)); p.drag(12.0)
        assertTrue(p.release(241.0, 400.0, 2_002 * ms, false))
        assertEquals(PageMenuPhase.CLOSING, p.frame.value.phase)
        val negative = BrowserPageMenuPresentation(owner())
        negative.open(0, false, false); negative.beginDrag(ms); negative.drag(0.0)
        assertFalse(negative.release(999.0, 400.0, 2 * ms, false))
    }

    @Test fun currentSourceStrictReleaseThresholdsAndReducedDisabledTimingArePreserved() {
        val p = BrowserPageMenuPresentation(owner())
        p.open(0, true)
        p.advance(100 * ms)
        assertEquals(.5, p.frame.value.progress, 1e-9)
        p.advance(200 * ms); assertTrue(p.frame.value.interactive)
        p.beginDrag(201 * ms); p.drag(120.0)
        assertFalse(p.release(240.0, 400.0, 202 * ms, true))
        p.advance(402 * ms)
        p.beginDrag(403 * ms); p.drag(120.01)
        assertTrue(p.release(0.0, 400.0, 404 * ms, true))
        assertEquals(PageMenuPhase.CLOSING, p.advance(603 * ms).phase)
        assertEquals(PageMenuPhase.CLOSED, p.advance(604 * ms).phase)
        val disabled = BrowserPageMenuPresentation(owner())
        disabled.open(0, false, false)
        assertEquals(1.0, disabled.frame.value.progress, 0.0)
        assertTrue(disabled.close(ms, false, false))
        assertEquals(PageMenuPhase.CLOSED, disabled.frame.value.phase)
    }

    @Test fun siteNavigationReversesFromItsMeasuredLivePoseDuringTheSameClock() {
        val p = BrowserPageMenuPresentation(owner())
        p.open(0, false, false)
        assertTrue(p.navigate(PageMenuPage.SITE, ms, false))
        val first = p.advance(80 * ms).site
        assertTrue(first > 0 && first < 1)
        assertTrue(p.navigate(PageMenuPage.MENU, 80 * ms, false))
        assertEquals(first, p.frame.value.site, 1e-12)
        p.advance(2_000 * ms); assertEquals(0.0, p.frame.value.site, 0.0)
        p.navigate(PageMenuPage.CERTIFICATE, 2_001 * ms, false)
        val mid = p.advance(2_090 * ms)
        assertTrue(mid.site > 0 && mid.certificate > 0 && mid.running)
        p.close(2_090 * ms, false)
        assertFalse(p.advance(2_410 * ms).running)
        p.revoke(); p.advance(4_000 * ms)
        assertEquals(PageMenuPhase.REVOKED, p.frame.value.phase)
    }

    @Test fun invalidOriginsAndMissingFieldDestinationsFailClosed() {
        assertThrows(IllegalArgumentException::class.java) { geometry().copy(plate = PageMenuRect(Double.NaN, 1.0, 10.0, 10.0)) }
        assertThrows(IllegalArgumentException::class.java) { geometry().copy(safeTop = Double.POSITIVE_INFINITY) }
        assertThrows(IllegalArgumentException::class.java) { geometry().pose(PageMenuFrame(progress = 1.0, toField = .5), false) }
        val layout = BrowserPageMenuLayoutLease()
        assertTrue(layout.accept(geometry()))
        assertTrue(layout.accept(geometry().copy(menuBody = 600.0, hostTitleWidth = 120.0)))
        assertFalse(layout.accept(geometry().copy(plate = geometry().plate.copy(y = 767.0))))
        assertFalse(layout.accept(geometry()))
        assertTrue(BrowserPageMenuLayoutLease().accept(geometry().copy(width = 844.0, height = 390.0)))
    }

    @Test fun retiredBodyCallbacksCannotOperateTheNewPageExitOrReplacedLayout() {
        var actions = 0
        val entry = BrowserPageMenuEntry(owner(), { true }, {}, { _, _ -> }, { y, _ -> y },
            { _, _ -> }, { _, _ -> }, {}, {}, {})
        entry.layoutLease.accept(geometry())
        val now = System.nanoTime()
        entry.presentation.open(now, false, false)
        val scope = BrowserPageMenuScope(geometry().pose(entry.presentation.frame.value, false), true,
            PageMenuPage.MENU, entry, false, true, PageMenuPage.MENU)
        assertTrue(scope.perform { actions++ })
        assertTrue(scope.navigate(PageMenuPage.SITE))
        entry.presentation.advance(System.nanoTime() + 2_000_000_000L)
        assertFalse(scope.perform { actions++ })
        assertFalse(scope.navigate(PageMenuPage.MENU))
        entry.presentation.close(System.nanoTime() + 2_000_000_001L, false)
        assertFalse(scope.perform { actions++ })
        assertEquals(1, actions)
        entry.layoutLease.accept(geometry().copy(width = 400.0))
        assertFalse(scope.perform { actions++ })
    }
}

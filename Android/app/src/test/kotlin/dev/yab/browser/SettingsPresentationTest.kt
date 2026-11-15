package dev.yab.browser

import dev.yab.browser.ui.*
import org.junit.Assert.*
import org.junit.Test

/** Drives the production model clock. Source curves/decisions only, not presented-frame proof. */
class SettingsPresentationTest {
    @Test fun fullHeightEntryAndExitUseIndependent500And300MillisAndCannotFinishAnOldClose() {
        val p = SettingsPresentation()
        p.show(0, false, true)
        assertEquals(1.0, p.frame.value.offset, 0.0)
        val half = p.advance(250_000_000).offset
        assertTrue(half in 0.0..1.0 && half != 0.0)
        assertEquals(0.0, p.advance(500_000_000).offset, 0.0)
        p.hide(500_000_000)
        val closing = p.advance(650_000_000)
        assertEquals(SettingsPhase.CLOSING, closing.phase)
        assertTrue(closing.offset > 0)
        p.show(650_000_000, false, true)
        assertEquals(closing.offset, p.frame.value.offset, 1e-12)
        val afterOldDeadline = p.advance(800_000_000)
        assertTrue(afterOldDeadline.shown)
        assertNotEquals(SettingsPhase.CLOSED, afterOldDeadline.phase)
        assertEquals(SettingsPhase.OPEN, p.advance(1_150_000_000).phase)
        p.hide(1_150_000_000)
        assertEquals(SettingsPhase.CLOSING, p.advance(1_449_999_999).phase)
        assertEquals(SettingsPhase.CLOSED, p.advance(1_450_000_000).phase)
    }

    @Test fun actualHorizontalStackRetainsIdsAndInterruptsPushWithBackWithoutASnap() {
        val p = SettingsPresentation(); p.show(0, false, true); p.advance(500_000_000)
        val root = p.frame.value.routes.single().id
        p.push("Appearance", 500_000_000)
        val before = p.advance(580_000_000)
        val outgoing = before.routes.last()
        assertTrue(outgoing.x > 0 && outgoing.x < 1)
        assertTrue(before.routes.first().x in -1.0/3..0.0)
        p.back(580_000_000)
        assertEquals(outgoing.x, p.frame.value.routes.last().x, 0.0)
        assertTrue(p.routeCurrent(root)); assertFalse(p.routeCurrent(outgoing.id))
        assertEquals(2, p.frame.value.routes.size)
        p.advance(930_000_000)
        assertEquals(listOf(root), p.frame.value.routes.map { it.id })
        p.push("Appearance", 930_000_000); p.advance(1_350_000_000)
        p.push("App Icon", 1_350_000_000); p.advance(1_770_000_000)
        assertEquals(3, p.frame.value.routes.size)
        assertFalse(p.frame.value.routes.first().visible)
        assertEquals(-1.0/3, p.frame.value.routes[1].x, 1e-12)
        assertEquals(.08, p.frame.value.routes[1].dim, 1e-12)
        assertTrue(p.frame.value.canBack)
    }

    @Test fun edgeGestureCapturesThePathAndHonorsProjectionVelocityAndCancel() {
        val p = SettingsPresentation(); p.show(0, false, false); p.push("Tabs", 0)
        val tabs = p.frame.value.routes.last().id
        assertTrue(p.beginBack(tabs, 0)); p.pullBack(tabs, .1)
        assertFalse(p.endBack(tabs, 400.0, 0.0, 0, cancelled = true))
        assertTrue(p.routeCurrent(tabs))
        assertTrue(p.beginBack(tabs, 1)); p.pullBack(tabs, .1)
        assertTrue(p.endBack(tabs, 400.0, 650.0, 1))
        assertFalse(p.routeCurrent(tabs))
        p.push("Search", 2); val search = p.frame.value.routes.last().id
        assertTrue(p.beginBack(search, 2)); p.push("General", 2)
        p.pullBack(search, .9)
        assertFalse(p.endBack(search, 400.0, 1000.0, 2))
        assertEquals("General", p.frame.value.routes.last().title)
    }

    @Test fun committedEdgeKeepsTheSourcePathAndBackActionUntilItsOwn350MillisLanding() {
        val p = SettingsPresentation(); p.show(0, false, true); p.advance(500_000_000)
        val root = p.frame.value.routes.single().id
        p.push("General", 500_000_000); p.advance(920_000_000)
        val general = p.frame.value.routes.last().id
        assertTrue(p.beginBack(general, 920_000_000)); p.pullBack(general, .5)
        assertTrue(p.endBack(general, 402.0, 0.0, 920_000_000))
        // Phone SettingsUI keeps navigation.last until the edge animation completes.
        assertFalse(p.routeCurrent(root)); assertTrue(p.routeCurrent(general))
        assertFalse(p.frame.value.routes.first().interactive)
        assertTrue(p.frame.value.canBack); assertFalse(p.frame.value.routes.last().retired)
        val mid = p.advance(1_095_000_000)
        assertTrue(mid.routes.last().x > .5 && mid.routes.last().x < 1)
        assertTrue(mid.canBack); assertFalse(p.routeCurrent(root))
        p.advance(1_269_999_999)
        assertTrue(p.routeCurrent(general)); assertFalse(p.routeCurrent(root))
        p.advance(1_270_000_000)
        assertEquals(listOf(root), p.frame.value.routes.map { it.id })
        assertTrue(p.routeCurrent(root)); assertFalse(p.frame.value.canBack)

        p.push("General", 1_270_000_000); p.advance(1_690_000_000)
        val next = p.frame.value.routes.last().id
        p.beginBack(next, 1_690_000_000); p.pullBack(next, .5)
        p.endBack(next, 402.0, 0.0, 1_690_000_000)
        // A button/OS Back during flight still pops immediately and cannot become sheet Close.
        assertTrue(p.frame.value.canBack); assertTrue(p.back(1_770_000_000))
        assertTrue(p.routeCurrent(root))
        p.push("Search", 1_770_000_000)
        val search = p.frame.value.routes.last().id
        p.advance(2_190_000_000)
        assertTrue(p.routeCurrent(search)); assertEquals("Search", p.frame.value.title)
    }

    @Test fun edgeCompletionCannotPopARegrabbedReplacedReopenedOrRevokedPath() {
        fun scene(): SettingsPresentation = SettingsPresentation().also {
            it.show(0, false, true); it.advance(500_000_000)
            it.push("General", 500_000_000); it.advance(920_000_000)
        }
        fun commit(p: SettingsPresentation): Long = p.frame.value.routes.last().id.also {
            assertTrue(p.beginBack(it, 920_000_000)); p.pullBack(it, .5)
            assertTrue(p.endBack(it, 402.0, 0.0, 920_000_000))
        }
        val regrab = scene(); val original = commit(regrab)
        val moving = regrab.advance(1_000_000_000).routes.last().x
        assertTrue(regrab.beginBack(original, 1_000_000_000))
        assertEquals(moving, regrab.frame.value.routes.last().x, 0.0)
        regrab.pullBack(original, .2)
        assertFalse(regrab.endBack(original, 402.0, 0.0, 1_000_000_000, cancelled = true))
        regrab.advance(1_350_000_000)
        assertTrue(regrab.routeCurrent(original)); assertEquals(0.0, regrab.frame.value.routes.last().x, 0.0)
        val replacement = scene(); commit(replacement)
        replacement.push("Search", 1_000_000_000); val search = replacement.frame.value.routes.last().id
        replacement.advance(1_420_000_000)
        assertTrue(replacement.routeCurrent(search)); assertEquals(3, replacement.frame.value.routes.size)
        val reopened = scene(); val retained = commit(reopened)
        reopened.hide(1_000_000_000); reopened.show(1_050_000_000, false, true)
        reopened.advance(1_550_000_000)
        assertTrue(reopened.routeCurrent(retained)); assertFalse(reopened.frame.value.routes.last().retired)
        assertEquals(0.0, reopened.frame.value.routes.last().x, 0.0)
        val revoked = scene(); commit(revoked); revoked.revoke()
        assertEquals(SettingsPhase.REVOKED, revoked.advance(2_000_000_000).phase)
        assertTrue(revoked.frame.value.routes.isEmpty())
    }

    @Test fun reducedSheetFades200WithoutPageTranslationsAndDirectAboutIsItsOwnRoot() {
        val p = SettingsPresentation("About"); p.show(0, true, true)
        assertEquals(0.0, p.frame.value.opacity, 0.0)
        assertEquals(0.0, p.frame.value.offset, 0.0)
        assertFalse(p.frame.value.canBack)
        assertFalse(p.back(0))
        assertTrue(p.advance(100_000_000).opacity in .01.. .99)
        assertEquals(1.0, p.advance(200_000_000).opacity, 0.0)
        p.push("General", 200_000_000)
        assertTrue(p.frame.value.canBack)
        assertEquals(0.0, p.frame.value.routes.last().x, 0.0)
        p.hide(200_000_000)
        assertEquals(SettingsPhase.CLOSED, p.advance(400_000_000).phase)
    }

    @Test fun aSheetExitDoesNotWaitForAnUnrelatedLongerPagePush() {
        val p = SettingsPresentation(); p.show(0, false, true); p.advance(500_000_000)
        p.push("General", 500_000_000)
        p.hide(510_000_000)
        assertEquals(SettingsPhase.CLOSING, p.advance(809_999_999).phase)
        assertEquals(SettingsPhase.CLOSED, p.advance(810_000_000).phase)
    }

    @Test fun aHeldHeaderStaysDraggingAcrossFramesUntilAnExplicitReleaseOrCancel() {
        val p = SettingsPresentation(); p.show(0, false, true); p.advance(500_000_000)
        p.pullSheet(121.0, 874.0, 500_000_000)
        listOf(516_000_000L, 700_000_000L, 1_500_000_000L).forEach { now ->
            val held = p.advance(now)
            assertEquals(SettingsPhase.DRAGGING, held.phase)
            assertEquals(121.0, held.drag, 0.0)
            assertTrue(held.shown)
        }
        assertTrue(p.releaseSheet(0.0, 1_500_000_000))
        assertEquals(SettingsPhase.CLOSING, p.frame.value.phase)
        val cancelled = SettingsPresentation(); cancelled.show(0, false, true); cancelled.advance(500_000_000)
        cancelled.pullSheet(121.0, 874.0, 500_000_000); cancelled.advance(1_500_000_000)
        assertFalse(cancelled.releaseSheet(900.0, 1_500_000_000, cancelled = true))
        assertTrue(cancelled.advance(3_000_000_000).shown)
        assertEquals(0.0, cancelled.frame.value.drag, 0.0)
    }

    @Test fun headerPullCannotCloseOnCancelAndRevokeRemovesAllRoutePixels() {
        val p = SettingsPresentation(); p.show(0, false, true); p.advance(500_000_000)
        p.pullSheet(150.0, 874.0, 500_000_000)
        assertFalse(p.releaseSheet(900.0, 500_000_000, cancelled = true))
        assertTrue(p.frame.value.shown)
        p.advance(2_000_000_000)
        p.pullSheet(121.0, 874.0, 2_000_000_000)
        assertTrue(p.releaseSheet(0.0, 2_000_000_000))
        assertEquals(SettingsPhase.CLOSING, p.frame.value.phase)
        p.revoke()
        assertTrue(p.frame.value.routes.isEmpty())
        assertEquals(SettingsPhase.REVOKED, p.advance(10_000_000_000).phase)
    }

    @Test fun renderedRouteRevisionCannotReviveAfterPushBackToTheSameRootOrWhileClosing() {
        val p = SettingsPresentation(); p.show(0, false, true); p.advance(500_000_000)
        val root = p.frame.value.routes.single().id
        val originalRevision = p.frame.value.generation
        assertTrue(p.routeCurrent(root, originalRevision))

        assertTrue(p.push("General", 500_000_000))
        assertFalse(p.routeCurrent(root, originalRevision))
        val pushed = p.frame.value.routes.last().id
        assertTrue(p.routeCurrent(pushed, p.frame.value.generation))
        assertTrue(p.back(580_000_000))

        assertEquals(root, p.frame.value.routes.first().id)
        assertTrue(p.routeCurrent(root))
        assertFalse(p.routeCurrent(root, originalRevision))
        val freshRevision = p.frame.value.generation
        assertTrue(freshRevision > originalRevision)
        assertTrue(p.routeCurrent(root, freshRevision))

        assertTrue(p.hide(580_000_000))
        assertEquals(SettingsPhase.CLOSING, p.frame.value.phase)
        assertFalse(p.routeCurrent(root, freshRevision))
        assertFalse(p.routeCurrent(root, p.frame.value.generation))
        assertEquals(SettingsPhase.CLOSED, p.advance(880_000_000).phase)
        assertFalse(p.routeCurrent(root, p.frame.value.generation))
    }
}

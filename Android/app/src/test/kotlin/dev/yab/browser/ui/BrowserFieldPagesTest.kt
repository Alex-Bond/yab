package dev.yab.browser.ui

import org.junit.Assert.*
import org.junit.Test

class BrowserFieldPagesTest {
    private val pages = listOf(
        FieldPage(BrowserFieldPageSelection.PRIVATE, "Private", FieldPageKind.PRIVATE),
        FieldPage(BrowserFieldPageSelection.CHATS, "Chats", FieldPageKind.CHATS),
        FieldPage("space:a", "Personal", FieldPageKind.SPACE, "a"),
        FieldPage("space:b", "Work", FieldPageKind.SPACE, "b"))

    @Test fun frameTimeDoesNotMixUptimeWithAControlledClockOrChargeIdleAsMotion() {
        val clock = BrowserFieldPageClock()
        assertEquals(1L, clock.event(false))
        assertEquals(1L, clock.frame(7_000_000_000L))
        assertEquals(16_000_001L, clock.frame(7_016_000_000L))
        assertEquals(16_000_001L, clock.event(true))
        assertEquals(32_000_001L, clock.frame(7_032_000_000L))
        clock.event(false)
        assertEquals(32_000_001L, clock.frame(900_000_000_000L))
        assertEquals(48_000_001L, clock.frame(900_016_000_000L))
    }

    @Test fun eyesReturnToTheLastOrdinarySpaceWhileChatsKeepsThatChoice() {
        val selection = BrowserFieldPageSelection(pages, "a", false)
        assertEquals("space:a", selection.target)
        selection.picked("space:b")
        assertEquals(BrowserFieldPageSelection.PRIVATE, selection.eyes(true))
        selection.picked(BrowserFieldPageSelection.CHATS)
        assertEquals("b", selection.lastOrdinary)
        assertEquals("space:b", selection.eyes(false))
        assertNull(selection.picked("removed-page"))
        selection.configure(pages.filterNot { it.space == "b" }, "a")
        assertEquals("space:a", selection.target)
        val only = BrowserFieldPageSelection(pages.take(1), null, true)
        assertEquals(BrowserFieldPageSelection.PRIVATE, only.eyes(false))
    }

    @Test fun eachEyesReversalStartsAtTheActualInkAndKeepsTheFullRemainingCurve() {
        for (delay in listOf(80_000_000L, 160_000_000L)) {
            val ink = BrowserFieldPrivacyInk(false)
            val began = 1_000_000_000L
            ink.target(true, began, false, true)
            val before = ink.advance(began + delay)
            assertTrue(before > 0 && before < 1)
            ink.target(false, began + delay, false, true)
            assertEquals(before, ink.value, 0.0)
            val after = ink.advance(began + delay + 16_000_000L)
            assertTrue(after < before && after > 0)
            ink.advance(began + delay + 200_000_000L)
            assertEquals(0.0, ink.value, 0.0); assertFalse(ink.running)
        }
        val disabled = BrowserFieldPrivacyInk(false)
        disabled.target(true, 2_000_000_000L, true, false)
        assertEquals(1.0, disabled.value, 0.0); assertFalse(disabled.running)
    }

    @Test fun privateAuthorizationKeepsTheShackleHoldBeforeRevealingAndLockErasesImmediately() {
        val model = BrowserFieldPrivatePresentation(false)
        val start = 1_000_000_000L
        val attempt = requireNotNull(model.request(start, true))
        assertEquals(FieldPrivatePhase.TRYING, model.frame.value.phase)
        for (n in 1..12) model.advance(start + n * 16_000_000L)
        assertTrue(model.frame.value.words < .01)
        assertTrue(model.received(attempt, true, start + 200_000_000L, true, true))
        for (n in 1..24) model.advance(start + 200_000_000L + n * 16_000_000L)
        assertEquals(FieldPrivatePhase.OPENING, model.frame.value.phase)
        assertEquals(0.0, model.frame.value.list, 0.0)
        model.advance(start + 600_000_000L)
        assertEquals(FieldPrivatePhase.REVEALING, model.frame.value.phase)
        for (n in 1..80) model.advance(start + 600_000_000L + n * 16_000_000L)
        assertEquals(FieldPrivatePhase.REVEALED, model.frame.value.phase)
        assertEquals(1.0, model.frame.value.list, 0.0)
        model.lock()
        assertEquals(FieldPrivateFrame(FieldPrivatePhase.LOCKED), model.frame.value)
        assertFalse(model.received(attempt, true, start + 2_000_000_000L, true, true))
    }

    @Test fun failedOrSupersededAttemptCannotRevealAndAlreadyUnlockedStartsListed() {
        val model = BrowserFieldPrivatePresentation(false)
        val first = requireNotNull(model.request(1_000_000_000L, true))
        assertTrue(model.received(first, false, 1_050_000_000L, false, true))
        for (n in 1..60) model.advance(1_050_000_000L + n * 16_000_000L)
        assertEquals(FieldPrivatePhase.LOCKED, model.frame.value.phase)
        assertEquals(1.0, model.frame.value.words, 0.0)
        assertEquals(0.0, model.frame.value.list, 0.0)
        val pending = requireNotNull(model.request(2_100_000_000L, true))
        model.revoke()
        assertFalse(model.received(pending, true, 2_200_000_000L, true, true))
        assertEquals(FieldPrivatePhase.REVOKED, model.frame.value.phase)
        val unlocked = BrowserFieldPrivatePresentation(true)
        assertEquals(FieldPrivatePhase.REVEALED, unlocked.frame.value.phase)
        assertEquals(1.0, unlocked.frame.value.list, 0.0)
        val external = BrowserFieldPrivatePresentation(false)
        val old = requireNotNull(external.request(1_000_000_000L, true))
        external.authorized(1_020_000_000L, false, false)
        assertEquals(FieldPrivatePhase.REVEALED, external.frame.value.phase)
        assertFalse(external.received(old, false, 1_030_000_000L, false, false))
    }
}

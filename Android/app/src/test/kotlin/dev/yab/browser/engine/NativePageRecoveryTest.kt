package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

class NativePageRecoveryTest {
    @Test fun theSecondForegroundDeathBeforeSuccessStopsAutomaticRetry() {
        val page = NativePageRecovery()
        page.stopped(away = false)
        assertTrue(page.begin(requireNotNull(page.queue(true)), true))
        page.stopped(away = false)
        assertEquals(NativePageRecovery.Phase.FAILED, page.phase)
        assertNull(page.queue(true))
        page.succeeded(); page.stopped(away = false)
        assertTrue(page.begin(requireNotNull(page.queue(true)), true))
    }

    @Test fun backgroundDeathPrecedesTheBudgetCheckAndForegroundGrantsOneNewAttempt() {
        val page = NativePageRecovery()
        page.stopped(false); assertTrue(page.begin(requireNotNull(page.queue(true)), true))
        page.stopped(away = true)
        assertEquals(NativePageRecovery.Phase.DEFERRED, page.phase)
        assertNull(page.queue(false))
        page.foregrounded()
        assertTrue(page.begin(requireNotNull(page.queue(true)), true))
        page.stopped(false)
        assertEquals(NativePageRecovery.Phase.FAILED, page.phase)
    }

    @Test fun hidingOrLockingAfterQueueDoesNotSpendAnAttemptOrUseItsOldCompletion() {
        val page = NativePageRecovery()
        page.stopped(false)
        assertNull(page.queue(false))
        val old = requireNotNull(page.queue(true))
        assertFalse(page.begin(old, false))
        val current = requireNotNull(page.queue(true))
        assertFalse(page.begin(old, true))
        assertTrue(page.begin(current, true))
    }

    @Test fun removedNavigatedAndIdentityRevokedPagesCannotUseAQueuedTicket() {
        for (manual in listOf(false, true)) {
            val page = NativePageRecovery()
            page.stopped(false); val retired = requireNotNull(page.queue(true))
            if (manual) page.reset() else page.invalidate()
            assertFalse(page.begin(retired, true)); assertNull(page.queue(true))
            assertEquals(NativePageRecovery.Phase.IDLE, page.phase)
        }
    }

    @Test fun aFailedRestoreIsBoundedUntilExplicitReloadOrANewForeground() {
        val page = NativePageRecovery()
        page.stopped(false); assertTrue(page.begin(requireNotNull(page.queue(true)), true))
        page.failed(); assertNull(page.queue(true))
        page.foregrounded(); assertTrue(page.begin(requireNotNull(page.queue(true)), true))
        page.failed(); page.reset(); page.stopped(false)
        assertTrue(page.begin(requireNotNull(page.queue(true)), true))
    }

    @Test fun aHiddenDeathAfterAnUnfinishedRecoveryWaitsThenGetsOneAttemptWhenShown() {
        val page = NativePageRecovery()
        page.stopped(false); assertTrue(page.begin(requireNotNull(page.queue(true)), true))
        // #350: the old recovery did not finish, but this page is now behind
        // the selected tab. Showing it later must not strand it in FAILED.
        page.stopped(away = true)
        assertEquals(NativePageRecovery.Phase.DEFERRED, page.phase)
        assertNull(page.queue(eligible = false))
        assertTrue(page.begin(requireNotNull(page.queue(eligible = true)), eligible = true))
        page.stopped(away = false)
        assertEquals(NativePageRecovery.Phase.FAILED, page.phase)
        assertNull(page.queue(true))
    }

    @Test fun aReturnedAppLoadsOnlyItsShownPageAndHiddenRepeatedDeathsRetainTheirLaterAttempt() {
        val front = NativePageRecovery(); val behind = NativePageRecovery()
        for (page in listOf(front, behind)) {
            page.stopped(false); assertTrue(page.begin(requireNotNull(page.queue(true)), true))
            page.stopped(away = true)
            page.foregrounded()
        }
        assertTrue(front.begin(requireNotNull(front.queue(true)), true))
        assertNull(behind.queue(false))
        // It is briefly shown and starts recovery, then goes behind again
        // before success. No new application-foreground event grants a retry.
        assertTrue(behind.begin(requireNotNull(behind.queue(true)), true))
        // While hidden with the app in use, two more native terminations
        // must wait for actual showing rather than spend the foreground budget.
        behind.stopped(away = true); behind.stopped(away = true)
        assertNull(behind.queue(false))
        val retired = requireNotNull(behind.queue(true))
        assertFalse(behind.begin(retired, false))
        val shown = requireNotNull(behind.queue(true))
        assertFalse(behind.begin(retired, true))
        assertTrue(behind.begin(shown, true))
        behind.stopped(false)
        assertEquals(NativePageRecovery.Phase.FAILED, behind.phase)
    }
}

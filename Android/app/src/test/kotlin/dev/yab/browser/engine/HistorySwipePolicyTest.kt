package dev.yab.browser.engine

import dev.yab.browser.model.HistorySwipeDirection
import org.junit.Assert.*
import org.junit.Test

class HistorySwipePolicyTest {
    private val free = HistoryApzResult(true, false, false, false, false, true)
    private class Fixture {
        val policy = HistorySwipePolicy { "a".repeat(32) }.apply { newDocument(); configure(true) }
        var sequence = 23L // A restored BFCache realm need not start at zero.
        init { policy.receive(HistoryTouchReceipt(HistoryTouchPhase.SYNC, sequence, 0)) }
        fun arm(): HistoryArmRequest = checkNotNull(policy.requestArm()).also {
            policy.receive(HistoryTouchReceipt(HistoryTouchPhase.ARMED, sequence, 0, it.serial, it.token, accepted = true))
        }
        fun start(): HistoryDownTicket {
            arm()
            return checkNotNull(policy.down()).also { sequence++; start(it) }
        }
        fun start(ticket: HistoryDownTicket, held: Boolean = false, contacts: Int = 1) =
            policy.receive(HistoryTouchReceipt(HistoryTouchPhase.START, sequence, contacts, ticket.arm.serial, ticket.arm.token, held = held))
        fun end(ticket: HistoryDownTicket, cancel: Boolean = false) = policy.receive(HistoryTouchReceipt(
            if (cancel) HistoryTouchPhase.CANCEL else HistoryTouchPhase.END, sequence, 0, ticket.arm.serial, ticket.arm.token, held = false))
    }

    @Test fun positiveArmBeforeDownAndBothPageAndApzAreRequiredWithoutAssumingZeroBfcacheCounter() {
        val f = Fixture(); f.arm(); val ticket = f.policy.down()!!; f.sequence++
        assertFalse(f.policy.mayClaim(ticket, HistorySwipeDirection.BACK))
        f.policy.apz(ticket, free)
        assertFalse(f.policy.mayClaim(ticket, HistorySwipeDirection.BACK))
        f.start(ticket)
        assertTrue(f.policy.mayClaim(ticket, HistorySwipeDirection.BACK))
        f.end(ticket)
        assertTrue(f.policy.up(ticket, HistorySwipeDirection.BACK, false))
        assertNotNull(f.policy.requestArm())
    }

    @Test fun downDuringArmingNeverWaitsForLatePermissionOrGrantsTheFollowingDown() {
        val f = Fixture(); val pending = f.policy.requestArm()!!
        assertNull(f.policy.down())
        f.policy.receive(HistoryTouchReceipt(HistoryTouchPhase.ARMED, f.sequence, 0, pending.serial, pending.token, true))
        f.policy.up(null, null, false)
        assertNull(f.policy.requestArm())
        assertNull(f.policy.down())
        f.policy.up(null, null, false)
        assertNull(f.policy.requestArm())
    }

    @Test fun nativeUpAloneCannotRearmAndQueuedOldStartOrApzCannotGrantTheNextGesture() {
        val f = Fixture(); val old = f.start(); f.policy.apz(old, free)
        assertTrue(f.policy.up(old, HistorySwipeDirection.BACK, false))
        assertNull(f.policy.requestArm())
        assertNull(f.policy.down())
        f.policy.apz(old, free); f.start(old)
        f.policy.up(null, null, false)
        f.end(old)
        assertNull(f.policy.requestArm()) // Old DOM END cannot renumber the second native gesture.
        f.sequence++
        f.policy.receive(HistoryTouchReceipt(HistoryTouchPhase.END, f.sequence, 0, held = false))
        assertNotNull(f.policy.requestArm()) // Only the exact known-offset unarmed END restores idle.
    }

    @Test fun pageHeldMultitouchUnknownOrContentNativeResultsAndDirectionSpecificScrollAlwaysVeto() {
        for (result in listOf(free.copy(handled = false), free.copy(contentOwned = true), free.copy(ignored = true),
            free.copy(known = false), free.copy(horizontalOverscroll = false), free.copy(scrollsLeft = true))) {
            val f = Fixture(); val ticket = f.start(); f.policy.apz(ticket, result)
            assertFalse(result.toString(), f.policy.mayClaim(ticket, HistorySwipeDirection.BACK))
        }
        val forward = Fixture(); val ticket = forward.start(); forward.policy.apz(ticket, free.copy(scrollsRight = true))
        assertFalse(forward.policy.mayClaim(ticket, HistorySwipeDirection.FORWARD))
        for (held in listOf(true, false)) {
            val f = Fixture(); val value = f.start(); f.policy.apz(value, free)
            if (held) f.start(value, held = true) else f.policy.multipleContacts()
            f.start(value, held = false)
            assertFalse("A later positive message cannot undo a veto", f.policy.mayClaim(value, HistorySwipeDirection.BACK))
        }
    }

    @Test fun ownNativeHandoffCancelIsAnEndAckWhileFrameworkCancelStillNeverCommits() {
        val f = Fixture(); val ticket = f.start(); f.policy.apz(ticket, free)
        assertTrue(f.policy.mayClaim(ticket, HistorySwipeDirection.BACK))
        assertTrue(f.policy.handoff(ticket)); assertFalse(f.policy.handoff(ticket))
        f.end(ticket, cancel = true)
        assertTrue(f.policy.up(ticket, HistorySwipeDirection.BACK, false))
        assertNotNull(f.policy.requestArm())
        val cancelled = Fixture(); val other = cancelled.start(); cancelled.policy.apz(other, free)
        assertFalse(cancelled.policy.up(other, HistorySwipeDirection.BACK, true))
    }

    @Test fun settingOrOwnerRevocationInvalidatesOldCallbacksAndLeaseEvenWhenReenabled() {
        val f = Fixture(); val ticket = f.start(); f.policy.apz(ticket, free)
        f.policy.configure(false); f.policy.configure(true); f.start(ticket); f.policy.apz(ticket, free)
        assertFalse(f.policy.up(ticket, HistorySwipeDirection.BACK, false))
        f.policy.newDocument(); f.policy.receive(HistoryTouchReceipt(HistoryTouchPhase.SYNC, 89, 0))
        assertNotNull(f.policy.requestArm())
    }

    @Test fun idleResyncBeforeAnyNativeInputCanRecoverFromRefusedBfcacheCounterWithoutClockGuess() {
        val f = Fixture(); val request = f.policy.requestArm()!!
        f.policy.receive(HistoryTouchReceipt(HistoryTouchPhase.ARMED, 24, 0, request.serial, request.token, false))
        f.policy.receive(HistoryTouchReceipt(HistoryTouchPhase.SYNC, 24, 0))
        assertEquals(24L, f.policy.requestArm()!!.afterSequence)
    }

    @Test fun firstInputBeforeOffsetIsKnownRemainsNativeOnlyUntilNewDocument() {
        val f = HistorySwipePolicy { "b".repeat(32) }.apply { newDocument(); configure(true) }
        assertNull(f.down()); f.up(null, null, false)
        f.receive(HistoryTouchReceipt(HistoryTouchPhase.SYNC, 1, 0))
        assertNull(f.requestArm())
        f.newDocument(); f.receive(HistoryTouchReceipt(HistoryTouchPhase.SYNC, 12, 0))
        assertNotNull(f.requestArm())
    }

    @Test fun aRevokedPermitCanOnlyAcknowledgeItsNativeOnlyEndAndNeverGrantANewDown() {
        val f = Fixture(); val permit = f.arm()
        f.policy.configure(false); f.policy.configure(true)
        assertNull(f.policy.down()); f.sequence++
        f.policy.up(null, null, false)
        f.policy.receive(HistoryTouchReceipt(HistoryTouchPhase.END, f.sequence, 0, permit.serial, "c".repeat(32), held = false))
        assertNull(f.policy.requestArm())
        f.policy.receive(HistoryTouchReceipt(HistoryTouchPhase.END, f.sequence, 0, permit.serial, permit.token, held = false))
        assertNotNull(f.policy.requestArm())
    }
}

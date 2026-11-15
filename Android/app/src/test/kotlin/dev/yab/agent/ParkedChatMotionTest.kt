package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ParkedChatMotionTest {
    private fun motion() = ParkedChatPresentation(ParkedChat("fixture", "account", false, 2, 7))
    private fun drag(model: ParkedChatPresentation, amount: Double) { assertTrue(model.beginDrag(0)); model.drag(amount) }

    @Test fun exactDistanceAndVelocityBoundariesReturnButTwelvePointFastFlickLeaves() {
        val boundary = motion(); drag(boundary, 110.0)
        assertFalse(boundary.release(650.0, 0, false))
        assertEquals(ParkedLinePhase.RETURNING, boundary.frame.value.phase)
        val distance = motion(); drag(distance, -110.001)
        assertTrue(distance.release(0.0, 0, false)); distance.advance(200_000_000)
        assertEquals(-420.0, distance.frame.value.offset, 0.0)
        val fast = motion(); drag(fast, 12.0)
        assertTrue(fast.release(650.001, 0, false))
        assertEquals(ParkedLinePhase.LEAVING, fast.frame.value.phase)
        assertFalse(fast.claimCompletion()); fast.advance(199_999_999); assertFalse(fast.claimCompletion())
        fast.advance(200_000_000); assertTrue(fast.claimCompletion()); assertFalse(fast.claimCompletion())
    }

    @Test fun originalTimingCurvesSolveXAndKeepReturnOvershootAndExactFadeDomains() {
        val back = motion(); drag(back, 100.0); assertFalse(back.release(0.0, 0, false))
        // Cubic parameter t=.5 gives x=.3875, y=.95 for (.3,1.2,.4,1).
        back.advance(116_250_000); assertEquals(5.0, back.frame.value.offset, 1e-8)
        // t=.75 gives x=.6328125, y=1.0125: the source has a small overshoot.
        back.advance(189_843_750); assertEquals(-1.25, back.frame.value.offset, 1e-8)
        assertEquals(1 - 1.25 / 320, back.frame.value.opacity, 1e-10)
        back.advance(300_000_000); assertEquals(ParkedLinePhase.READY, back.frame.value.phase)
        val away = motion(); drag(away, 20.0)
        assertEquals(1 - 20.0 / 320, away.frame.value.opacity, 0.0)
        away.leave(1.0, 0, false)
        assertEquals(1 - 20.0 / 420, away.frame.value.opacity, 0.0)
        // LetGo parameter t=.5 gives x=.5375, y=.2 for (.3,0,.8,.2).
        away.advance(107_500_000); assertEquals(100.0, away.frame.value.offset, 1e-8)
        assertEquals(1 - 100.0 / 420, away.frame.value.opacity, 1e-10)
    }

    @Test fun cancelledLongDragCanNeverDeleteAndReturnsWithoutAnOpacityFloor() {
        val model = motion(); drag(model, 350.0)
        assertEquals(0.0, model.frame.value.opacity, 0.0)
        model.cancel(0, false); model.advance(500_000_000)
        assertEquals(ParkedLinePhase.READY, model.frame.value.phase)
        assertEquals(0.0, model.frame.value.offset, 0.0); assertEquals(1.0, model.frame.value.opacity, 0.0)
        assertFalse(model.claimCompletion())
    }

    @Test fun regrabAndDirectionReverseStartAtTheLiveReturnPose() {
        val model = motion(); drag(model, 90.0); model.release(0.0, 0, false)
        val live = model.advance(75_000_000).offset
        assertTrue(live > 0 && live < 90)
        assertTrue(model.beginDrag(75_000_000)); assertEquals(live, model.frame.value.offset, 0.0)
        model.drag(-8.0); assertEquals(live - 8.0, model.frame.value.offset, 0.0)
        assertTrue(model.release(-800.0, 75_000_000, false)); model.advance(275_000_000)
        assertEquals(-420.0, model.frame.value.offset, 0.0)
    }

    @Test fun ownerRevocationAndReparkCannotCompleteAnOldFlight() {
        val old = motion(); drag(old, 150.0); old.release(0.0, 0, false)
        old.advance(100_000_000); old.revoke()
        old.advance(Long.MAX_VALUE); assertFalse(old.claimCompletion()); assertEquals(0.0, old.frame.value.opacity, 0.0)
        assertFalse(old.beginDrag(Long.MAX_VALUE)); old.leave(1.0, Long.MAX_VALUE, false)
        assertEquals(ParkedLinePhase.REVOKED, old.frame.value.phase)
        val replacement = ParkedChatPresentation(old.owner.copy(generation = 8))
        assertEquals(ParkedLinePhase.READY, replacement.frame.value.phase)
    }

    @Test fun reducedUsesTheActualMotionRunSubstitutionWhileDisabledCompletesImmediately() {
        val back = motion(); drag(back, 100.0); back.release(0.0, 0, true)
        back.advance(100_000_000); assertEquals(50.0, back.frame.value.offset, 1e-8)
        back.advance(200_000_000); assertEquals(ParkedLinePhase.READY, back.frame.value.phase)
        val away = motion(); away.leave(1.0, 0, true); away.advance(100_000_000)
        assertEquals(210.0, away.frame.value.offset, 1e-8)
        assertEquals(.5, away.frame.value.opacity, 1e-8)
        val disabled = motion(); disabled.leave(1.0, 0, false, animations = false)
        assertEquals(ParkedLinePhase.COMPLETE, disabled.frame.value.phase); assertTrue(disabled.claimCompletion())
    }
}

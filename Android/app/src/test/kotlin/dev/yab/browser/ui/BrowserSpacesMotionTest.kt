package dev.yab.browser.ui

import org.junit.Assert.*
import org.junit.Test

class BrowserSpacesMotionTest {
    private fun capsule(current: Int = 1) = BrowserSpaceCapsuleModel(listOf(80.0, 72.0, 110.0, 84.0), current, 195.0, 230.0, 362.0, false)
    private fun settle(model: BrowserSpaceCapsuleModel) { repeat(600) { if (!model.isSettled) model.step(1.0 / 120) }; assertTrue("Capsule never settled", model.isSettled) }
    private fun settle(model: BrowserSpacesTravel) { repeat(600) { if (model.moving) model.step(1.0 / 120) }; assertFalse("Spaces never settled", model.moving) }

    @Test fun aPairKeepsItsNamesAndRecessStillWhileOnlyTheLensTravels() {
        val model = BrowserSpaceCapsuleModel(listOf(80.0, 96.0), 0, 187.5, 215.0, 351.0, true)
        val start = model.pose
        assertEquals(BrowserSpaceCapsuleModel.Event.Tap(1), model.select(1))
        model.step(1.0 / 60)
        assertEquals(start.left, model.pose.left, 1e-9)
        assertEquals(start.trackX, model.pose.trackX, 1e-9)
        assertTrue(model.pose.lensCenter > start.lensCenter)
        settle(model)
        assertEquals(1.0, model.pose.fraction, 1e-9)
        assertEquals(0.0, model.pose.side, 1e-9)
        assertEquals(3.0, model.pose.left + model.pose.width - (model.pose.lensCenter + model.pose.lensWidth / 2), 1e-9)
    }

    @Test fun verticalCancellationKeepsTheDrawnPoseAndReturnsWithoutSelectingAnotherSpace() {
        val model = capsule()
        model.down(195.0); model.move(183.0); model.step(1.0 / 60); model.move(151.0); model.step(1.0 / 60)
        val before = model.pose
        model.cancel()
        assertEquals(before, model.pose)
        assertFalse(model.isTouched)
        assertEquals(1, model.current)
        settle(model)
        assertEquals(195.0, model.pose.lensCenter, 0.02)
        assertEquals(230.0, model.pose.width, 0.02)
        assertEquals(0.0, model.pose.side, 1e-9)
    }

    @Test fun aThrowContinuesItsVelocityAndCanBeTakenAgainBeforeTheNamesRest() {
        val model = capsule()
        model.down(195.0); model.move(187.0); model.step(1.0 / 60); model.move(150.0); model.step(1.0 / 60); model.move(100.0)
        assertEquals(BrowserSpaceCapsuleModel.Event.Release(3), model.up(100.0))
        model.step(1.0 / 60)
        val moving = model.pose
        assertTrue(model.trackX.velocity < 0)
        model.down(150.0)
        assertEquals(moving, model.pose)
        model.move(162.0); model.step(1.0 / 120); model.move(220.0)
        assertNotNull(model.up(220.0))
        settle(model)
        assertTrue(model.current in 0..3)
        assertTrue(model.pose.width.isFinite() && model.pose.lensCenter.isFinite())
    }

    @Test fun oneTravelOwnsTheLiftShapeAndAReversedCloseCannotFireItsOldCompletion() {
        val plate = SpacesRect(81.0, 768.0, 228.0, 48.0)
        val travel = BrowserSpacesTravel(844.0, 56.0)
        assertEquals(plate, requireNotNull(BrowserSpacesLiftFrame.at(travel.reveal, 390.0, 844.0, plate)).rect)
        travel.open(); repeat(5) { travel.step(1.0 / 60) }
        assertTrue(travel.reveal > 0 && travel.reveal < 1)
        val close = travel.close(); repeat(3) { travel.step(1.0 / 60) }
        val before = travel.reveal
        travel.beginLower()
        assertEquals(before, travel.reveal, 0.0)
        assertFalse(travel.isClosedCompletion(close))
        travel.lowerMoved(-200.0); travel.lowerEnded(-900.0); settle(travel)
        assertEquals(1.0, travel.reveal, 0.0)
        assertNull(BrowserSpacesLiftFrame.at(travel.reveal, 390.0, 844.0, plate))
        assertFalse(travel.isClosedCompletion(close))
    }

    @Test fun shortSlowLiftCancelsButFastLiftOpensAndAStallDoesNotSkipTheTravel() {
        val short = BrowserSpacesTravel(844.0, 56.0)
        short.beginLift(); short.liftMoved(-40.0); val close = short.liftEnded(0.0); settle(short)
        assertEquals(0.0, short.reveal, 0.0); assertTrue(short.isClosedCompletion(close))
        val fast = BrowserSpacesTravel(844.0, 56.0)
        fast.beginLift(); fast.liftMoved(-40.0); fast.liftEnded(-900.0); settle(fast)
        assertEquals(1.0, fast.reveal, 0.0)
        val a = BrowserSpacesTravel(844.0, 56.0); val b = BrowserSpacesTravel(844.0, 56.0)
        a.open(); b.open(); a.step(10.0); b.step(0.05)
        assertEquals(a.reveal, b.reveal, 1e-12); assertTrue(a.reveal < 1)
    }

    @Test fun theRetainedOriginSurvivesLayoutButAnOldOrPrivateOwnerCannotReleaseItsReplacement() {
        val retained = BrowserSpacesRetainedOrigin()
        val ordinary = BrowserSpacesOwner(1, "ordinary-page", false)
        val private = BrowserSpacesOwner(2, "private-page", true)
        val first = SpacesRect(81.0, 768.0, 228.0, 48.0)
        val second = SpacesRect(110.0, 768.0, 170.0, 48.0)
        retained.retain(ordinary, first); retained.retain(ordinary, second)
        assertEquals(first, retained.plate)
        retained.retain(private, second)
        assertFalse(retained.release(ordinary)); assertEquals(second, retained.plate)
        retained.invalidate(); assertNull(retained.plate); assertFalse(retained.isCurrent(private))
    }
}

package dev.yab.browser

import dev.yab.browser.model.BrowserLookAmount
import dev.yab.browser.model.BrowserLookAmountController
import dev.yab.browser.model.BrowserLookAmountHaptic
import dev.yab.browser.model.BrowserLookAmountKind
import java.math.BigInteger
import org.junit.Assert.*
import org.junit.Test

/** Source numeric/transaction contracts, not UIKit/SeekBar raster or native input acceptance. */
class BrowserLookAmountTest {
    @Test fun trackAndNativeThumbTravelUseTheSameSevenPointInset() {
        assertEquals(48.0, BrowserLookAmount.HEIGHT, 0.0)
        assertEquals(14.0, BrowserLookAmount.PILL_WIDTH, 0.0)
        assertEquals(4.0, BrowserLookAmount.PILL_SHADOW_PAD, 0.0)
        for (width in listOf(44.0, 160.0, 320.0)) for (amount in listOf(0.0, .25, .5, 1.0)) {
            val track = requireNotNull(BrowserLookAmount.track(width, 48.0, amount, false))
            assertEquals(7.0, track.left, 0.0)
            assertEquals(width - 14, track.width, 0.0)
            assertEquals(24.0, track.middle, 0.0)
            assertEquals(34.0, track.pillHeight, 0.0)
            val shadowImageWidth = 14.0 + 4.0 * 2
            val nativeOffset = shadowImageWidth / 2
            //AbsSeekBar setThumbPos: available - imageWidth +2*offset; canvas left=padding-offset.
            val available = width - 7 * 2 - shadowImageWidth + nativeOffset * 2
            val nativeCenter = 7 - nativeOffset + amount * available + shadowImageWidth / 2
            assertEquals(nativeCenter, track.pillX, 0.0)
            assertEquals(7 + amount * (width - 14), track.pillX, 0.0)
        }
        assertEquals(38.0, requireNotNull(BrowserLookAmount.track(320.0, 48.0, .5, true)).pillHeight, 0.0)
        assertNull(BrowserLookAmount.track(Double.NaN, 48.0, .5, false))
        assertNull(BrowserLookAmount.track(13.0, 48.0, .5, false))
        assertNull(BrowserLookAmount.track(320.0, 0.0, .5, false))
    }

    @Test fun bubbleUsesSourceClampOrderAboveTheControlAndPercentRounding() {
        assertEquals(BrowserLookAmount.Bubble(0.0, -18.0, 80.0, 20.0), BrowserLookAmount.bubble(320.0, 0.0, 80.0, 20.0))
        assertEquals(BrowserLookAmount.Bubble(120.0, -18.0, 80.0, 20.0), BrowserLookAmount.bubble(320.0, .5, 80.0, 20.0))
        assertEquals(BrowserLookAmount.Bubble(240.0, -18.0, 80.0, 20.0), BrowserLookAmount.bubble(320.0, 1.0, 80.0, 20.0))
        //The source min(max(0,x-w/2),bounds-w) keeps this negative result for a narrow control.
        assertEquals(-36.0, requireNotNull(BrowserLookAmount.bubble(44.0, .5, 80.0, 20.0)).x, 0.0)
        assertNull(BrowserLookAmount.bubble(0.0, .5, 80.0, 20.0))
        assertEquals("No grain", BrowserLookAmount.bubbleText(BrowserLookAmountKind.GRAIN, 0.0))
        assertEquals("Grain 1%", BrowserLookAmount.bubbleText(BrowserLookAmountKind.GRAIN, .005))
        assertEquals("Drawings 35%", BrowserLookAmount.bubbleText(BrowserLookAmountKind.DRAWINGS, .345))
        assertEquals(140L, BrowserLookAmount.BUBBLE_FADE_MILLIS)
    }

    @Test fun grainScatterUsesUnsigned64WrappingAndCrossesIncludeBothEndpoints() {
        val mask = BigInteger.ONE.shiftLeft(64) - BigInteger.ONE
        var seed = BigInteger("9E3779B97F4A7C15", 16)
        fun next(): Double {
            seed = seed.multiply(BigInteger("6364136223846793005"))
                .add(BigInteger("1442695040888963407")).and(mask)
            return seed.shiftRight(33).toDouble() / 2147483648.0
        }
        val reference = buildList {
            while (size < 170) {
                val x = next()
                if (next() < .12 + x * .88) add(BrowserLookAmount.Grain(x, next() * 2 - 1, .8 + next() * .6))
            }
        }
        val actual = BrowserLookAmount.grains()
        assertEquals(reference, actual)
        assertEquals(170, actual.size)
        assertEquals(actual, BrowserLookAmount.grains())
        assertNotSame(actual, BrowserLookAmount.grains())
        assertTrue(actual.all { it.x >= 0 && it.x < 1 && it.y >= -1 && it.y < 1 && it.radius >= .8 && it.radius < 1.4 })
        assertEquals(21, BrowserLookAmount.crosses().size)
        for ((index, position) in BrowserLookAmount.crosses().withIndex()) assertEquals(index * .05, position, 1e-15)
        assertEquals(0.0, BrowserLookAmount.crosses().first(), 0.0)
        assertEquals(1.0, BrowserLookAmount.crosses().last(), 0.0)
    }

    @Test fun grainRoundsByFivePercentWhileDrawingsKeepContinuousInput() {
        assertEquals(.0, BrowserLookAmount.changedValue(BrowserLookAmountKind.GRAIN, .024), 0.0)
        assertEquals(.05, BrowserLookAmount.changedValue(BrowserLookAmountKind.GRAIN, .025), 0.0)
        assertEquals(.1, BrowserLookAmount.changedValue(BrowserLookAmountKind.GRAIN, .075), 0.0)
        assertEquals(1.0, BrowserLookAmount.changedValue(BrowserLookAmountKind.GRAIN, 1.3), 0.0)
        assertEquals(0.0, BrowserLookAmount.changedValue(BrowserLookAmountKind.DRAWINGS, -.1), 0.0)
        assertEquals(.317, BrowserLookAmount.changedValue(BrowserLookAmountKind.DRAWINGS, .317), 0.0)
        val projected = BrowserLookAmountController(BrowserLookAmountKind.GRAIN, .317)
        assertEquals(.317, projected.shown, 0.0) //Remote/source projection is not rounded until a local change.
        assertTrue(projected.begin(true, touching = true))
        assertEquals(.3, requireNotNull(projected.change(.317, true)).value, 0.0)
    }

    @Test fun sourceInclusiveCrossingAndEndpointHapticsRemainDistinct() {
        assertTrue(BrowserLookAmount.crossed(.1, .11)) //The source includes the starting boundary.
        assertTrue(BrowserLookAmount.crossed(.11, .1))
        assertFalse(BrowserLookAmount.crossed(.11, .19))
        assertTrue(BrowserLookAmount.crossed(.19, .201))
        assertFalse(BrowserLookAmount.crossed(Double.NaN, .2))
        assertFalse(BrowserLookAmount.crossed(.1, .2, 0.0))
        val control = BrowserLookAmountController(BrowserLookAmountKind.DRAWINGS, .11)
        assertTrue(control.begin(true, touching = true))
        assertEquals(BrowserLookAmountHaptic.NONE, requireNotNull(control.change(.19, true)).haptic)
        assertEquals(BrowserLookAmountHaptic.STEP, requireNotNull(control.change(.201, true)).haptic)
        assertEquals(BrowserLookAmountHaptic.END, requireNotNull(control.change(1.0, true)).haptic)
        assertEquals(BrowserLookAmountHaptic.NONE, requireNotNull(control.change(1.0, true)).haptic)
        assertEquals(BrowserLookAmountHaptic.END, requireNotNull(control.change(0.0, true)).haptic)
    }

    @Test fun heldInputIgnoresRemoteProjectionUntilTheOriginalTransactionEnds() {
        val control = BrowserLookAmountController(BrowserLookAmountKind.DRAWINGS, .2)
        assertTrue(control.begin(true, touching = true))
        assertTrue(control.held)
        assertEquals(.4, requireNotNull(control.change(.4, true)).value, 0.0)
        control.project(.9)
        assertEquals(.4, control.shown, 0.0)
        assertFalse(control.begin(true, touching = true))
        assertTrue(control.finish(true))
        assertFalse(control.held)
        control.project(.9)
        assertEquals(.9, control.shown, 0.0)
    }

    @Test fun releaseOrCurrentOwnerCancelEndsOnceWithoutRollingBack() {
        for (ending in listOf("UP", "CANCEL")) {
            val control = BrowserLookAmountController(BrowserLookAmountKind.GRAIN, .35)
            var commits = 0
            assertTrue(control.begin(true, touching = true))
            control.change(.62, true)
            if (control.finish(true)) commits++ //Native UP/CANCEL both enter this one end path.
            if (control.finish(true)) commits++ //Native onStop and the finally path may both arrive.
            assertEquals(ending, 1, commits)
            assertEquals(.6, control.shown, 0.0)
            assertFalse(control.active)
        }
    }

    @Test fun aRefusedOriginalOwnerNeverBorrowsFreshAuthorityOrChangesItsRetainedValue() {
        val control = BrowserLookAmountController(BrowserLookAmountKind.DRAWINGS, .2)
        assertTrue(control.begin(true, touching = true))
        control.change(.3, true)
        assertNull(control.change(.8, false))
        assertTrue(control.revoked)
        assertFalse(control.active)
        control.project(.9)
        assertFalse(control.accept(true))
        assertFalse(control.begin(true, touching = false))
        assertNull(control.change(.7, true))
        assertFalse(control.finish(true))
        assertEquals(.3, control.shown, 0.0)
        val observedWhileIdle = BrowserLookAmountController(BrowserLookAmountKind.GRAIN, .35)
        assertFalse(observedWhileIdle.accept(false))
        assertFalse(observedWhileIdle.begin(true, touching = true))
        //A separately keyed fresh native view has its own immutable callbacks and controller.
        assertTrue(BrowserLookAmountController(BrowserLookAmountKind.GRAIN, .35).begin(true, touching = true))
    }

    @Test fun discreteAccessibilityOrKeyChangeIsOneNonHeldTransactionAndRejectsNonfiniteInput() {
        val control = BrowserLookAmountController(BrowserLookAmountKind.GRAIN, .35)
        assertNull(control.change(.8, true))
        assertTrue(control.begin(true, touching = false))
        assertFalse(control.held)
        assertNull(control.change(Double.NaN, true))
        assertNull(control.change(Double.POSITIVE_INFINITY, true))
        assertEquals(.35, control.shown, 0.0)
        assertEquals(.4, requireNotNull(control.change(.4, true)).value, 0.0)
        assertTrue(control.finish(true))
        assertFalse(control.finish(true))
        assertFalse(control.active)
    }
}

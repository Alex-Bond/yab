package dev.yab.browser.ui

import dev.yab.browser.model.SpaceLookColor
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI

class BrowserLookEditorMotionTest {
    private fun handle(index: Int, x: Double, y: Double = .5) = LookHandleTarget(index, x, y, 0xFF112233)
    private fun BrowserLookEditorMotion.at(index: Int) = frame.value.handles.single { it.index == index }
    private fun BrowserLookEditorMotion.frames(from: Long, count: Int) {
        repeat(count) { onFrame(from + it * 16_000_000L) }
    }

    @Test fun aRetargetPreservesTheActualSampledPositionAndVelocity() {
        val spring = LookEditorSpring(0.0)
        spring.target(1000.0, .27, .65, true); spring.advance(.04)
        val value = spring.value; val velocity = spring.velocity
        assertTrue(value in 0.0..1000.0); assertTrue(velocity > 0)
        spring.target(0.0, .27, .65, true)
        assertEquals(value, spring.value, 0.0); assertEquals(velocity, spring.velocity, 0.0)
        spring.advance(1.0)
        assertEquals(0.0, spring.value, 0.0); assertEquals(0.0, spring.velocity, 0.0)
    }

    @Test fun addAndRemoveKeepSurvivingHandlesWhileLastLinkedHandleDisappearsImmediately() {
        val model = BrowserLookEditorMotion(listOf(handle(-1, .4), handle(0, .1)), 0, null)
        model.handles(listOf(handle(-1, .4), handle(0, .8), handle(1, .6)), LookEditorFlight.LINKS)
        assertEquals(.1, model.at(0).x, 0.0); assertEquals(.6, model.at(1).x, 0.0)
        model.frames(1, 4)
        val before = model.at(0).x
        assertTrue(before > .1 && before < .8)
        model.handles(listOf(handle(-1, .4), handle(0, .3)), LookEditorFlight.LINKS)
        assertFalse(model.frame.value.handles.any { it.index == 1 })
        assertEquals(before, model.at(0).x, 0.0)
        model.frames(64_000_001, 100)
        assertEquals(.3, model.at(0).x, 0.0); assertFalse(model.frame.value.running)
    }

    @Test fun presetAcrossTheHueSeamMovesCartesianHandlesWithoutTakingALongHueArc() {
        val a = SpaceLookColor(.65, 1.0, 2 * PI - .03)
        val b = SpaceLookColor(.65, 1.0, .03)
        val model = BrowserLookEditorMotion(listOf(handle(-1, a.pointX, a.pointY)), 0, null)
        model.handles(listOf(handle(-1, b.pointX, b.pointY)), LookEditorFlight.PRESET)
        model.frames(1, 8)
        assertTrue(model.at(-1).x > .9)
        assertTrue(model.at(-1).y > a.pointY)
        model.frames(128_000_001, 100)
        assertEquals(b.pointX, model.at(-1).x, 0.0); assertEquals(b.pointY, model.at(-1).y, 0.0)
    }

    @Test fun selectionAndPageInterruptionsKeepTheirCurrentDrawnPositions() {
        val model = BrowserLookEditorMotion(listOf(handle(-1, .5)), 0, 0 to 0)
        val start = model.frame.value.ring!!
        model.selected(0 to 8)
        assertEquals(start, model.frame.value.ring!!, 0.0)
        model.frames(1, 5)
        val before = model.frame.value.ring!!
        assertTrue(before > start)
        model.selected(0 to 3)
        assertEquals(before, model.frame.value.ring!!, 0.0)
        model.page(1); model.frames(80_000_001, 5)
        val page = model.frame.value.page
        assertTrue(page > 0 && page < 1)
        model.page(0)
        assertEquals(page, model.frame.value.page, 0.0)
        model.frames(160_000_001, 100)
        assertEquals(0.0, model.frame.value.page, 0.0)
        assertEquals((3.5 / 9), model.frame.value.ring!!, .000001)
        assertEquals(1.0, model.frame.value.chosen.getValue(3), 0.0)
        assertFalse(model.frame.value.chosen.containsKey(8)); assertFalse(model.frame.value.running)
    }

    @Test fun physicalDragSnapsAndRebasesWithoutALatePresetFrameOrRevokedPublication() {
        val model = BrowserLookEditorMotion(listOf(handle(-1, .1)), 0, null)
        model.handles(listOf(handle(-1, .9)), LookEditorFlight.PRESET); model.frames(1, 4)
        assertTrue(model.rebase())
        model.handles(listOf(handle(-1, .25)), LookEditorFlight.DIRECT)
        model.frames(64_000_001, 10)
        assertEquals(.25, model.at(-1).x, 0.0); assertFalse(model.frame.value.running)
        model.revoke()
        assertFalse(model.handles(listOf(handle(-1, .8)), LookEditorFlight.PRESET)); assertFalse(model.rebase())
        model.page(3); model.selected(3 to 1); model.frames(1_000_000_001, 10)
        assertEquals(.25, model.at(-1).x, 0.0); assertEquals(0.0, model.frame.value.page, 0.0)
    }

    @Test fun reducedOrDisabledAnimationsSettleEveryExplicitTrackWithoutReplayingOnReturn() {
        val model = BrowserLookEditorMotion(listOf(handle(-1, .1)), 0, 0 to 0)
        model.handles(listOf(handle(-1, .9)), LookEditorFlight.PRESET); model.page(2); model.selected(2 to 4)
        model.frames(1, 3); model.configure(false)
        assertEquals(.9, model.at(-1).x, 0.0); assertEquals(2.0, model.frame.value.page, 0.0)
        assertFalse(model.frame.value.running)
        model.configure(true); model.onFrame(50_000_000_000)
        assertEquals(.9, model.at(-1).x, 0.0); assertFalse(model.frame.value.running)
    }

    @Test fun pressAndReleaseUseDifferentSourceResponsesAndReverseWithoutAJump() {
        val press = BrowserLookEditorPress()
        press.target(true, true); press.onFrame(1); press.onFrame(40_000_001)
        val before = press.frame.value.amount
        assertTrue(before > 0 && before < 1)
        press.target(false, true)
        assertEquals(before, press.frame.value.amount, 0.0)
        press.target(true, false)
        assertEquals(1.0, press.frame.value.amount, 0.0); assertFalse(press.frame.value.running)
        press.target(false, true); press.onFrame(2_000_000_001); press.onFrame(2_040_000_001)
        assertTrue(press.frame.value.amount > 1 - before)
        press.onFrame(4_000_000_001)
        assertEquals(0.0, press.frame.value.amount, 0.0); assertFalse(press.frame.value.running)
    }
}

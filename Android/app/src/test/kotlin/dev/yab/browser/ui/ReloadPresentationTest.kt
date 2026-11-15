package dev.yab.browser.ui

import org.junit.Assert.*
import org.junit.Test

class ReloadPresentationTest {
    @Test fun quickLoadsNeverFlashStopAndAReplacementDelayCannotPublishTheOldLoad() {
        val model = ReloadPresentation()
        fun change(ms: Long, loading: Boolean) = model.update(ms * 1_000_000, loading, false, false, true)
        change(0, true)
        assertEquals(0f, model.advance(449_000_000).stop, 0f)
        change(464, false) // The replacement is applied on the next frame after 449 ms.
        assertEquals(0f, model.advance(900_000_000).stop, 0f)
        change(1000, true)
        assertEquals(0f, model.advance(1_449_000_000).stop, 0f)
        assertEquals(0f, model.advance(1_450_000_000).stop, 0f)
        val half = model.advance(1_500_000_000).stop
        assertEquals(.5f, half, .00001f)
        // An interrupted exit starts from the actually drawn value.
        assertEquals(half, change(1500, false).stop, 0f)
        assertEquals(0f, model.advance(1_600_000_000).stop, 0f)
        assertFalse(model.moving)
        change(2000, true)
        assertEquals(1f, model.advance(2_550_000_000).stop, 0f)

        val interrupted = ReloadPresentation()
        interrupted.update(0, true, false, false, true)
        interrupted.advance(550_000_000)
        interrupted.update(600_000_000, false, false, false, true)
        assertTrue(interrupted.advance(650_000_000).stop > 0f)
        interrupted.update(650_000_000, true, false, false, true)
        // Even if no frame was requested during the delay, the former exit
        // must finish before the new crossfade starts from zero.
        assertEquals(0f, interrupted.advance(1_100_000_000).stop, 0f)
        assertEquals(.5f, interrupted.advance(1_150_000_000).stop, .00001f)
    }

    @Test fun pressReversesFromItsCurrentPoseAndLoadingOrReducedMotionDimsInsteadOfTurning() {
        val model = ReloadPresentation()
        fun change(ms: Long, loading: Boolean = false, pressed: Boolean = false, reduced: Boolean = false, animations: Boolean = true) =
            model.update(ms * 1_000_000, loading, pressed, reduced, animations)
        change(0)
        change(10, pressed = true)
        val held = model.advance(60_000_000)
        assertTrue(held.rotation > 45f && held.rotation < 90f)
        assertEquals(held, change(60))
        assertEquals(0f, model.advance(200_000_000).rotation, 0f)
        change(250, pressed = true, reduced = true)
        val quiet = model.advance(350_000_000)
        assertEquals(0f, quiet.rotation, 0f); assertEquals(.6f, quiet.opacity, 0f)
        change(400, loading = true, pressed = true)
        assertEquals(0f, model.pose.rotation, 0f); assertEquals(.6f, model.pose.opacity, 0f)
        assertEquals(0f, model.pose.stop, 0f)
        change(410, loading = true, pressed = true, animations = false)
        assertEquals(1f, model.pose.stop, 0f)
        assertEquals(.6f, model.pose.opacity, 0f)
        assertFalse(model.moving)
    }
}

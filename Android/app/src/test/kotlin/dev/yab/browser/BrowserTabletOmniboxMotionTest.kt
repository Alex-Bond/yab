package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import org.junit.Assert.*
import org.junit.Test

class BrowserTabletOmniboxMotionTest {
    private val viewport = TabletOmniboxViewport(BrowserWorkspaceWindow(1280.0, 1000.0),
        TabletOmniboxRoot(0.0, 0.0, 1280.0, 1000.0), 24.0, 0.0)
    private fun target(ime: Double = 0.0, resting: Boolean = false, view: TabletOmniboxViewport = viewport,
        rows: Int = 5, answer: Boolean = false, scale: Double = 1.0) =
        TabletOmniboxMotionTarget(view, ime, resting, rows, answer, false, scale)

    @Test fun terminalKeyboardUsesSourceCurveAndExactTargetAt300Milliseconds() {
        val start = target(); val end = target(700.0)
        val motion = BrowserTabletOmniboxMotion(start)
        motion.target(end, 0, reduced = false, animations = true)
        assertEquals(start.frame, motion.advance(0))
        val half = motion.advance(150_000_000)
        val fraction = (half.y - start.frame.y) / (end.frame.y - start.frame.y)
        assertTrue(fraction > .94 && fraction < .95) // Distinguishes the source cubic from linear timing.
        assertTrue(half.bodyHeight < start.frame.bodyHeight && half.bodyHeight > end.frame.bodyHeight)
        assertEquals(end.frame, motion.advance(300_000_000))
        assertFalse(motion.running)
    }

    @Test fun currentPlatformImeSamplesDoNotRestartTheTerminalTransaction() {
        val end = target(700.0)
        val control = BrowserTabletOmniboxMotion(target())
        val sampled = BrowserTabletOmniboxMotion(target())
        control.target(end, 0, false, true); sampled.target(end, 0, false, true)
        for (step in 1..6) {
            val now = step * 50_000_000L
            sampled.target(target(700.0, view = viewport.copy(imeBottom = step * 100.0)), now, false, true)
            assertEquals(control.advance(now), sampled.value)
        }
        assertEquals(end.frame, sampled.value)
        assertFalse(sampled.running)
        // The host can publish resting after terminal0; identical destination
        // geometry must not start the already-running visual trip a second time.
        val hiding = BrowserTabletOmniboxMotion(end)
        val hiddenControl = BrowserTabletOmniboxMotion(end)
        hiding.target(target(), 0, false, true); hiddenControl.target(target(), 0, false, true)
        hiding.target(target(resting = true), 80_000_000, false, true)
        assertEquals(hiddenControl.advance(300_000_000), hiding.advance(300_000_000))
        assertFalse(hiding.running)
    }

    @Test fun reversingKeyboardAndRestingStartsFromTheCurrentVisualPose() {
        val motion = BrowserTabletOmniboxMotion(target())
        motion.target(target(700.0), 0, false, true)
        val interrupted = motion.advance(80_000_000)
        val resting = target(700.0, resting = true)
        motion.target(resting, 80_000_000, false, true)
        assertEquals(interrupted, motion.value)
        val returning = motion.advance(160_000_000)
        assertTrue(returning.y > interrupted.y && returning.y < resting.frame.y)
        motion.target(target(700.0), 160_000_000, false, true)
        assertEquals(returning, motion.value)
        assertEquals(target(700.0).frame, motion.advance(460_000_000))
    }

    @Test fun reducedPolicyRebasesCurrentPoseAndUses200MillisecondNumericTransition() {
        val start = target(); val end = target(700.0)
        val reduced = BrowserTabletOmniboxMotion(start)
        reduced.target(end, 0, true, true)
        val half = reduced.advance(100_000_000)
        assertEquals((start.frame.y + end.frame.y) / 2, half.y, 1e-7)
        assertEquals(end.frame, reduced.advance(200_000_000))
        val changed = BrowserTabletOmniboxMotion(start)
        changed.target(end, 0, false, true)
        val current = changed.advance(80_000_000)
        changed.target(end, 80_000_000, true, true)
        assertEquals(current, changed.value)
        assertEquals(end.frame, changed.advance(280_000_000))
    }

    @Test fun disabledAnimationsSnapAndClockGoingBackwardCannotRewindAVisualSample() {
        val motion = BrowserTabletOmniboxMotion(target())
        motion.target(target(700.0), 0, false, true)
        val current = motion.advance(80_000_000)
        assertEquals(current, motion.advance(40_000_000))
        motion.target(target(700.0), 80_000_000, false, false)
        assertEquals(target(700.0).frame, motion.value)
        assertFalse(motion.running)
        motion.target(target(0.0), 90_000_000, true, false)
        assertEquals(target().frame, motion.value)
    }

    @Test fun realRootResizeOriginAndConfigurationSnapInsteadOfReplayingOsMovement() {
        val motion = BrowserTabletOmniboxMotion(target())
        motion.target(target(700.0), 0, false, true)
        motion.advance(80_000_000)
        val resized = target(700.0, view = viewport.copy(root = viewport.root.copy(height = 300.0)))
        motion.target(resized, 80_000_000, false, true)
        assertEquals(resized.frame, motion.value); assertFalse(motion.running)
        val moved = target(300.0, view = viewport.copy(root = TabletOmniboxRoot(12.0, 40.0, 900.0, 700.0)))
        motion.target(moved, 100_000_000, false, true)
        assertEquals(moved.frame, motion.value); assertFalse(motion.running)
        val rotated = target(200.0, view = viewport.copy(window = BrowserWorkspaceWindow(1000.0, 1280.0)))
        motion.target(rotated, 120_000_000, false, true)
        assertEquals(rotated.frame, motion.value); assertFalse(motion.running)
    }

    @Test fun currentImeAndRootClampEveryRenderedSampleWithoutFeedingBackIntoTheTrack() {
        val motion = BrowserTabletOmniboxMotion(target())
        motion.target(target(700.0), 0, false, true)
        val pose = motion.advance(80_000_000)
        val actual = viewport.copy(root = TabletOmniboxRoot(0.0, 40.0, 1280.0, 300.0), imeBottom = 700.0)
        assertEquals(260.0, BrowserTabletOmniboxMotion.visibleBottom(actual), 0.0)
        val clipped = BrowserTabletOmniboxMotion.clipped(pose, actual)
        assertTrue(clipped.bodyHeight >= 0 && clipped.bodyHeight <= pose.bodyHeight)
        assertTrue(clipped.bodyHeight <= (260.0 - pose.y - pose.headerHeight - 16).coerceAtLeast(0.0))
        assertEquals(pose, motion.value)
        // Already resized root: the same keyboard is intersected once, never subtracted twice.
        assertEquals(300.0, BrowserTabletOmniboxMotion.visibleBottom(viewport.copy(
            root = viewport.root.copy(height = 300.0), imeBottom = 700.0)), 0.0)
        assertEquals(0.0, BrowserTabletOmniboxMotion.visibleBottom(viewport.copy(imeBottom = 1200.0)), 0.0)
    }

    @Test fun rowAnswerAndFontLayoutChangesSnapWithoutInventingTypedRowTiming() {
        val motion = BrowserTabletOmniboxMotion(target())
        motion.target(target(700.0), 0, false, true)
        motion.advance(80_000_000)
        for (next in listOf(target(700.0, rows = 1), target(700.0, rows = 1, answer = true),
            target(700.0, rows = 1, answer = true, scale = 1.3))) {
            motion.target(next, 100_000_000, false, true)
            assertEquals(next.frame, motion.value); assertFalse(motion.running)
        }
    }
}

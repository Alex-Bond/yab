package dev.yab.browser.ui

import dev.yab.browser.model.*
import kotlin.math.abs
import kotlin.math.min

/** Drawing inputs only. Current animated IME samples are deliberately absent from layout. */
internal data class TabletOmniboxMotionLayout(val window: BrowserWorkspaceWindow,
    val root: TabletOmniboxRoot, val statusTop: Double, val rows: Int, val answer: Boolean,
    val showsAddress: Boolean, val textScale: Double)

internal data class TabletOmniboxMotionTarget(val viewport: TabletOmniboxViewport,
    val terminalIme: Double, val resting: Boolean, val rows: Int, val answer: Boolean,
    val showsAddress: Boolean, val textScale: Double) {
    init { require(terminalIme.isFinite() && terminalIme >= 0) }
    val layout get() = TabletOmniboxMotionLayout(viewport.window, viewport.root, viewport.statusTop,
        rows, answer, showsAddress, textScale)
    val frame get() = BrowserTabletOmniboxGeometry.frame(viewport.copy(imeBottom = terminalIme),
        resting, rows, answer, showsAddress, textScale)
}

/** Phone keyboardFollow's visual top/body transaction. Never owns input or an IME. */
internal class BrowserTabletOmniboxMotion(initial: TabletOmniboxMotionTarget) {
    var value = initial.frame; private set
    private var from = value
    private var target = initial.frame
    private var layout = initial.layout
    private var clock = 0L
    private var start = 0L
    private var reduced = false
    var running = false; private set

    fun target(next: TabletOmniboxMotionTarget, now: Long, reduced: Boolean, animations: Boolean) {
        advance(now)
        val nextFrame = next.frame
        val layoutChanged = layout != next.layout
        if (!layoutChanged && nextFrame == target &&
            reduced == this.reduced && animations) return
        layout = next.layout
        from = value; target = nextFrame; start = clock; this.reduced = reduced
        // Actual root/configuration, row layout and font changes already have their own
        // physical placement. Never replay them as another keyboard animation.
        running = !layoutChanged && animations &&
            (abs(from.y - target.y) > 1e-9 || abs(from.bodyHeight - target.bodyHeight) > 1e-9)
        if (!running) value = target
    }

    fun advance(now: Long): TabletOmniboxFrame {
        clock = maxOf(clock, now)
        if (!running) return value
        val duration = if (reduced) 200_000_000.0 else 300_000_000.0
        val q = ((clock - start) / duration).coerceIn(0.0, 1.0)
        // Motion.run uses its named easeInOut(.2) policy for Reduce Motion;
        // keyboardFollow has no opacity property or FieldMotion.morph fade branch.
        val t = if (reduced) curve(q, .42, 0.0, .58, 1.0) else curve(q, .2, .8, .2, 1.0)
        value = target.copy(y = from.y + (target.y - from.y) * t,
            bodyHeight = from.bodyHeight + (target.bodyHeight - from.bodyHeight) * t)
        if (q == 1.0) { value = target; running = false }
        return value
    }

    companion object {
        /** Current actual viewport, not terminal IME, limits every rendered sample. */
        fun visibleBottom(viewport: TabletOmniboxViewport): Double {
            require(viewport.valid)
            return (min(viewport.root.bottom, viewport.window.height - viewport.imeBottom) - viewport.root.y)
                .coerceIn(0.0, viewport.root.height)
        }

        fun clipped(frame: TabletOmniboxFrame, viewport: TabletOmniboxViewport): TabletOmniboxFrame =
            frame.copy(bodyHeight = min(frame.bodyHeight,
                (visibleBottom(viewport) - frame.y - frame.headerHeight - 16.0).coerceAtLeast(0.0)))

        private fun curve(x: Double, x1: Double, y1: Double, x2: Double, y2: Double): Double {
            if (x <= 0 || x >= 1) return x.coerceIn(0.0, 1.0)
            fun at(a: Double, b: Double, t: Double): Double {
                val u = 1 - t
                return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
            }
            var low = 0.0; var high = 1.0
            repeat(40) { val t = (low + high) / 2; if (at(x1, x2, t) < x) low = t else high = t }
            return at(y1, y2, (low + high) / 2)
        }
    }
}

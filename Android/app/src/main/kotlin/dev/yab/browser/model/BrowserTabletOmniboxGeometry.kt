package dev.yab.browser.model

import kotlin.math.floor
import kotlin.math.min

/** Window-local logical points. The actual root viewport may already be IME-resized. */
internal data class TabletOmniboxRoot(val x: Double, val y: Double, val width: Double, val height: Double) {
    val valid get() = listOf(x, y, width, height).all(Double::isFinite) && width > 0 && height > 0
    val bottom get() = y + height
}
internal data class TabletOmniboxFrame(val x: Double, val y: Double, val width: Double,
    val bodyHeight: Double, val rowHeight: Double) {
    val headerHeight get() = 52.0
    val height get() = headerHeight + bodyHeight
}
internal data class TabletOmniboxViewport(val window: BrowserWorkspaceWindow, val root: TabletOmniboxRoot,
    val statusTop: Double, val imeBottom: Double) {
    val valid get() = window.valid && root.valid && statusTop.isFinite() && statusTop >= 0 && imeBottom.isFinite() && imeBottom >= 0
}

internal object BrowserTabletOmniboxGeometry {
    fun eligible(window: BrowserWorkspaceWindow, smallestScreenWidthDp: Int): Boolean =
        smallestScreenWidthDp >= 600 && window.valid && min(window.width, window.height) >= 700.0

    /** Swift rounded()'s half-away rule; the outer max also handles very short available space. */
    fun top(available: Double): Double {
        require(available.isFinite())
        return maxOf(16.0, min(floor((available - 58.0 - 417.0) / 2.0 + .5), floor(available * .18 + .5)))
    }

    fun keyboardOverlap(viewport: TabletOmniboxViewport): Double {
        require(viewport.valid)
        if (viewport.imeBottom == 0.0) return 0.0
        return (viewport.root.bottom - (viewport.window.height - viewport.imeBottom)).coerceIn(0.0, viewport.root.height)
    }

    fun frame(viewport: TabletOmniboxViewport, resting: Boolean, rows: Int, answer: Boolean,
        showsAddress: Boolean, textScale: Double): TabletOmniboxFrame {
        require(viewport.valid && rows >= 0 && textScale.isFinite() && textScale > 0)
        val workspaceTop = viewport.statusTop + 56.0
        // min prevents subtracting the keyboard twice when adjustResize has already
        // shortened the actual root. No drawing or hit region extends below that root.
        val bottom = min(viewport.root.bottom, viewport.window.height - if (resting) 0.0 else viewport.imeBottom)
        val available = (bottom - workspaceTop).coerceAtLeast(0.0)
        val top = top(available)
        val rowHeight = 40.0 * textScale
        val count = if (showsAddress) 0 else min(rows, if (answer) 4 else 5)
        val answerHeight = if (answer && !showsAddress) rowHeight else 0.0
        val wanted = if (count == 0 && answerHeight == 0.0) 0.0 else count * rowHeight + 12.0 + answerHeight
        val body = min(wanted, (available - top - 52.0 - 16.0).coerceAtLeast(0.0))
        val width = min(540.0, viewport.window.width - 32.0).coerceAtLeast(0.0)
        return TabletOmniboxFrame((viewport.window.width - width) / 2.0 - viewport.root.x,
            workspaceTop + top - viewport.root.y, width, body, rowHeight)
    }
}

/** Specific rendered Field placement. Drawing geometry never grants PAGE/toolbar authority.
 * The sole editor may move, but an old callback keeps this original source forever. */
internal class BrowserFieldPlacementLease private constructor(private val controller: BrowserController,
    val tablet: Boolean, val controls: Any, val input: FieldInputLease?, private val windowGeneration: Long,
    private val windowRegistered: Boolean, private val foreground: Long, private val boundary: Long,
    private val sourceGeneration: Long, private val wasActive: Boolean, private val originalCurrent: (() -> Boolean)?) {
    private var retired = false
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (originalCurrent != null && !runCatching(originalCurrent).getOrDefault(false)) {
            retired = true
            return false
        }
        return wasActive && input?.let(controller::fieldInputCurrent) == true &&
        controller.historyPresentationLifetime.value == sourceGeneration &&
        controller.settingsPresentationLifetime.value.let { it.active && it.generation == foreground && it.privateBoundary == boundary } &&
        controller.workspaceWindow.value.let { it.registered == windowRegistered && it.generation == windowGeneration &&
            (!windowRegistered || it.geometry?.valid == true) }
    }

    companion object {
        fun capture(controller: BrowserController, tablet: Boolean, controls: Any = Any(),
            originalCurrent: (() -> Boolean)? = null): BrowserFieldPlacementLease {
            val lifetime = controller.settingsPresentationLifetime.value
            val window = controller.workspaceWindow.value
            return BrowserFieldPlacementLease(controller, tablet, controls,
                if (lifetime.active) controller.captureFieldInput() else null, window.generation,
                window.registered, lifetime.generation, lifetime.privateBoundary,
                controller.historyPresentationLifetime.value, lifetime.active, originalCurrent)
        }
    }
}

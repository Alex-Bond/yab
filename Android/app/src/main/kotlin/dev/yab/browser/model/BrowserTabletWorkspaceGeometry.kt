package dev.yab.browser.model

/** Root-local logical points. A drawing rectangle never grants a window or page authority. */
internal data class TabletWorkspaceRect(val x: Double, val y: Double, val width: Double, val height: Double)

/** Original full-window permission and inset page drawing are deliberately separate.
 * `paired` remembers the caller's pair even when the page is too narrow or tall to draw it. */
internal data class BrowserTabletWorkspaceFrame(
    val originalWindow: BrowserWorkspaceWindow,
    val top: Double,
    val sidebar: TabletWorkspaceRect?,
    val rim: Double,
    val toolbar: TabletWorkspaceRect,
    val page: TabletWorkspaceRect,
    val paired: Boolean,
    val splitFraction: Double = .5,
) {
    // Fixed top and minimum bottom; actual bottom corners also use the current window.
    val pageCornerRadius: Double get() = if (rim > 0) 10.0 else 0.0
    val pageStrokeWidth: Double get() = if (rim > 0) 1.0 else 0.0
    val fullWindowCanSplit: Boolean get() = originalWindow.canSplit
    val drawnSplit: Boolean get() = pageLayout.split

    val fullWindowLayout: BrowserWorkspaceLayout get() = BrowserWorkspaceLayout(
        originalWindow.width.toInt(), originalWindow.height.toInt(), paired, originalWindow)

    // The actual root decides landscape; a short inset page must not turn a landscape
    // pair into portrait. Its own width still reserves both 320-point documents.
    val pageLayout: BrowserWorkspaceLayout get() = BrowserWorkspaceLayout(
        page.width.toInt(), page.height.toInt(), paired && page.width >= 648.0, originalWindow)

    val effectiveSplitFraction: Double get() {
        val minimum = minOf(.5, 320.0 / maxOf(1.0, page.width - 8.0))
        return (if (splitFraction.isFinite()) splitFraction else .5).coerceIn(minimum, 1.0 - minimum)
    }
    /** The same root-local rectangles draw Compose and place its retained native documents. */
    fun pane(second: Boolean): TabletWorkspaceRect {
        if (!pageLayout.split) return page
        val first = (page.width - 8.0) * effectiveSplitFraction
        return TabletWorkspaceRect(page.x + if (second) first + 8.0 else 0.0,
            page.y, if (second) page.width - first - 8.0 else first, page.height)
    }
    val divider: TabletWorkspaceRect? get() = if (!pageLayout.split) null else
        TabletWorkspaceRect(page.x + (page.width - 8.0) * effectiveSplitFraction, page.y, 8.0, page.height)

}

/** Phone TabletWorkspaceGeometry's reserved top, persistent sidebar and optional page frame.
 * Frame projection is pure and does not select tabs, clear a pair, create a Field or register
 * a window. A real caller must separately hold the existing registered source/eligibility. */
internal object BrowserTabletWorkspaceGeometry {
    const val toolbarHeight = 44.0
    const val sidebarWidth = 264.0

    fun eligible(window: BrowserWorkspaceWindow, smallestScreenWidthDp: Int): Boolean =
        BrowserTabletOmniboxGeometry.eligible(window, smallestScreenWidthDp)

    fun frame(window: BrowserWorkspaceWindow, statusBar: Double, sidebarShown: Boolean = true,
        framed: Boolean = true, paired: Boolean = false, sidebarExtent: Double = sidebarWidth,
        splitFraction: Double = .5): BrowserTabletWorkspaceFrame {
        require(window.valid && statusBar.isFinite() && statusBar >= 0)
        val top = statusBar + toolbarHeight
        require(top.isFinite())
        val extent = (if (sidebarExtent.isFinite()) sidebarExtent else sidebarWidth).coerceIn(220.0, 360.0)
        val reserved = if (paired && window.width > window.height) 648.0 else 320.0
        val side = if (sidebarShown && window.width - extent - (if (framed) 16.0 else 0.0) >= reserved) extent else 0.0
        val rim = if (side > 0 && framed) 8.0 else 0.0
        return BrowserTabletWorkspaceFrame(window, top,
            if (side > 0) TabletWorkspaceRect(0.0, top, side, window.height - top) else null,
            rim, TabletWorkspaceRect(0.0, statusBar, window.width, toolbarHeight),
            TabletWorkspaceRect(side + rim, top + rim,
                maxOf(1.0, window.width - side - rim * 2),
                maxOf(1.0, window.height - top - rim * 2)), paired, splitFraction)
    }
}

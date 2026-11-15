package dev.yab.browser.model

/** One rendered selected-public-space PAGE. This grants no native/account admission.
 * The Activity adapter must additionally retain its original environment. */
class TabletSidebarPageLease internal constructor(
    internal val ownership: Long,
    internal val foreground: Long,
    internal val privateBoundary: Long,
    internal val sourceGeneration: Long,
    internal val revision: Long,
    internal val windowGeneration: Long,
    internal val smallestScreenWidthDp: Int,
    internal val surfaceEpoch: Long,
    internal val space: BrowserSpace,
    internal val target: TabletPageTarget,
    internal val workspace: BrowserWorkspace?,
)

internal sealed interface TabletSidebarTarget {
    data class Tab(val tab: BrowserTab) : TabletSidebarTarget
    data class Folder(val folder: BrowserFolder) : TabletSidebarTarget
    data object ClearToday : TabletSidebarTarget
    data object NewTab : TabletSidebarTarget
}

/** Immutable original command target, with one local synchronous consumption. */
class TabletSidebarActionLease internal constructor(
    internal val page: TabletSidebarPageLease,
    internal val target: TabletSidebarTarget,
) {
    internal var consumed = false
}

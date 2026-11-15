package dev.yab.browser.model

/** Full Activity-window logical points, independent of the IME-resized content hierarchy. */
data class BrowserWorkspaceWindow(val width: Double, val height: Double) {
    val valid: Boolean get() = width.isFinite() && height.isFinite() && width > 0 && height > 0
    val expanded: Boolean get() = valid && width >= 600.0
    val canSplit: Boolean get() = expanded && width > height && width >= 641.0
}

/** RAM only. Configuration invalidation happens before Android publishes its new layout. */
data class WorkspaceWindowState(
    val registered: Boolean = false,
    val configuration: Long = 0,
    val generation: Long = 0,
    val geometry: BrowserWorkspaceWindow? = null,
)

/** Original rendered entry. Opening a menu cannot reacquire authority from an old callback. */
class WorkspaceEntryLease internal constructor(
    internal val owner: Long,
    internal val foreground: Long,
    internal val privateBoundary: Long,
    internal val sourceGeneration: Long,
    internal val windowGeneration: Long,
    internal val space: String,
    internal val profile: WebsiteProfile,
    internal val front: BrowserTab,
    internal val surface: BrowserSurface,
    internal val epoch: Long,
    internal val workspace: BrowserWorkspace?,
)

/** One opened menu's original target. Retired before a changed target can be published. */
class WorkspaceActionLease internal constructor(
    internal val entry: WorkspaceEntryLease,
    internal val target: BrowserTab?,
)

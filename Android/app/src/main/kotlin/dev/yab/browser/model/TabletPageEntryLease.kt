package dev.yab.browser.model

/** A blank tab still has a native document owner. Empty is the distinct local page with no tab. */
internal sealed interface TabletPageTarget {
    data class Tab(val id: String, val url: String, val isPrivate: Boolean) : TabletPageTarget
    data object Empty : TabletPageTarget
}

/** One rendered tablet PAGE source, kept only in RAM. This is not native or account admission:
 * the Activity must additionally retain and check its original environment before a UI action. */
class TabletPageEntryLease internal constructor(
    internal val ownership: Long,
    internal val foreground: Long,
    internal val privateBoundary: Long,
    internal val sourceGeneration: Long,
    internal val windowGeneration: Long,
    internal val smallestScreenWidthDp: Int,
    internal val surfaceEpoch: Long,
    internal val space: String,
    internal val profile: WebsiteProfile,
    internal val privateSpace: Boolean,
    internal val target: TabletPageTarget,
    internal val workspace: BrowserWorkspace?,
)

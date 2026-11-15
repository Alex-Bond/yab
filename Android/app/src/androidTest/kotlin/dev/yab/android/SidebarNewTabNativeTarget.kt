package dev.yab.android

import android.content.res.Configuration
import android.graphics.Rect
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.model.BrowserSurface
import java.io.Closeable
import kotlin.math.ceil
import kotlin.math.floor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** Only the existing Sidebar New Tab row. No label fallback, input retry or shared input API. */
internal class SidebarNewTabNativeTarget private constructor(
    private val rowBounds: Rect,
    private val labelBounds: Rect,
    private val originalCurrent: () -> Boolean,
) {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val own = instrumentation.targetContext.packageName

    suspend fun tap(ui: OwnedBrowserTestUi) {
        check(current()) { "Original Sidebar target is stale before native projection" }
        project().use { first ->
            check(current()) { "Original Sidebar target changed during native projection" }
            delay(96)
            check(current()) { "Original Sidebar target changed before second projection" }
            project().use { second ->
                check(first.node == second.node && first.window == second.window &&
                    first.bounds == second.bounds && first.rootBounds == second.rootBounds) {
                    "Original Sidebar native target moved or changed"
                }
                check(current()) { "Original Sidebar target changed during second projection" }
                // The shared helper keeps its active owned package/window checks.
                // Its Main source callback reads the original retained layouts only.
                ui.tapBounds(first.bounds, originalCurrent)
            }
        }
    }

    private suspend fun current(): Boolean = withContext(Dispatchers.Main) { originalCurrent() }

    private class Hit(val node: AccessibilityNodeInfo, val bounds: Rect,
        val window: Int, val rootBounds: Rect) : Closeable {
        override fun close() { node.recycle() }
    }

    /** A complete owned-window walk still sees the legitimate toolbar duplicate.
     * Exactly one eligible New Tab must be inside the original Sidebar row/text. */
    private fun project(): Hit {
        val root = checkNotNull(instrumentation.uiAutomation.rootInActiveWindow)
        var copied: AccessibilityNodeInfo? = null
        var copiedBounds: Rect? = null
        var eligible = 0
        var visited = 0
        var complete = true
        var success = false
        var window = -1
        val rootBounds = Rect()
        fun visit(node: AccessibilityNodeInfo) {
            try {
                if (++visited > 512) { complete = false; return }
                if (node.packageName?.toString() != own || node.windowId != window) complete = false
                if (!complete) return
                val bounds = Rect().also(node::getBoundsInScreen)
                val exact = node.text?.toString() == "New Tab" || node.contentDescription?.toString() == "New Tab"
                if (exact && node.isVisibleToUser && node.isEnabled && !node.isPassword && !bounds.isEmpty &&
                    rootBounds.contains(bounds) && rowBounds.contains(bounds) && labelBounds.contains(bounds)) {
                    eligible++
                    if (eligible == 1) {
                        copied = AccessibilityNodeInfo.obtain(node)
                        copiedBounds = Rect(bounds)
                    }
                }
                val children = node.childCount
                if (children > 128) { complete = false; return }
                for (i in 0 until children) {
                    if (!complete) break
                    val child = node.getChild(i)
                    if (child == null) complete = false else visit(child)
                }
            } finally { node.recycle() }
        }
        try {
            window = root.windowId
            root.getBoundsInScreen(rootBounds)
            check(root.packageName?.toString() == own && !rootBounds.isEmpty && rootBounds.contains(rowBounds)) {
                "Original Sidebar row is outside the active owned window"
            }
            visit(root)
            check(complete && eligible == 1 && copied != null && copiedBounds != null) {
                "One complete original Sidebar New Tab native target was not available"
            }
            val hit = Hit(checkNotNull(copied), checkNotNull(copiedBounds), window, rootBounds)
            success = true
            return hit
        } finally {
            // visit owns root once entered; the pre-walk check can also fail.
            if (visited == 0) root.recycle()
            if (!success) copied?.recycle()
        }
    }

    companion object {
        /** Called once on Main, with the exact nodes captured from the real composition. */
        fun capture(host: MainActivity, model: BrowserSessionViewModel,
            row: SemanticsNode, label: SemanticsNode): SidebarNewTabNativeTarget {
            val browser = model.browser
            val engine = model.engine
            val state = browser.state.value
            val tab = checkNotNull(state.tab)
            val space = checkNotNull(state.space)
            val sync = (host.application as YabApplication).sync
            val account = sync.accountRecords.value
            val entrance = checkNotNull(host.intent)
            val configuration = Configuration(host.resources.configuration)
            check(!state.loading && !state.privateContentBlocked && state.surface == BrowserSurface.PAGE &&
                !space.isPrivate && !tab.isPrivate)
            val native = checkNotNull(engine.captureExternalActivityOwner())
            val history = browser.historyPresentationLifetime.value
            val lifetime = browser.settingsPresentationLifetime.value
            val sidebar = browser.tabletSidebarRevision.value
            val window = browser.workspaceWindow.value
            check(lifetime.active && window.registered)
            val rowInfo = row.layoutInfo
            val labelInfo = label.layoutInfo
            val rowId = row.id
            val labelId = label.id
            val root = checkNotNull(row.root)
            check(label.root === root)
            val view = (root as? ViewRootForTest)?.view ?: error("Original Sidebar has no native Compose root")
            val decor = host.window.decorView
            val token = checkNotNull(view.windowToken)
            check(view.rootView === decor && decor.windowToken === token)
            val rowFrame = row.boundsInWindow
            val labelFrame = label.boundsInWindow
            val windowOrigin = origin(view)
            val viewFrame = checkNotNull(visibleFrame(view))
            val decorFrame = checkNotNull(visibleFrame(decor))
            val rowBounds = pixels(rowFrame, windowOrigin)
            val labelBounds = pixels(labelFrame, windowOrigin)
            check(!rowBounds.isEmpty && !labelBounds.isEmpty && rowBounds.contains(labelBounds) && decorFrame.contains(rowBounds))
            val current: () -> Boolean = {
                val now = browser.state.value
                val latestAccount = sync.accountRecords.value
                !host.isDestroyed && !host.isFinishing && host.hasWindowFocus() &&
                    host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                    host.intent === entrance && host.resources.configuration == configuration &&
                    latestAccount.account == account.account && latestAccount.device == account.device &&
                    latestAccount.epoch == account.epoch && latestAccount.removed == account.removed &&
                    !account.removed && sync.nativeOwnerCurrent(account) &&
                    !now.loading && !now.privateContentBlocked && now.surface == state.surface &&
                    now.surfaceEpoch == state.surfaceEpoch && now.selectedSpaceId == state.selectedSpaceId &&
                    now.space?.websiteProfile == space.websiteProfile && now.tab?.let { it.id == tab.id && it.url == tab.url } == true &&
                    browser.historyPresentationLifetime.value == history && browser.settingsPresentationLifetime.value == lifetime &&
                    browser.tabletSidebarRevision.value == sidebar && browser.workspaceWindow.value == window &&
                    engine.ownsExternalActivity(native) &&
                    view.isAttachedToWindow && view.isShown && view.windowToken === token && view.rootView === decor &&
                    decor.isAttachedToWindow && decor.isShown && decor.windowToken === token &&
                    visibleFrame(view) == viewFrame && visibleFrame(decor) == decorFrame && origin(view) == windowOrigin &&
                    row.layoutInfo === rowInfo && label.layoutInfo === labelInfo &&
                    rowInfo.isAttached && rowInfo.isPlaced && labelInfo.isAttached && labelInfo.isPlaced &&
                    rowInfo.semanticsId == rowId && labelInfo.semanticsId == labelId &&
                    row.root === root && label.root === root && row.boundsInWindow == rowFrame && label.boundsInWindow == labelFrame &&
                    !row.config.contains(SemanticsProperties.Disabled) && row.config.contains(SemanticsActions.OnClick)
            }
            check(current()) { "Original Sidebar row is not currently attached to its source" }
            return SidebarNewTabNativeTarget(rowBounds, labelBounds, current)
        }

        private fun origin(view: View): Pair<Int, Int> {
            val screen = IntArray(2)
            val window = IntArray(2)
            view.getLocationOnScreen(screen)
            view.getLocationInWindow(window)
            return screen[0] - window[0] to screen[1] - window[1]
        }

        private fun visibleFrame(view: View): Rect? = Rect().takeIf {
            view.isAttachedToWindow && view.isShown && view.getGlobalVisibleRect(it) && !it.isEmpty
        }

        private fun pixels(frame: androidx.compose.ui.geometry.Rect, origin: Pair<Int, Int>): Rect = Rect(
            floor(frame.left + origin.first.toDouble()).toInt(), floor(frame.top + origin.second.toDouble()).toInt(),
            ceil(frame.right + origin.first.toDouble()).toInt(), ceil(frame.bottom + origin.second.toDouble()).toInt())
    }
}

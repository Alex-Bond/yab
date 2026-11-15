package dev.yab.android

import android.content.res.Configuration
import android.graphics.Rect
import android.os.SystemClock
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.model.BrowserTab
import java.io.Closeable
import kotlin.math.ceil
import kotlin.math.floor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** Only the selected Gallery card, never an arbitrary exact-label or parent-action fallback. */
internal class GalleryCardNativeTarget private constructor(private val original: Observation) {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val own = instrumentation.targetContext.packageName
    private var attempted = false

    suspend fun tap(ui: OwnedBrowserTestUi) {
        check(!attempted) { "Original Gallery target already consumed" }
        attempted = true
        check(current()) { "Original Gallery card is stale before native projection" }
        project().use { first ->
            check(current()) { "Original Gallery card changed during native projection" }
            delay(96)
            check(current()) { "Original Gallery card changed before second projection" }
            project().use { second ->
                check(first.node == second.node && first.window == second.window &&
                    first.bounds == second.bounds && first.rootBounds == second.rootBounds) {
                    "Original Gallery native card moved or changed"
                }
                check(current()) { "Original Gallery card changed during second projection" }
                // The unchanged shared helper rechecks this original source/layout at DOWN and UP.
                ui.tapBounds(first.bounds, original::current)
            }
        }
    }

    private suspend fun current(): Boolean = withContext(Dispatchers.Main) { original.current() }

    private class Hit(val node: AccessibilityNodeInfo, val bounds: Rect,
        val window: Int, val rootBounds: Rect) : Closeable {
        override fun close() { node.recycle() }
    }

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
                val exact = node.text?.toString() == original.label || node.contentDescription?.toString() == original.label
                if (exact && node.isVisibleToUser && node.isEnabled && !node.isPassword && !bounds.isEmpty &&
                    rootBounds.contains(bounds) && original.cardBounds.contains(bounds)) {
                    eligible++
                    if (eligible == 1) {
                        copied = AccessibilityNodeInfo.obtain(node)
                        copiedBounds = Rect(bounds)
                    }
                }
                val children = node.childCount
                if (children > 128) { complete = false; return }
                for (index in 0 until children) {
                    if (!complete) break
                    val child = node.getChild(index)
                    if (child == null) complete = false else visit(child)
                }
            } finally { node.recycle() }
        }
        try {
            window = root.windowId
            root.getBoundsInScreen(rootBounds)
            check(root.packageName?.toString() == own && !rootBounds.isEmpty && rootBounds.contains(original.cardBounds)) {
                "Original Gallery card is outside the active owned window"
            }
            visit(root)
            check(complete && eligible == 1 && copied != null && copiedBounds != null) {
                "One complete original Gallery card native target was not available"
            }
            val hit = Hit(checkNotNull(copied), checkNotNull(copiedBounds), window, rootBounds)
            success = true
            return hit
        } finally {
            if (visited == 0) root.recycle()
            if (!success) copied?.recycle()
        }
    }

    /** Before input only. Observations cannot dispatch and cannot renew a captured target. */
    internal class Observation internal constructor(internal val card: Boolean, internal val label: String,
        internal val cardBounds: Rect, private val identity: List<Any?>, private val originalCurrent: () -> Boolean) {
        fun current(): Boolean = originalCurrent()
        fun same(next: Observation): Boolean = identity == next.identity && current() && next.current()
    }

    /** Uses the caller's existing 30s await, without an independent timeout or input retry. */
    internal class Readiness {
        private var original: Observation? = null
        private var began = 0L
        private var ready = false
        private var consumed = false
        fun reset() { check(!consumed); original = null; ready = false }
        fun observe(next: Observation?): Boolean {
            check(!consumed)
            val now = SystemClock.elapsedRealtime()
            if (next == null || !next.current()) { original = null; ready = false; return false }
            val first = original
            if (first == null || !first.same(next)) { original = next; began = now; ready = false; return false }
            ready = now - began >= 250
            return ready
        }
        fun captureCard(): GalleryCardNativeTarget {
            check(!consumed && ready)
            consumed = true
            val first = checkNotNull(original)
            check(first.card && first.current()) { "Settled original Gallery card changed before capture" }
            return GalleryCardNativeTarget(first)
        }
    }

    companion object {
        fun observeCard(host: MainActivity, model: BrowserSessionViewModel, node: SemanticsNode,
            expected: BrowserTab): Observation? = observe(host, model, node, BrowserSurface.GALLERY,
                expected, "browser.gallery.card.${expected.id}", expected.title, card = true)

        fun observeAllTabs(host: MainActivity, model: BrowserSessionViewModel,
            node: SemanticsNode): Observation? {
            val expected = model.browser.state.value.tab ?: return null
            return observe(host, model, node, BrowserSurface.PAGE, expected,
                "browser.tablet.all-tabs", "All Tabs", card = false)
        }

        /** Called on Main with the unique already-fetched actual control, before any input. */
        private fun observe(host: MainActivity, model: BrowserSessionViewModel, node: SemanticsNode,
            surface: BrowserSurface, expected: BrowserTab, tag: String, label: String, card: Boolean): Observation? {
            val browser = model.browser
            val engine = model.engine
            val state = browser.state.value
            val tab = state.tab ?: return null
            val space = state.space ?: return null
            if (state.loading || state.privateContentBlocked || state.surface != surface || space.isPrivate || tab.isPrivate ||
                tab.id != expected.id || tab.url != expected.url || tab.title != expected.title ||
                space.tabs.singleOrNull { it.id == tab.id } != tab || (!card && state.page.loading)) return null
            val native = engine.captureExternalActivityOwner() ?: return null
            if (native.tab != tab.id || native.session.settings.contextId != space.websiteProfile.id ||
                native.session.settings.usePrivateMode) return null
            val sync = (host.application as YabApplication).sync
            val account = sync.accountRecords.value
            val entrance = host.intent ?: return null
            val configuration = Configuration(host.resources.configuration)
            val history = browser.historyPresentationLifetime.value
            val lifetime = browser.settingsPresentationLifetime.value
            val window = browser.workspaceWindow.value
            if (!lifetime.active || !window.registered || window.geometry?.valid != true) return null
            val info = node.layoutInfo
            val id = node.id
            val root = node.root ?: return null
            val view = (root as? ViewRootForTest)?.view ?: return null
            val ownWindow = host.window
            val store = host.viewModelStore
            val decor = ownWindow.decorView
            val token = view.windowToken ?: return null
            if (view.rootView !== decor || decor.windowToken !== token) return null
            val frame = node.boundsInWindow
            val windowOrigin = origin(view)
            val viewFrame = visibleFrame(view) ?: return null
            val decorFrame = visibleFrame(decor) ?: return null
            val actualWindow = Rect(host.windowManager.currentWindowMetrics.bounds)
            val bounds = pixels(frame, windowOrigin)
            if (bounds.isEmpty || !decorFrame.contains(bounds)) return null
            val current: () -> Boolean = {
                val now = browser.state.value
                val latestAccount = sync.accountRecords.value
                !host.isDestroyed && !host.isFinishing && host.hasWindowFocus() &&
                    host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                    host.window === ownWindow && host.viewModelStore === store &&
                    host.intent === entrance && host.resources.configuration == configuration &&
                    host.windowManager.currentWindowMetrics.bounds == actualWindow &&
                    latestAccount.account == account.account && latestAccount.device == account.device &&
                    latestAccount.epoch == account.epoch && latestAccount.removed == account.removed &&
                    !account.removed && sync.nativeOwnerCurrent(account) &&
                    !now.loading && !now.privateContentBlocked && now.surface == surface && now.surfaceEpoch == state.surfaceEpoch &&
                    now.selectedSpaceId == state.selectedSpaceId && now.space?.websiteProfile == space.websiteProfile &&
                    now.space?.isPrivate == false && now.tab?.let {
                        it.id == tab.id && it.url == tab.url && it.title == tab.title && !it.isPrivate
                    } == true && now.space?.tabs?.singleOrNull { it.id == tab.id } == now.tab &&
                    (card || !now.page.loading) && browser.historyPresentationLifetime.value == history &&
                    browser.settingsPresentationLifetime.value == lifetime && browser.workspaceWindow.value == window &&
                    engine.ownsExternalActivity(native) &&
                    view.isAttachedToWindow && view.isShown && view.windowToken === token && view.rootView === decor &&
                    decor.isAttachedToWindow && decor.isShown && decor.windowToken === token &&
                    visibleFrame(view) == viewFrame && visibleFrame(decor) == decorFrame && origin(view) == windowOrigin &&
                    node.layoutInfo === info && info.isAttached && info.isPlaced && info.semanticsId == id &&
                    node.root === root && node.boundsInWindow == frame &&
                    node.config.getOrNull(SemanticsProperties.TestTag) == tag &&
                    node.config.getOrNull(SemanticsProperties.ContentDescription)?.contains(label) == true &&
                    !node.config.contains(SemanticsProperties.Disabled) && node.config.contains(SemanticsActions.OnClick)
            }
            if (!current()) return null
            val identity = listOf(host, model, store, ownWindow, entrance, configuration, actualWindow, native.session, native.document,
                state.surface, state.surfaceEpoch, state.selectedSpaceId, tab.id, tab.url, tab.title, space.websiteProfile,
                account.account, account.device, account.epoch, account.removed, history, lifetime, window,
                root, view, decor, token, info, id, frame, windowOrigin, viewFrame, decorFrame, card)
            return Observation(card, label, bounds, identity, current)
        }

        private fun origin(view: View): Pair<Int, Int> {
            val screen = IntArray(2); val window = IntArray(2)
            view.getLocationOnScreen(screen); view.getLocationInWindow(window)
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

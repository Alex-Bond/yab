package dev.yab.browser.ui

import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.BrowserTabletWorkspaceFrame
import dev.yab.browser.model.BrowserTabletWorkspaceGeometry
import dev.yab.browser.model.WorkspaceWindowState
import dev.yab.browser.model.TabletOmniboxRoot
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserFieldPlacementLease
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.model.BrowserTabletOmniboxGeometry

/** One accepted drawing projection/root shared by Main's visibility and Screen's paint.
 * These values grant no native, PAGE or input authority. */
class BrowserTabletWorkspaceDrawing internal constructor(
    internal val presentation: BrowserTabletWorkspacePresentation,
    internal val root: TabletOmniboxRoot,
) {
    internal val frame get() = presentation.frame
}

/** Retained pixels only. The original context cannot supply or replace a PAGE action. */
class BrowserTabletSidebarDrawingContext internal constructor(internal val scrollKey: Any = Any(),
    private val originalCurrent: () -> Boolean) {
    private var retired = false
    fun current(): Boolean {
        if (retired) return false
        if (!originalCurrent()) { retired = true; return false }
        return true
    }
}

/** Plain render-only identity. A genuine Field may cover the same public page without
 * replacing its drawing source. Account/space/profile changes still replace it; returning
 * to PAGE adopts the new monotonic PAGE source generation. No action uses this as authority. */
internal class BrowserTabletWorkspaceDrawingSource {
    private var context: Any? = null
    private var pageGeneration = 0L
    private var source = Any()
    fun capture(originalContext: Any, generation: Long, fieldOverlay: Boolean): Any {
        if (context !== originalContext || !fieldOverlay && pageGeneration != generation) {
            context = originalContext; pageGeneration = generation; source = Any()
        }
        return source
    }
    fun current(original: Any): Boolean = source === original
}

/** Main's UI-only state, above Screen and the single movable Field. Capturing a
 * drawing projection never registers a window or grants a native PAGE action. */
internal class BrowserTabletWorkspaceState(initialFramed: Boolean = true,
    initialSidebarWidth: Double = 264.0, initialSplitFraction: Double = .5,
    private val persistDimensions: (Double, Double) -> Boolean = { _, _ -> true },
    private val persistFramed: (Boolean) -> Boolean = { true }) {
    private data class Visibility(val shown: Boolean, val framed: Boolean, val revision: Long)
    private data class Layout(val window: WorkspaceWindowState, val smallestWidth: Int,
        val statusTop: Double, val paired: Boolean)
    private var visibility by mutableStateOf(Visibility(true, initialFramed, 0))
    private data class Dimensions(val width: Double, val fraction: Double)
    private var dimensions by mutableStateOf(Dimensions(
        (if (initialSidebarWidth.isFinite()) initialSidebarWidth else 264.0).coerceIn(220.0, 360.0),
        (if (initialSplitFraction.isFinite()) initialSplitFraction else .5).coerceIn(.15, .85)))
    private var revision = 0L
    private var layout: Layout? = null
    private var source: Any? = null
    private var original: BrowserTabletWorkspacePresentation? = null

    val sidebarShown: Boolean get() = visibility.shown
    val framed: Boolean get() = visibility.framed
    val layoutRevision: Long get() = visibility.let { dimensions.let { revision } }

    /** Call only in a fresh render. source is a stable original PAGE/context key,
     * not a newly captured native-owner wrapper or a mutable callback delegate. */
    fun capture(window: WorkspaceWindowState, smallestWidth: Int, statusTop: Double,
        paired: Boolean, source: Any, originalSceneCurrent: () -> Boolean): BrowserTabletWorkspacePresentation? {
        // A cached projection still has to observe dimensions in every render.
        // Otherwise a later composition drops this read and a successful resize
        // updates the preference without invalidating the visible frame.
        val currentDimensions = dimensions
        val geometry = window.geometry
        if (!window.registered || geometry == null || !BrowserTabletWorkspaceGeometry.eligible(geometry, smallestWidth) ||
            !statusTop.isFinite() || statusTop < 0 || statusTop + BrowserTabletWorkspaceGeometry.toolbarHeight >= geometry.height) {
            if (layout != null || this.source != null) revision++
            layout = null; this.source = null; original = null
            return null
        }
        val next = Layout(window, smallestWidth, statusTop, paired)
        if (layout != next || this.source !== source) {
            // Plain UI-thread capture state: observed A->B->A permanently retires A.
            // This must not publish Compose state or start a composition-write loop.
            revision++
            layout = next; this.source = source; original = null
        }
        original?.takeIf { !it.isRetired && matches(it) }?.let { return it }
        return BrowserTabletWorkspacePresentation(this, revision, visibility.shown, visibility.framed, window,
            BrowserTabletWorkspaceGeometry.frame(geometry, statusTop, visibility.shown, framed = visibility.framed, paired = paired, sidebarExtent = currentDimensions.width, splitFraction = currentDimensions.fraction),
            originalSceneCurrent).also { original = it }
    }

    internal fun matches(presentation: BrowserTabletWorkspacePresentation): Boolean =
        original === presentation && presentation.revision == revision && presentation.sidebarShown == visibility.shown &&
            presentation.framed == visibility.framed

    internal fun layoutMatches(presentation: BrowserTabletWorkspacePresentation): Boolean =
        presentation.revision == revision && presentation.sidebarShown == visibility.shown &&
            presentation.framed == visibility.framed && layout?.window == presentation.window

    internal fun toggle(presentation: BrowserTabletWorkspacePresentation): Boolean {
        if (!presentation.current() || !matches(presentation)) return false
        val next = ++revision // Revoke old scopes before publishing the new visible layout.
        original = null
        visibility = Visibility(!visibility.shown, visibility.framed, next)
        return true
    }

    /** A live gesture retains the original public/native scope, while accepting only
     * its own layout revisions. A source, coverage or window change ends that gesture. */
    internal fun beginResize(presentation: BrowserTabletWorkspacePresentation, sidebar: Boolean,
        sceneCurrent: () -> Boolean): BrowserTabletResizeSession? {
        if (!presentation.current() || !sceneCurrent() || !matches(presentation) ||
            (if (sidebar) presentation.frame.sidebar == null else !presentation.frame.drawnSplit)) return null
        val initialLayout = layout
        val initialSource = source
        val initialDimensions = dimensions
        val frame = presentation.frame
        var expectedRevision = revision
        var retired = false
        fun current(): Boolean {
            if (retired) return false
            if (revision != expectedRevision || layout != initialLayout || source !== initialSource ||
                !presentation.sceneCurrent() || !sceneCurrent()) { retired = true; return false }
            return true
        }
        fun publish(value: Dimensions) {
            if (value == dimensions) return
            expectedRevision = ++revision
            original = null
            dimensions = value
        }
        val start = if (sidebar) frame.sidebar!!.width else frame.pane(false).width
        return BrowserTabletResizeSession(start, { value, save ->
            if (!value.isFinite() || !current()) false else {
                val next = if (sidebar) dimensions.copy(width = value.coerceIn(220.0, 360.0)) else {
                    val available = maxOf(1.0, frame.page.width - 8.0)
                    val minimum = maxOf(.15, minOf(.5, 320.0 / available))
                    dimensions.copy(fraction = (value / available).coerceIn(minimum, 1.0 - minimum))
                }
                if (save && (!runCatching { persistDimensions(next.width, next.fraction) }.getOrDefault(false) || !current())) false
                else { publish(next); if (save) retired = true; true }
            }
        }, {
            if (current()) publish(initialDimensions)
            retired = true
        })
    }

    /** Complete the original Field transition first. Its own terminal surface change
     * revokes input leases, so no replacement PAGE capture or post-dismiss check follows.
     * A refused dismissal must leave both the visible value and layout revision intact. */
    internal fun ensureShownAfter(dismissOriginal: () -> Boolean): Boolean {
        if (!dismissOriginal()) return false
        if (!visibility.shown) {
            val next = ++revision
            original = null
            visibility = Visibility(true, visibility.framed, next)
        }
        return true
    }

    internal fun toggleFrame(presentation: BrowserTabletWorkspacePresentation): Boolean {
        if (!presentation.current() || !matches(presentation)) return false
        val target = !visibility.framed
        // This is a local preference, outside BrowserSettings/Sync. A failed write
        // preserves the visible value; the one-shot control still cannot retry itself.
        if (!runCatching { persistFramed(target) }.getOrDefault(false) || !presentation.current() || !matches(presentation)) return false
        val next = ++revision // Retire old layout even while hidden, where rim remains0.
        original = null
        visibility = Visibility(visibility.shown, target, next)
        return true
    }
}

/** Original Main FIELD admission, independent of the public-only Sidebar drawing.
 * Both public and Private New Tab use the same UI flag; this grants no PAGE action. */
class BrowserTabletNewTabRestingEntry internal constructor(
    private val controller: BrowserController,
    private val workspace: BrowserTabletWorkspaceState,
    private val original: BrowserFieldPlacementLease,
    private val originalSceneCurrent: () -> Boolean,
) {
    private var retired = false
    fun retire() { retired = true }
    internal fun current(): Boolean {
        if (retired) return false
        val input = original.input
        if (!original.tablet || input?.surface != BrowserSurface.FIELD || !input.newTab ||
            !original.current() || !originalSceneCurrent() || !original.current()) {
            retired = true; return false
        }
        return true
    }
    internal fun bind(source: BrowserFieldPlacementLease, originalSceneCurrent: () -> Boolean) =
        BrowserTabletNewTabRestingControl(this, source, originalSceneCurrent)

    internal fun complete(source: BrowserFieldPlacementLease): Boolean {
        val input = source.input ?: return false
        val originalInput = original.input ?: return false
        if (!current() || !source.current() || !source.tablet || !input.newTab ||
            input.epoch != originalInput.epoch || input.privately != originalInput.privately ||
            !controller.state.value.fieldResting) return false
        retired = true
        return workspace.ensureShownAfter { controller.dismissField(originalInput.epoch) }
    }

    internal companion object {
        fun capture(controller: BrowserController, workspace: BrowserTabletWorkspaceState,
            smallestWidth: Int, originalSceneCurrent: () -> Boolean): BrowserTabletNewTabRestingEntry? {
            val state = controller.state.value
            val window = controller.workspaceWindow.value
            if (state.surface != BrowserSurface.FIELD || !state.fieldIsNewTab || state.privateContentBlocked ||
                !window.registered || window.geometry?.let { BrowserTabletOmniboxGeometry.eligible(it, smallestWidth) } != true) return null
            val original = BrowserFieldPlacementLease.capture(controller, true)
            return BrowserTabletNewTabRestingEntry(controller, workspace, original, originalSceneCurrent)
                .takeIf { it.current() }
        }
    }
}

/** One rendered Host/body. Coverage, disposal or source replacement permanently
 * retires it, even if the same New Tab facts are presented again later. */
internal class BrowserTabletNewTabRestingControl(
    private val entry: BrowserTabletNewTabRestingEntry,
    private val original: BrowserFieldPlacementLease,
    private val originalSceneCurrent: () -> Boolean,
) {
    private var retired = false
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!original.tablet || !original.current() || !originalSceneCurrent() ||
            !entry.current() || !original.current()) { retired = true; return false }
        return true
    }
    fun perform(): Boolean {
        if (!current()) return false
        retired = true
        return entry.complete(original)
    }
}

/** Immutable original drawing and UI layout scope. Main and Screen must share
 * this same frame; native operations still require their independent source78 lease. */
class BrowserTabletWorkspacePresentation internal constructor(
    private val owner: BrowserTabletWorkspaceState,
    internal val revision: Long,
    val sidebarShown: Boolean,
    val framed: Boolean,
    internal val window: WorkspaceWindowState,
    internal val frame: BrowserTabletWorkspaceFrame,
    private val originalSceneCurrent: () -> Boolean,
) {
    private var retired = false
    private var layoutRetired = false
    internal val isRetired: Boolean get() = retired
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!owner.matches(this) || !originalSceneCurrent() || !owner.matches(this)) { retired = true; return false }
        return true
    }
    /** Drawing/layout lifetime only. Coverage may replace a control presentation without
     * changing this layout. This never replaces a PAGE/native/account action lease. */
    internal fun layoutCurrent(): Boolean {
        if (layoutRetired) return false
        if (!owner.layoutMatches(this)) { layoutRetired = true; return false }
        return true
    }
    internal fun sceneCurrent(): Boolean = originalSceneCurrent()
    internal fun beginResize(sidebar: Boolean, sceneCurrent: () -> Boolean) = owner.beginResize(this, sidebar, sceneCurrent)
    internal fun toggleSidebar(): Boolean = owner.toggle(this)
    internal fun toggleControl(originalSceneCurrent: () -> Boolean): BrowserTabletSidebarToggleControl =
        BrowserTabletSidebarToggleControl(this, originalSceneCurrent)
    internal fun frameControl(originalSceneCurrent: () -> Boolean): BrowserTabletFrameControl =
        BrowserTabletFrameControl(this, originalSceneCurrent)
    internal fun toggleFrame(): Boolean = owner.toggleFrame(this)
}

/** The context menu keeps this original UI/layout and native-scene predicate. */
internal class BrowserTabletFrameControl(private val original: BrowserTabletWorkspacePresentation,
    private val originalSceneCurrent: () -> Boolean) {
    private var retired = false
    val framed: Boolean get() = original.framed
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!original.current() || !originalSceneCurrent() || !original.current()) { retired = true; return false }
        return true
    }
    fun perform(): Boolean {
        if (!current()) return false
        retired = true
        return original.toggleFrame()
    }
}

/** Screen captures this with its original attached root/coverage/layout source. */
internal class BrowserTabletSidebarToggleControl(private val original: BrowserTabletWorkspacePresentation,
    private val originalSceneCurrent: () -> Boolean) {
    private var retired = false
    val shown: Boolean get() = original.frame.sidebar != null
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!original.current() || !originalSceneCurrent() || !original.current()) { retired = true; return false }
        return true
    }
    fun perform(): Boolean {
        if (!current()) return false
        retired = true
        return original.toggleSidebar()
    }
}

@Composable
internal fun BrowserTabletSidebarToggle(control: BrowserTabletSidebarToggleControl, modifier: Modifier = Modifier) {
    DisposableEffect(control) { onDispose { control.retire() } }
    key(control) {
        IconButton(onClick = { control.perform() }, enabled = control.current(), modifier = modifier.size(44.dp)
            .testTag("browser.tablet.sidebar.toggle")
            .semantics { stateDescription = if (control.shown) "shown" else "hidden" }) {
            Icon(YabGlyphs.TabletSidebar, "Sidebar")
        }
    }
}

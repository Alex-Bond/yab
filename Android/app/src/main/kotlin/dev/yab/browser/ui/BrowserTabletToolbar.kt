package dev.yab.browser.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.FieldAnchor
import dev.yab.browser.model.BrowserState
import dev.yab.browser.model.HistoryPresentation
import dev.yab.android.R

/** Actual commands only. The middle capsule's complete Reload/address/Site group is
 * max540, not540 plus two controls. Address remains the one existing real Field entry. */
@Composable
internal fun BrowserTabletToolbar(control: BrowserTabletToolbarControl, root: LayoutCoordinates,
    siteAvailable: Boolean, onSite: (FieldAnchor) -> Boolean, onGallery: (BrowserTabletGallerySource) -> Unit,
    splitAvailable: Boolean, splitEnabled: Boolean, onSplit: (FieldAnchor) -> Boolean,
    modifier: Modifier = Modifier,
    sidebar: @Composable () -> Unit, address: @Composable (Modifier) -> Unit) {
    var redraw by remember(control) { mutableLongStateOf(0) }
    val back = remember(control, redraw) { control.back?.let(control::command) }
    val forward = remember(control, redraw) { control.command(BrowserTabletToolbarCommand.FORWARD) }
    val reload = remember(control, redraw) { control.reload?.let(control::command) }
    val newTab = remember(control, redraw) { control.newTab() }
    val originalGallery = remember(control) { onGallery }
    val tabs = remember(control, redraw) {
        control.gallery()?.let { gallery -> BrowserTabletSidebarAction(control::current) {
            if (gallery.open()) { originalGallery(gallery); true } else false
        } }
    }
    DisposableEffect(back, forward, reload, newTab, tabs) {
        onDispose { listOfNotNull(back, forward, reload, newTab, tabs).forEach { it.retire() } }
    }
    fun accepted(action: BrowserTabletSidebarAction?) { if (action?.perform() == true) redraw++ }
    Row(modifier.fillMaxWidth().height(44.dp).background(MaterialTheme.colorScheme.surface)
        .padding(horizontal = 12.dp).testTag("browser.tablet.toolbar"),
        horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.width(132.dp), verticalAlignment = Alignment.CenterVertically) {
            sidebar()
            ToolbarCommand(back, "Back", "back", { accepted(back) }) { ToolbarGlyph(R.drawable.tablet_toolbar_back) }
            ToolbarCommand(forward, "Forward", "forward", { accepted(forward) }) { ToolbarGlyph(R.drawable.tablet_toolbar_forward) }
        }
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            Row(Modifier.widthIn(max = 540.dp).fillMaxWidth().height(44.dp)
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = .055f), CircleShape),
                verticalAlignment = Alignment.CenterVertically) {
                val stopping = control.reload == BrowserTabletToolbarCommand.STOP
                ToolbarCommand(reload, if (stopping) "Stop" else "Reload", "reload", { accepted(reload) }) {
                    ToolbarGlyph(if (stopping) R.drawable.tablet_toolbar_stop else R.drawable.tablet_toolbar_reload)
                }
                address(Modifier.weight(1f))
                ToolbarMeasuredButton(control, root, siteAvailable, "Site Controls", "site-controls", onSite) {
                    ToolbarGlyph(R.drawable.tablet_toolbar_site_controls)
                }
            }
        }
        Row(Modifier.width(if (splitAvailable) 132.dp else 88.dp), verticalAlignment = Alignment.CenterVertically) {
            if (splitAvailable) ToolbarMeasuredButton(control, root, splitEnabled, "Split View", "split", onSplit) {
                ToolbarGlyph(R.drawable.tablet_toolbar_split_view)
            }
            ToolbarCommand(newTab, "New Tab", "new-tab", { accepted(newTab) }) { ToolbarGlyph(R.drawable.tablet_toolbar_new_tab) }
            ToolbarCommand(tabs, "All Tabs", "all-tabs", { accepted(tabs) }) { ToolbarGlyph(R.drawable.tablet_toolbar_all_tabs) }
        }
    }
}

@Composable
private fun ToolbarGlyph(resource: Int) = Icon(painterResource(resource), null, Modifier.size(20.dp))

/** Current accepted public drawing only, below a Field or owned menu. No action,
 * gesture node, source recapture or accessibility control is retained here. */
@Composable
internal fun BrowserTabletToolbarBackdrop(state: BrowserState, splitAvailable: Boolean, modifier: Modifier = Modifier) {
    @Composable fun glyph(resource: Int, enabled: Boolean = true) {
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
            CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else .38f)) {
                ToolbarGlyph(resource)
            }
        }
    }
    Row(modifier.fillMaxWidth().height(44.dp).background(MaterialTheme.colorScheme.surface)
        .padding(horizontal = 12.dp).clearAndSetSemantics {}, horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.width(132.dp), verticalAlignment = Alignment.CenterVertically) {
            glyph(R.drawable.tablet_toolbar_sidebar)
            glyph(R.drawable.tablet_toolbar_back, state.tab != null && (state.page.readerEnabled || state.page.canGoBack || state.tab?.openerId != null))
            glyph(R.drawable.tablet_toolbar_forward, state.tab != null && state.page.canGoForward)
        }
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            Row(Modifier.widthIn(max = 540.dp).fillMaxWidth().height(44.dp)
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = .055f), CircleShape), verticalAlignment = Alignment.CenterVertically) {
                glyph(if (state.page.loading) R.drawable.tablet_toolbar_stop else R.drawable.tablet_toolbar_reload, state.tab != null)
                Text(state.tab?.url?.let(HistoryPresentation::pretty) ?: "Search or enter address", Modifier.weight(1f).padding(horizontal = 16.dp),
                    fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.MiddleEllipsis, textAlign = TextAlign.Center)
                glyph(R.drawable.tablet_toolbar_site_controls, state.tab != null)
            }
        }
        Row(Modifier.width(if (splitAvailable) 132.dp else 88.dp), verticalAlignment = Alignment.CenterVertically) {
            if (splitAvailable) glyph(R.drawable.tablet_toolbar_split_view, state.tab != null)
            glyph(R.drawable.tablet_toolbar_new_tab)
            glyph(R.drawable.tablet_toolbar_all_tabs, state.tab != null)
        }
    }
}

@Composable
private fun ToolbarCommand(action: BrowserTabletSidebarAction?, description: String, tag: String,
    onClick: () -> Unit, modifier: Modifier = Modifier, glyph: @Composable () -> Unit) {
    // Node replacement owns the original action; a saved callback never receives a new command.
    key(action) {
        IconButton(enabled = action?.current() == true, onClick = onClick,
            modifier = modifier.size(44.dp).testTag("browser.tablet.$tag")
                .semantics { contentDescription = description }) { glyph() }
    }
}

/** Original keyed node plus actual measured bounds. A failed pre-layout observation
 * captures no replacement authority and may recover only on a genuine fresh layout. */
@Composable
private fun ToolbarMeasuredButton(control: BrowserTabletToolbarControl, root: LayoutCoordinates,
    available: Boolean, description: String, tag: String, onOpen: (FieldAnchor) -> Boolean,
    glyph: @Composable () -> Unit) {
    val density = LocalDensity.current.density
    val originalOpen = remember(control, root, density) { onOpen }
    var coordinates by remember(control, root, density) { mutableStateOf<LayoutCoordinates?>(null) }
    var measured by remember(control, root, density) { mutableStateOf<FieldAnchor?>(null) }
    var measuredRoot by remember(control, root, density) { mutableStateOf<FieldAnchor?>(null) }
    fun frame(c: LayoutCoordinates): FieldAnchor? {
        if (!c.isAttached || !density.isFinite() || density <= 0f) return null
        val r = c.boundsInRoot()
        return FieldAnchor(r.left / density.toDouble(), r.top / density.toDouble(),
            r.width / density.toDouble(), r.height / density.toDouble()).takeIf { it.valid() }
    }
    val open = open@ {
        if (!control.current()) return@open
        val c = coordinates ?: return@open
        val anchor = frame(c) ?: return@open
        val bounds = frame(root) ?: return@open
        if (anchor != measured || bounds != measuredRoot || anchor.x < bounds.x || anchor.y < bounds.y ||
            anchor.x + anchor.width > bounds.x + bounds.width || anchor.y + anchor.height > bounds.y + bounds.height ||
            !control.current()) return@open
        originalOpen(anchor)
        Unit
    }
    key(control, root, density) {
        IconButton(enabled = available && control.current(), onClick = open,
            modifier = Modifier.size(44.dp).onGloballyPositioned {
                coordinates = it; measured = frame(it); measuredRoot = frame(root)
            }.testTag("browser.tablet.$tag").semantics { contentDescription = description }) { glyph() }
    }
}

/** Both gestures belong to this rendered control. The context action retains
 * the measured original node; it never looks up a replacement toolbar. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun BrowserTabletToolbarSidebar(toggle: BrowserTabletSidebarToggleControl,
    control: BrowserTabletToolbarControl, root: LayoutCoordinates, onContext: (FieldAnchor) -> Boolean) {
    val density = LocalDensity.current.density
    val originalContext = remember(toggle, control, root, density) { onContext }
    var node by remember(toggle, control, root, density) { mutableStateOf<LayoutCoordinates?>(null) }
    var measured by remember(toggle, control, root, density) { mutableStateOf<FieldAnchor?>(null) }
    fun frame(c: LayoutCoordinates): FieldAnchor? {
        if (!c.isAttached || !density.isFinite() || density <= 0f) return null
        val r = c.boundsInRoot()
        return FieldAnchor(r.left / density.toDouble(), r.top / density.toDouble(), r.width / density.toDouble(),
            r.height / density.toDouble()).takeIf { it.valid() }
    }
    val context = context@ {
        if (!control.current() || !toggle.current()) return@context
        val anchor = node?.let(::frame) ?: return@context
        val bounds = frame(root) ?: return@context
        if (anchor != measured || anchor.x < bounds.x || anchor.y < bounds.y ||
            anchor.x + anchor.width > bounds.x + bounds.width || anchor.y + anchor.height > bounds.y + bounds.height ||
            !control.current() || !toggle.current()) return@context
        originalContext(anchor); Unit
    }
    key(toggle, control, root, density) {
        Box(Modifier.size(44.dp).onGloballyPositioned { node = it; measured = frame(it) }
            .combinedClickable(enabled = toggle.current() && control.current(), role = Role.Button,
                onClick = { toggle.perform() }, onLongClickLabel = "Frame Page with Sidebar", onLongClick = context)
            .testTag("browser.tablet.sidebar.toggle").semantics {
                contentDescription = "Sidebar"; stateDescription = if (toggle.shown) "Shown" else "Hidden"
            }, contentAlignment = Alignment.Center) { ToolbarGlyph(R.drawable.tablet_toolbar_sidebar) }
    }
}

package dev.yab.browser.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.*

internal data class TabletOmniboxRow(val id: String, val title: String, val detail: String?,
    val end: String, val icon: ImageVector, val action: () -> Unit)

/** The same editor is supplied by Screen's single movable Field. This is an own-root
 * overlay, never an oversized pane child or a second native popup/window. */
@Composable
internal fun BrowserTabletFieldHost(state: BrowserState, controller: BrowserController,
    source: BrowserFieldPlacementLease, viewport: TabletOmniboxViewport, covered: Boolean,
    onMounted: (Boolean) -> Unit, onHeader: ((FieldRect) -> Unit)? = null,
    focusOwner: BrowserFieldInputFocus? = null,
    newTabResting: BrowserTabletNewTabRestingEntry? = null,
    content: @Composable (BrowserState, BrowserFieldPresentation, TabletOmniboxViewport) -> Unit) {
    val input = source.input
    val active = state.surface == BrowserSurface.FIELD && input?.epoch == state.surfaceEpoch
    val interactive = active && !covered && source.current()
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val ownership = focusOwner ?: remember(controller) { BrowserFieldInputFocus() }
    val inputFocus = remember(ownership, source) { ownership.bind() }
    val inputFocused = inputFocus.ownsFocus
    val currentCovered by rememberUpdatedState(covered)
    val restingControl = remember(newTabResting, source, covered, state.fieldResting) {
        if (covered || !state.fieldResting) null else newTabResting?.bind(source) { !currentCovered }
    }
    DisposableEffect(restingControl) { onDispose { restingControl?.retire() } }
    fun clearInput() = inputFocus.clear({ focus.clearFocus(force = true) }, { keyboard?.hide() })
    val close: () -> Unit = {
        if (source.current() && !covered && input != null && controller.dismissField(input.epoch)) {
            clearInput()
        }
    }
    SideEffect { onMounted(active) }
    DisposableEffect(controller) { onDispose { onMounted(false) } }
    DisposableEffect(inputFocus) { onDispose { clearInput() } }
    BackHandler(enabled = active && !covered, onBack = close)
    LaunchedEffect(source, inputFocus, covered, state.fieldResting) {
        if (covered || state.fieldResting || !source.current()) clearInput()
    }
    LaunchedEffect(restingControl, active, state.fieldResting) {
        if (active && state.fieldResting && !covered) restingControl?.perform()
    }
    LaunchedEffect(source, inputFocus, inputFocused, viewport.imeBottom, active) {
        if (active && source.current() && inputFocused) {
            if (viewport.imeBottom > 80) inputFocus.keyboardShown()
            else if (viewport.imeBottom < 1 && !state.fieldResting && input != null && inputFocus.takeKeyboardDismissal())
                controller.restField(input.epoch)
        }
    }
    val geometry = BrowserFieldGeometry(viewport.root.width.coerceAtLeast(80.0), viewport.root.height, 0.0)
    val pose = BrowserFieldPose(geometry, geometry.plate, geometry.stack, 1.0, 1.0, 1.0)
    val headerObserver = LocalTabletOmniboxHeader.current
    CompositionLocalProvider(LocalTabletOmniboxHeader provides { rect -> headerObserver?.invoke(rect); onHeader?.invoke(rect) }) {
        Box(Modifier.fillMaxSize().clipToBounds()
            .then(if (interactive) Modifier else Modifier.clearAndSetSemantics {})
            .drawWithContent { if (source.current() && !covered) drawContent() }) {
            // Keep the editor's composition alive while background/foreground publication
            // rebinds its admission. Stale drawings and accessibility are withheld above.
            content(state, BrowserFieldPresentation(pose, interactive, 1f, 1f, 1f, 1f, close, close, inputFocus = inputFocus), viewport)
        }
    }
}

private val LocalTabletOmniboxHeader = staticCompositionLocalOf<((FieldRect) -> Unit)?> { null }

@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun BrowserTabletOmnibox(viewport: TabletOmniboxViewport, resting: Boolean, showsAddress: Boolean,
    privateInput: Boolean, source: BrowserFieldPlacementLease, interactive: Boolean,
    rows: List<TabletOmniboxRow>, answer: TabletOmniboxRow?,
    input: @Composable (Modifier) -> Unit, close: () -> Unit) {
    val density = LocalDensity.current
    val terminalIme = WindowInsets.imeAnimationTarget.getBottom(density) / density.density.toDouble()
    val target = TabletOmniboxMotionTarget(viewport, terminalIme, resting, rows.size, answer != null,
        showsAddress, density.fontScale.toDouble())
    val motion = remember(source, target.layout) { BrowserTabletOmniboxMotion(target) }
    var pose by remember(motion) { mutableStateOf(motion.value) }
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val animations = android.animation.ValueAnimator.areAnimatorsEnabled()
    LaunchedEffect(motion, terminalIme, resting, reduced, animations) {
        withFrameNanos { now -> motion.target(target, now, reduced, animations); pose = motion.value }
        while (motion.running) withFrameNanos { now -> pose = motion.advance(now) }
    }
    val frame = BrowserTabletOmniboxMotion.clipped(if (animations) pose else target.frame, viewport)
    val visibleBottom = BrowserTabletOmniboxMotion.visibleBottom(viewport) * density.density
    val reportHeader = LocalTabletOmniboxHeader.current
    val controls = interactive && source.current()
    val background = if (privateInput) Color(0xFF212121) else MaterialTheme.colorScheme.surface
    Box(Modifier.fillMaxSize().clipToBounds().drawWithContent {
        clipRect(bottom = visibleBottom.toFloat().coerceIn(0f, size.height)) { this@drawWithContent.drawContent() }
    }) {
        key(source) { Box(Modifier.fillMaxSize().clickable(enabled = controls, onClick = close).testTag("browser.tablet.omnibox.backdrop")) }
        Surface(Modifier.offset(frame.x.dp, frame.y.dp).width(frame.width.dp).testTag("browser.tablet.omnibox"),
            shape = RoundedCornerShape(18.dp), color = background, shadowElevation = 8.dp) {
            Column {
                Row(Modifier.fillMaxWidth().height(52.dp).testTag("browser.tablet.omnibox.header")
                    .onGloballyPositioned { coordinates ->
                        val bounds = coordinates.boundsInRoot()
                        reportHeader?.invoke(FieldRect(bounds.left / density.density.toDouble(), bounds.top / density.density.toDouble(),
                            bounds.width / density.density.toDouble(), bounds.height / density.density.toDouble()))
                    }.padding(end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    key(source.controls) {
                        input(Modifier.weight(1f).height(52.dp))
                        Spacer(Modifier.width(12.dp))
                        key(source) { IconButton(enabled = controls, onClick = close,
                            modifier = Modifier.width(32.dp).height(44.dp).testTag("browser.field.close")) {
                            Icon(YabGlyphs.CrossMedium, "Close Search", Modifier.size(14.dp))
                        } }
                    }
                }
                if (frame.bodyHeight > 0) {
                    Column(Modifier.fillMaxWidth().height(frame.bodyHeight.dp).verticalScroll(rememberScrollState()).padding(6.dp)) {
                        val visible = buildList {
                            if (!showsAddress) answer?.let(::add)
                            if (!showsAddress) addAll(rows.take(if (answer == null) 5 else 4))
                        }
                        visible.forEach { row -> key(source, row.id) {
                            Row(Modifier.fillMaxWidth().height(frame.rowHeight.dp)
                                .clickable(enabled = controls, onClick = { if (source.current()) row.action() })
                                .padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Icon(row.icon, null, Modifier.size(22.dp))
                                Text(row.title, Modifier.weight(1f), fontSize = 13.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                row.detail?.takeIf(String::isNotBlank)?.let { Text(it, Modifier.weight(1f), fontSize = 13.5.sp,
                                    maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                Text(row.end, fontSize = 13.5.sp, maxLines = 1, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        } }
                    }
                }
            }
        }
    }
}

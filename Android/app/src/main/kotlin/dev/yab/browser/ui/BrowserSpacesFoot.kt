package dev.yab.browser.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.FieldAnchor
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserState
import kotlin.math.abs
import kotlin.math.max

/** What a space's page shows (the three dots). */
internal enum class SpacesFilter(val title: String) { EVERYTHING("Everything"), PINS("Pins"), TODAY("Today") }

/** Set over the pages of the spaces at rest: the room their lists keep over the foot bar,
 * which they run on under. Null on the old layouts. */
internal val LocalSpacesFootRoom = staticCompositionLocalOf<Dp?> { null }

@Composable
internal fun browserFootBottom(): Float {
    val density = LocalDensity.current
    return browserChromeBottom(28f, 48f, WindowInsets.tappableElement.getBottom(density) / density.density)
}

private val turnEasing = CubicBezierEasing(.42f, 0f, .58f, 1f)

/** The spaces' foot, in place of a field: Settings, + for the sheet, the blue check back to the
 * page. On Chats: a new chat, the search, the check. One plate in each place; only its glyph
 * turns, through a blur, as the page does. The list runs on under it. */
@Composable
internal fun BrowserSpacesFootBar(chats: Boolean, enabled: Boolean, shown: () -> Float,
    onSettings: () -> Unit, onNewChat: () -> Unit, onPlus: () -> Unit, onSearchChats: () -> Unit, onDone: () -> Unit) {
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val turn by animateFloatAsState(if (chats) 1f else 0f, tween(if (reduced) 0 else 280, easing = turnEasing), label = "foot glyphs")
    val bottom = browserFootBottom().toDouble()
    BoxWithConstraints(Modifier.fillMaxSize().graphicsLayer { alpha = shown() }.testTag("spaces.foot")) {
        val rects = BrowserFootRects(maxWidth.value.toDouble(), maxHeight.value.toDouble(), bottom)
        val ink = MaterialTheme.colorScheme.onSurface
        BrowserFootPlate(rects.left, Modifier.semantics { contentDescription = if (chats) "New Chat" else "Settings" }, enabled = enabled,
            onClick = { if (chats) onNewChat() else onSettings() }) {
            BlurTurn(turn, { Icon(YabGlyphs.SettingsGear1, null, Modifier.align(Alignment.Center).size(22.dp), tint = ink) },
                { Icon(YabGlyphs.MacSquareAndPencil, null, Modifier.align(Alignment.Center).size(22.dp), tint = ink) })
        }
        BrowserFootPlate(rects.center, Modifier.semantics { contentDescription = if (chats) "Search Chats" else "Search" }, enabled = enabled,
            onClick = { if (chats) onSearchChats() else onPlus() }) {
            BlurTurn(turn, { Icon(YabGlyphs.PlusMedium, null, Modifier.align(Alignment.Center).size(22.dp), tint = ink) },
                { Icon(YabGlyphs.MagnifyingGlass, null, Modifier.align(Alignment.Center).size(22.dp), tint = ink) })
        }
        BrowserFootPlate(rects.right, Modifier.semantics { contentDescription = "Done" }, color = BrowserDoneBlue, enabled = enabled, onClick = onDone) {
            Icon(YabGlyphs.Checkmark1, null, Modifier.size(28.dp), tint = Color.White)
        }
    }
}

/** The three dots at the capsule's right, with this page's filters and the quick switch. */
@Composable
internal fun BrowserSpacesMoreMenu(ink: Color, plate: Color, chats: Boolean, archived: Boolean, onArchived: (Boolean) -> Unit,
    filter: SpacesFilter, onFilter: (SpacesFilter) -> Unit, macTabs: Boolean, onMacTabs: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    var open by remember { mutableStateOf(false) }
    fun choice(title: String, chosen: Boolean, action: () -> Unit): @Composable ColumnScope.() -> Unit = {
        DropdownMenuItem(text = { Text(title, fontSize = 17.sp) }, onClick = { open = false; action() },
            modifier = Modifier.widthIn(min = 236.dp), trailingIcon = if (chosen) ({ Icon(YabGlyphs.Checkmark1Small, null, Modifier.size(20.dp)) }) else null)
    }
    Box(modifier) {
        // See-through, so no system shadow: its hollow middle would show as a polygon.
        Surface(Modifier.size(44.dp), shape = CircleShape, color = plate, border = androidx.compose.foundation.BorderStroke(.5.dp, ink.copy(alpha = .12f))) {
            IconButton(onClick = { open = true }, modifier = Modifier.fillMaxSize()) {
                Icon(YabGlyphs.DotGrid1x3Horizontal, "More", Modifier.size(22.dp), tint = ink)
            }
        }
        DropdownMenu(open, { open = false }) {
            if (chats) {
                choice("All Chats", !archived) { onArchived(false) }()
                choice("Archived", archived) { onArchived(true) }()
            } else {
                SpacesFilter.entries.forEach { choice(it.title, it == filter) { onFilter(it) }() }
                HorizontalDivider()
                choice("Your Mac’s Tabs", macTabs) { onMacTabs(!macTabs) }()
            }
        }
    }
}

/** The dot grid under All Tabs and the empty screen. */
@Composable
internal fun BrowserTabGroundDots(dark: Boolean, modifier: Modifier = Modifier) {
    val color = if (dark) Color.White.copy(alpha = .1f) else Color.Black.copy(alpha = .12f)
    Canvas(modifier.fillMaxSize()) {
        val step = 20.dp.toPx()
        val radius = .8.dp.toPx()
        var y = step / 2
        while (y < size.height) {
            var x = step / 2
            while (x < size.width) { drawCircle(color, radius, Offset(x, y)); x += step }
            y += step
        }
    }
}

/** All Tabs' ground: the look's own color, the empty screen's too. */
@Composable
internal fun BrowserTabGround(space: BrowserSpace?, modifier: Modifier = Modifier) {
    val isPrivate = space?.isPrivate == true
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    val paint = remember(space?.look, space?.color, isPrivate) { browserSpaceSurface(space) }
    val wash = BrowserSpacesWash.at(listOf(paint.tint), 0.0, if (isPrivate) 0 else null, dark)
    Box(modifier) {
        BrowserLookSurfaceBackdrop(wash, paint.grain, Modifier.fillMaxSize())
        if (!isPrivate) BrowserTabGroundDots(dark)
    }
}

/** No tabs: All Tabs with its cards gone. The same ground and the same buttons, so the last card
 * closed only takes its card away, and a word over + saying where search is. A tab waiting in
 * the stack keeps the page's bar and its stack. Up from the ground, as from the plate: the spaces. */
@Composable
internal fun BrowserEmptyHome(state: BrowserState, controller: BrowserController, inputCurrent: () -> Boolean,
    onLiftMove: (Double) -> Long?, onLiftEnd: (Long, Double, Double) -> Unit) {
    val density = LocalDensity.current
    val move by rememberUpdatedState(onLiftMove)
    val end by rememberUpdatedState(onLiftEnd)
    val bar = state.emptyHomeBar
    val bottom = browserFootBottom().toDouble()
    val hint = MaterialTheme.colorScheme.onSurfaceVariant
    BoxWithConstraints(Modifier.fillMaxSize().testTag("empty.home")) {
        val rects = BrowserFootRects(maxWidth.value.toDouble(), maxHeight.value.toDouble(), bottom)
        BrowserTabGround(state.space, Modifier.fillMaxSize().pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val tracker = VelocityTracker().apply { addPosition(down.uptimeMillis, down.position) }
                var opened: Long? = null
                var lifting = false
                var dy = 0.0
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    tracker.addPosition(change.uptimeMillis, change.position)
                    dy = (change.position.y - down.position.y) / density.density.toDouble()
                    if (!lifting && dy < -12 && abs(dy) > abs((change.position.x - down.position.x) / density.density.toDouble())) lifting = true
                    if (lifting) { change.consume(); opened = (if (inputCurrent()) move(dy) else null) ?: opened }
                    if (!change.pressed) {
                        if (lifting) opened?.let { end(it, dy, tracker.calculateVelocity().y / density.density.toDouble()) }
                        else if (abs(dy) < 12 && inputCurrent() && controller.state.value.emptyHomeBar) controller.openField(origin = rects.center.let { FieldAnchor(it.x, it.y, it.width, it.height) })
                        break
                    }
                }
            }
        }.clearAndSetSemantics {})
        Column(Modifier.fillMaxWidth().offset(y = (rects.center.y - 14 - 24 - 20).dp)
            .graphicsLayer { alpha = if (state.message == null) 1f else 0f }.clearAndSetSemantics {},
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Tap to search", fontSize = 16.sp, color = hint)
            Icon(YabGlyphs.ArrowUp, null, Modifier.size(13.dp).graphicsLayer { rotationZ = 180f }, tint = hint)
        }
        if (bar) {
            BrowserFootPlate(rects.left, Modifier.semantics { contentDescription = "Settings" },
                onClick = { if (inputCurrent()) controller.show(dev.yab.browser.model.BrowserSurface.SETTINGS) }) {
                Icon(YabGlyphs.SettingsGear1, null, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onSurface)
            }
            BrowserFootPlate(rects.center, Modifier.semantics { contentDescription = "New Tab" },
                onClick = { if (inputCurrent()) controller.openField(origin = rects.center.let { FieldAnchor(it.x, it.y, it.width, it.height) }) }) {
                Icon(YabGlyphs.PlusMedium, null, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}

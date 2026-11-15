package dev.yab.browser.ui

import androidx.compose.animation.core.exponentialDecay
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.AnchoredDraggableState
import androidx.compose.foundation.gestures.DraggableAnchors
import androidx.compose.foundation.gestures.snapTo
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.TabPlace
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs

/** The same edge ownership as the current iPhone's native List. */
internal object BrowserSpaceRowSwipeGeometry {
    fun owns(x: Float, width: Float) = x > 28f && x < width - 28f
}
private enum class RowSwipeAnchor { CLOSED, LEADING, TRAILING, KEEP, CLOSE }

internal class BrowserSpaceRowSwipeScope {
    var page: Rect? = null
    var row by mutableStateOf<String?>(null)
    var reset: (() -> Unit)? = null
    var animation: Job? = null
    var current: (() -> Boolean)? = null
    fun close(): Boolean {
        val wasOpen = row != null
        animation?.cancel(); animation = null
        val originalReset = reset
        row = null; current = null; reset = null
        originalReset?.invoke()
        return wasOpen
    }
}

@Suppress("DEPRECATION")
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun BrowserSpaceRowSwipe(tab: BrowserTab, scope: BrowserSpaceRowSwipeScope?, enabled: Boolean,
    current: () -> Boolean, keep: () -> Unit, pin: () -> Unit, close: () -> Unit, content: @Composable () -> Unit) {
    if (scope == null) { content(); return }
    val density = LocalDensity.current.density
    val keyboard = LocalSoftwareKeyboardController.current
    val coroutine = rememberCoroutineScope()
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    // Measured from the current iPhone's native action frames: equal leading
    // capsules, inline 13-point words, 44-point height and ten-point gaps.
    val leadingWidth = if (tab.place == TabPlace.KEPT) 95.333f else 77.5f
    val leadingReveal = leadingWidth * 2f + 30.333f
    val admitted by rememberUpdatedState(enabled && current())
    val currentAction by rememberUpdatedState(current)
    var coordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    // Foundation owns the anchors, cancellation and settling physics. Only the
    // touchdown router is shared with the surrounding horizontal pager.
    val drag = remember(tab, density, reduced) {
        AnchoredDraggableState(initialValue = RowSwipeAnchor.CLOSED,
            positionalThreshold = { it * .5f }, velocityThreshold = { 450f * density },
            snapAnimationSpec = if (reduced) snap() else spring(dampingRatio = 1f, stiffness = 420f),
            decayAnimationSpec = exponentialDecay())
    }
    val displacement = if (scope.row == tab.id) drag.offset.takeIf { it.isFinite() }?.div(density) ?: 0f else 0f
    fun admittedAction(action: () -> Unit): Boolean {
        if (!admitted || !currentAction() || scope.row != tab.id || scope.current?.invoke() != true) return false
        scope.close(); action(); return true
    }
    fun settle(velocity: Float, cancelled: Boolean) {
        if (scope.row != tab.id) return
        scope.animation?.cancel()
        scope.animation = coroutine.launch {
            if (cancelled) drag.snapTo(RowSwipeAnchor.CLOSED) else drag.settle(velocity * density)
            if (scope.row == tab.id) when (drag.currentValue) {
                RowSwipeAnchor.CLOSED -> scope.close()
                RowSwipeAnchor.KEEP -> if (!admittedAction(keep)) scope.close()
                RowSwipeAnchor.CLOSE -> if (!admittedAction(close)) scope.close()
                else -> Unit
            }
        }
    }
    DisposableEffect(scope, tab) { onDispose { if (scope.row == tab.id) scope.close() } }
    Box(Modifier.fillMaxWidth().onSizeChanged { size ->
        val width = size.width.toFloat()
        if (width > 0f) drag.updateAnchors(DraggableAnchors {
            RowSwipeAnchor.CLOSED at 0f
            if (!tab.isPrivate) {
                RowSwipeAnchor.LEADING at minOf(leadingReveal * density, width * .75f)
                RowSwipeAnchor.KEEP at width
            }
            RowSwipeAnchor.TRAILING at -minOf(103.333f * density, width * .6f)
            RowSwipeAnchor.CLOSE at -width
        })
    }.onGloballyPositioned { coordinates = it }.testTag("browser.row.swipe.${tab.id}")
        .semantics(mergeDescendants = true) {
            if (enabled) customActions = buildList {
                if (!tab.isPrivate) add(CustomAccessibilityAction("Pin") { if (current()) { scope.close(); pin(); true } else false })
                if (!tab.isPrivate) add(CustomAccessibilityAction(if (tab.place == TabPlace.KEPT) "Unkeep" else "Keep") { if (current()) { scope.close(); keep(); true } else false })
                add(CustomAccessibilityAction("Close") { if (current()) { scope.close(); close(); true } else false })
            }
        }
        .then(if (!enabled) Modifier else Modifier.pointerInput(scope, tab, density) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                val original = coordinates?.takeIf { it.isAttached }?.localToRoot(down.position) ?: return@awaitEachGesture
                val page = scope.page ?: return@awaitEachGesture
                if (!admitted || !currentAction() || !BrowserSpaceRowSwipeGeometry.owns((original.x - page.left) / density, page.width / density)) return@awaitEachGesture
                val originalCurrent = currentAction
                val tracker = VelocityTracker().also { it.addPosition(down.uptimeMillis, original) }
                var applied = 0f
                var dragging = false
                var completed = false
                try {
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!admitted || !originalCurrent() || change.isConsumed) break
                        val root = coordinates?.takeIf { it.isAttached }?.localToRoot(change.position) ?: break
                        val dx = (root.x - original.x) / density
                        val dy = (root.y - original.y) / density
                        tracker.addPosition(change.uptimeMillis, root)
                        if (!dragging && (abs(dx) > 8f || abs(dy) > 8f)) {
                            if (abs(dy) >= abs(dx)) break
                            scope.animation?.cancel()
                            if (scope.row != tab.id) scope.close()
                            scope.row = tab.id; scope.current = originalCurrent
                            scope.reset = { coroutine.launch { drag.snapTo(RowSwipeAnchor.CLOSED) }; Unit }
                            keyboard?.hide(); dragging = true
                        }
                        if (dragging) {
                            drag.dispatchRawDelta((dx - applied) * density)
                            applied = dx
                            change.consume()
                        }
                        if (!change.pressed) { completed = true; break }
                    } while (true)
                } finally { if (dragging) settle(tracker.calculateVelocity().x / density, !completed) }
            }
        })) {
        if (displacement != 0f) Box(Modifier.matchParentSize()) {
            val leading = displacement > 0f
            Box(Modifier.align(if (leading) Alignment.CenterStart else Alignment.CenterEnd)
                .offset(x = if (leading) (-6).dp else 6.dp).width(abs(displacement).dp).height(44.dp).clipToBounds()) {
            Row(Modifier.align(if (leading) Alignment.CenterStart else Alignment.CenterEnd), horizontalArrangement = Arrangement.spacedBy(10.333.dp)) {
                if (leading) {
                    BrowserRowSwipeButton(tab.id, if (tab.place == TabPlace.KEPT) "Unkeep" else "Keep", "keep", if (tab.place == TabPlace.KEPT) YabGlyphs.MacAnchor else YabGlyphs.MacYabAnchor, Color(0xFFBB8D53), leadingWidth, admitted) { admittedAction(keep) }
                    BrowserRowSwipeButton(tab.id, "Pin", "pin", YabGlyphs.MacPin, Color(0xFFFF9F0A), leadingWidth, admitted) { admittedAction(pin) }
                } else BrowserRowSwipeButton(tab.id, "Close", "close", YabGlyphs.MacYabTabX, Color(0xFFFF383C), 83.333f, admitted) { admittedAction(close) }
            }
            }
        }
        Box(Modifier.fillMaxWidth().graphicsLayer { translationX = displacement * density }) { content() }
    }
}

@Composable
private fun BrowserRowSwipeButton(tabId: String, title: String, key: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector, fill: Color, width: Float, enabled: Boolean, action: () -> Unit) {
    FilledIconButton(onClick = action, enabled = enabled,
        modifier = Modifier.width(width.dp).height(44.dp).testTag("browser.row.action.$tabId.$key"),
        shape = CircleShape, colors = IconButtonDefaults.filledIconButtonColors(containerColor = fill, contentColor = Color.White)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
            Icon(icon, null, Modifier.size(18.dp))
            Text(title, fontSize = 13.sp, lineHeight = 16.sp, letterSpacing = 0.sp, fontWeight = FontWeight.Normal)
        }
    }
}

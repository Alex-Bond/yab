package dev.yab.browser.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.BrowserTabletWorkspaceFrame
import dev.yab.browser.model.TabletOmniboxRoot
import kotlin.math.abs

/** UI layout only, admitted by the original public PAGE and window scope. */
internal class BrowserTabletResizeSession(val start: Double,
    private val change: (Double, Boolean) -> Boolean, private val abandon: () -> Unit) {
    fun moveTo(value: Double) = change(value, false)
    fun finish(value: Double) = change(value, true)
    fun cancel() = abandon()
}

/** Keep overlay insertions in their own stable layout/composition parent. Page
 * nodes and sidebar subcompositions must not share the handles' removal group. */
@Composable
internal fun BrowserTabletResizeHandles(frame: BrowserTabletWorkspaceFrame?, root: TabletOmniboxRoot?,
    enabled: Boolean, begin: (Boolean) -> BrowserTabletResizeSession?, modifier: Modifier = Modifier) {
    Box(modifier) {
        if (enabled && frame != null && root != null) {
            val sidebar = frame.sidebar
            if (sidebar != null) key("sidebar") {
                BrowserTabletResizeHandle(true, sidebar.width, { begin(true) },
                    Modifier.offset(x = (sidebar.width - 10.0 - root.x).dp, y = (sidebar.y - root.y).dp)
                        .requiredHeight(sidebar.height.dp))
            }
            val divider = frame.divider
            if (divider != null) key("split") {
                BrowserTabletResizeHandle(false, frame.pane(false).width, { begin(false) },
                    Modifier.offset(x = (divider.x + divider.width / 2.0 - 10.0 - root.x).dp,
                        y = (divider.y - root.y).dp).requiredHeight(divider.height.dp))
            }
        }
    }
}

@Composable
internal fun BrowserTabletResizeHandle(sidebar: Boolean, value: Double, begin: () -> BrowserTabletResizeSession?, modifier: Modifier) {
    val label = if (sidebar) "Sidebar Width" else "Split Width"
    val latestBegin by rememberUpdatedState(begin)
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    var coordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var dragging by remember { mutableStateOf(false) }
    Box(modifier.width(20.dp).onGloballyPositioned { coordinates = it }
        .testTag(if (sidebar) "browser.tablet.sidebar.resize" else "browser.tablet.split.resize")
        .semantics {
            contentDescription = label
            stateDescription = value.toInt().toString()
            customActions = listOf(CustomAccessibilityAction("Increase $label") { latestBegin()?.finish(value + 20) == true },
                CustomAccessibilityAction("Decrease $label") { latestBegin()?.finish(value - 20) == true })
        }
        // Stable pointer node: fresh frames must not replace an already admitted gesture.
        .pointerInput(sidebar, density) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val original = coordinates?.takeIf { it.isAttached }?.localToRoot(down.position) ?: return@awaitEachGesture
                val session = latestBegin() ?: return@awaitEachGesture
                var distance = 0.0
                var moved = false
                var finished = false
                try {
                    do {
                        val event = awaitPointerEvent()
                        val point = event.changes.firstOrNull { it.id == down.id } ?: break
                        val root = coordinates?.takeIf { it.isAttached }?.localToRoot(point.position) ?: break
                        distance = ((root.x - original.x) / density).toDouble()
                        if (abs(distance) >= 1.0 || moved) {
                            moved = true; dragging = true
                            if (point.pressed) {
                                if (!session.moveTo(session.start + distance)) break
                            } else if (!point.isConsumed) {
                                finished = session.finish(session.start + distance)
                            }
                            point.consume()
                        }
                        if (!point.pressed) break
                    } while (true)
                } finally { if (!finished) session.cancel(); dragging = false }
            }
        }, contentAlignment = Alignment.Center) {
        Box(Modifier.width(3.dp).height(32.dp).background(MaterialTheme.colorScheme.onSurface.copy(alpha = if (dragging) .45f else .2f), CircleShape))
    }
}

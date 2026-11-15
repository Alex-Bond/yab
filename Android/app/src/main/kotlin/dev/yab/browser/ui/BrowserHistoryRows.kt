package dev.yab.browser.ui

import android.animation.ValueAnimator
import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import dev.yab.browser.model.*
import java.text.DateFormat
import java.util.Date
import kotlin.math.*

internal val LocalHistoryRowAnimationsEnabled = staticCompositionLocalOf<Boolean?> { null }
internal val HistoryRowOffsetKey = SemanticsPropertyKey<Float>("HistoryRowOffset")
internal val HistoryRowDeletingKey = SemanticsPropertyKey<Boolean>("HistoryRowDeleting")

/** Only a rejected touch's UP dispatch is gated; semantic/key actions stay independent. */
private class HistoryRowPointerClick { var blocked = false }

/** Immutable callbacks belong to this captured outer lease; never borrowed by a new host. */
internal class BrowserHistoryRows(
    val current: () -> Boolean,
    val accepts: (HistoryRowPresentationLease) -> Boolean,
    val open: (HistoryRowPresentationLease) -> Boolean,
    val delete: (HistoryRowPresentationLease) -> Boolean,
) {
    val motion = HistoryRowMotion()
    fun admitted(source: HistoryRowPresentationLease) = current() && accepts(source)
    fun reconcile() = motion.reconcile(current()) { source, visit ->
        (source as? HistoryRowPresentationLease)?.let { it.visit == visit && admitted(it) } == true
    }
    fun tap(source: HistoryRowPresentationLease): Boolean {
        if (!admitted(source)) return false
        return if (motion.tap()) open(source) else true
    }
    fun remove(source: HistoryRowPresentationLease): Boolean {
        if (!admitted(source)) return false
        motion.close(); return delete(source)
    }
    fun frame(now: Long) {
        val completed = motion.advance(now, current()) { source, visit ->
            (source as? HistoryRowPresentationLease)?.let { it.visit == visit && admitted(it) } == true
        }
        // No suspension or fresh lease capture between the old completion and its action.
        for (ticket in completed) (ticket.source as? HistoryRowPresentationLease)?.let { original ->
            if (original.visit == ticket.visit && admitted(original)) delete(original)
        }
    }
}

@Composable
internal fun HistoryRowsClock(rows: BrowserHistoryRows) {
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val animations = LocalHistoryRowAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()
    val frame by rows.motion.frame.collectAsState()
    SideEffect { rows.motion.configure(reduced, animations); rows.reconcile() }
    DisposableEffect(rows) { onDispose { rows.motion.revoke() } }
    LaunchedEffect(rows, frame.running) {
        while (rows.motion.frame.value.running) rows.frame(withFrameNanos { it })
    }
}

@Composable
internal fun BrowserHistoryRow(source: HistoryRowPresentationLease, rows: BrowserHistoryRows, first: Boolean, last: Boolean,
    time: DateFormat, modifier: Modifier = Modifier) {
    val frame by rows.motion.frame.collectAsState()
    val pose = frame.rows[source.visit.identity] ?: HistoryRowPose(0.0)
    val visit = source.visit
    val density = LocalDensity.current
    val view = LocalView.current
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    val group = if (dark) Color(0xFF2C2C2E) else Color.White
    val ink = if (dark) Color.White else Color(0xFF1C1C1E)
    val secondary = if (dark) Color(0xFFEBEBF5).copy(alpha = .72f) else Color(0xFF3C3C43).copy(alpha = .72f)
    val shape = RoundedCornerShape(topStart = if (first) 16.dp else 0.dp, topEnd = if (first) 16.dp else 0.dp,
        bottomStart = if (last) 16.dp else 0.dp, bottomEnd = if (last) 16.dp else 0.dp)
    val card = pose.x < -4
    val title = visit.title.takeIf(String::isNotBlank) ?: visit.host
    val label = listOfNotNull(title, visit.host, visit.syncedDevice?.let { "on Another device" }, time.format(Date(visit.visitedAt))).joinToString(", ")
    val pressedSource = remember(source) { MutableInteractionSource() }
    val pressed by pressedSource.collectIsPressedAsState()
    val pointerClick = remember(source, rows) { HistoryRowPointerClick() }
    DisposableEffect(pointerClick) { onDispose { pointerClick.blocked = false } }
    var coordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var cardCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    val animations = LocalHistoryRowAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()
    val capsule by animateDpAsState(if (-pose.x > 250) 300.dp else 96.dp,
        tween(if (!animations) 0 else 250, easing = BrowserMotion.easeOut), label = "history.delete.capsule")
    Box(modifier.fillMaxWidth().testTag("history.pan.${visit.identity}").background(group, shape).zIndex(if (card) 1f else 0f)
        .onGloballyPositioned { coordinates = it }
        .pointerInput(source, rows) {
            fun root(point: Offset): Offset? = coordinates?.takeIf { it.isAttached }?.localToRoot(point)?.takeIf { it.x.isFinite() && it.y.isFinite() }
            awaitEachGesture {
                val down = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.pressed && !it.previousPressed } ?: return@awaitEachGesture
                if (down.isConsumed || !rows.admitted(source)) return@awaitEachGesture
                val start = root(down.position) ?: return@awaitEachGesture
                // The source pan belongs to the translated row, not the exposed Delete capsule.
                if (cardCoordinates?.takeIf { it.isAttached }?.boundsInRoot()?.contains(start) != true) return@awaitEachGesture
                val tracker = VelocityTracker(); tracker.addPosition(down.uptimeMillis, start)
                var previousPoint = start
                var previousTime = down.uptimeMillis
                var ticket: HistoryRowTicket? = null
                var rejected = false
                var rejectedHorizontal = false
                try {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val change = event.changes.singleOrNull { it.id == down.id }
                        if (change == null || event.changes.count { it.pressed } > 1 || change.isConsumed || !rows.admitted(source)) break
                        val point = root(change.position) ?: break
                        tracker.addPosition(change.uptimeMillis, point)
                        val delta = (point - start) / density.density
                        val tracked = tracker.calculateVelocity()
                        // Two physical samples may not yet fit the tracker polynomial. Use only
                        // their observed displacement/time, never a guessed speed or end point.
                        val dt = change.uptimeMillis - previousTime
                        val sampled = if (dt > 0) (point - previousPoint) * (1000f / dt) else Offset.Zero
                        val vx = (if (tracked.x == 0f && tracked.y == 0f) sampled.x else tracked.x) / density.density.toDouble()
                        val vy = (if (tracked.x == 0f && tracked.y == 0f) sampled.y else tracked.y) / density.density.toDouble()
                        previousPoint = point; previousTime = change.uptimeMillis
                        if (ticket == null && !rejected && hypot(delta.x, delta.y) >= viewConfiguration.touchSlop / density.density) {
                            if (rows.motion.canStart(visit, delta.x.toDouble(), delta.y.toDouble(), vx, vy))
                                ticket = rows.motion.begin(source, visit)
                            else rejected = true
                        }
                        if (rejected && hypot(delta.x, delta.y) >= viewConfiguration.touchSlop / density.density &&
                            abs(vx) + abs(delta.x) > abs(vy) + abs(delta.y)) rejectedHorizontal = true
                        val held = ticket
                        if (held != null) {
                            val wasFull = -(rows.motion.frame.value.rows[visit.identity]?.x ?: 0.0) > HistoryRowMotion.ACT
                            rows.motion.move(held, delta.x.toDouble())
                            if (!wasFull && -(rows.motion.frame.value.rows[visit.identity]?.x ?: 0.0) > HistoryRowMotion.ACT && rows.admitted(source))
                                view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                            change.consume()
                        }
                        if (!change.pressed) {
                            if (held != null) { rows.motion.release(held, vx); ticket = null }
                            if (rejected) {
                                // A first jump on UP has no prior MOVE to cancel the child click.
                                // Clickable invokes its pointer callback in Main, before Final.
                                pointerClick.blocked = true
                                awaitPointerEvent(PointerEventPass.Final)
                                pointerClick.blocked = false
                            }
                            break
                        }
                        if (rejectedHorizontal) {
                            // Ancestors see this rejected MOVE in Main before the child's click
                            // learns about cancellation in Final. Vertical scrolling is untouched.
                            val final = awaitPointerEvent(PointerEventPass.Final)
                            if (rows.admitted(source)) final.changes.singleOrNull { it.id == down.id }?.consume()
                        }
                    }
                } finally { pointerClick.blocked = false; ticket?.let(rows.motion::cancel) }
            }
        }) {
        if (card) Box(Modifier.align(Alignment.CenterEnd).padding(end = 8.dp).heightIn(min = 44.dp)
            .clickable(enabled = rows.admitted(source) && frame.open == visit.identity && !pose.deleting, role = Role.Button,
                interactionSource = remember(source) { MutableInteractionSource() }, indication = null, onClick = { rows.remove(source) })
            .testTag("history.swipe.delete.${visit.identity}").semantics { contentDescription = "Delete $title" }, contentAlignment = Alignment.Center) {
            Row(Modifier.width(capsule).height(36.dp).clip(RoundedCornerShape(50)).background(Color(0xFFFF3B30)),
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
                Icon(YabGlyphs.TrashCan, null, Modifier.size(19.dp), tint = Color.White)
                Text("Delete", color = Color.White, fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold)
            }
        }
        Row(Modifier.fillMaxWidth().offset { IntOffset((pose.x * density.density).roundToInt(), 0) }
            .onGloballyPositioned { cardCoordinates = it }
            .then(if (card) Modifier.dropShadow(RoundedCornerShape(22.dp), Shadow(radius = 9.dp,
                color = Color.Black.copy(alpha = .18f), offset = DpOffset(0.dp, 6.dp))) else Modifier)
            .background(group, if (card) RoundedCornerShape(22.dp) else shape)
            .clickable(enabled = rows.admitted(source) && !pose.deleting, interactionSource = pressedSource, indication = null, role = Role.Button,
                onClick = { if (!pointerClick.blocked) rows.tap(source) })
            .testTag("history.row.${visit.identity}")
            .semantics(mergeDescendants = true) {
                contentDescription = label
                this[HistoryRowOffsetKey] = pose.x.toFloat(); this[HistoryRowDeletingKey] = pose.deleting
                customActions = listOf(CustomAccessibilityAction("Delete") { rows.remove(source) })
            }.heightIn(min = with(density) { 60.sp.toDp() }), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.fillMaxWidth()) {
                Row(Modifier.fillMaxWidth().clip(shape)
                    .background(if (pressed) Color(0xFF767680).copy(alpha = if (dark) .24f else .12f) else Color.Transparent)
                    .heightIn(min = with(density) { 60.sp.toDp() }).padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    BrowserFavicon(remember(visit) { BrowserTab("history:${visit.identity}", url = visit.url, title = visit.title, createdAt = visit.visitedAt) }, 28.dp, loads = true)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(title, color = ink, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(visit.host, Modifier.weight(1f, fill = false), color = secondary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                            if (visit.syncedDevice != null) {
                                Text("·", color = secondary, fontSize = 13.sp)
                                Icon(YabGlyphs.MacYabLaptopRight, null, Modifier.size(13.dp), tint = secondary)
                                Text("Another device", color = secondary, fontSize = 13.sp, maxLines = 1)
                            }
                        }
                    }
                    Text(time.format(Date(visit.visitedAt)), color = secondary, fontSize = 13.sp, fontFamily = FontFamily.Monospace, maxLines = 1)
                }
                if (!first && !card) HorizontalDivider(Modifier.align(Alignment.TopStart).padding(start = 52.dp), thickness = .5.dp,
                    color = if (dark) Color(0xFF545458).copy(alpha = .45f) else Color(0xFF3C3C43).copy(alpha = .16f))
            }
        }
    }
}

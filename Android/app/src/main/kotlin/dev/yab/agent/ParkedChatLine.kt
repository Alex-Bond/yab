package dev.yab.agent

import dev.yab.browser.ui.YabGlyphs

import android.animation.ValueAnimator
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.yab.browser.ui.LocalBrowserAccessibility
import kotlinx.coroutines.CancellationException
import kotlin.math.abs
import kotlin.math.hypot

/** Fixture-only override; null honors the person's actual system animator preference. */
internal val LocalParkedLineAnimationsEnabled = staticCompositionLocalOf<Boolean?> { null }
internal val ParkedLinePoseKey = SemanticsPropertyKey<List<Float>>("ParkedLinePose")
/** Controlled fixtures observe actual draw callbacks, never infer presented/iOS frame equivalence. */
internal val LocalParkedLineDrawObserver = staticCompositionLocalOf<((ParkedLineFrame, Rect, Long) -> Unit)?> { null }

@Composable
internal fun ParkedChatLine(chat: AgentChat, presentation: ParkedChatPresentation, ownerCurrent: () -> Boolean,
    onRestore: () -> Unit, onLetGo: () -> Unit) {
    val density = LocalDensity.current.density
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val animations = LocalParkedLineAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()
    val frame by presentation.frame.collectAsState()
    // A previous coroutine retains its own callback cells when a new generation
    // reuses this composition location. It can never borrow the replacement's action.
    var current by remember(presentation) { mutableStateOf(ownerCurrent) }
    var restore by remember(presentation) { mutableStateOf(onRestore) }
    var letGo by remember(presentation) { mutableStateOf(onLetGo) }
    var reduce by remember(presentation) { mutableStateOf(reduced) }
    var animate by remember(presentation) { mutableStateOf(animations) }
    SideEffect { current = ownerCurrent; restore = onRestore; letGo = onLetGo; reduce = reduced; animate = animations }
    val observer = LocalParkedLineDrawObserver.current
    var bounds by remember(presentation) { mutableStateOf(Rect.Zero) }
    fun complete() {
        if (current() && presentation.claimCompletion()) letGo()
    }
    fun dismiss() {
        if (!current()) { presentation.revoke(); return }
        presentation.leave(1.0, System.nanoTime(), reduce, animate)
        complete()
    }
    // Recheck before the first draw, including an account/privacy change before collection catches up.
    if (!ownerCurrent() || frame.phase == ParkedLinePhase.REVOKED) {
        SideEffect { presentation.revoke() }
        return
    }
    DisposableEffect(presentation) {
        onDispose { if (!current()) presentation.revoke() }
    }
    LaunchedEffect(presentation, frame.running) {
        while (presentation.frame.value.running) {
            withFrameNanos { now ->
                if (!current()) presentation.revoke()
                else { presentation.advance(now); complete() }
            }
        }
    }
    // The gesture target stays still while its child follows the finger. Pointer coordinates
    // and VelocityTracker therefore share one physical/root frame, in logical points per second.
    Box(Modifier.fillMaxWidth().testTag("chats.now").onGloballyPositioned { bounds = it.boundsInWindow() }
        .semantics {
            this[ParkedLinePoseKey] = listOf(frame.offset.toFloat(), frame.opacity.toFloat(), frame.velocity.toFloat(), frame.phase.ordinal.toFloat())
            customActions = listOf(CustomAccessibilityAction("Let Go") {
                if (current() && presentation.frame.value.interactive) { dismiss(); true } else false
            })
        }.pointerInput(presentation, density) {
            try {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    if (!current() || !presentation.frame.value.interactive) return@awaitEachGesture
                    val tracker = VelocityTracker().apply { addWindowChange(down) }
                    var dragging = false
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Main)
                        val change = event.changes.firstOrNull { it.id == down.id }
                        if (!current()) { presentation.revoke(); break }
                        if (change == null || change.isConsumed) {
                            if (dragging) presentation.cancel(System.nanoTime(), reduce, animate)
                            break
                        }
                        tracker.addWindowChange(change)
                        val delta = change.position - down.position
                        if (!change.pressed) {
                            if (dragging) {
                                presentation.release(tracker.calculateVelocity().x / density.toDouble(), System.nanoTime(), reduce,
                                    animate)
                                complete()
                            }
                            break
                        }
                        if (!dragging && hypot(delta.x.toDouble(), delta.y.toDouble()) / density >= ParkedChatPresentation.minimum && abs(delta.x) > abs(delta.y))
                            dragging = presentation.beginDrag(System.nanoTime())
                        if (dragging) { change.consume(); presentation.drag(delta.x / density.toDouble()) }
                    }
                }
            } catch (cancelled: CancellationException) {
                if (current()) presentation.cancel(System.nanoTime(), reduce, animate) else presentation.revoke()
                throw cancelled
            }
        }.drawWithContent { if (current()) { drawContent(); observer?.invoke(frame, bounds, System.nanoTime()) } }) {
        Surface(Modifier.fillMaxWidth().graphicsLayer {
            translationX = (frame.offset * density).toFloat(); alpha = frame.opacity.toFloat()
        }, shape = RoundedCornerShape(24.dp), shadowElevation = 4.dp, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f).clickable(enabled = frame.interactive) { if (current()) restore() }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(if (chat.ephemeral && chat.messages.lastOrNull { it.role == MessageRole.ASSISTANT }?.origin == AnswerOrigin.DEVICE)
                        YabGlyphs.Sparkle else YabGlyphs.ChatBubble7, null)
                    Column(Modifier.weight(1f)) {
                        Text("Now", style = MaterialTheme.typography.labelSmall)
                        Text(chat.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                IconButton(enabled = frame.interactive, onClick = ::dismiss) { Icon(YabGlyphs.CrossMedium, "Let Go") }
            }
        }
    }
}

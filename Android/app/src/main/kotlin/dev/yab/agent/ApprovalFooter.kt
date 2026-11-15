package dev.yab.agent

import dev.yab.browser.ui.YabGlyphs

import android.animation.ValueAnimator
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.ui.LocalBrowserAccessibility

/** Visual only. Every action rechecks the original consumer admission before invocation. */
@Composable
internal fun ApprovalFooter(owner: Any, model: ApprovalFooterPresentation, site: String, enabled: Boolean,
    current: () -> Boolean, invoke: () -> Unit) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    val ink = if (dark) Color(0xFFF2F2F7) else Color(0xFF161615)
    val onInk = if (dark) Color.Black else Color.White
    val gray = (if (dark) Color(0xFFEBEBF5) else Color(0xFF3C3C43)).copy(alpha = .6f)
    val animations = ValueAnimator.areAnimatorsEnabled()
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        if (model.accounts) Text(if (model.phase == ApprovalFooterPhase.READY) "Tap an account to sign in" else "",
            Modifier.height(20.dp).testTag("approval.accounts.hint"), color = gray, fontSize = 13.sp)
        else key(owner, enabled) {
            // Clickable's saved semantics action reads its node's mutable onClick. Give
            // each rendered action its own node and immutable, disposable callback.
            val control = remember { ApprovalFooterControl(enabled, current, invoke) }
            DisposableEffect(control) { onDispose { control.dispose() } }
            val interaction = remember { MutableInteractionSource() }
            val pressed by interaction.collectIsPressedAsState()
            Box(Modifier.fillMaxWidth().height(50.dp)
                .graphicsLayer { alpha = if (pressed) .82f else 1f }
                .clip(RoundedCornerShape(50)).background(if (model.success) Color(0xFF33C759) else ink)
                .clickable(enabled = enabled, role = Role.Button, interactionSource = interaction, indication = null) {
                    control.invoke()
                }.testTag("approval.yes").semantics {
                    contentDescription = model.label
                    stateDescription = model.phase.name.lowercase()
                }, contentAlignment = Alignment.Center) {
                val color = if (model.success) Color.White else onInk
                when (model.phase) {
                    ApprovalFooterPhase.SENDING -> {
                        val drawn = remember(owner, model.phase) { Animatable(0f) }
                        LaunchedEffect(owner, model.phase, reduced, animations) {
                            if (!animations) drawn.snapTo(1f)
                            else drawn.animateTo(1f, tween(if (reduced) 200 else 600,
                                easing = if (reduced) CubicBezierEasing(.42f, 0f, .58f, 1f) else CubicBezierEasing(.4f, 0f, .2f, 1f)))
                        }
                        Canvas(Modifier.size(24.dp).testTag("approval.sending")) {
                            drawArc(color, -90f, 360f * drawn.value, false,
                                style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round))
                        }
                    }
                    ApprovalFooterPhase.PAYING -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        val turn = if (animations) {
                            val transition = rememberInfiniteTransition(label = "approval.paying")
                            val value by transition.animateFloat(0f, 360f,
                                infiniteRepeatable(tween(900, easing = LinearEasing)), label = "approval.paying.turn")
                            value
                        } else 0f
                        Canvas(Modifier.size(18.dp)) {
                            drawArc(color, turn, 360f * .28f, false, style = Stroke(2.4.dp.toPx(), cap = StrokeCap.Round))
                        }
                        Text("Paying on $site", Modifier.testTag("approval.paying"), color = color,
                            fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    }
                    ApprovalFooterPhase.PAID, ApprovalFooterPhase.DONE -> Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(YabGlyphs.Checkmark1Small, null, Modifier.size(16.dp), tint = color)
                        Text(if (model.phase == ApprovalFooterPhase.PAID) "Paid" else "Done", Modifier.testTag("approval.completed"),
                            color = color, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    }
                    else -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        // Android's device proof can be a credential or biometric; do not claim
                        // Face ID/Touch ID from a generic successful-capability check.
                        if (model.proof) Icon(YabGlyphs.Lock, null, Modifier.size(20.dp).testTag("approval.proof"), tint = color)
                        Text(model.label, color = color, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
        if (model.reserveLine) Text(model.line.ifEmpty { " " }, Modifier.heightIn(min = 18.dp).testTag("approval.footLine"),
            color = if (model.warning) Color(0xFFFF3B30) else gray, fontSize = 13.sp,
            maxLines = 2, textAlign = TextAlign.Center)
    }
}

/** Only this keyed control's original admission/callback survives a semantics capture. */
private class ApprovalFooterControl(private val enabled: Boolean, private val current: () -> Boolean,
    private val action: () -> Unit) {
    private var disposed = false
    fun dispose() { disposed = true }
    fun invoke() { if (!disposed && enabled && current()) action() }
}

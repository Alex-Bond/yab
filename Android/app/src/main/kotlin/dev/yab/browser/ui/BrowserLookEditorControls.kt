package dev.yab.browser.ui

import android.animation.ValueAnimator
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.*
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import dev.yab.browser.model.BrowserLookPresets
import dev.yab.browser.model.BrowserSpaceLook
import kotlin.math.roundToInt

/** The source's plain press, without Material ripple. Only drawing samples are animated;
 * the original callback still passes its captured editor lease at the moment of action. */
@Composable
internal fun LookEditorPressButton(owner: Any, enabled: Boolean = true, current: () -> Boolean,
    label: String, tag: String, plate: Boolean, modifier: Modifier = Modifier,
    selected: Boolean? = null, onClick: () -> Unit, content: @Composable () -> Unit) {
    val interactions = remember(owner) { MutableInteractionSource() }
    val pressed by interactions.collectIsPressedAsState()
    val press = remember(owner) { BrowserLookEditorPress() }
    val pose by press.frame.collectAsState()
    val animated = !LocalBrowserAccessibility.current.reduceMotion && ValueAnimator.areAnimatorsEnabled()
    SideEffect { press.target(pressed && enabled && current(), animated) }
    LaunchedEffect(press, pose.running) {
        while (press.frame.value.running) withFrameNanos { press.onFrame(it) }
    }
    val amount = pose.amount.toFloat().coerceIn(0f, 1f)
    val foreground = if (plate) MaterialTheme.colorScheme.onSurface.copy(alpha = .72f + .28f * amount)
        else LocalContentColor.current
    Box(modifier.heightIn(min = 44.dp).then(if (plate) Modifier.width(44.dp) else Modifier)
        .clickable(interactionSource = interactions, indication = null, enabled = enabled,
            role = Role.Button, onClick = { if (current()) onClick() })
        .testTag(tag).semantics {
            contentDescription = label
            selected?.let { this.selected = it }
        }, contentAlignment = Alignment.Center) {
        val scale = 1f - (if (plate) .06f else .08f) * amount
        Box(Modifier.graphicsLayer { scaleX = scale; scaleY = scale }
            .then(if (plate) Modifier.size(24.dp)
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = .1f * amount), RoundedCornerShape(8.dp))
                else Modifier)
            .graphicsLayer { alpha = if (plate && !enabled) .72f else 1f },
            contentAlignment = Alignment.Center) {
            CompositionLocalProvider(LocalContentColor provides foreground) { content() }
        }
    }
}

/** Explicit source selection/page springs. Native predictedEndTranslation and exact
 * matchedGeometry rendering are not substituted with a guessed drag predictor here. */
@Composable
internal fun LookEditorPresetRow(owner: Any, page: Int, selected: Pair<Int, Int>?, frame: LookEditorFrame,
    current: () -> Boolean, slide: (Int) -> Unit, pick: (Int, Int, BrowserLookPresets.Preset) -> Unit) {
    val density = LocalDensity.current
    var track by remember(owner) { mutableIntStateOf(0) }
    val ink = MaterialTheme.colorScheme.onSurface
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("space.look.presets")) {
        LookEditorPressButton(owner, page > 0, current, "Previous Colors", "space.look.presets.back", true,
            onClick = { slide(-1) }) { Text("‹", fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
        Box(Modifier.weight(1f).height(44.dp).onSizeChanged { track = it.width }.clipToBounds()
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                val fade = (3.dp.toPx() / size.width.coerceAtLeast(1f)).coerceAtMost(.5f)
                drawRect(Brush.horizontalGradient(0f to Color.Transparent, fade to Color.Black,
                    1f - fade to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
            }) {
            frame.ring?.let { position ->
                Box(Modifier.offset { IntOffset(((position - frame.page) * track - 14.dp.toPx()).roundToInt(), 8.dp.roundToPx()) }
                    .size(28.dp).border(2.dp, ink, CircleShape))
            }
            if (track > 0) BrowserLookPresets.pages.forEachIndexed { p, presets ->
                Row(Modifier.width(with(density) { track.toDp() })
                    .offset { IntOffset(((p - frame.page) * track).roundToInt(), 0) }
                    .then(if (p == page) Modifier else Modifier.clearAndSetSemantics {})) {
                    presets.forEachIndexed { index, preset ->
                        val colors = (listOf(preset.main) + preset.colors.reversed()).map { Color(it) }
                        val chosen = frame.chosen[BrowserLookEditorMotion.id(p to index)] ?: 0.0
                        LookEditorPressButton(owner, p == page, current, BrowserSpaceLook.hex(preset.main),
                            "space.look.preset.$p.$index", false, Modifier.weight(1f), selected == (p to index),
                            onClick = { if (p == page) pick(p, index, preset) }) {
                            Box(Modifier.size(20.dp).graphicsLayer {
                                scaleX = (1 - .18 * chosen).toFloat(); scaleY = scaleX
                            }.background(Brush.linearGradient(if (colors.size == 1) colors + colors else colors), CircleShape)
                                .border(1.5.dp, Color.Black.copy(alpha = .12f), CircleShape))
                        }
                    }
                }
            }
        }
        LookEditorPressButton(owner, page < BrowserLookPresets.pages.lastIndex, current, "More Colors", "space.look.presets.more", true,
            onClick = { slide(1) }) { Text("›", fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
    }
}

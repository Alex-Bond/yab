package dev.yab.browser.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.channels.Channel
import kotlin.math.*

/** Current CardCapsule's shared lens/track geometry. Android's material drawing and native
 * font still require paired capture; this is not an implementation of iOS Liquid Glass. */
@Composable
internal fun BrowserSpaceCapsule(
    names: List<String>, current: Int, position: Double, dark: Boolean,
    onPick: (Int) -> Unit, onAbout: () -> Unit, onSettings: () -> Unit,
    modifier: Modifier = Modifier,
    onSheetDrag: (dy: Double, ended: Boolean, velocity: Double) -> Unit = { _, _, _ -> },
    onSheetCancel: () -> Unit = {},
    onSelectionTick: () -> Unit = {},
    privateDarkness: Float = if (dark) 1f else 0f,
    /** The three dots at the right, in place of the gear (it moved to the foot). */
    more: (@Composable (Modifier, Color, Color) -> Unit)? = null,
) {
    if (names.isEmpty()) return
    val density = LocalDensity.current
    val measurer = rememberTextMeasurer()
    val textStyle = TextStyle(fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.155).sp)
    val widths = remember(names, density.density, density.fontScale, measurer) {
        names.map { ceil(with(density) { measurer.measure(it, textStyle).size.width.toDp().value.toDouble() } * 10) / 10 + 28 }
    }
    val pick by rememberUpdatedState(onPick)
    val sheetDrag by rememberUpdatedState(onSheetDrag)
    val sheetCancel by rememberUpdatedState(onSheetCancel)
    val selectionTick by rememberUpdatedState(onSelectionTick)
    val visibleIndex by rememberUpdatedState(current)
    val inputObserver by rememberUpdatedState(LocalBrowserSpacesInputObserver.current)
    BoxWithConstraints(modifier.fillMaxWidth().height(50.dp).testTag("browser.spaces.capsule")) {
        val width = maxWidth.value.toDouble()
        val rest = min(246.0, width - 160).coerceAtLeast(1.0)
        val wide = max(rest, min(362.0, width - 24))
        val model = remember(widths, width) { BrowserSpaceCapsuleModel(widths, current, width / 2, rest, wide, names.size == 2) }
        var pose by remember(model) { mutableStateOf(model.pose) }
        val wake = remember(model) { Channel<Unit>(Channel.CONFLATED) }
        var origin by remember { mutableStateOf(Offset.Zero) }
        fun run() { pose = model.pose; wake.trySend(Unit) }
        fun choose(event: BrowserSpaceCapsuleModel.Event?) {
            when (event) {
                is BrowserSpaceCapsuleModel.Event.Tap -> pick(event.index)
                is BrowserSpaceCapsuleModel.Event.Release -> pick(event.index)
                BrowserSpaceCapsuleModel.Event.PressCurrent, null -> Unit
            }
            run()
        }
        DisposableEffect(wake) { onDispose { wake.close() } }
        LaunchedEffect(model) {
            var lastTicks = model.ticks
            for (ignored in wake) {
                var lastTime = 0L
                while (!model.isSettled) {
                    withFrameNanos { now ->
                        val dt = if (lastTime == 0L) 1.0 / 60 else min(0.05, (now - lastTime).coerceAtLeast(0) / 1e9)
                        lastTime = now
                        model.step(dt)
                        if (model.ticks != lastTicks) { lastTicks = model.ticks; selectionTick() }
                        pose = model.pose
                    }
                }
            }
        }
        LaunchedEffect(model, position) {
            if (!model.isTouched) { model.follow(position, visibleIndex); run() }
        }
        val shade = privateDarkness.coerceIn(0f, 1f)
        val ink = lerp(MaterialTheme.colorScheme.onSurface, Color.White, shade)
        Box(Modifier.fillMaxSize().semantics {
                contentDescription = "Spaces"
                stateDescription = names.getOrNull(current).orEmpty()
                // iOS exposes every name to VoiceOver. Keep all destinations available
                // through TalkBack actions while masked drawing creates no invisible button.
                customActions = names.mapIndexed { index, name -> CustomAccessibilityAction("Switch to $name") { choose(model.select(index)); true } }
                horizontalScrollAxisRange = ScrollAxisRange({ position.toFloat() }, { (names.size - 1).toFloat() })
                scrollBy { x, _ ->
                    val next = (current + if (x >= 0) 1 else -1).coerceIn(names.indices)
                    choose(model.select(next)); true
                }
            }.onGloballyPositioned { origin = it.positionInRoot() }
            .pointerInput(model, density.density) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val start = down.position + origin
                    // Keep this finger's original sheet/source callbacks. A new
                    // composition must not lend it a replacement account or card.
                    val originalSheetDrag = sheetDrag
                    val originalSheetCancel = sheetCancel
                    inputObserver?.invoke(BrowserSpacesInputFrame("capsule-down", x = start.x.toDouble(), y = start.y.toDouble()))
                    val tracker = VelocityTracker()
                    tracker.addPosition(down.uptimeMillis, start)
                    var vertical: Boolean? = null
                    model.down((start.x - origin.x) / density.density.toDouble()); run()
                    var last = down
                    try { do {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        last = change
                        val global = change.position + origin
                        tracker.addPosition(change.uptimeMillis, global)
                        val dx = (global.x - start.x) / density.density
                        val dy = (global.y - start.y) / density.density
                        if (vertical == null && max(abs(dx), abs(dy)) > 8) {
                            vertical = abs(dy) > abs(dx)
                            if (vertical == true) model.cancel()
                        }
                        if (change.pressed) {
                            if (vertical == true) {
                                inputObserver?.invoke(BrowserSpacesInputFrame("capsule-vertical-move", x = global.x.toDouble(), y = global.y.toDouble(), dy = dy.toDouble()))
                                originalSheetDrag(dy.toDouble(), false, 0.0)
                            }
                            else model.move((global.x - origin.x) / density.density.toDouble())
                            if (vertical != null) change.consume()
                            run()
                        } else if (change.isConsumed) {
                            // Compose synthesizes a consumed up-state for a
                            // cancelled stream. It must never commit a release.
                            inputObserver?.invoke(BrowserSpacesInputFrame("capsule-cancel"))
                            if (vertical == true) originalSheetCancel() else model.cancel()
                            run()
                        } else {
                            if (vertical == true) {
                                inputObserver?.invoke(BrowserSpacesInputFrame("capsule-up", x = global.x.toDouble(), y = global.y.toDouble(), dy = dy.toDouble()))
                                originalSheetDrag(dy.toDouble(), true, tracker.calculateVelocity().y / density.density.toDouble())
                            }
                            else choose(model.up((global.x - origin.x) / density.density.toDouble()))
                            run()
                        }
                    } while (last.pressed) }
                    finally {
                        if (model.isTouched) { model.cancel(); run() }
                        if (last.pressed && vertical == true) {
                            inputObserver?.invoke(BrowserSpacesInputFrame("capsule-cancel"))
                            originalSheetCancel()
                        }
                    }
                }
            }) {
            Surface(Modifier.offset { IntOffset(with(density) { pose.left.dp.roundToPx() }, 0) }.width(pose.width.dp).height(50.dp)
                .testTag("browser.spaces.recess"), shape = CircleShape,
                color = Color.Black.copy(alpha = .075f + (.32f - .075f) * shade), border = androidx.compose.foundation.BorderStroke(0.5.dp, Color.White.copy(alpha = .45f + (.07f - .45f) * shade))) {}
            Surface(Modifier.offset { IntOffset(with(density) { (pose.lensCenter - pose.lensWidth / 2).dp.roundToPx() }, with(density) { 3.dp.roundToPx() }) }
                .width(pose.lensWidth.dp).height(44.dp).graphicsLayer {
                    scaleX = (1 + 0.08 * pose.press).toFloat(); scaleY = scaleX
                }.testTag("browser.spaces.lens"), shape = CircleShape,
                color = Color.White.copy(alpha = .42f + (.16f - .42f) * shade)) {}
            Box(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    val left = pose.left.toFloat() * density.density; val cap = pose.width.toFloat() * density.density
                    val clip = Path().apply { addRoundRect(RoundRect(Rect(left, 0f, left + cap, size.height), CornerRadius(size.height / 2))) }
                    clipPath(clip) { this@drawWithContent.drawContent() }
                    val edge = (18f * density.density / cap.coerceAtLeast(1f)).coerceIn(0f, 0.5f)
                    drawRect(Brush.horizontalGradient(0f to if (pose.fadeLeft) Color.Transparent else Color.Black,
                        edge to Color.Black, (1 - edge) to Color.Black, 1f to if (pose.fadeRight) Color.Transparent else Color.Black,
                        startX = left, endX = left + cap), blendMode = BlendMode.DstIn)
                }) {
                names.forEachIndexed { index, name ->
                    val opacity = 1 - 0.55 * min(1.0, abs(index - pose.fraction))
                    val textCenter = pose.trackX + model.centers[index]
                    val textHalf = (widths[index] - 28) / 2
                    val visible = textCenter + textHalf > max(0.0, pose.left) && textCenter - textHalf < min(width, pose.left + pose.width)
                    val nameSemantics = if (visible) Modifier.semantics {
                        contentDescription = name; role = Role.Button; selected = index == current
                        onClick { choose(model.select(index)); true }
                    } else Modifier.clearAndSetSemantics {}
                    Box(Modifier.offset { IntOffset(with(density) { (pose.trackX + model.centers[index] - widths[index] / 2).dp.roundToPx() }, with(density) { 3.dp.roundToPx() }) }
                        .width(widths[index].dp).height(44.dp).then(nameSemantics).testTag("browser.spaces.name.$index"), contentAlignment = Alignment.Center) {
                        Text(name, style = textStyle, color = ink.copy(alpha = opacity.toFloat()), maxLines = 1)
                    }
                }
            }
            Row(Modifier.fillMaxSize().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                val buttons = Modifier.size(44.dp).graphicsLayer { alpha = (1 - pose.side).toFloat() }
                IconButton(onClick = onAbout, enabled = pose.side < 0.5, modifier = buttons.graphicsLayer { translationX = (-12 * pose.side * density.density).toFloat() }) {
                    Image(painterResource(dev.yab.android.R.drawable.spaces_yab_mark), "About Yab", Modifier.size(30.dp).clip(RoundedCornerShape(7.dp)))
                }
                val plate = if (dark) Color.White.copy(alpha = .08f) else Color.White.copy(alpha = .86f)
                if (more != null) more(buttons.graphicsLayer { translationX = (12 * pose.side * density.density).toFloat() }, ink, plate)
                else Surface(buttons.graphicsLayer { translationX = (12 * pose.side * density.density).toFloat() }, shape = CircleShape,
                    color = plate, border = androidx.compose.foundation.BorderStroke(.5.dp, ink.copy(alpha = .12f))) {
                    IconButton(onClick = onSettings, enabled = pose.side < 0.5, modifier = Modifier.fillMaxSize()) {
                        Icon(YabGlyphs.SettingsGear1, "Settings", Modifier.size(22.dp), tint = ink)
                    }
                }
            }
        }
    }
}

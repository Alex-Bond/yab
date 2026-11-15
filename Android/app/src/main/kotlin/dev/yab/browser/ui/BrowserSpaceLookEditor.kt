package dev.yab.browser.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import android.animation.ValueAnimator
import dev.yab.browser.model.*
import kotlin.math.*

/** Current Phone explicit editor springs and original source-bound palette actions.
 * SwiftUI .snappy/implicit raster behavior remains unverified; no animation writes settings. */
@Composable
internal fun BrowserSpaceLookEditor(owner: Any, look: BrowserSpaceLook, current: () -> Boolean,
    change: (BrowserSpaceLook) -> Unit, ended: () -> Unit) {
    var primary by remember(owner) { mutableStateOf(SpaceLookColor.fromRgb(look.primary)) }
    var harmony by remember(owner) { mutableStateOf(SpaceLookHarmony(primary, look.colors)) }
    var held by remember(owner) { mutableStateOf<Int?>(null) }
    var size by remember(owner) { mutableStateOf(IntSize.Zero) }
    var page by remember(owner) { mutableIntStateOf(BrowserLookPresets.place(look)?.first ?: 0) }
    val liveLook by rememberUpdatedState(look)
    // An old pointer/AT closure must never borrow a replacement route's fresh action token.
    val liveCurrent = remember(owner) { current }
    val liveChange = remember(owner) { change }
    val liveEnded = remember(owner) { ended }
    val density = LocalDensity.current.density
    fun targets(): List<LookHandleTarget> = (harmony.colors(primary).mapIndexed { index, c -> index to c } + (-1 to primary))
        .map { (index, c) -> LookHandleTarget(index, c.pointX, c.pointY, c.rgb) }
    val motion = remember(owner) { BrowserLookEditorMotion(targets(), page, BrowserLookPresets.place(look)) }
    val pose by motion.frame.collectAsState()
    val animated = !LocalBrowserAccessibility.current.reduceMotion && ValueAnimator.areAnimatorsEnabled()
    val picked = BrowserLookPresets.place(look)
    SideEffect { motion.configure(animated); motion.selected(picked) }
    DisposableEffect(motion) { onDispose { motion.revoke() } }
    LaunchedEffect(motion, pose.running) {
        while (motion.frame.value.running) withFrameNanos { motion.onFrame(it) }
    }
    LaunchedEffect(owner, look.primary, look.colors) {
        if (held == null && look.primary != primary.rgb) {
            primary = SpaceLookColor.fromRgb(look.primary); harmony = SpaceLookHarmony(primary, look.colors)
            motion.handles(targets(), LookEditorFlight.DIRECT)
        }
    }
    fun publish(flight: LookEditorFlight = LookEditorFlight.DIRECT) {
        if (liveCurrent()) {
            motion.handles(targets(), flight)
            liveChange(liveLook.palette(primary.rgb, harmony.colors(primary).map { it.rgb }))
        }
    }
    fun adjust(index: Int, hue: Double, reach: Double): Boolean {
        if (!liveCurrent()) return false
        if (index < 0) primary = SpaceLookColor(primary.lightness, primary.reach + reach, primary.hue + hue * 2 * PI)
        else if (index in harmony.links.indices) harmony = SpaceLookHarmony(harmony.links.mapIndexed { i, link ->
            if (i == index) link.copy(hue = SpaceLookColor.turn(link.hue + hue * 2 * PI), reach = link.reach + reach) else link
        }) else return false
        publish(); liveEnded(); return true
    }
    val dot = 36 * density
    val fieldHeight = (size.height - 28 * density).coerceAtLeast(dot + 1)
    val travel = Offset((size.width - dot).coerceAtLeast(1f), (fieldHeight - dot).coerceAtLeast(1f))
    fun location(color: SpaceLookColor) = Offset(dot / 2 + color.pointX.toFloat() * travel.x, dot / 2 + color.pointY.toFloat() * travel.y)
    data class PrintedDot(val at: Offset, val color: Color)
    val printedLightness = primary.lightness.coerceIn(.55, .75)
    val lattice = remember(printedLightness, size, density) {
        val made = ArrayList<PrintedDot>()
        if (size.width > 0 && size.height > 0) {
            var y = 5 * density
            while (y < fieldHeight) {
                var x = 5 * density
                while (x < size.width) {
                    val c = SpaceLookColor(printedLightness, 0.0, 0.0).move(
                        ((x - dot / 2) / travel.x).toDouble().coerceIn(0.0, 1.0),
                        ((y - dot / 2) / travel.y).toDouble().coerceIn(0.0, 1.0))
                    made += PrintedDot(Offset(x, y), Color(c.rgb)); x += 10 * density
                }
                y += 10 * density
            }
        }
        made
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.testTag("space.look.editor")) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.fillMaxWidth().aspectRatio(4f / 3).clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = .05f)).onSizeChanged { size = it }
                .pointerInput(owner, size) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = true)
                        if (!liveCurrent() || size.width <= 0) return@awaitEachGesture
                        val drawn = motion.frame.value.handles
                        fun drawnLocation(index: Int) = drawn.first { it.index == index }.let {
                            Offset(dot / 2 + it.x.toFloat() * travel.x, dot / 2 + it.y.toFloat() * travel.y)
                        }
                        val main = drawnLocation(-1)
                        val candidate = if ((down.position - main).getDistance() <= dot / 2) -1 else
                            drawn.filter { it.index >= 0 && (down.position - drawnLocation(it.index)).getDistance() <= 12 * density }
                                .minByOrNull { (down.position - drawnLocation(it.index)).getDistance() }?.index ?: -1
                        val center = if (candidate < 0) main else drawnLocation(candidate)
                        motion.rebase()
                        val grab = if ((down.position - center).getDistance() <= (if (candidate < 0) dot / 2 else 12 * density)) down.position - center else Offset.Zero
                        held = candidate; down.consume()
                        fun move(at: Offset) {
                            if (!liveCurrent()) return
                            val p = at - grab
                            val x = ((p.x - dot / 2) / travel.x).toDouble().coerceIn(0.0, 1.0)
                            val y = ((p.y - dot / 2) / travel.y).toDouble().coerceIn(0.0, 1.0)
                            if (candidate < 0) primary = primary.move(x, y) else harmony = harmony.move(candidate, x, y, primary)
                            publish()
                        }
                        try {
                            move(down.position)
                            while (true) {
                                val event = awaitPointerEvent()
                                val finger = event.changes.singleOrNull { it.id == down.id } ?: break
                                if (!liveCurrent() || event.changes.count { it.pressed } > 1 || finger.isConsumed) break
                                move(finger.position); finger.consume()
                                if (!finger.pressed) { liveEnded(); break }
                            }
                        } finally { held = null }
                    }
                }) {
                Canvas(Modifier.fillMaxSize()) {
                    val lens = location(primary)
                    lattice.forEach {
                        val distance = (it.at - lens).getDistance()
                        val radius = (1.6 + 2.2 * exp(-distance * distance / (2 * (24 * density).pow(2)))).toFloat() * density
                        drawCircle(it.color, radius, it.at)
                    }
                }
                pose.handles.forEach { handle ->
                    val index = handle.index
                    val side = if (index < 0) 36.dp else 24.dp
                    val center = Offset(dot / 2 + handle.x.toFloat() * travel.x, dot / 2 + handle.y.toFloat() * travel.y)
                    Box(Modifier.offset { IntOffset((center.x - side.toPx() / 2).roundToInt(), (center.y - side.toPx() / 2).roundToInt()) }
                        // .snappy(.14) is private SwiftUI physics; retain its literal grabbed scale without claiming that curve.
                        .size(side).graphicsLayer { scaleX = if (held == index) 1.1f else 1f; scaleY = scaleX }
                        .background(Color(handle.color), CircleShape).border(3.dp, Color.White, CircleShape)
                        .testTag(if (index < 0) "space.look.main" else "space.look.link.$index")
                        .semantics {
                            contentDescription = if (index < 0) "Main color" else "Linked color ${index + 1}"
                            stateDescription = BrowserSpaceLook.hex(handle.color)
                            customActions = listOf(CustomAccessibilityAction("Next hue") { adjust(index, .05, 0.0) },
                                CustomAccessibilityAction("Previous hue") { adjust(index, -.05, 0.0) },
                                CustomAccessibilityAction("More color") { adjust(index, 0.0, .05) },
                                CustomAccessibilityAction("Less color") { adjust(index, 0.0, -.05) })
                        })
                }
                // Phone's 24pt plate ends 2pt above the field foot, inside its 44pt touch room.
                Row(Modifier.align(Alignment.BottomCenter).offset(y = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    LookEditorPressButton(owner, harmony.links.isNotEmpty(), liveCurrent, "Remove color", "space.look.remove", true,
                        onClick = { if (liveCurrent() && harmony.links.isNotEmpty()) {
                            harmony = SpaceLookHarmony.suggested(harmony.links.size - 1); publish(LookEditorFlight.LINKS); liveEnded()
                        } }) { Text("−", fontSize = 12.sp, fontWeight = FontWeight.Medium) }
                    LookEditorPressButton(owner, harmony.links.size < 2, liveCurrent, "Add color", "space.look.add", true,
                        onClick = { if (liveCurrent() && harmony.links.size < 2) {
                            harmony = SpaceLookHarmony.suggested(harmony.links.size + 1); publish(LookEditorFlight.LINKS); liveEnded()
                        } }) { Text("+", fontSize = 12.sp, fontWeight = FontWeight.Medium) }
                }
            }
            LookEditorPresetRow(owner, page, picked, pose, liveCurrent,
                slide = { by -> if (liveCurrent()) {
                    page = (page + by).coerceIn(0, BrowserLookPresets.pages.lastIndex); motion.page(page)
                } }, pick = { requestedPage, _, preset -> if (liveCurrent() && requestedPage == page) {
                    primary = SpaceLookColor.fromRgb(preset.main); harmony = SpaceLookHarmony(primary, preset.colors)
                    publish(LookEditorFlight.PRESET); liveEnded()
                } })
        }
        BrowserLookAmountSlider(owner, BrowserLookAmountKind.GRAIN, look.grain,
            current = liveCurrent,
            change = { amount -> if (liveCurrent()) liveChange(liveLook.grain((amount * 20).roundToInt() / 20.0)) },
            ended = liveEnded, modifier = Modifier.fillMaxWidth().height(48.dp).testTag("space.look.grain"))
        val dark = MaterialTheme.colorScheme.background.luminance() < .5f
        Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Drawings", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                if (look.drawings.isNotEmpty()) Text("${(look.drawingsStrength * 100).roundToInt()}%",
                    style = TextStyle(fontSize = 15.sp, fontFeatureSettings = "tnum"),
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("" to "None", "browser" to "Browser", "life" to "Life").forEach { (value, title) ->
                    val chosen = look.drawings == value
                    LookEditorPressButton(owner, current = liveCurrent,
                        label = if (value.isEmpty()) "No drawings" else "$title drawings",
                        tag = "space.look.drawings.${value.ifEmpty { "none" }}", plate = false,
                        modifier = Modifier.weight(1f), selected = chosen, onClick = {
                            if (liveCurrent()) {
                                var next = liveLook.drawings(value)
                                if (value.isNotEmpty() && liveLook.drawings.isEmpty()) next = next.drawingsStrength(.45)
                                liveChange(next); liveEnded()
                            }
                        }) {
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp),
                            horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(8.dp))
                                .border(if (chosen) 2.dp else .5.dp,
                                    MaterialTheme.colorScheme.onSurface.copy(alpha = if (chosen) 1f else .12f), RoundedCornerShape(8.dp))) {
                                BrowserSpaceLookWash(look, dark, Modifier.fillMaxSize())
                                if (value.isNotEmpty()) BrowserSpaceLookDrawings(value, 1.0, look.primary, Modifier.fillMaxSize())
                            }
                            Text(title, fontSize = 12.sp,
                                color = if (chosen) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            if (look.drawings.isNotEmpty()) BrowserLookAmountSlider(owner, BrowserLookAmountKind.DRAWINGS, look.drawingsStrength,
                current = liveCurrent,
                change = { amount -> if (liveCurrent()) liveChange(liveLook.drawingsStrength(amount)) },
                ended = liveEnded, modifier = Modifier.fillMaxWidth().height(48.dp).testTag("space.look.drawings"))
        }
    }
}

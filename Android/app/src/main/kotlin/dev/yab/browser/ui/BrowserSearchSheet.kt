package dev.yab.browser.ui

import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Field/SearchSheet.swift's numbers: search as a low sheet over the page, as wide as the
 * keyboard, the field on top and the omnibox's rows under it. Pulled up, it becomes the
 * spaces, its second height, under the finger; pulled down, it goes. */
internal object SearchSheet {
    const val Top = 16.0
    const val Gap = 8.0
    const val Foot = 14.0
    /** The field and the rows 16 from the screen's sides. */
    const val FieldInset = 16.0
    const val FieldHeight = 48.0
    /** Concentric with the field, which stands FieldInset in from its top and sides. */
    const val Radius = FieldHeight / 2 + FieldInset
    /** The field's magnifier on the rows' icons, its words on their titles. */
    const val FieldLeading = 12
    const val Rows = 5
    const val Line = 46.0
    const val GrabberWidth = 36
    const val GrabberHeight = 5
    const val GrabberTop = 5
    /** Past this share of the way, let go, it opens. */
    const val OpensAt = 0.3f
    const val Flick = 900.0
    const val DragFollow = 0.6f
    const val CloseDistance = 60.0
    const val CloseVelocity = 500.0
    /** The morph, by share of the way: the rows are gone before the spaces come, so two lists
     * never meet; the field turns into the capsule as it rises; the head and the foot bar come last. */
    val RowsOut = .08..0.22
    val SpacesIn = .28..0.45
    val WordsOut = .2..0.36
    val FieldToCapsule = .2..1.0
    /** The head stands lower than its capsule on the way: it comes in only under the field that lands there. */
    val HeadIn = .93..1.0
    val BarIn = .7..1.0
    val FieldOut = .93..1.0
    /** The spaces stand this far low as they come, and fade in under the field this soft. */
    const val SpacesRise = 14.0
    const val SpacesEdge = 26.0
    /** The spaces get built once the sheet has risen, so the first frame of a pull has them. */
    const val SpacesReadyMillis = 350L
    /** A breath of the space's own color on the ground, and the page beside the sheet. */
    const val SpaceTint = .1f
    const val Dim = .3f
    const val PrivateTint = .86f
    const val BlurTurn = 10
    /** Growing out of a control: the ground first, then the rows and the field's words. */
    val GroundIn = .0..0.3
    val RowsIn = .3..0.75
    val WordsIn = .2..0.6
    /** Going up: the words go at once, the ground turns solid for the page to stand on. */
    val LeaveWords = .0..0.4
    val LeaveSolid = .25..0.9
    const val RevealMillis = 170
    /** Where the rising spring stands at 0.6 of its time: the page starts to show from here. */
    const val RevealAt = .89f

    fun body(plain: Boolean) = if (plain) Foot else Rows * Line + Foot
    fun share(e: Double, stretch: ClosedFloatingPointRange<Double>) =
        ((e - stretch.start) / (stretch.endInclusive - stretch.start)).coerceIn(0.0, 1.0)
}

internal data class SearchSheetPose(val expand: Double, val rise: Double, val body: Double,
    /** 0 where it stands, 1 at the screen's top: a new page chosen. */
    val leave: Double = 0.0,
    /** What it grows out of as it rises (the plate, +); null rises from under the screen. */
    val origin: FieldRect? = null) {
    /** How much of the sheet's own ground and rows has come, out of `origin`. */
    fun grown(stretch: ClosedFloatingPointRange<Double>) = if (origin == null) 1.0 else SearchSheet.share(rise, stretch)
}

/** Where the sheet stands: a whole number of dp, in the pane's coordinates. */
internal data class BrowserSheetGeometry(val width: Double, val height: Double, val keyboard: Double,
    val highest: Double, val fieldHeight: Double = SearchSheet.FieldHeight) {
    private fun mix(a: Double, b: Double, t: Double) = a + (b - a) * t
    /** The whole screen's capsule, where the sheet's field lands. */
    val capsule: FieldRect get() {
        val w = min(362.0 - 58 * 2, width - 2 * (12 + 44 + 24)).coerceAtLeast(1.0)
        return FieldRect((width - w) / 2, 12 + highest, w, 50.0)
    }
    /** Where a whole screen's page starts, under the capsule. */
    val restHead get() = 12 + highest + 50 + 6
    /** The sheet's top on its keyboard, before it is pulled. */
    fun sheetTop(p: SearchSheetPose) = height - keyboard - (SearchSheet.Top + fieldHeight + SearchSheet.Gap + p.body)
    /** The finger's way from the sheet to the whole screen: the sheet's top follows it one to one. */
    fun span(p: SearchSheetPose) = max(1.0, sheetTop(p))
    fun top(p: SearchSheetPose) = mix(mix(sheetTop(p), 0.0, p.expand), 0.0, p.leave)
    fun radius(p: SearchSheetPose) = mix(SearchSheet.Radius, 0.0, max(p.expand, p.leave))
    /** How far under its place the sheet stands while it rises and goes. */
    fun drop(p: SearchSheetPose) = (1 - p.rise) * ((p.origin?.let { it.y - SearchSheet.Top } ?: (height + SearchSheet.Foot)) - top(p))
    /** The field on the sheet's top, turning into the spaces' capsule as it rises. */
    fun field(p: SearchSheetPose): FieldRect {
        val t = SearchSheet.share(p.expand, SearchSheet.FieldToCapsule)
        val field = FieldRect(mix(SearchSheet.FieldInset, capsule.x, t), max(top(p) + SearchSheet.Top, capsule.y),
            mix(width - SearchSheet.FieldInset * 2, capsule.width, t), mix(fieldHeight, capsule.height, t))
        val origin = p.origin ?: return field
        return FieldRect(mix(origin.x, field.x, p.rise), field.y, mix(origin.width, field.width, p.rise), mix(origin.height, field.height, p.rise))
    }
    /** What stands under the field starts here. */
    fun under(p: SearchSheetPose) = top(p) + SearchSheet.Top + fieldHeight + SearchSheet.Gap
    /** The one spaces card rides the sheet under the field, its head coming last. */
    fun hang(p: SearchSheetPose) = max(0.0, under(p) - restHead) + SearchSheet.SpacesRise * (1 - SearchSheet.share(p.expand, SearchSheet.SpacesIn))
    /** How much of the screen's top stays hidden, its soft edge just under. */
    fun hidden(p: SearchSheetPose) = max(top(p), hang(p) + restHead * (1 - SearchSheet.share(p.expand, SearchSheet.HeadIn)))
}

/** The foot's three places, All Tabs' bar and the page's chrome row: one row on every screen. */
internal data class BrowserFootRects(val width: Double, val height: Double, val bottom: Double) {
    private val y get() = height - bottom - 48.0
    val left get() = FieldRect(26.0, y, 48.0, 48.0)
    val center get() = FieldRect((width - 96.0) / 2, y, 96.0, 48.0)
    val right get() = FieldRect(width - 26.0 - 48.0, y, 48.0, 48.0)
}

/** The keyboard's height from the screen's foot, as it last said: the sheet keeps it while the
 * keyboard is down, so the finger's way stays the same. Process-local, as FieldModel.keyboard. */
internal object BrowserSheetKeyboard {
    var last = 0.0
}

/** One sheet's way from low to the whole screen. Held across the Field's editor replacements. */
@Stable
internal class BrowserSheetMotion(expanded: Boolean, standing: Boolean, plain: Boolean) {
    var expand by mutableFloatStateOf(if (expanded) 1f else 0f)
    var rise by mutableFloatStateOf(if (standing || expanded) 1f else 0f)
    var drag by mutableFloatStateOf(0f)
    var body by mutableFloatStateOf(SearchSheet.body(plain).toFloat())
    var origin by mutableStateOf<FieldRect?>(null)
    /** 1 at the screen's top, on its way to being the page just chosen. */
    var leave by mutableFloatStateOf(0f)
    /** The sheet standing at the top lets the page show through. */
    var veil by mutableFloatStateOf(1f)
    /** A finger holds the sheet, so its way is not animated from outside. */
    var pulling by mutableStateOf(false)
    var spacesReady by mutableStateOf(expanded)
    private var travel: Job? = null
    private var dragBack: Job? = null

    private var eyesAt = 0L
    fun eyesTurned() { eyesAt = android.os.SystemClock.uptimeMillis() }
    fun eyesTurning() = android.os.SystemClock.uptimeMillis() - eyesAt < 2_500

    fun pose() = SearchSheetPose(expand.toDouble(), rise.toDouble(), body.toDouble(), leave.toDouble(), origin)
    /** Called back while it was going: it stands again. */
    fun stay() { leave = 0f; veil = 1f }
    suspend fun leaveUp() { animate(leave * 1000, 1000f, animationSpec = BrowserMotion.spring(.26f)) { value, _ -> leave = value / 1000 } }
    suspend fun reveal() { animate(veil, 0f, animationSpec = tween(SearchSheet.RevealMillis, easing = BrowserMotion.easeOut)) { value, _ -> veil = value } }
    fun hold() { travel?.cancel() }
    fun travel(scope: CoroutineScope, to: Float, reduced: Boolean, velocity: Float = 0f) {
        travel?.cancel()
        if (reduced) { expand = to; return }
        travel = scope.launch {
            animate(expand * 1000, to * 1000, velocity * 1000, BrowserMotion.spring(.42f)) { value, _ -> expand = (value / 1000).coerceIn(0f, 1f) }
        }
    }
    fun letDragBack(scope: CoroutineScope) {
        dragBack?.cancel()
        dragBack = scope.launch { animate(drag, 0f, animationSpec = tween(240, 70, BrowserMotion.easeOut)) { value, _ -> drag = value } }
    }
    fun holdDrag() { dragBack?.cancel() }
    suspend fun rise(to: Float, reduced: Boolean) {
        if (reduced) rise = to
        else animate(rise * 1000, to * 1000, animationSpec = BrowserMotion.spring(if (origin != null) .32f else .25f)) { value, _ -> rise = value / 1000 }
    }
}

/** What the sheet is told by the Field that owns it. Everything here reads the moving numbers
 * in layout and drawing, never in composition, so a finger never rebuilds the rows. */
internal class BrowserSheetActions(val close: () -> Unit, val rest: () -> Unit, val ask: () -> Unit)

private enum class SheetGrab { NONE, UP, DOWN, IGNORED }

/** The grabber and the rows: gone before the spaces come, and first of all on the way up. */
private fun rowsLeft(p: SearchSheetPose) = ((1 - SearchSheet.share(p.expand, SearchSheet.RowsOut)) * p.grown(SearchSheet.RowsIn) *
    (1 - SearchSheet.share(p.leave, SearchSheet.LeaveWords))).toFloat()

/** A child standing in a moving rectangle, measured and placed in the layout phase. */
private fun Modifier.sheetRect(rect: () -> FieldRect) = layout { measurable, constraints ->
    val r = rect()
    val w = (r.width * density).roundToInt().coerceAtLeast(0)
    val h = (r.height * density).roundToInt().coerceAtLeast(0)
    val placeable = measurable.measure(Constraints.fixed(w, h))
    layout(constraints.maxWidth, constraints.maxHeight) { placeable.place((r.x * density).roundToInt(), (r.y * density).roundToInt()) }
}

@Composable
internal fun BrowserSearchSheetLayout(
    motion: BrowserSheetMotion?, keyboard: Double, highest: Double, dim: Float, fieldAlpha: Float,
    interactive: Boolean, private: Float, typed: Boolean, canPull: Boolean, resting: Boolean, chats: Boolean, asking: Boolean,
    own: Color, wash: BrowserSpacesWash?, grain: Double, actions: BrowserSheetActions, reduced: Boolean,
    spaces: @Composable () -> Unit, lines: @Composable () -> Unit, input: @Composable (Modifier, () -> Float) -> Unit,
    askingField: (@Composable () -> Unit)?, foot: @Composable (() -> Float) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = maxWidth.value.toDouble()
        val height = maxHeight.value.toDouble()
        val density = LocalDensity.current.density
        val geometry = BrowserSheetGeometry(width, height, keyboard, highest)
        fun pose() = motion?.pose() ?: SearchSheetPose(1.0, 1.0, SearchSheet.body(false))
        val latestPull by rememberUpdatedState(canPull)
        val latestResting by rememberUpdatedState(resting)
        val latestTyped by rememberUpdatedState(typed)
        val latestChats by rememberUpdatedState(chats)
        val latestActions by rememberUpdatedState(actions)
        val latestGeometry by rememberUpdatedState(geometry)
        if (motion != null) {
            LaunchedEffect(motion) { delay(SearchSheet.SpacesReadyMillis); motion.spacesReady = true }
            LaunchedEffect(motion, resting, chats, reduced) {
                if (motion.pulling) return@LaunchedEffect
                if (resting || chats) { if (motion.expand < 1f) motion.travel(scope, 1f, reduced) }
                else if (motion.expand > 0f) motion.travel(scope, 0f, reduced)
            }
        }
        val pull = if (motion == null) Modifier else Modifier.pointerInput(motion, density) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                val start = down.position
                val p = latestGeometry
                val tracker = VelocityTracker().apply { addPosition(down.uptimeMillis, start) }
                val y0 = start.y / density
                // Typed rows scroll by themselves; a finger on them is theirs.
                val onLines = y0 > p.under(motion.pose()) && y0 < height - p.keyboard
                var grab = SheetGrab.NONE
                val from = motion.expand
                var dy = 0f
                try {
                    while (true) {
                        val change = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed && change.isConsumed) break
                        tracker.addPosition(change.uptimeMillis, change.position)
                        dy = (change.position.y - start.y) / density
                        val dx = (change.position.x - start.x) / density
                        if (grab == SheetGrab.NONE && max(abs(dx), abs(dy)) > 8) {
                            grab = when {
                                latestResting || motion.expand > .5f || abs(dx) > abs(dy) || latestTyped && onLines -> SheetGrab.IGNORED
                                dy > 0 -> SheetGrab.DOWN
                                latestPull -> SheetGrab.UP
                                else -> SheetGrab.IGNORED
                            }
                            if (grab == SheetGrab.UP) { motion.hold(); motion.pulling = true }
                            if (grab == SheetGrab.DOWN) motion.holdDrag()
                        }
                        when (grab) {
                            SheetGrab.UP -> { motion.expand = (from - dy / p.span(motion.pose()).toFloat()).coerceIn(0f, 1f); change.consume() }
                            SheetGrab.DOWN -> { motion.drag = max(0f, dy) * SearchSheet.DragFollow; change.consume() }
                            else -> Unit
                        }
                        if (!change.pressed) {
                            val velocity = tracker.calculateVelocity().y / density
                            if (grab == SheetGrab.UP) {
                                motion.pulling = false
                                if (velocity < -SearchSheet.Flick || motion.expand > SearchSheet.OpensAt && velocity < SearchSheet.Flick) {
                                    motion.travel(scope, 1f, reduced); latestActions.rest()
                                } else motion.travel(scope, 0f, reduced)
                            } else if (grab == SheetGrab.DOWN) {
                                if (dy > SearchSheet.CloseDistance || velocity > SearchSheet.CloseVelocity) latestActions.close()
                                else motion.letDragBack(scope)
                            }
                            grab = SheetGrab.NONE
                            break
                        }
                    }
                } finally {
                    if (grab == SheetGrab.UP) { motion.pulling = false; motion.travel(scope, 0f, reduced) }
                    if (grab == SheetGrab.DOWN) motion.letDragBack(scope)
                }
            }
        }
        Box(Modifier.fillMaxSize().then(pull).semantics {
            stateDescription = if (motion == null) "spaces" else if (motion.expand < .01f) "low" else if (motion.expand >= 1f) "spaces" else "pulled"
            if (motion != null && !latestChats) customActions = listOf(CustomAccessibilityAction("Show Spaces") { latestActions.rest(); true })
        }.testTag("search.sheet")) {
            // Over the sheet the page stays in sight, dimmed. A tap beside it closes.
            if (motion != null) Box(Modifier.fillMaxSize().graphicsLayer { alpha = dim }.background(Color.Black.copy(alpha = SearchSheet.Dim))
                .clickable(remember { MutableInteractionSource() }, null, enabled = interactive, onClick = actions.close).testTag("browser.field.backdrop"))
            val surfaceBase = if (dark) Color(0xFF1C1C1E) else Color.White
            // One sheet: Android's plain surface for its glass, the space's breath on it, the
            // spaces' wash coming up over the whole of it at once, Private's dark where it stands.
            Box(Modifier.fillMaxSize().graphicsLayer {
                val p = pose()
                translationY = ((geometry.top(p) + geometry.drop(p) + (motion?.drag ?: 0f)) * density).toFloat()
                shape = RoundedCornerShape(topStart = geometry.radius(p).dp, topEnd = geometry.radius(p).dp)
                clip = true
                alpha = p.grown(SearchSheet.GroundIn).toFloat() * (motion?.veil ?: 1f)
            }.background(surfaceBase.copy(alpha = .96f))) {
                Box(Modifier.fillMaxSize().background(own.copy(alpha = SearchSheet.SpaceTint * (1 - private))))
                if (wash != null) BrowserLookSurfaceBackdrop(wash, grain, Modifier.fillMaxSize().graphicsLayer {
                    alpha = SearchSheet.share(pose().expand, SearchSheet.SpacesIn).toFloat() * (1 - private)
                })
                Box(Modifier.fillMaxSize().graphicsLayer {
                    alpha = private * max(SearchSheet.PrivateTint.toDouble(), SearchSheet.share(pose().expand, SearchSheet.SpacesIn)).toFloat()
                }.background(Color(0xFF1C1C20)))
                Box(Modifier.fillMaxSize().graphicsLayer { alpha = SearchSheet.share(pose().leave, SearchSheet.LeaveSolid).toFloat() }.background(surfaceBase))
            }
            // One spaces card for the field's whole life, built once the sheet has risen.
            if (motion == null || motion.spacesReady || motion.expand > .001f) {
                Box(Modifier.fillMaxSize().graphicsLayer {
                    compositingStrategy = CompositingStrategy.Offscreen
                    alpha = SearchSheet.share(pose().expand, SearchSheet.SpacesIn).toFloat()
                }.drawWithContent {
                    drawContent()
                    val p = pose()
                    if (p.expand < 1) {
                        val hidden = (geometry.hidden(p) + geometry.drop(p)).toFloat() * this.density
                        val edge = SearchSheet.SpacesEdge.toFloat() * this.density
                        drawRect(Color.Black, Offset.Zero, Size(size.width, hidden), blendMode = BlendMode.DstOut)
                        drawRect(Brush.verticalGradient(0f to Color.Black, 1f to Color.Transparent, startY = hidden, endY = hidden + edge),
                            Offset(0f, hidden), Size(size.width, edge), blendMode = BlendMode.DstOut)
                    }
                }) {
                    Box(Modifier.fillMaxSize().offset { IntOffset(0, ((geometry.hang(pose()) + geometry.drop(pose())) * density).roundToInt()) }
                        .padding(top = highest.dp)) { spaces() }
                }
            }
            if (motion != null) {
                // The sheet's front: its grabber and what stands under the field.
                Box(Modifier.offset { IntOffset(((width - SearchSheet.GrabberWidth) / 2 * density).roundToInt(),
                        ((geometry.top(pose()) + geometry.drop(pose()) + motion.drag + SearchSheet.GrabberTop) * density).roundToInt()) }
                    .size(SearchSheet.GrabberWidth.dp, SearchSheet.GrabberHeight.dp)
                    .graphicsLayer { alpha = rowsLeft(pose()) }
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = .2f), CircleShape))
                if (motion.expand < 1f) Box(Modifier.offset { IntOffset((SearchSheet.FieldInset * density).roundToInt(),
                        ((geometry.under(pose()) + geometry.drop(pose()) + motion.drag) * density).roundToInt()) }
                    .width((width - SearchSheet.FieldInset * 2).dp).height((SearchSheet.Rows * SearchSheet.Line).dp)
                    .graphicsLayer { alpha = rowsLeft(pose()) }) { lines() }
                // The field, when the sheet is on it. Chats have their own search.
                if (!chats) Box(Modifier.sheetRect {
                    val p = pose()
                    val r = geometry.field(p)
                    // At the whole screen the capsule takes over: the field takes no finger there.
                    if (p.expand >= .999) r.copy(width = 0.0, height = 0.0) else r.copy(y = r.y + geometry.drop(p) + motion.drag)
                }.graphicsLayer {
                    alpha = fieldAlpha * ((1 - SearchSheet.share(pose().expand, SearchSheet.FieldOut)) * (1 - SearchSheet.share(pose().leave, SearchSheet.LeaveWords))).toFloat()
                }) {
                    input(Modifier.fillMaxSize()) { ((1 - SearchSheet.share(pose().expand, SearchSheet.WordsOut)) * pose().grown(SearchSheet.WordsIn)).toFloat() }
                }
            }
            if (!asking) foot { SearchSheet.share(pose().expand, SearchSheet.BarIn).toFloat() }
            if (asking) askingField?.invoke()
        }
    }
}

/** Two faces of one place, turned through a blur (SwiftUI's blurReplace). */
@Composable
internal fun BlurTurn(amount: Float, first: @Composable BoxScope.() -> Unit, second: @Composable BoxScope.() -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
        if (amount < 1f) Box(Modifier.fillMaxSize().graphicsLayer { alpha = 1 - amount }
            .then(if (amount > 0f) Modifier.blur((SearchSheet.BlurTurn * amount).dp) else Modifier), content = first)
        if (amount > 0f) Box(Modifier.fillMaxSize().graphicsLayer { alpha = amount }
            .then(if (amount < 1f) Modifier.blur((SearchSheet.BlurTurn * (1 - amount)).dp) else Modifier), content = second)
    }
}

/** Android's material where iOS has its glass: one raised plate, as the chrome's. */
@Composable
internal fun BrowserFootPlate(rect: FieldRect, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.surface,
    onClick: () -> Unit, enabled: Boolean = true, content: @Composable BoxScope.() -> Unit) {
    val shape = if (rect.width > rect.height) RoundedCornerShape(rect.height.dp / 2) else CircleShape
    Surface(Modifier.offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp).then(modifier), shape = shape, color = color, shadowElevation = 3.dp) {
        Box(Modifier.fillMaxSize().clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center, content = content)
    }
}

internal val BrowserDoneBlue = Color(0xFF0A84FF)

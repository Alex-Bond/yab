package dev.yab.browser.ui

import android.animation.ValueAnimator
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.*
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

internal val FieldProgressKey = SemanticsPropertyKey<Float>("FieldProgress")
internal val FieldKeyboardKey = SemanticsPropertyKey<Float>("FieldKeyboard")
internal val FieldClosingKey = SemanticsPropertyKey<Boolean>("FieldClosing")
internal val FieldPillPoseKey = SemanticsPropertyKey<List<Float>>("FieldPillPose")

private class FieldMotionState(reduced: Boolean, inPlace: Boolean, val sheet: BrowserSheetMotion?) {
    val progress = Animatable(if (reduced || inPlace) 1f else 0f)
    val pill = Animatable(if (reduced && !inPlace) 0f else 1f)
    val backdrop = Animatable(if (inPlace) 1f else 0f)
    val cards = Animatable(if (inPlace) 1f else 0f)
    val contents = Animatable(1f)
    var wash: BrowserFieldWashMotion? = null
    val washClock = BrowserFieldPageClock()
}

@Stable
internal class BrowserFieldHostState private constructor(val lease: FieldPresentationLease,
    internal var snapshot: BrowserState, internal val origin: FieldRect, internal val closeOrigin: FieldRect,
    private val motion: FieldMotionState) {
    var visible by mutableStateOf(true)
    var closing by mutableStateOf(false)
    var lastKeyboard by mutableDoubleStateOf(0.0)
    var sawKeyboard = false
    private var renderedPill: FieldRect? = null
    private var segment: FieldMorphSegment? = null
    internal fun rendered(rect: FieldRect) { renderedPill = rect }
    val progress get() = motion.progress.value
    /** The field stands in the search sheet (BrowserSearchSheet). */
    val sheet get() = motion.sheet
    internal fun reverse(next: FieldPresentationLease, state: BrowserState) =
        BrowserFieldHostState(next, state, origin, closeOrigin, motion).also {
            it.lastKeyboard = lastKeyboard; it.sawKeyboard = sawKeyboard
            it.renderedPill = renderedPill
            renderedPill?.let { rect -> it.segment = FieldMorphSegment(rect, motion.progress.value.toDouble(), 1.0) }
        }
    internal fun pose(geometry: BrowserFieldGeometry) = BrowserFieldPose(geometry, origin, closeOrigin,
        motion.progress.value.toDouble(), motion.cards.value.toDouble(), motion.contents.value.toDouble(),
        segment?.at(if (closing) geometry.plate else geometry.field, motion.progress.value.toDouble()))
    internal val pillAlpha get() = motion.pill.value
    internal val backdropAlpha get() = motion.backdrop.value
    internal val cardsAlpha get() = motion.cards.value
    internal val contentsAlpha get() = motion.contents.value
    internal fun wash(initial: Double) = motion.wash ?: BrowserFieldWashMotion(initial).also { motion.wash = it }
    internal val washClock get() = motion.washClock

    internal suspend fun animate(open: Boolean, reduced: Boolean, replaced: Boolean, upward: Boolean = false) {
        val sheet = motion.sheet
        if (sheet != null) {
            closing = !open
            if (open) { visible = true; sheet.stay() }
            else if (sheet.rise >= .99f) sheet.origin = null
            coroutineScope {
                launch { motion.progress.snapTo(1f); motion.pill.snapTo(1f); motion.cards.snapTo(1f); motion.contents.snapTo(1f) }
                if (!open && upward && !reduced && !replaced) {
                    launch { sheet.leaveUp() }
                    // The page shows while the sheet still rises: its spring's rest would leave an empty sheet.
                    snapshotFlow { sheet.leave }.first { it >= SearchSheet.RevealAt }
                    launch { motion.backdrop.animateTo(0f, tween(SearchSheet.RevealMillis, easing = BrowserMotion.easeOut)) }
                    sheet.reveal()
                } else {
                    launch { motion.backdrop.animateTo(if (open) 1f else 0f, BrowserMotion.spring(.25f)) }
                    launch { sheet.rise(if (open) 1f else 0f, reduced) }
                }
            }
            if (!open) visible = false
            return
        }
        coroutineScope {
            if (!open && !closing) renderedPill?.let { segment = FieldMorphSegment(it, motion.progress.value.toDouble(), 0.0) }
            closing = !open
            if (open) {
                visible = true
                launch { motion.contents.animateTo(1f, tween(120, easing = LinearEasing)) }
                launch { motion.backdrop.animateTo(1f, tween(200, easing = LinearEasing)) }
                launch { motion.cards.animateTo(1f, tween(240, delayMillis = 70, easing = BrowserMotion.easeOut)) }
                if (reduced) {
                    motion.progress.snapTo(1f)
                    motion.pill.animateTo(1f, tween(200, easing = CubicBezierEasing(.42f, 0f, .58f, 1f)))
                } else {
                    motion.pill.snapTo(1f)
                    motion.progress.animateTo(1f, tween(300, easing = BrowserMotion.easeOut))
                }
            } else {
                launch { motion.backdrop.animateTo(0f, tween(180, easing = LinearEasing)) }
                launch { motion.cards.animateTo(0f, tween(150, easing = BrowserMotion.easeIn)) }
                if (replaced) motion.contents.animateTo(0f, tween(120, easing = LinearEasing))
                else if (reduced) motion.pill.animateTo(0f, tween(200, easing = CubicBezierEasing(.42f, 0f, .58f, 1f)))
                else {
                    launch { motion.contents.animateTo(0f, tween(120, easing = LinearEasing)) }
                    motion.progress.animateTo(0f, tween(240, easing = BrowserMotion.easeOut))
                }
            }
        }
        // Keep the retained host until all concurrent fades have actually completed.
        if (!open) visible = false
    }

    companion object {
        internal fun make(lease: FieldPresentationLease, state: BrowserState, origin: FieldRect, close: FieldRect, reduced: Boolean, sheet: Boolean = false) =
            BrowserFieldHostState(lease, state, origin, close, FieldMotionState(reduced, state.fieldInPlace,
                if (sheet) BrowserSheetMotion(state.fieldFromSpaces, state.fieldInPlace, browserSheetPlain(state)).also {
                    // It grows out of what was tapped; with no such thing on the screen it rises from the foot.
                    val tapped = state.fieldAnchor?.valid() == true || state.tab != null && !state.emptyHomeBar
                    if (!reduced && !state.fieldInPlace && !state.fieldFromSpaces && tapped) it.origin = origin
                } else null))
    }
}

/** Lives outside the selected-tab key, so a chosen destination cannot erase a closing field. */
@Composable
internal fun rememberBrowserFieldHost(state: BrowserState, controller: BrowserController, enabled: Boolean,
    width: Double, height: Double, rootPlate: SpacesRect?, rootStack: GalleryRect?, pane: SpacesRect?, sheetAllowed: Boolean = false): BrowserFieldHostState? {
    var memory by remember(controller) { mutableStateOf<BrowserFieldHostState?>(null) }
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val active = enabled && state.surface == BrowserSurface.FIELD && !state.privateContentBlocked
    val old = memory
    val result = if (active) {
        if (old?.lease?.surfaceEpoch == state.surfaceEpoch && old.visible && controller.fieldPresentationCurrent(old.lease)) old
        else {
            val lease = controller.captureFieldPresentation()
            if (lease == null) null else {
                val sameContext = old != null && old.visible && controller.fieldPresentationOwned(old.lease) &&
                    old.snapshot.selectedSpaceId == state.selectedSpaceId && old.snapshot.space?.websiteProfile == state.space?.websiteProfile &&
                    old.snapshot.fieldIsPrivate == state.fieldIsPrivate && old.snapshot.fieldIsNewTab == state.fieldIsNewTab
                if (sameContext) requireNotNull(old).reverse(lease, state)
                else {
                    val g = BrowserFieldGeometry(width.coerceAtLeast(80.0), height, 0.0)
                    fun local(anchor: FieldAnchor) = FieldRect(anchor.x - (pane?.x ?: 0.0), anchor.y - (pane?.y ?: 0.0), anchor.width, anchor.height)
                    val measured = state.fieldAnchor?.takeIf(FieldAnchor::valid)?.let(::local)
                        ?: if (state.fieldIsNewTab) rootStack?.let { FieldRect(it.x - (pane?.x ?: 0.0), it.y - (pane?.y ?: 0.0), it.width, it.height) }
                        else rootPlate?.let { FieldRect(it.x - (pane?.x ?: 0.0), it.y - (pane?.y ?: 0.0), it.width, it.height) }
                    BrowserFieldHostState.make(lease, state, measured ?: g.plate,
                        rootStack?.let { FieldRect(it.x - (pane?.x ?: 0.0), it.y - (pane?.y ?: 0.0), it.width, it.height) } ?: g.stack, reduced,
                        // A private tab's own field keeps its card: no spaces behind a private tab.
                        sheet = sheetAllowed && (state.fieldIsNewTab || !state.fieldPagePrivate))
                }
            }
        }
    } else old?.takeIf { enabled && it.visible && controller.fieldPresentationCurrent(it.lease) &&
        it.snapshot.selectedSpaceId == state.selectedSpaceId && it.snapshot.space?.websiteProfile == state.space?.websiteProfile &&
        (!it.snapshot.fieldPagePrivate || state.space?.isPrivate == true) }
    SideEffect {
        memory = result
        if (active && result != null) result.snapshot = state
    }
    return result
}

internal data class BrowserFieldPresentation(val pose: BrowserFieldPose, val interactive: Boolean,
    val pillAlpha: Float, val backdrop: Float, val cards: Float, val contents: Float,
    val close: () -> Unit, val rest: () -> Unit, val washBottom: Double = pose.geometry.spacesBottom,
    val inputFocus: BrowserFieldInputFocus.Binding? = null, val sheet: BrowserSheetMotion? = null, val keyboard: Double = 0.0)

/** Draw coordinates only. These objects carry no input or authorization capability. */
internal class BrowserFieldWashAnchor { var coordinates: LayoutCoordinates? = null }
internal class BrowserFieldWashPlacement(val geometry: BrowserFieldWashGeometry, private val root: BrowserFieldWashAnchor,
    private val layer: BrowserFieldWashAnchor, private val bodyHeight: Int, val clipBody: Boolean) {
    fun projection(local: LayoutCoordinates?): FieldWashProjection? {
        val parent = root.coordinates ?: return null
        val cards = layer.coordinates ?: return null
        if (!parent.isAttached || !cards.isAttached || local?.isAttached != true) return null
        return runCatching {
            val origin = parent.localPositionOf(local, Offset.Zero)
            val layerOrigin = parent.localPositionOf(cards, Offset.Zero)
            // Supply every extent in actual pixels; no dp round-trip can shift a clip edge.
            geometry.projection(origin.x.toDouble(), origin.y.toDouble(), parent.size.width.toDouble(), parent.size.height.toDouble(),
                layerOrigin.x.toDouble(), layerOrigin.y.toDouble(), bodyHeight.toDouble())
        }.getOrNull()
    }
}

/** Retains the old body alpha-layer clip while the sibling decoration owns more room. */
@Composable
internal fun browserFieldBodyClip(wash: BrowserFieldWashPlacement): Modifier {
    val anchor = remember { BrowserFieldWashAnchor() }
    return Modifier.onPlaced { anchor.coordinates = it }.drawWithContent {
        if (!wash.clipBody) drawContent()
        else wash.projection(anchor.coordinates)?.let { p ->
            clipRect(p.clipLeft.toFloat(), p.bodyClipTop.toFloat(), p.clipRight.toFloat(), p.bodyClipBottom.toFloat()) { this@drawWithContent.drawContent() }
        }
    }
}

@Composable
internal fun BrowserFieldHost(state: BrowserState, controller: BrowserController, host: BrowserFieldHostState,
    width: Double, height: Double, keyboard: Double, covered: Boolean, onMounted: (Boolean) -> Unit,
    fromMenu: Double = 1.0, onFieldDestination: ((FieldRect) -> Unit)? = null,
    placement: BrowserFieldPlacementLease? = null, focusOwner: BrowserFieldInputFocus? = null,
    content: @Composable (BrowserState, BrowserFieldPresentation) -> Unit) {
    // This synchronous projection precedes effects and cannot display an old account/Private frame.
    if (!host.visible || !controller.fieldPresentationCurrent(host.lease)) { SideEffect { onMounted(false) }; return }
    val active = state.surface == BrowserSurface.FIELD && state.surfaceEpoch == host.lease.surfaceEpoch
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val focus = LocalFocusManager.current
    val softwareKeyboard = LocalSoftwareKeyboardController.current
    val ownership = focusOwner ?: remember(host) { BrowserFieldInputFocus() }
    val inputFocus = remember(ownership, host, placement) { ownership.bind() }
    val inputFocused = inputFocus.ownsFocus
    fun clearInput() = inputFocus.clear({ focus.clearFocus(force = true) }, { softwareKeyboard?.hide() })
    val density = LocalDensity.current
    val shown = if (active) state else host.snapshot.let {
        if (it.fieldIsNewTab && it.fieldIsPrivate) it.copy(fieldText = "") else it
    }
    val interactive = active && !covered
    val close: () -> Unit = { if (controller.fieldPresentationCurrent(host.lease)) controller.dismissField(host.lease.surfaceEpoch) }
    val rest: () -> Unit = {
        if (inputFocus.ownsFocus && placement?.current() != false && controller.fieldPresentationCurrent(host.lease) &&
            controller.restField(host.lease.surfaceEpoch)) clearInput()
    }
    SideEffect { onMounted(true) }
    DisposableEffect(host) { onDispose { onMounted(false) } }
    DisposableEffect(inputFocus) { onDispose { clearInput() } }
    BackHandler(onBack = { if (active) close() })
    LaunchedEffect(host, active, covered, reduced) {
        if (!active || covered) clearInput()
        if (active) withFrameNanos { }
        host.animate(active && !covered, reduced, covered || state.surface == BrowserSurface.SETTINGS, state.fieldGoesUp)
    }
    LaunchedEffect(host, inputFocus, active, shown.fieldResting) {
        if (active && shown.fieldResting) clearInput()
    }
    LaunchedEffect(host, inputFocus, inputFocused, keyboard, active) {
        if (active && inputFocused && placement?.current() != false && controller.fieldPresentationCurrent(host.lease)) {
            if (keyboard > 80) { host.lastKeyboard = keyboard; host.sawKeyboard = true; inputFocus.keyboardShown() }
            else if (keyboard < 1 && !state.fieldResting && inputFocus.takeKeyboardDismissal()) {
                // The eyes hand the keyboard to a new editor: that dip is no dismissal, the sheet stands.
                if (host.sheet?.eyesTurning() != true) rest()
            }
        }
    }
    val keyboardNow = if (active && !shown.fieldResting && keyboard > 0) keyboard else host.lastKeyboard
    val resting = shown.fieldResting || !host.sawKeyboard && keyboard < 1
    val foot by animateFloatAsState((if (resting) 32.0 else keyboardNow).toFloat(),
        tween(300, easing = BrowserMotion.easeOut), label = "field keyboard")
    // Unlike the input's 32pt resting foot, NewTabSpaces washes to the screen bottom.
    // This track belongs to the retained motion state, so reversing the Field keeps its sample.
    val washTarget = (height - if (resting) 0.0 else keyboardNow).coerceIn(0.0, height)
    val wash = remember(host) { host.wash(washTarget) }
    var washBottom by remember(host) { mutableDoubleStateOf(wash.value) }
    val washAnimations = ValueAnimator.areAnimatorsEnabled()
    LaunchedEffect(host, washTarget, reduced, washAnimations) {
        wash.target(washTarget, host.washClock.event(wash.running), reduced, washAnimations)
        washBottom = wash.value
        while (wash.running) withFrameNanos { washBottom = wash.advance(host.washClock.frame(it)) }
    }
    val geometry = BrowserFieldGeometry(width.coerceAtLeast(80.0), height, foot.toDouble(),
        textScale = density.fontScale.toDouble(), lineHeight = 20.3 * density.fontScale,
        resting = false,
        statusTop = WindowInsets.statusBars.getTop(density) / density.density.toDouble())
    val pose = host.pose(geometry)
    SideEffect { host.rendered(pose.pill); onFieldDestination?.invoke(geometry.field) }
    val menuFactors = PageMenuFieldFactors.at(fromMenu)
    Box(Modifier.fillMaxSize().testTag("browser.field.motion").semantics {
        this[FieldProgressKey] = host.progress
        this[FieldKeyboardKey] = geometry.keyboard.toFloat()
        this[FieldClosingKey] = !interactive
        this[FieldPillPoseKey] = listOf(pose.pill.x.toFloat(), pose.pill.y.toFloat(), pose.pill.width.toFloat(), pose.pill.height.toFloat())
    }) {
        Box(Modifier.fillMaxSize().then(if (fromMenu <= .6) Modifier.clearAndSetSemantics {} else Modifier)
            .then(if (interactive) Modifier else Modifier.clearAndSetSemantics {}.pointerInput(host) {
            awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
        })) {
            content(shown, BrowserFieldPresentation(pose, interactive, host.pillAlpha * menuFactors.pill,
                host.backdropAlpha * menuFactors.backdrop, host.cardsAlpha * menuFactors.cards,
                host.contentsAlpha, close, rest, washBottom.coerceIn(0.0, height), inputFocus, host.sheet, keyboard))
        }
    }
}

/** Card and input are siblings. Only the capsule shape grows; editor content keeps its final frame. */
@Composable
internal fun BrowserFieldLayout(presentation: BrowserFieldPresentation, privateInput: Boolean, color: Color,
    privateFraction: Float = if (privateInput) 1f else 0f,
    spaceWash: Boolean = true,
    content: @Composable (Modifier, BrowserFieldWashPlacement) -> Unit, input: @Composable (Modifier) -> Unit, close: @Composable (Modifier) -> Unit) {
    val p = presentation.pose
    val density = LocalDensity.current
    fun positioned(r: FieldRect) = Modifier.offset(r.x.dp, r.y.dp).size(r.width.coerceAtLeast(0.0).dp, r.height.coerceAtLeast(0.0).dp)
    val mask = Modifier.drawWithContent {
        val r = p.pill
        val path = Path().apply { addRoundRect(RoundRect(Rect((r.x * density.density).toFloat(), (r.y * density.density).toFloat(),
            (r.right * density.density).toFloat(), (r.bottom * density.density).toFloat()), CornerRadius((p.radius * density.density).toFloat()))) }
        clipPath(path) { this@drawWithContent.drawContent() }
    }
    val washRoot = remember { BrowserFieldWashAnchor() }
    val washLayer = remember { BrowserFieldWashAnchor() }
    val washGeometry = BrowserFieldWashGeometry(p.geometry.width, p.geometry.height,
        p.geometry.cardBottom.coerceIn(0.0, p.geometry.height), presentation.washBottom.coerceIn(0.0, p.geometry.height), p.rowsDrop, spaceWash)
    val bodyHeight = with(density) { washGeometry.cardBottom.dp.roundToPx() }
    val padding = with(density) { washGeometry.innerBottomPaddingPixels(density.density).toDp() }
    // Auto only required an offscreen buffer (and its body-size clip) while alpha<1.
    // At rest preserve the old clip=false overflow/shadows; decoration still clips itself.
    val washPlacement = BrowserFieldWashPlacement(washGeometry, washRoot, washLayer, bodyHeight,
        clipBody = presentation.cards < 1f)
    Box(Modifier.fillMaxSize().onPlaced { washRoot.coordinates = it }) {
        val privateInk = privateFraction.coerceIn(0f, 1f)
        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.lerp(MaterialTheme.colorScheme.background, Color(0xFF0E0D12), privateInk)
            .copy(alpha = presentation.backdrop * (.66f + .16f * privateInk)))
            .clickable(enabled = presentation.interactive, onClick = presentation.rest).testTag("browser.field.backdrop"))
        // Modifier order matters: the visible viewport-sized alpha layer precedes the
        // padding that restores the original inner card measurement and all weights.
        content(Modifier.width(p.geometry.width.dp).height(washGeometry.layerHeight.dp)
            .offset(y = p.rowsDrop.dp).graphicsLayer { alpha = presentation.cards }
            .onPlaced { washLayer.coordinates = it }.padding(bottom = padding), washPlacement)
        Surface(positioned(p.pill).graphicsLayer { alpha = presentation.pillAlpha }, shape = CircleShape,
            color = color, shadowElevation = 1.dp) {}
        Box(Modifier.fillMaxSize().then(mask).graphicsLayer { alpha = presentation.pillAlpha * presentation.contents }) {
            input(positioned(p.geometry.field).testTag("browser.field.pill"))
        }
        close(positioned(p.close).graphicsLayer { alpha = (presentation.pillAlpha * p.closeGlyph).toFloat() })
    }
}

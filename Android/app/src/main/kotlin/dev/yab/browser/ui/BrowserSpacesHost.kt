package dev.yab.browser.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.*
import kotlinx.coroutines.channels.Channel
import kotlin.math.min

internal val SpacesRevealKey = SemanticsPropertyKey<Float>("SpacesReveal")
internal val SpacesOriginKey = SemanticsPropertyKey<List<Float>>("SpacesOrigin")
internal data class BrowserSpacesInputFrame(val kind: String, val x: Double = 0.0, val y: Double = 0.0,
    val dy: Double = 0.0, val velocity: Double = 0.0, val reveal: Double = 0.0)
/** Optional owned-fixture input diagnosis; contains no tab, account or field content. */
internal val LocalBrowserSpacesInputObserver = staticCompositionLocalOf<((BrowserSpacesInputFrame) -> Unit)?> { null }

/** Shared observable travel: the mask, contents and real chrome read the same frame's value. */
@Stable
internal class BrowserSpacesHostState(
    val owner: BrowserSpacesOwner, val origin: SpacesRect?, val width: Double,
    val height: Double, highest: Double, reduced: Boolean,
) {
    private val travel = BrowserSpacesTravel(height, highest, if (origin == null || reduced) 1.0 else 0.0)
    val wake = Channel<Unit>(Channel.CONFLATED)
    val opacity = Animatable(if (reduced) 0f else 1f)
    var reveal by mutableDoubleStateOf(travel.reveal)
        private set
    var closing by mutableStateOf(false)
        private set
    var reduced by mutableStateOf(reduced)
        private set
    private var lastLower: Double? = null
    var gestureOpening = false
        private set
    val pose get() = BrowserSpacesPose(reveal)
    val chromeVeil get() = if (reduced) opacity.value.toDouble() else pose.chromeVeil
    val completionGeneration get() = travel.generation
    val moving get() = travel.moving
    fun current(state: BrowserState) = state.surface == BrowserSurface.SPACES && state.surfaceEpoch == owner.surfaceEpoch &&
        !state.privateContentBlocked && (state.space?.isPrivate == true) == owner.privateOrigin
    fun open(isReduced: Boolean) { reduced = isReduced; closing = false; travel.open(isReduced); changed() }
    fun close() { if (closing) return; closing = true; travel.close(reduced); changed() }
    fun beginLift() { gestureOpening = true; closing = false; travel.beginLift(); changed() }
    fun liftMoved(dy: Double) { travel.liftMoved(dy); changed() }
    fun liftEnded(velocity: Double) { travel.liftEnded(velocity, reduced); closing = travel.closing; changed() }
    fun lower(dy: Double, ended: Boolean, velocity: Double) {
        if (!ended) {
            if (lastLower == null) { travel.beginLower(); closing = false }
            travel.lowerMoved(dy - (lastLower ?: 0.0)); lastLower = dy
        } else { lastLower = null; travel.lowerEnded(velocity, reduced); closing = travel.closing }
        changed()
    }
    fun cancelLower() { lastLower = null; open(reduced) }
    private fun changed() { reveal = travel.reveal; wake.trySend(Unit) }
    fun step(dt: Double) { travel.step(dt); reveal = travel.reveal }
    fun closed(expected: Long) = travel.isClosedCompletion(expected)
}

@Composable
internal fun rememberBrowserSpacesHostState(state: BrowserState, enabled: Boolean, width: Double, height: Double,
    highest: Double, rootPlate: SpacesRect?, paneRoot: SpacesRect?, reduced: Boolean, liftInput: BrowserSpacesLiftInput): BrowserSpacesHostState? {
    if (!enabled || state.surface != BrowserSurface.SPACES || state.privateContentBlocked) return null
    val privateOrigin = state.space?.isPrivate == true
    // Account/surface/privacy replacement changes this key during composition, before any effect.
    return remember(state.surfaceEpoch, privateOrigin) {
        val local = if (rootPlate != null && paneRoot != null) rootPlate.copy(x = rootPlate.x - paneRoot.x, y = rootPlate.y - paneRoot.y) else null
        BrowserSpacesHostState(BrowserSpacesOwner(state.surfaceEpoch, state.tab?.id, privateOrigin), local, width, height, highest, reduced).also(liftInput::attach)
    }
}

/** Resting spaces stay mounted until their own spring closes. Editing/address field remains
 * a separate surface; this host alone does not establish field-pill or native glass parity. */
@Composable
internal fun BrowserSpacesHost(state: BrowserState, controller: BrowserController, host: BrowserSpacesHostState,
    liftInput: BrowserSpacesLiftInput,
    content: @Composable (BrowserSpacesPresentation) -> Unit) {
    // Never draw a retained Private or replaced field even for the frame before LaunchedEffect.
    if (!host.current(state)) return
    val density = LocalDensity.current
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val inputObserver = LocalBrowserSpacesInputObserver.current
    val close: () -> Unit = { host.close() }
    BackHandler(onBack = close)
    DisposableEffect(host) { onDispose { liftInput.detach(host); host.wake.close() } }
    LaunchedEffect(host) {
        // The measured source stands for one frame before the first spring update.
        val initialGeneration = host.completionGeneration
        withFrameNanos { }
        if (!host.gestureOpening && !host.closing && host.completionGeneration == initialGeneration) host.open(reduced)
        for (ignored in host.wake) {
            var last = 0L
            while (host.moving) {
                withFrameNanos { now ->
                    val dt = if (last == 0L) 1.0 / 60 else min(0.05, (now - last).coerceAtLeast(0) / 1e9)
                    last = now; host.step(dt)
                }
            }
            if (!host.reduced && host.closed(host.completionGeneration)) controller.dismissSpaces(host.owner.surfaceEpoch)
        }
    }
    LaunchedEffect(host, reduced) {
        if (host.reduced != reduced) { if (host.closing) { host.open(reduced); host.close() } else host.open(reduced) }
    }
    LaunchedEffect(host, host.closing, host.reduced) {
        if (host.closing) { focus.clearFocus(force = true); keyboard?.hide() }
        if (host.reduced) {
            val generation = host.completionGeneration
            host.opacity.animateTo(if (host.closing) 0f else 1f, tween(200, easing = CubicBezierEasing(.42f, 0f, .58f, 1f)))
            if (host.closing && host.closed(generation)) controller.dismissSpaces(host.owner.surfaceEpoch)
        } else host.opacity.snapTo(1f)
    }
    val frame = if (host.reduced || host.origin == null) null else BrowserSpacesLiftFrame.at(host.reveal, host.width, host.height, host.origin)
    val shape = Modifier.drawWithContent {
        if (frame == null) drawContent()
        else {
            val rect = frame.rect
            val path = Path().apply { addRoundRect(RoundRect(Rect((rect.x * density.density).toFloat(), (rect.y * density.density).toFloat(),
                ((rect.x + rect.width) * density.density).toFloat(), (rect.bottom * density.density).toFloat()), CornerRadius((frame.radius * density.density).toFloat()))) }
            clipPath(path) { this@drawWithContent.drawContent() }
        }
    }
    val interactive = !host.closing
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = (0.2 * host.pose.backdrop).toFloat()))
        .testTag("browser.spaces.motion").semantics {
            this[SpacesRevealKey] = host.reveal.toFloat()
            this[SpacesOriginKey] = host.origin?.let { listOf(it.x.toFloat(), it.y.toFloat(), it.width.toFloat(), it.height.toFloat()) }.orEmpty()
        }) {
        Box(Modifier.fillMaxSize().then(shape).graphicsLayer { alpha = if (host.reduced) host.opacity.value else host.pose.cardOpacity.toFloat() }) {
            Box(Modifier.fillMaxSize().offset(y = (frame?.drop ?: 0.0).dp)
                .then(if (interactive) Modifier else Modifier.clearAndSetSemantics {})
                .pointerInput(host) {
                    // Removing this handler on a closing→held reversal cancels
                    // the child's captured pointer. Keep the route and only
                    // update whether ordinary covered content can receive it.
                    awaitPointerEventScope { while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        if (host.closing) event.changes.forEach { it.consume() }
                    } }
                }) {
                content(BrowserSpacesPresentation(host.reveal, interactive, close, { dy, ended, velocity ->
                    inputObserver?.invoke(BrowserSpacesInputFrame(if (ended) "lower-before-end" else "lower-before-move", dy = dy, velocity = velocity, reveal = host.reveal))
                    host.lower(dy, ended, velocity)
                    inputObserver?.invoke(BrowserSpacesInputFrame(if (ended) "lower-after-end" else "lower-after-move", dy = dy, velocity = velocity, reveal = host.reveal))
                }, host::cancelLower))
            }
        }
    }
}

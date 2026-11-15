package dev.yab.browser.ui

import android.animation.ValueAnimator
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.IntOffset
import dev.yab.browser.model.*
import kotlinx.coroutines.channels.Channel
import kotlin.math.abs

internal val SettingsOffsetKey = SemanticsPropertyKey<Float>("SettingsOffset")
internal val SettingsDragKey = SemanticsPropertyKey<Float>("SettingsDrag")
internal val SettingsPresenceKey = SemanticsPropertyKey<Float>("SettingsPresence")
internal val SettingsPhaseKey = SemanticsPropertyKey<String>("SettingsPhase")
internal val SettingsRouteXKey = SemanticsPropertyKey<Float>("SettingsRouteX")
internal val SettingsTabletKey = SemanticsPropertyKey<Boolean>("SettingsTablet")
internal val SettingsKeyboardOverlapKey = SemanticsPropertyKey<Float>("SettingsKeyboardOverlap")
/** Fixture override is local to this app composition; default follows the actual OS setting. */
internal val LocalSettingsAnimationsEnabled = staticCompositionLocalOf<Boolean?> { null }
internal val LocalSettingsFrameObserver = staticCompositionLocalOf<((SettingsFrame) -> Unit)?> { null }
internal enum class SettingsFunctionalStage { LEASE_BEFORE, LEASE_AFTER, FRAME_COMMITTED, ROUTE_COMMITTED,
    HEADER_DOWN, HEADER_ACCEPTED, HEADER_REFUSED, HEADER_SAMPLE, HEADER_CLAIM, HEADER_MOVE, HEADER_RELEASE, HEADER_FINALLY }
internal enum class SettingsFunctionalReason { NONE, NOT_CURRENT, NO_COORDINATES, NO_ROOT_POINT,
    MULTIPLE_POINTERS, LEASE_CHANGED, GENERATION_CHANGED, CONSUMED, POINTER_MISSING, COORDINATES_CHANGED, TARGET_FRAME_CHANGED, INCOMPLETE }
internal data class SettingsFunctionalEvent(val stage: SettingsFunctionalStage, val reason: SettingsFunctionalReason,
    val modelPhase: SettingsPhase, val modelDrag: Double?, val composedPhase: SettingsPhase?, val composedDrag: Double?,
    val leaseBound: Boolean?, val gate: Boolean?, val claimed: Boolean?, val targetKeyChanged: Boolean)
/** Functional failure projection only. No observer value participates in input or animation. */
internal val LocalSettingsFunctionalObserver = staticCompositionLocalOf<((SettingsFunctionalEvent) -> Unit)?> { null }

@Stable
internal class BrowserSettingsHostState(initialLease: SettingsPresentationLease, initialPage: String, var freshSpaceRequest: Boolean = false) {
    var lease by mutableStateOf(initialLease)
    val leaveHandlers = mutableMapOf<Long, () -> Unit>()
    val presentation = SettingsPresentation(initialPage).also { model ->
        model.beforeRouteLeave = { id -> leaveHandlers[id]?.invoke() }
    }
    val wake = Channel<Unit>(Channel.CONFLATED)
    var now = 0L
    var reduced = false
    var animations = true
    var flickNext = false
    var suspended = false
    var functionalObserver: ((SettingsFunctionalEvent) -> Unit)? = null
    var functionalComposed: SettingsFrame? = null
    var committedInputFrame: SettingsSheetInputFrame? = null
    fun observe(stage: SettingsFunctionalStage, reason: SettingsFunctionalReason = SettingsFunctionalReason.NONE,
        leaseBound: Boolean? = null, gate: Boolean? = null, claimed: Boolean? = null,
        originalFrame: SettingsSheetInputFrame? = committedInputFrame, targetKeyChanged: Boolean? = null) {
        val observer = functionalObserver ?: return
        runCatching {
            val model = presentation.frame.value
            fun finite(value: Double?) = value?.takeIf { it.isFinite() }?.coerceIn(-10000.0, 10000.0)
            observer(SettingsFunctionalEvent(stage, reason, model.phase, finite(model.drag), functionalComposed?.phase,
                finite(functionalComposed?.drag), leaseBound, gate, claimed,
                targetKeyChanged ?: (originalFrame != committedInputFrame)))
        }
    }
    /** Receives the original predicate's single result and returns it unchanged. */
    fun diagnosticRejected(value: Boolean, reason: SettingsFunctionalReason,
        originalFrame: SettingsSheetInputFrame?, claimed: Boolean): Boolean {
        if (value) observe(SettingsFunctionalStage.HEADER_REFUSED, reason, claimed = claimed, originalFrame = originalFrame)
        return value
    }
    fun changed() { wake.trySend(Unit) }
    fun actionCurrent(expected: SettingsPresentationLease, route: Long, controller: BrowserController): Boolean =
        lease === expected && controller.settingsActionsCurrent(expected) && presentation.routeCurrent(route)
    fun push(title: String) { presentation.push(title, now); changed() }
    fun push(destination: SettingsDestination) { presentation.pushAll(listOf(destination), now); changed() }
    fun back() { presentation.back(now); changed() }
    /** No suspension after consuming the one-shot flow value: setting it null may restart
     * the caller's effect. Keep the captured owner and route delivery in this same turn. */
    fun deliverCreatedSpace(controller: BrowserController, request: SettingsSpaceNavigation,
        expected: SettingsPresentationLease, reducedMotion: Boolean = reduced, animationsEnabled: Boolean = animations): Boolean {
        if (lease !== expected || !controller.consumeSettingsSpaceNavigation(request, expected)) return false
        presentation.configure(reducedMotion, animationsEnabled)
        if (freshSpaceRequest) { presentation.showSettled(now, reducedMotion, animationsEnabled); freshSpaceRequest = false }
        val opened = presentation.pushAll(listOf(SettingsDestination.Space(request.id),
            SettingsDestination.Editor(request.id, SettingsSpaceStep.NAME, namingNew = true)), now)
        changed(); return opened
    }
    fun close(controller: BrowserController) {
        presentation.frame.value.routes.lastOrNull { it.interactive }?.let { leaveHandlers[it.id]?.invoke() }
        if (controller.dismissSettings(lease)) { presentation.hide(now, flickNext); flickNext = false; changed() }
    }
}

/** Stable sibling of the native page and Field. The retained exit owns pixels only. */
@Composable
internal fun BrowserSettingsHost(state: BrowserState, controller: BrowserController,
    onMounted: (Boolean) -> Unit = {}, content: @Composable (BrowserSettingsHostState, SettingsPresentationLease) -> Unit) {
    val mountedCallback by rememberUpdatedState(onMounted)
    DisposableEffect(controller) { onDispose { mountedCallback(false) } }
    var retained by remember(controller) { mutableStateOf<BrowserSettingsHostState?>(null) }
    val lifetime by controller.settingsPresentationLifetime.collectAsState()
    val spaceNavigation by controller.settingsSpaceNavigation.collectAsState()
    val incoming = remember(state.surface, state.surfaceEpoch, lifetime) { controller.captureSettingsPresentation() }
    val old = retained
    val oldFrame = old?.let { key(it) { it.presentation.frame.collectAsState().value } }
    val host = if (incoming != null) {
        if (old != null && (controller.sameSettingsOwner(old.lease, incoming) ||
                controller.sameSettingsSource(old.lease, incoming)) &&
            oldFrame?.phase !in setOf(SettingsPhase.CLOSED, SettingsPhase.REVOKED)) old
        else remember(incoming) { BrowserSettingsHostState(incoming, state.settingsPage?.title ?: "Settings",
            spaceNavigation?.let { controller.settingsSpaceNavigationCurrent(it, incoming) } == true) }
    } else old
    if (host == null) { SideEffect { mountedCallback(false) }; return }
    val nextLease = incoming ?: host.lease
    val frame by key(host) { host.presentation.frame.collectAsState() }
    val suspended = !lifetime.active && controller.settingsPresentationRetainable(host.lease)
    val resuming = incoming != null && controller.sameSettingsSource(host.lease, incoming) &&
        !controller.sameSettingsOwner(host.lease, incoming) && frame.phase != SettingsPhase.MOUNTED
    // This render-time check removes stale account/foreground/Private content before effects.
    if (!suspended && (incoming == null && !controller.settingsPresentationCurrent(host.lease) || !controller.settingsPresentationOwned(nextLease))) {
        SideEffect { host.presentation.revoke(); if (retained === host) retained = null; mountedCallback(false) }
        return
    }
    val functionalObserver = LocalSettingsFunctionalObserver.current
    SideEffect {
        val changed = host.lease !== nextLease || host.functionalObserver !== functionalObserver
        host.functionalObserver = functionalObserver
        if (changed) host.observe(SettingsFunctionalStage.LEASE_BEFORE, leaseBound = host.lease === nextLease)
        host.lease = nextLease; host.suspended = suspended; if (retained !== host) retained = host
        if (changed) host.observe(SettingsFunctionalStage.LEASE_AFTER, leaseBound = true)
    }
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val animations = LocalSettingsAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()
    val observer = LocalSettingsFrameObserver.current
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val open = incoming != null
    LaunchedEffect(host, open, nextLease, suspended, reduced, animations) {
        if (suspended) { focus.clearFocus(force = true); keyboard?.hide(); return@LaunchedEffect }
        withFrameNanos { host.now = it }
        host.reduced = reduced; host.animations = animations
        host.presentation.configure(reduced, animations)
        if (open && !resuming) host.presentation.show(host.now, reduced, animations)
        else if (!open) { focus.clearFocus(force = true); keyboard?.hide(); host.presentation.hide(host.now, host.flickNext); host.flickNext = false }
        host.changed()
    }
    LaunchedEffect(host, spaceNavigation, nextLease) {
        val request = spaceNavigation ?: return@LaunchedEffect
        withFrameNanos { host.now = it }
        host.deliverCreatedSpace(controller, request, nextLease, reduced, animations)
    }
    LaunchedEffect(host) {
        for (ignored in host.wake) {
            do {
                withFrameNanos { now -> host.now = now; host.presentation.advance(now) }
            } while (host.presentation.frame.value.running)
            if (host.presentation.frame.value.phase == SettingsPhase.CLOSED && retained === host) retained = null
        }
    }
    DisposableEffect(host) { onDispose { host.presentation.revoke(); host.wake.close() } }
    SideEffect { observer?.invoke(frame); mountedCallback(!suspended && frame.phase !in setOf(SettingsPhase.CLOSED, SettingsPhase.REVOKED)) }
    if (frame.phase in setOf(SettingsPhase.CLOSED, SettingsPhase.REVOKED)) return
    BackHandler(enabled = open) {
        if (controller.settingsActionsCurrent(nextLease)) {
            if (host.presentation.frame.value.canBack) host.back() else host.close(controller)
        }
    }
    var rootOrigin by remember { mutableStateOf<SettingsRootOrigin?>(null) }
    BoxWithConstraints(Modifier.fillMaxSize().onGloballyPositioned {
        val point = it.positionInWindow()
        val origin = SettingsRootOrigin(point.x, point.y)
        rootOrigin = origin
        // Input can arrive before a second composition after a root translation.
        host.committedInputFrame = host.committedInputFrame?.copy(root = origin)
    }.graphicsLayer { alpha = if (suspended) 0f else 1f }
        .background(Color.Black.copy(alpha = (.18 * frame.presence).toFloat()))
        .testTag("settings.motion").semantics { this[SettingsOffsetKey] = frame.offset.toFloat(); this[SettingsPhaseKey] = frame.phase.name
            this[SettingsDragKey] = frame.drag.toFloat(); this[SettingsPresenceKey] = frame.presence.toFloat() }) {
        val density = LocalDensity.current
        val target = BrowserTabletSettingsGeometry.frame(constraints.maxWidth, constraints.maxHeight,
            density.density.toDouble(), LocalConfiguration.current.smallestScreenWidthDp)
        val overlap = if (target.tablet) BrowserTabletSettingsGeometry.keyboardOverlap(target, rootOrigin,
            LocalWindowInfo.current.containerSize.height, WindowInsets.ime.getBottom(density)) else 0.0
        val viewport = SettingsViewport(SettingsSheetInputFrame(target, rootOrigin),
            overlap)
        SideEffect {
            val changed = host.committedInputFrame != null && host.committedInputFrame != viewport.frame
            host.committedInputFrame = viewport.frame; host.functionalComposed = frame
            host.observe(SettingsFunctionalStage.FRAME_COMMITTED, targetKeyChanged = changed)
        }
        val shape = if (target.tablet) RoundedCornerShape(22.dp) else
            RoundedCornerShape(topStart = if (frame.sheetSettled) 0.dp else 55.dp,
                topEnd = if (frame.sheetSettled) 0.dp else 55.dp)
        Box(Modifier.offset { IntOffset(target.x, target.y) }
            .size(with(density) { target.width.toDp() }, with(density) { target.height.toDp() })) {
            CompositionLocalProvider(LocalSettingsViewport provides viewport) {
                Surface(Modifier.fillMaxSize().graphicsLayer {
                    translationY = frame.offset.toFloat() * target.height + frame.drag.toFloat() * density.density
                    alpha = frame.opacity.toFloat()
                }.dropShadow(shape, Shadow(radius = 20.dp, color = Color.Black.copy(alpha = frame.shadow.toFloat()), offset = DpOffset(0.dp, (-10).dp)))
                    .testTag("settings.sheet").semantics {
                        this[SettingsTabletKey] = target.tablet
                        this[SettingsKeyboardOverlapKey] = (viewport.keyboardOverlapPx / density.density).toFloat()
                    }, shape = shape, color = MaterialTheme.colorScheme.surface) {
                    SettingsInputGate(open && controller.settingsActionsCurrent(nextLease)) { key(host) { content(host, nextLease) } }
                }
            }
        }
    }
}

@Composable
internal fun SettingsInputGate(enabled: Boolean, content: @Composable () -> Unit) {
    val current by rememberUpdatedState(enabled)
    Box(Modifier.fillMaxSize().then(if (enabled) Modifier else Modifier.clearAndSetSemantics {})
        .pointerInput(Unit) { awaitPointerEventScope { while (true) {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            if (!current) event.changes.forEach { it.consume() }
        } } }) { content() }
}

/** Retains each body's composition and scroll; only the exact live route can receive input. */
@Composable
internal fun SettingsRouteDeck(host: BrowserSettingsHostState, lease: SettingsPresentationLease,
    controller: BrowserController, content: @Composable (SettingsRouteFrame, () -> Boolean) -> Unit) {
    val frame by host.presentation.frame.collectAsState()
    val density = LocalDensity.current
    val inputFrame = LocalSettingsViewport.current?.frame
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
        val widthPx = constraints.maxWidth.toFloat()
        frame.routes.forEach { route -> key(route.id) {
            val revision = frame.generation
            val actionCurrent = remember(host, lease, route.id, revision, controller) {
                { host.actionCurrent(lease, route.id, controller) && host.presentation.frame.value.generation == revision }
            }
            val currentAction by rememberUpdatedState(actionCurrent)
            var coordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
            // Each page is opaque, as on iPhone: the page under it stays shifted and dimmed for
            // the back swipe, and must never show through a pushed page's gaps.
            Box(Modifier.fillMaxSize().graphicsLayer {
                translationX = route.x.toFloat() * widthPx; alpha = if (route.visible) 1f else 0f
            }.background(MaterialTheme.colorScheme.background).testTag("settings.route.${route.id}").semantics { this[SettingsRouteXKey] = route.x.toFloat() }) {
                val routeEnabled = route.visible && route.interactive && controller.settingsActionsCurrent(lease) &&
                    host.presentation.routeCurrent(route.id, revision)
                SideEffect { if (route.interactive) host.observe(SettingsFunctionalStage.ROUTE_COMMITTED,
                    leaseBound = host.lease === lease, gate = routeEnabled) }
                SettingsInputGate(routeEnabled) {
                    Box(Modifier.fillMaxSize().onGloballyPositioned { coordinates = it }
                        .settingsEdgeBack(host, route.id, widthPx / density.density, inputFrame, { coordinates }) { currentAction() }) {
                        content(route, actionCurrent)
                    }
                }
                if (route.dim > 0) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = route.dim.toFloat()))
                    .clearAndSetSemantics {})
            }
        } }
    }
}

private fun Modifier.settingsEdgeBack(host: BrowserSettingsHostState, route: Long, width: Float,
    inputFrame: SettingsSheetInputFrame?, coordinates: () -> LayoutCoordinates?, current: () -> Boolean): Modifier = pointerInput(host, route, width, inputFrame) {
    val scale = density
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = true)
        if (down.position.x >= 24 * scale || !current() || host.committedInputFrame != inputFrame) return@awaitEachGesture
        val ownerCoordinates = coordinates()?.takeIf { it.isAttached } ?: return@awaitEachGesture
        val rootDown = ownerCoordinates.rootPoint(down.position) ?: return@awaitEachGesture
        val generation = host.presentation.frame.value.generation
        val sourceLease = host.lease
        val tracker = VelocityTracker(); tracker.addPosition(down.uptimeMillis, rootDown)
        var claimed = false; var completed = false
        try {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Main)
                val change = event.changes.singleOrNull { it.id == down.id } ?: break
                if (event.changes.count { it.pressed } > 1 || !current() || host.lease !== sourceLease || host.presentation.frame.value.generation != generation || change.isConsumed) break
                if (coordinates() !== ownerCoordinates || host.committedInputFrame != inputFrame) break
                val rootNow = ownerCoordinates.rootPoint(change.position) ?: break
                tracker.addPosition(change.uptimeMillis, rootNow)
                val delta = rootNow - rootDown
                if (!claimed && delta.x > viewConfiguration.touchSlop && delta.x > abs(delta.y))
                    claimed = host.presentation.beginBack(route, host.now)
                if (claimed) {
                    host.presentation.pullBack(route, (delta.x / scale / width).toDouble()); host.changed()
                    if (!change.pressed) {
                        host.presentation.endBack(route, width.toDouble(), tracker.calculateVelocity().x / scale.toDouble(), host.now)
                        host.changed(); completed = true; change.consume(); break
                    }
                    change.consume()
                } else if (!change.pressed) { completed = true; break }
            }
        } finally {
            if (claimed && !completed) {
                host.presentation.endBack(route, width.toDouble(), 0.0, host.now, cancelled = true); host.changed()
            }
        }
    }
}

/** A close pull begins only in the header's unused hit area; native buttons consume first. */
internal fun Modifier.settingsHeaderPull(host: BrowserSettingsHostState, height: Double,
    inputFrame: SettingsSheetInputFrame?,
    coordinates: () -> LayoutCoordinates?, current: () -> Boolean,
    close: () -> Unit): Modifier = pointerInput(host, height, inputFrame) {
    val scale = density
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = true)
        host.observe(SettingsFunctionalStage.HEADER_DOWN, originalFrame = inputFrame)
        if (!current() || host.committedInputFrame != inputFrame) {
            host.observe(SettingsFunctionalStage.HEADER_REFUSED, SettingsFunctionalReason.NOT_CURRENT, originalFrame = inputFrame)
            return@awaitEachGesture
        }
        val ownerCoordinates = coordinates()?.takeIf { it.isAttached } ?: run {
            host.observe(SettingsFunctionalStage.HEADER_REFUSED, SettingsFunctionalReason.NO_COORDINATES, originalFrame = inputFrame)
            return@awaitEachGesture
        }
        val rootDown = ownerCoordinates.rootPoint(down.position) ?: run {
            host.observe(SettingsFunctionalStage.HEADER_REFUSED, SettingsFunctionalReason.NO_ROOT_POINT, originalFrame = inputFrame)
            return@awaitEachGesture
        }
        val generation = host.presentation.frame.value.generation
        val sourceLease = host.lease
        val tracker = VelocityTracker(); tracker.addPosition(down.uptimeMillis, rootDown)
        var claimed = false; var complete = false
        host.observe(SettingsFunctionalStage.HEADER_ACCEPTED, claimed = false, originalFrame = inputFrame)
        try {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Main)
                val change = event.changes.singleOrNull { it.id == down.id }
                if (change == null) { host.observe(SettingsFunctionalStage.HEADER_REFUSED, SettingsFunctionalReason.POINTER_MISSING,
                    claimed = claimed, originalFrame = inputFrame); break }
                if (host.diagnosticRejected(event.changes.count { it.pressed } > 1, SettingsFunctionalReason.MULTIPLE_POINTERS, inputFrame, claimed) ||
                    host.diagnosticRejected(!current(), SettingsFunctionalReason.NOT_CURRENT, inputFrame, claimed) ||
                    host.diagnosticRejected(host.lease !== sourceLease, SettingsFunctionalReason.LEASE_CHANGED, inputFrame, claimed) ||
                    host.diagnosticRejected(host.presentation.frame.value.generation != generation, SettingsFunctionalReason.GENERATION_CHANGED, inputFrame, claimed) ||
                    host.diagnosticRejected(change.isConsumed, SettingsFunctionalReason.CONSUMED, inputFrame, claimed) ||
                    host.diagnosticRejected(host.committedInputFrame != inputFrame, SettingsFunctionalReason.TARGET_FRAME_CHANGED, inputFrame, claimed)) break
                if (coordinates() !== ownerCoordinates) { host.observe(SettingsFunctionalStage.HEADER_REFUSED,
                    SettingsFunctionalReason.COORDINATES_CHANGED, claimed = claimed, originalFrame = inputFrame); break }
                val rootNow = ownerCoordinates.rootPoint(change.position)
                if (rootNow == null) { host.observe(SettingsFunctionalStage.HEADER_REFUSED, SettingsFunctionalReason.NO_ROOT_POINT,
                    claimed = claimed, originalFrame = inputFrame); break }
                tracker.addPosition(change.uptimeMillis, rootNow)
                val delta = rootNow - rootDown
                host.observe(SettingsFunctionalStage.HEADER_SAMPLE, claimed = claimed, originalFrame = inputFrame)
                if (!claimed && delta.getDistance() >= 8 * scale) {
                    claimed = true
                    host.observe(SettingsFunctionalStage.HEADER_CLAIM, claimed = true, originalFrame = inputFrame)
                }
                if (claimed) {
                    host.presentation.pullSheet(delta.y / scale.toDouble(), height, host.now); host.changed()
                    host.observe(SettingsFunctionalStage.HEADER_MOVE, claimed = true, originalFrame = inputFrame)
                    if (!change.pressed) {
                        val leave = host.presentation.releaseSheet(tracker.calculateVelocity().y / scale.toDouble(), host.now)
                        host.changed(); if (leave) close()
                        host.observe(SettingsFunctionalStage.HEADER_RELEASE, claimed = true, originalFrame = inputFrame)
                        complete = true; change.consume(); break
                    }
                    change.consume()
                } else if (!change.pressed) { complete = true; break }
            }
        } finally {
            host.observe(SettingsFunctionalStage.HEADER_FINALLY, if (complete) SettingsFunctionalReason.NONE else SettingsFunctionalReason.INCOMPLETE,
                claimed = claimed, originalFrame = inputFrame)
            if (claimed && !complete) { host.presentation.releaseSheet(0.0, host.now, cancelled = true); host.changed() }
        }
    }
}

/** Query the actual current layer transform; never add a guessed/cached moving origin. */
private fun LayoutCoordinates.rootPoint(local: Offset): Offset? =
    if (!isAttached) null else localToRoot(local).takeIf { it.x.isFinite() && it.y.isFinite() }

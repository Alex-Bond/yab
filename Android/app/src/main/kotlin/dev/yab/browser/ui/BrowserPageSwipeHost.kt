package dev.yab.browser.ui

import android.view.HapticFeedbackConstants

import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.zIndex
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.*
import dev.yab.browser.engine.PagingCaptureOutcome
import dev.yab.browser.engine.PagingCaptureResult
import dev.yab.browser.engine.PagingFrame
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.Channel
import kotlin.math.min

internal val PageSwipePoseKey = SemanticsPropertyKey<List<Float>>("PageSwipePose")
internal val PageSwipePhaseKey = SemanticsPropertyKey<String>("PageSwipePhase")
internal val PageSwipePagePositionKey = SemanticsPropertyKey<List<Float>>("PageSwipePagePosition")
internal val PageSwipeCaptureKey = SemanticsPropertyKey<String>("PageSwipeCapture")

internal class BrowserPageSwipeScene(val lease: PageSwipeLease, val model: BrowserPageSwipeModel) {
    var fieldEpoch: Long? = null
    var fadeDirection: Int? = null
    var fadeFromOffset = 0.0
    var fadeProgress = 0.0
    var fadeStarted = 0L
    var committedDirection: Int? = null
    var committedProjectionSeen = false
    var capturing = false
    var returnFrame: PagingFrame? = null
    var feltTicks = 0
    var feltEdges = 0
    val phase get() = when {
        capturing -> "CAPTURE_PENDING"
        fadeDirection != null -> "CROSSFADE"
        committedDirection != null -> "HANDOFF"
        model.blank -> "BLANK"
        model.touching -> "DRAGGING"
        else -> "SETTLING"
    }
    val fading get() = fadeDirection != null
}

/** One UI lifetime. Native drawing visibility is separate from controller selection/input ownership. */
@Stable
internal class BrowserPageSwipeHostState(private val controller: BrowserController,
    private val canPresent: () -> Boolean, private val canBegin: () -> Boolean,
    private val capture: ((PageSwipeLease, (PagingCaptureResult) -> Unit) -> Job)? = null,
    private val feel: (Boolean, Boolean) -> Unit) {
    private var current: BrowserPageSwipeScene? = null
    private var revision by mutableLongStateOf(0)
    private var width = 0.0
    private var height = 0.0
    private var pane: SpacesRect? = null
    private var reduced = false
    private var captureJob: Job? = null
    private var captureGeneration = 0L
    var captureOutcome by mutableStateOf("NOT_REQUESTED"); private set
    val wake = Channel<Unit>(Channel.CONFLATED)
    val scene: BrowserPageSwipeScene? get() { revision; return current?.takeIf(::owns) }
    val running get() = current?.let { it.model.moving || it.fading } == true

    fun configure(nextWidth: Double, nextHeight: Double, root: SpacesRect?, reduce: Boolean, projected: BrowserState) {
        reduced = reduce; pane = root
        if (width != 0.0 && width != nextWidth || height != 0.0 && height != nextHeight) clear()
        width = nextWidth; height = nextHeight
        val value = current ?: return
        if (!owns(value)) { clear(); return }
        value.committedDirection?.let { direction ->
            val target = if (direction < 0) value.lease.before else value.lease.after
            if (target != null && projected.surface == BrowserSurface.PAGE && projected.surfaceEpoch == value.lease.epoch &&
                projected.selectedSpaceId == value.lease.space && projected.space?.websiteProfile == value.lease.profile &&
                projected.tab?.id == target.id && projected.tab?.url == target.url && projected.tab?.isPrivate == target.isPrivate) {
                value.committedProjectionSeen = true
                // A StateFlow selection and a Compose snapshot invalidate different consumers.
                // Keep all keyed page slots until THIS consumer has actually drawn the new tab.
                if (!value.fading) { clear(); return }
            }
        }
        if (value.fieldEpoch != null && controller.state.value.surface == BrowserSurface.PAGE && value.model.blank) {
            // A dismissal may arrive before the reduced landing has finished fading.
            // Retire that presentation before starting the same owned blank's return.
            value.fadeDirection = null; value.fadeStarted = 0L
            handle(value, value.model.leaveBlank(reduced))
            changed()
        }
    }

    private fun owns(value: BrowserPageSwipeScene): Boolean {
        if (!canPresent()) return false
        if (value.returnFrame?.bitmapIfCurrent() == null && value.returnFrame != null) return false
        val direction = value.fadeDirection ?: value.committedDirection
        return if (direction != null) controller.pageSwipePresentationCurrent(value.lease, direction, value.fieldEpoch)
            else controller.pageSwipeCurrent(value.lease, value.fieldEpoch)
    }

    fun begin(source: PageSwipeLease?): Boolean {
        if (!canBegin() || !width.isFinite() || width <= 0 || source == null || !controller.pageSwipeCurrent(source)) return false
        val old = current
        if (old != null && owns(old) && old.fieldEpoch == null && !old.fading && old.lease.front.id == source.front.id) {
            if (old.capturing) {
                captureGeneration++; captureJob?.cancel(); captureJob = null; old.capturing = false
                captureOutcome = PagingCaptureOutcome.REVOKED.name
            }
            if (!old.model.down()) return false
        } else {
            clear()
            val model = BrowserPageSwipeModel(width, source.before != null, source.after != null)
            if (!model.down()) return false
            current = BrowserPageSwipeScene(source, model)
        }
        changed()
        return true
    }

    fun move(translation: Double): Boolean {
        val value = current ?: return false
        if (!canBegin() || !owns(value) || value.fading || value.capturing || value.fieldEpoch != null) { clear(); return false }
        value.model.move(translation); feedback(value); changed()
        return true
    }

    fun end(translation: Double, speed: Double) {
        val value = current ?: return
        if (!canBegin() || !owns(value) || value.fading || value.capturing || value.fieldEpoch != null) { clear(); return }
        if (reduced && translation.isFinite() && speed.isFinite()) {
            value.model.move(translation)
            if (BrowserPageSwipeMath.destination(value.model.offset + speed * BrowserPageSwipeMath.projection,
                    value.lease.before != null, value.lease.after != null) == 0 && kotlin.math.abs(value.model.offset) >= .04) {
                captureReturn(value); return
            }
        }
        val held = value.model.offset
        val event = value.model.up(translation, speed, reduced)
        feedback(value)
        if (reduced && event is BrowserPageSwipeModel.Event.Settled && event.direction != 0) {
            // Swift changes selection inside its reduced-motion transition. The old page is readonly.
            value.committedDirection = event.direction
            if (!controller.settlePageSwipe(value.lease, event.direction) ||
                !controller.pageSwipePresentationCurrent(value.lease, event.direction)) { clear(); return }
            value.fadeDirection = event.direction; value.fadeFromOffset = held; value.fadeProgress = 0.0; value.fadeStarted = 0L
        } else if (reduced && event == BrowserPageSwipeModel.Event.Blank) {
            handle(value, event)
            if (current === value) {
                value.fadeDirection = 1; value.fadeFromOffset = held; value.fadeProgress = 0.0; value.fadeStarted = 0L
            }
        } else handle(value, event)
        changed()
    }

    fun cancel() {
        val value = current ?: return
        if (!owns(value) || value.fading || value.fieldEpoch != null) { clear(); return }
        if (value.capturing) return
        if (reduced && kotlin.math.abs(value.model.offset) >= .04) { captureReturn(value); return }
        handle(value, value.model.cancel(reduced)); changed()
    }

    private fun captureReturn(value: BrowserPageSwipeScene) {
        if (current !== value || !owns(value)) { clear(); return }
        val generation = ++captureGeneration
        value.capturing = true; captureOutcome = "REQUESTED"; changed()
        fun complete(result: PagingCaptureResult) {
            if (current !== value || captureGeneration != generation || !owns(value)) { result.frame?.close(); return }
            captureJob = null; value.capturing = false; captureOutcome = result.outcome.name
            val frame = result.frame?.takeIf { result.outcome == PagingCaptureOutcome.READY && it.bitmapIfCurrent() != null }
            if (frame == null) {
                result.frame?.close()
                if (result.outcome == PagingCaptureOutcome.READY) captureOutcome = PagingCaptureOutcome.REVOKED.name
                // Safe same-page fallback is observable as refusal, never a claimed crossfade.
                handle(value, value.model.cancel(true)); changed(); return
            }
            value.fadeFromOffset = value.model.offset
            value.model.cancel(true) // Same native page at its final position; no selection event.
            value.returnFrame = frame; value.fadeDirection = 0; value.fadeProgress = 0.0; value.fadeStarted = 0L
            changed()
        }
        val job = capture?.invoke(value.lease, ::complete)
        if (job == null) complete(PagingCaptureResult(PagingCaptureOutcome.UNAVAILABLE))
        else if (current === value && value.capturing && captureGeneration == generation) captureJob = job else job.cancel()
    }

    fun frame(now: Long, dt: Double) {
        val value = current ?: return
        if (!owns(value)) { if (value.returnFrame != null || value.capturing) captureOutcome = PagingCaptureOutcome.REVOKED.name; clear(); return }
        if (value.fading) {
            if (value.fadeStarted == 0L) value.fadeStarted = now
            value.fadeProgress = ((now - value.fadeStarted).coerceAtLeast(0) / 200_000_000.0).coerceIn(0.0, 1.0)
            if (value.fadeProgress >= 1) {
                if (value.returnFrame != null) clear()
                else if (value.model.blank && value.fieldEpoch != null) { value.fadeDirection = null; changed() }
                else if (value.committedProjectionSeen) clear()
                else { value.fadeDirection = null; changed() }
            } else changed()
        } else { handle(value, value.model.frame(dt)); changed() }
    }

    private fun handle(value: BrowserPageSwipeScene, event: BrowserPageSwipeModel.Event?) {
        if (current !== value || !owns(value)) { clear(); return }
        when (event) {
            BrowserPageSwipeModel.Event.Blank -> {
                if (!canPresent() || value.fieldEpoch != null) { clear(); return }
                val field = BrowserFieldGeometry(width.coerceAtLeast(80.0), height, 0.0, resting = true).field
                val anchor = FieldAnchor(field.x + (pane?.x ?: 0.0), field.y + (pane?.y ?: 0.0), field.width, field.height)
                value.fieldEpoch = controller.openPageSwipeField(value.lease, anchor) ?: run { clear(); return }
            }
            is BrowserPageSwipeModel.Event.Settled -> {
                // Returning from the blank never selects a tab or creates a placeholder.
                if (value.fieldEpoch == null && event.direction != 0) {
                    value.committedDirection = event.direction
                    if (!controller.settlePageSwipe(value.lease, event.direction)) clear()
                } else {
                    if (value.fieldEpoch == null) controller.settlePageSwipe(value.lease, event.direction)
                    clear()
                }
            }
            null -> Unit
        }
    }

    fun tapBlank() {
        val value = current ?: return
        val epoch = value.fieldEpoch ?: return
        if (!controller.pageSwipeCurrent(value.lease, epoch)) { clear(); return }
        if (controller.state.value.surface == BrowserSurface.FIELD) controller.dismissField(epoch)
        else if (canPresent()) { handle(value, value.model.leaveBlank(reduced)); changed() }
    }

    private fun feedback(value: BrowserPageSwipeScene) {
        if (!owns(value) || !canBegin()) return
        if (value.model.edgeTicks > value.feltEdges) feel(true, false)
        else if (value.model.ticks > value.feltTicks) feel(false, value.lease.after == null && value.model.offset < 0)
        value.feltEdges = value.model.edgeTicks; value.feltTicks = value.model.ticks
    }

    fun step(direction: Int): Boolean {
        if (direction !in listOf(-1, 1) || current != null || !begin(controller.capturePageSwipe())) return false
        end(if (direction > 0) -BrowserPageSwipeMath.slot(width) else BrowserPageSwipeMath.slot(width), 0.0)
        return true
    }

    fun clear() {
        captureGeneration++; captureJob?.cancel(); captureJob = null
        if (current?.capturing == true) captureOutcome = PagingCaptureOutcome.REVOKED.name
        current?.returnFrame?.close(); current?.model?.revoke(); current = null; revision++
    }
    private fun changed() { revision++; if (running) wake.trySend(Unit) }
}

/** The frame pump and lease live outside any selected-tab key. */
@Composable
internal fun rememberBrowserPageSwipeHost(state: BrowserState, controller: BrowserController, allowed: Boolean, beginAllowed: Boolean,
    width: Double, height: Double, pane: SpacesRect?, onVisibility: ((PageSwipeLease?, Long?) -> Unit)?,
    captureFrame: (suspend (PageSwipeLease) -> PagingCaptureResult)?): BrowserPageSwipeHostState {
    val currentAllowed by rememberUpdatedState(allowed)
    val currentBegin by rememberUpdatedState(beginAllowed)
    val view = LocalView.current
    val capture by rememberUpdatedState(captureFrame)
    val scope = rememberCoroutineScope()
    val host = remember(controller, view, scope) { BrowserPageSwipeHostState(controller, { currentAllowed }, { currentBegin },
        capture = { lease, complete -> scope.launch {
            val result = try { capture?.invoke(lease) ?: PagingCaptureResult(PagingCaptureOutcome.UNAVAILABLE) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { PagingCaptureResult(PagingCaptureOutcome.CAPTURE_FAILED) }
            try { coroutineContext.ensureActive(); complete(result) }
            catch (cancelled: CancellationException) { result.frame?.close(); throw cancelled }
        } }) { edge, newTab ->
        // Android's own feedback policy respects the person's view/system settings.
        view.performHapticFeedback(if (edge) HapticFeedbackConstants.CONTEXT_CLICK else if (newTab) HapticFeedbackConstants.VIRTUAL_KEY else HapticFeedbackConstants.CLOCK_TICK)
    } }
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val callback by rememberUpdatedState(onVisibility)
    val scene = host.scene
    SideEffect { callback?.invoke(scene?.lease, scene?.fieldEpoch) }
    LaunchedEffect(host, state, allowed, beginAllowed, width, height, pane, reduced) { host.configure(width, height, pane, reduced, state) }
    LaunchedEffect(host) {
        for (ignored in host.wake) {
            var last = 0L
            while (host.running) withFrameNanos { now ->
                val dt = if (last == 0L) 1.0 / 60 else min(.05, (now - last).coerceAtLeast(0) / 1e9)
                last = now; host.frame(now, dt)
            }
        }
    }
    DisposableEffect(host) { onDispose { host.clear(); host.wake.close(); callback?.invoke(null, null) } }
    return host
}

/** Every native page has one stable key/slot, including the neighbor that becomes selected. */
@Composable
internal fun BrowserPageSwipeDeck(state: BrowserState, tab: BrowserTab?, host: BrowserPageSwipeHostState?, modifier: Modifier,
    page: @Composable (BrowserTab, WebsiteProfile, Modifier) -> Unit, empty: @Composable () -> Unit,
    blank: @Composable (Modifier) -> Unit, pageTop: androidx.compose.ui.unit.Dp = 0.dp) {
    val scene = host?.scene
    val density = LocalDensity.current.density
    val profile = scene?.lease?.profile ?: state.space?.websiteProfile
    if (profile == null || tab == null) { Box(modifier) { empty() }; return }
    val offset = scene?.model?.offset ?: 0.0
    val beside = scene?.let { BrowserPageSwipeMath.beside(it.model.width, offset) }
    val entries = if (scene == null) listOf(tab) else listOfNotNull(scene.lease.before, scene.lease.front, scene.lease.after)
    Box(modifier.clipToBounds().background(if (profile.isPrivate) Color(0xFF0E0D12) else state.space?.let { Color(it.color) } ?: MaterialTheme.colorScheme.background)
        .testTag("browser.paging.deck").semantics {
            if (host != null) this[PageSwipeCaptureKey] = host.captureOutcome
            if (scene != null) {
                this[PageSwipePoseKey] = listOf(offset.toFloat(), scene.model.slot.toFloat(), beside!!.first.toFloat(), beside.second.toFloat())
                this[PageSwipePhaseKey] = scene.phase
            }
        }) {
        for (entry in entries) key(entry.id) {
            var measured by remember { mutableStateOf(emptyList<Float>()) }
            val role = when {
                scene == null || entry.id == scene.lease.front.id -> "front"
                entry.id == scene.lease.before?.id -> "before"
                else -> "after"
            }
            val x = when (role) { "before" -> beside?.first ?: 0.0; "after" -> beside?.second ?: 0.0; else -> offset }
            val returning = scene?.returnFrame != null
            val heldBeside = scene?.takeIf { returning }?.let { BrowserPageSwipeMath.beside(it.model.width, it.fadeFromOffset) }
            val fadingTarget = scene?.fadeDirection?.let { when { it < 0 -> scene.lease.before?.id; it > 0 -> scene.lease.after?.id; else -> scene.lease.front.id } }
            val target = fadingTarget == entry.id
            val drawX = if (returning) when (role) { "before" -> heldBeside!!.first; "after" -> heldBeside!!.second; else -> 0.0 }
                else if (scene?.fading == true) if (target) 0.0 else scene.fadeFromOffset else x
            val opacity = if (returning) if (role == "front") scene!!.fadeProgress else 1.0
                else if (scene?.fading == true) if (target) scene.fadeProgress else if (role == "front") 1 - scene.fadeProgress else 0.0 else 1.0
            Box(Modifier.fillMaxSize().offset(x = drawX.dp).graphicsLayer { alpha = opacity.toFloat() }
                .zIndex(if (returning && role == "front") 1f else 0f)
                .clip(RoundedCornerShape(if (scene != null && !(returning && role == "front")) BrowserPageSwipeMath.cardCorner.dp else 0.dp))
                .onGloballyPositioned { coordinates ->
                    val p = coordinates.positionInRoot()
                    measured = listOf(p.x / density, p.y / density, coordinates.size.width / density, coordinates.size.height / density)
                }.testTag("browser.paging.page.$role").semantics { this[PageSwipePagePositionKey] = measured }) {
                // Keep diagnostic role/geometry on the outer slot while clearing the neighbor's
                // actual page body. clearAndSetSemantics on that outer slot also erased its tag.
                Box(Modifier.fillMaxSize().then(if (scene != null && entry.id != state.tab?.id) Modifier.clearAndSetSemantics {} else Modifier)) {
                    // A page starts under the status bar, on a strip of the browser's own paper, so
                    // its header never sits under the clock (iPhone: WKWebView obscuredContentInsets).
                    if (!entry.isBlank) Column(Modifier.fillMaxSize()) {
                        if (pageTop > 0.dp) Box(Modifier.fillMaxWidth().height(pageTop).background(statusStrip(profile.isPrivate)))
                        page(entry, profile, Modifier.fillMaxWidth().weight(1f))
                    } else empty()
                }
            }
        }
        if (scene != null && scene.lease.after == null) {
            val returning = scene.returnFrame != null
            val blankX = if (returning) BrowserPageSwipeMath.beside(scene.model.width, scene.fadeFromOffset).second else beside!!.second
            Box(Modifier.fillMaxSize().offset(x = blankX.dp).clip(RoundedCornerShape(BrowserPageSwipeMath.cardCorner.dp))
                .graphicsLayer { alpha = if (scene.fading && !returning) scene.fadeProgress.toFloat() else 1f }
                .testTag("browser.paging.blank").clickable(enabled = scene.model.blank, onClick = { host?.tapBlank() })) {
                blank(Modifier.fillMaxSize().clearAndSetSemantics {})
            }
        }
        scene?.returnFrame?.bitmapIfCurrent()?.let { bitmap ->
            // Keep the old scene fully opaque underneath the incoming full page. Fading both
            // layers would blend the background twice and darken a cross-dissolve.
            Box(Modifier.fillMaxSize().offset(x = scene.fadeFromOffset.dp).zIndex(.5f)
                .clip(RoundedCornerShape(BrowserPageSwipeMath.cardCorner.dp)).testTag("browser.paging.ram-frame")
                .background(statusStrip(profile.isPrivate))) {
                // The frame is the page alone, so it sits where the live page sits, under the strip.
                Image(bitmap.asImageBitmap(), contentDescription = null, contentScale = ContentScale.FillBounds,
                    modifier = Modifier.fillMaxSize().padding(top = pageTop).clearAndSetSemantics {})
            }
        }
        if (scene != null && !scene.model.blank) Box(Modifier.fillMaxSize().pointerInput(scene) {
            // The chrome keeps its separate gesture path; a card moving under it cannot receive a stray page tap.
            awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
        })
    }
}

@Composable
private fun statusStrip(private: Boolean) = if (private) Color(0xFF0E0D12) else MaterialTheme.colorScheme.background

@Composable
internal fun BrowserPageSwipeLabels(scene: BrowserPageSwipeScene, pointSize: Float, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.clipToBounds().clearAndSetSemantics {}) {
        val labelWidth = maxWidth.value.toDouble()
        val slide = (if (scene.fading) scene.fadeFromOffset else scene.model.offset) * labelWidth / scene.model.slot
        val labels = listOf(scene.lease.before to -labelWidth, scene.lease.front to 0.0, scene.lease.after to labelWidth)
        for ((tab, position) in labels) {
            if (tab != null || position > 0 && scene.lease.after == null) Box(Modifier.width(labelWidth.dp).fillMaxHeight()
                .offset(x = (slide + position).dp).graphicsLayer { alpha = if (scene.fading && scene.returnFrame == null) (1 - scene.fadeProgress).toFloat() else 1f },
                contentAlignment = Alignment.Center) {
                PageSwipeLabel(tab, pointSize)
            }
        }
        if (scene.fading) Box(Modifier.fillMaxSize().graphicsLayer { alpha = scene.fadeProgress.toFloat() }, contentAlignment = Alignment.Center) {
            PageSwipeLabel(when { scene.fadeDirection!! < 0 -> scene.lease.before; scene.fadeDirection!! > 0 -> scene.lease.after; else -> scene.lease.front }, pointSize)
        }
    }
}

@Composable
private fun PageSwipeLabel(tab: BrowserTab?, pointSize: Float) {
    if (tab != null) BrowserChromeLabel(browserChromeAddress(tab.url), pointSize, Modifier.fillMaxWidth())
    else Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(YabGlyphs.PlusMedium, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text("New Tab", fontSize = pointSize.sp)
    }
}

package dev.yab.browser.ui

import android.animation.ValueAnimator
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.PageMenuLease
import kotlinx.coroutines.CancellationException
import kotlin.math.abs
import kotlin.math.hypot

/** Captured rows and callbacks belong to this one lease. Do not close over a mutable selected tab
 * or a replacement account. current() must synchronously compare atomic account/device/epoch,
 * controller surface/tab/profile, privacy availability and the captured native document owner.
 * It deliberately remains valid through a normal close while those source facts stay unchanged.
 * The owner of this entry retains it until released(), using an exact-generation CAS to remove it. */
internal class BrowserPageMenuEntry(
    val lease: PageMenuLease,
    val current: () -> Boolean,
    /** CAS the logical shown target, retaining this entry until released(). */
    val closing: (PageMenuLease) -> Unit,
    val released: (PageMenuLease, PageMenuRelease) -> Unit,
    /** Explicit platform predictor. SwiftUI's predictedEndTranslation is not implemented here. */
    val predictedEndY: (translation: Double, velocity: Double) -> Double,
    val background: @Composable (Modifier, BrowserPageMenuPose) -> Unit,
    val address: @Composable (BrowserPageMenuScope, Modifier) -> Unit,
    val menu: @Composable (BrowserPageMenuScope) -> Unit,
    val site: @Composable (BrowserPageMenuScope) -> Unit,
    val certificate: @Composable (BrowserPageMenuScope) -> Unit,
    val reopened: (PageMenuLease) -> Unit = {},
    val editAddress: ((PageMenuRect) -> Boolean)? = null,
) {
    val presentation = BrowserPageMenuPresentation(lease)
    internal val layoutLease = BrowserPageMenuLayoutLease()
    internal var measuredMenu by mutableDoubleStateOf(0.0)
    internal var measuredSite by mutableDoubleStateOf(0.0)
    internal var measuredCertificate by mutableDoubleStateOf(0.0)
    internal var fieldHandoff by mutableStateOf<BrowserPageMenuFieldHandoff?>(null)
    internal fun owned() = layoutLease.valid && current()
    internal fun drawingOwned() = layoutLease.valid && (fieldHandoff?.owned() ?: current())
    internal fun close(nanos: Long, reduced: Boolean, animations: Boolean, action: (() -> Unit)? = null): Boolean {
        if (!owned() || !presentation.close(nanos, reduced, animations, action)) return false
        if (owned()) closing(lease)
        return true
    }
    internal fun reopen(nanos: Long, reduced: Boolean, animations: Boolean) {
        if (!owned() || presentation.frame.value.phase != PageMenuPhase.CLOSING) return
        presentation.open(nanos, reduced, animations)
        if (owned() && presentation.frame.value.shown) reopened(lease)
    }
}

/** All functional controls use perform(); an enabled flag alone cannot authorize a delayed tap. */
internal class BrowserPageMenuScope internal constructor(val pose: BrowserPageMenuPose, val enabled: Boolean,
    val page: PageMenuPage, private val entry: BrowserPageMenuEntry, private val reduced: Boolean,
    private val animations: Boolean, private val bodyPage: PageMenuPage? = null) {
    private fun live(): Boolean {
        if (!enabled || !entry.owned()) return false
        val frame = entry.presentation.frame.value
        if (!frame.interactive) return false
        return when (bodyPage) {
            PageMenuPage.MENU -> frame.site == 0.0
            PageMenuPage.SITE -> frame.site == 1.0 && frame.certificate == 0.0
            PageMenuPage.CERTIFICATE -> frame.certificate == 1.0
            null -> true
        }
    }
    fun perform(afterLanding: Boolean = false, action: (PageMenuLease) -> Unit): Boolean {
        if (!live()) return false
        val source = entry.lease
        if (afterLanding) return entry.close(System.nanoTime(), reduced, animations) {
            if (entry.owned()) action(source)
        }
        if (!entry.owned()) return false
        action(source); return true
    }
    fun close() {
        entry.close(System.nanoTime(), reduced, animations)
    }
    fun navigate(destination: PageMenuPage): Boolean = live() &&
        entry.presentation.navigate(destination, System.nanoTime(), reduced, animations)
    fun back(): Boolean = live() && entry.presentation.back(System.nanoTime(), reduced, animations)
    val supportsFieldHandoff get() = entry.editAddress != null
    fun editAddress(): Boolean = live() && entry.editAddress?.invoke(pose.row) == true
}

/** Fixture-only animator override. Normal usage honors the actual Android setting. */
internal val LocalPageMenuAnimationsEnabled = staticCompositionLocalOf<Boolean?> { null }
internal val LocalPageMenuDrawObserver = staticCompositionLocalOf<((PageMenuFrame, BrowserPageMenuPose, Long) -> Unit)?> { null }

/** The host replaces no functional rows and supplies no imitation glass. The integration supplies
 * its actual background and captured content slots, and positions this host in the same root used
 * by the measured plate. It must keep the underlying plate/menu opener outside the morph's mask. */
@Composable
internal fun BrowserPageMenuHost(entry: BrowserPageMenuEntry, shown: Boolean, geometry: BrowserPageMenuGeometry,
    modifier: Modifier = Modifier) {
    val presentation = entry.presentation
    val frame by presentation.frame.collectAsState()
    val density = LocalDensity.current.density
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val animations = LocalPageMenuAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()
    val observer = LocalPageMenuDrawObserver.current
    val layoutCurrent = entry.layoutLease.accept(geometry)
    // A stale owner is removed before composition emits its text, accessibility nodes or images.
    // The draw guard closes the gap before an atomic account/native-owner change is collected.
    fun complete() {
        presentation.claimCompletion { it == entry.lease && entry.drawingOwned() }?.let { completion ->
            entry.released(entry.lease, completion.reason)
            if (completion.reason == PageMenuRelease.LANDED && entry.owned()) completion.action?.invoke()
        }
    }
    if (!layoutCurrent || !entry.drawingOwned() || frame.phase == PageMenuPhase.REVOKED) {
        SideEffect { presentation.revoke(); complete() }
        return
    }
    if (frame.phase in setOf(PageMenuPhase.CLOSED, PageMenuPhase.HANDED_OFF)) { SideEffect { complete() }; return }
    val measured = geometry.copy(menuBody = entry.measuredMenu.takeIf { it > 0 } ?: geometry.menuBody,
        siteBody = entry.measuredSite.takeIf { it > 0 } ?: geometry.siteBody,
        certificateBody = entry.measuredCertificate.takeIf { it > 0 } ?: geometry.certificateBody,
        field = entry.fieldHandoff?.destination ?: geometry.field)
    val actualGeometry by rememberUpdatedState(measured)
    val pose = measured.pose(frame, reduced)
    val interactive = shown && frame.interactive && entry.fieldHandoff == null
    val page = if (frame.certificate > .5) PageMenuPage.CERTIFICATE else if (frame.site > .5) PageMenuPage.SITE else PageMenuPage.MENU
    fun scope(enabled: Boolean, bodyPage: PageMenuPage? = null) =
        BrowserPageMenuScope(pose, interactive && enabled, page, entry, reduced, animations, bodyPage)
    BackHandler(enabled = entry.fieldHandoff == null) { entry.close(System.nanoTime(), reduced, animations) }
    DisposableEffect(entry) { onDispose { if (!entry.drawingOwned()) presentation.revoke() } }
    val handoff = entry.fieldHandoff
    LaunchedEffect(entry, shown, reduced, animations, handoff) {
        if (handoff != null) {
            if (!entry.drawingOwned()) presentation.revoke()
        } else if (shown) {
            // A mounted first frame is the captured plate. Measure bodies before starting the rise.
            if (presentation.frame.value.phase == PageMenuPhase.MOUNTED) { withFrameNanos { }; withFrameNanos { } }
            if (entry.owned()) presentation.open(System.nanoTime(), reduced, animations) else presentation.revoke()
        } else if (entry.owned()) presentation.close(System.nanoTime(), reduced, animations)
        else presentation.revoke()
        complete()
    }
    LaunchedEffect(entry, handoff, handoff?.destination) {
        handoff?.start(presentation, System.nanoTime())
        complete()
    }
    // One aggregate clock, so a site/certificate runner starting during the rise never restarts it.
    LaunchedEffect(entry, frame.running) {
        while (presentation.frame.value.running) withFrameNanos {
            // UI callbacks and this clock share the actual monotonic domain, including when an
            // accessibility fixture has a separate synthetic Compose test clock.
            if (!entry.drawingOwned()) presentation.revoke() else presentation.advance(System.nanoTime())
            complete()
        }
    }
    val contentGuard = if (interactive) Modifier else Modifier.clearAndSetSemantics {}.pointerInput(entry, shown) {
        awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
    }
    Box(modifier.fillMaxSize().testTag("browser.pageMenu.host")
        .semantics { isTraversalGroup = true; paneTitle = "Page Menu" }
        .pointerInput(entry, density, reduced, animations) {
            try {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val startPose = actualGeometry.pose(presentation.frame.value, reduced)
                    val point = down.position / density
                    if (!entry.owned() || !presentation.frame.value.interactive ||
                        point.x < startPose.sheet.x || point.x > startPose.sheet.right ||
                        point.y < startPose.sheet.y + startPose.sink || point.y > startPose.sheet.bottom + startPose.sink) return@awaitEachGesture
                    val tracker = VelocityTracker().apply { addPosition(down.uptimeMillis, down.position) }
                    var dragging = false
                    while (true) {
                        val change = awaitPointerEvent(PointerEventPass.Main).changes.firstOrNull { it.id == down.id }
                        if (!entry.owned()) {
                            // The address's accepted UP transferred input to the actual Field.
                            if (entry.fieldHandoff?.owned() != true) presentation.revoke()
                            break
                        }
                        if (change == null || change.isConsumed) {
                            if (dragging) presentation.cancelDrag(System.nanoTime(), reduced, animations)
                            break
                        }
                        tracker.addPosition(change.uptimeMillis, change.position)
                        val delta = (change.position - down.position) / density
                        if (!change.pressed) {
                            if (dragging) {
                                val predicted = entry.predictedEndY(delta.y.toDouble(), tracker.calculateVelocity().y / density.toDouble())
                                if (predicted.isFinite()) {
                                    if (presentation.release(predicted, startPose.travel, System.nanoTime(), reduced, animations) && entry.owned()) entry.closing(entry.lease)
                                }
                                else presentation.cancelDrag(System.nanoTime(), reduced, animations)
                                complete()
                            }
                            break
                        }
                        if (!dragging && hypot(delta.x.toDouble(), delta.y.toDouble()) >= 10 && abs(delta.y) > abs(delta.x) && delta.y > 0)
                            dragging = presentation.beginDrag(System.nanoTime())
                        if (dragging) { change.consume(); presentation.drag(delta.y.toDouble()) }
                    }
                }
            } catch (cancelled: CancellationException) {
                if (entry.owned()) presentation.cancelDrag(System.nanoTime(), reduced, animations)
                else if (entry.fieldHandoff?.owned() != true) presentation.revoke()
                throw cancelled
            }
        }.drawWithContent {
            if (entry.drawingOwned()) { drawContent(); observer?.invoke(frame, pose, System.nanoTime()) }
        }) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = pose.scrim.toFloat()))
            .clickable(enabled = shown && frame.shown && handoff == null) { scope(true).close() }
            .then(if (handoff == null) Modifier else Modifier.clearAndSetSemantics {})
            .semantics { contentDescription = "Close Menu" }.testTag("browser.pageMenu.scrim"))
        Box(Modifier.fillMaxSize().then(contentGuard).graphicsLayer { alpha = pose.opacity.toFloat(); translationY = (pose.sink * density).toFloat() }) {
            entry.background(positioned(pose.sheet).clearAndSetSemantics {}, pose)
            val mask = Modifier.drawWithContent {
                val path = Path().apply { addRoundRect(RoundRect(Rect((pose.sheet.x * density).toFloat(), (pose.sheet.y * density).toFloat(),
                    (pose.sheet.right * density).toFloat(), (pose.sheet.bottom * density).toFloat()), CornerRadius((pose.radius * density).toFloat()))) }
                clipPath(path) { this@drawWithContent.drawContent() }
            }
            Box(Modifier.fillMaxSize().then(mask).graphicsLayer { alpha = pose.bodyOpacity.toFloat(); translationY = (pose.bodyOffset * density).toFloat() }) {
                body(entry, PageMenuPage.MENU, scope(frame.site == 0.0, PageMenuPage.MENU), pose, geometry.width, density)
                body(entry, PageMenuPage.SITE, scope(frame.site == 1.0 && frame.certificate == 0.0, PageMenuPage.SITE), pose, geometry.width, density)
                body(entry, PageMenuPage.CERTIFICATE, scope(frame.certificate == 1.0, PageMenuPage.CERTIFICATE), pose, geometry.width, density)
            }
            entry.address(scope(true), positioned(pose.row).graphicsLayer { alpha = pose.rowOpacity.toFloat() })
        }
        if (frame.phase == PageMenuPhase.CLOSING) Box(positioned(geometry.plate)
            .clickable { entry.reopen(System.nanoTime(), reduced, animations) }
            .semantics { contentDescription = "Page menu" }.testTag("browser.pageMenu.reopen"))
    }
}

@Composable
private fun body(entry: BrowserPageMenuEntry, page: PageMenuPage, scope: BrowserPageMenuScope,
    pose: BrowserPageMenuPose, viewportWidth: Double, density: Float) {
    val alpha = when (page) { PageMenuPage.MENU -> 1 - pose.site; PageMenuPage.SITE -> pose.site * (1 - pose.certificate) * pose.block(0)
        PageMenuPage.CERTIFICATE -> pose.certificate * pose.block(0) }
    val active = when (page) { PageMenuPage.MENU -> pose.site == 0.0; PageMenuPage.SITE -> pose.site == 1.0 && pose.certificate == 0.0
        PageMenuPage.CERTIFICATE -> pose.certificate == 1.0 }
    val visibleToAccessibility = when (page) { PageMenuPage.MENU -> pose.site <= .5; PageMenuPage.SITE -> pose.site >= .5 && pose.certificate <= .5
        PageMenuPage.CERTIFICATE -> pose.certificate >= .5 }
    val y = pose.sheet.y + 78 + when (page) { PageMenuPage.MENU -> -8 * pose.site
        PageMenuPage.SITE -> 8 * (1 - pose.site) - 8 * pose.certificate; PageMenuPage.CERTIFICATE -> 8 * (1 - pose.certificate) }
    // The real bodies are measured offscreen before adoption, with their semantics/actions hidden.
    Column(Modifier.offset(x = (if (alpha > 0) 8.0 else 8 + 2 * viewportWidth).dp, y = y.dp)
        .width((viewportWidth - 16).dp).heightIn(max = pose.bodyRoom.dp)
        .graphicsLayer { this.alpha = alpha.toFloat() }
        .then(if (visibleToAccessibility && scope.enabled) Modifier else Modifier.clearAndSetSemantics {})
        .then(if (scope.enabled) Modifier else Modifier.pointerInput(entry, page) {
            awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
        })
        .verticalScroll(rememberScrollState(), enabled = active && scope.enabled && page != PageMenuPage.CERTIFICATE)) {
        Column(Modifier.fillMaxWidth().onSizeChanged { size ->
            if (entry.owned()) when (page) {
                PageMenuPage.MENU -> entry.measuredMenu = size.height / density.toDouble()
                PageMenuPage.SITE -> entry.measuredSite = size.height / density.toDouble()
                PageMenuPage.CERTIFICATE -> entry.measuredCertificate = size.height / density.toDouble()
            }
        }) {
            when (page) { PageMenuPage.MENU -> entry.menu(scope); PageMenuPage.SITE -> entry.site(scope)
                PageMenuPage.CERTIFICATE -> entry.certificate(scope) }
        }
    }
}

private fun positioned(rect: PageMenuRect) = Modifier.offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)

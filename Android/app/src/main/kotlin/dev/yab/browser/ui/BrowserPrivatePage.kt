package dev.yab.browser.ui

import android.animation.ValueAnimator
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.yab.browser.model.BrowserTab
import kotlinx.coroutines.launch

internal val FieldPrivatePoseKey = SemanticsPropertyKey<List<Float>>("FieldPrivatePose")
internal val FieldPrivateInkKey = SemanticsPropertyKey<Float>("FieldPrivateInk")
/** Controlled component fixtures only. Production null reads the actual platform animator flag. */
internal val LocalFieldPageAnimationsEnabled = staticCompositionLocalOf<Boolean?> { null }
internal val LocalFieldPrivateDrawObserver = staticCompositionLocalOf<((FieldPrivateFrame, Rect, Long) -> Unit)?> { null }

/** Private's page is an in-place field page. Device authentication is supplied by the existing
 * host. A lock/owner/lifecycle change suppresses private drawing before an effect can run. */
@Composable
internal fun BrowserPrivatePage(tabs: List<BrowserTab>, locked: Boolean, interactive: Boolean,
    ownerCurrent: () -> Boolean, inputCurrent: () -> Boolean, authorizationCurrent: () -> Boolean,
    onUnlock: ((Boolean) -> Unit) -> Unit, onPick: (BrowserTab) -> Unit,
    modifier: Modifier = Modifier, animationsEnabled: Boolean = LocalFieldPageAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var foreground by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    val scope = rememberCoroutineScope()
    val model = remember { BrowserFieldPrivatePresentation(!locked) }
    val frameClock = remember(model) { BrowserFieldPageClock() }
    val frame by model.frame.collectAsState()
    val own by rememberUpdatedState(ownerCurrent)
    val authorized by rememberUpdatedState(authorizationCurrent)
    val lockedNow by rememberUpdatedState(locked)
    var wasLocked by remember { mutableStateOf(locked) }
    var bounds by remember { mutableStateOf(Rect.Zero) }
    val observer = LocalFieldPrivateDrawObserver.current
    fun mayDrawPrivate() = own() && !lockedNow && authorized() && foreground && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    // Never retain old private words, icons or tab counts under a fading lock.
    val visible = if ((locked || !authorized()) && frame.phase in setOf(FieldPrivatePhase.OPENING, FieldPrivatePhase.REVEALING, FieldPrivatePhase.REVEALED))
        FieldPrivateFrame(FieldPrivatePhase.LOCKED) else frame
    SideEffect {
        if (!own()) model.revoke()
        else if ((locked || !authorized()) && (!wasLocked || frame.phase in setOf(FieldPrivatePhase.OPENING, FieldPrivatePhase.REVEALING, FieldPrivatePhase.REVEALED))) model.lock()
        else if (!locked && authorized() && frame.phase in setOf(FieldPrivatePhase.LOCKED, FieldPrivatePhase.TRYING))
            model.authorized(frameClock.event(model.frame.value.running), tabs.isNotEmpty(), animationsEnabled)
        wasLocked = locked
    }
    DisposableEffect(model, lifecycle) {
        val watch = LifecycleEventObserver { _, event ->
            foreground = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if (event == Lifecycle.Event.ON_STOP && lockedNow) model.lock()
        }
        lifecycle.addObserver(watch)
        onDispose { lifecycle.removeObserver(watch); model.revoke() }
    }
    LaunchedEffect(model, frame.running) {
        while (model.frame.value.running) withFrameNanos { model.advance(frameClock.frame(it)) }
    }
    BoxWithConstraints(modifier.fillMaxSize().testTag("browser.field.private.page")
        .onGloballyPositioned { bounds = it.boundsInWindow() }
        .semantics { this[FieldPrivatePoseKey] = listOf(visible.phase.ordinal.toFloat(), visible.shackle.toFloat(),
            visible.words.toFloat(), visible.glide.toFloat(), visible.list.toFloat()) }
        .drawWithContent { if (own()) { drawContent(); observer?.invoke(visible, bounds, System.nanoTime()) } }) {
        val list = visible.list.coerceIn(0.0, 1.0)
        if (mayDrawPrivate() && list > 0) {
            FieldPageInputGate(interactive && inputCurrent(), Modifier.fillMaxSize().graphicsLayer {
                alpha = list.toFloat()
                val scale = if (tabs.isEmpty()) (.94 + .06 * list).toFloat() else 1f
                scaleX = scale; scaleY = scale
                translationY = if (tabs.isEmpty()) 0f else ((1 - list) * 14.dp.toPx()).toFloat()
            }.drawWithContent { if (mayDrawPrivate()) drawContent() }) {
                if (tabs.isEmpty()) PrivateEmptyPage()
                else LazyColumn(Modifier.fillMaxSize().testTag("browser.field.private.tabs"), contentPadding = PaddingValues(top = 12.dp, bottom = 16.dp)) {
                    item { Text("Private", Modifier.padding(start = 24.dp, bottom = 8.dp).semantics { heading() },
                        color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, letterSpacing = (-.4).sp) }
                    items(tabs, key = BrowserTab::id) { tab ->
                        Row(Modifier.fillMaxWidth().testTag("browser.field.private.tab.${tab.id}")
                            .clickable(enabled = interactive, onClick = { if (inputCurrent() && mayDrawPrivate()) onPick(tab) })
                            .padding(horizontal = 24.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            BrowserFavicon(tab, 22.dp)
                            Column(Modifier.padding(start = 12.dp).weight(1f)) {
                                Text(tab.title, color = Color.White, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(tab.host, color = Color.White.copy(alpha = .6f), fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
        }
        if (visible.phase != FieldPrivatePhase.REVOKED && list < 1) {
            // The complete source lock stack is centered. Removing the words lets the
            // lock travel to the same page center; it never reveals whether tabs exist.
            val glide = visible.glide.coerceIn(0.0, 1.0)
            val restingTop = ((maxHeight.value - 167f) / 2).coerceAtLeast(0f)
            val waitingTop = ((maxHeight.value - 34f) / 2).coerceAtLeast(0f)
            Column(Modifier.fillMaxWidth().offset(y = (restingTop + (waitingTop - restingTop) * glide).dp)
                .graphicsLayer { alpha = (1 - list).toFloat(); scaleX = (1 - .1 * list).toFloat(); scaleY = scaleX }
                .testTag("browser.field.private.lock"), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.size(34.dp)) {
                    Icon(YabGlyphs.Lock, null, Modifier.fillMaxSize().graphicsLayer { alpha = (1 - visible.shackle).toFloat().coerceIn(0f, 1f) }, tint = Color.White.copy(alpha = .55f))
                    Icon(YabGlyphs.TabletUnlock, null, Modifier.fillMaxSize().graphicsLayer { alpha = visible.shackle.toFloat().coerceIn(0f, 1f) }, tint = Color.White.copy(alpha = .55f))
                }
                if (visible.words > 0) Column(Modifier.fillMaxWidth().graphicsLayer { alpha = visible.words.toFloat() }, horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Private is Locked", Modifier.padding(top = 20.dp).semantics { heading() }, color = Color.White.copy(alpha = .55f), fontSize = 17.sp)
                    Button(enabled = interactive && visible.phase == FieldPrivatePhase.LOCKED, modifier = Modifier.padding(top = 20.dp).testTag("browser.field.private.unlock"), onClick = {
                        if (!inputCurrent() || !ownerCurrent() || !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return@Button
                        val capturedOwner = ownerCurrent; val capturedInput = inputCurrent
                        val token = model.request(frameClock.event(model.frame.value.running), animationsEnabled) ?: return@Button
                        onUnlock { allowed ->
                            scope.launch {
                                if (capturedOwner() && capturedInput() && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
                                    model.received(token, allowed, frameClock.event(model.frame.value.running), tabs.isNotEmpty(), animationsEnabled)
                            }
                        }
                    }) { Text("Unlock", fontSize = 15.sp) }
                    Text(if (visible.failed) "Private is still locked." else " ", Modifier.padding(top = 20.dp, start = 32.dp, end = 32.dp),
                        color = Color.White.copy(alpha = .6f), fontSize = 13.sp, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

/** The parent pager keeps its native drag stream. Each child separately gates actions. */
@Composable
internal fun FieldPageInputGate(enabled: Boolean, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(modifier.then(if (enabled) Modifier else Modifier.clearAndSetSemantics {}), content = content)
}

@Composable
private fun PrivateEmptyPage() {
    BoxWithConstraints(Modifier.fillMaxSize().testTag("browser.field.private.empty")) {
        Column(Modifier.fillMaxWidth().padding(top = (maxHeight.value / 2 - 14).coerceAtLeast(0f).dp), horizontalAlignment = Alignment.CenterHorizontally) {
            PrivateMask()
            Text("Nothing open in Private", Modifier.padding(top = 12.dp), color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text("What you open here stays on this device,\nwith no history or sync.", Modifier.padding(top = 3.dp, start = 32.dp, end = 32.dp),
                color = Color.White.copy(alpha = .6f), fontSize = 13.sp, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun PrivateMask() {
    // Original current Phone Resources/Icons/Incognito.svg, native 24×24 path.
    val path = remember { PathParser().parsePathString("M19 11H21M19 11L18.2453 5.71716C18.1046 4.73186 17.2607 4 16.2654 4H7.73459C6.73929 4 5.89545 4.73186 5.75469 5.71716L5 11M19 11H5M3 11H5M9.99144 16.7717C9.87481 15.2215 8.58005 14 7 14C5.34315 14 4 15.3431 4 17C4 18.6569 5.34315 20 7 20C8.65685 20 10 18.6569 10 17C10 16.9232 9.99711 16.8471 9.99144 16.7717ZM9.99144 16.7717C11.1308 15.7429 12.8691 15.7428 14.0086 16.7713M14.0086 16.7713C14.0029 16.8468 14 16.9231 14 17C14 18.6569 15.3431 20 17 20C18.6569 20 20 18.6569 20 17C20 15.3431 18.6569 14 17 14C15.4201 14 14.1254 15.2213 14.0086 16.7713Z").toPath() }
    Canvas(Modifier.size(28.dp)) {
        scale(size.width / 24, size.height / 24, pivot = androidx.compose.ui.geometry.Offset.Zero) {
            drawPath(path, Color.White.copy(alpha = .92f), style = Stroke(2f, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
    }
}

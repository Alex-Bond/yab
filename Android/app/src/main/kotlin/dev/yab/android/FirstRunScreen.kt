package dev.yab.android

import android.animation.ValueAnimator
import androidx.activity.compose.BackHandler
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.BrowserWorkspaceWindow
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.ui.LocalBrowserAccessibility
import dev.yab.sync.AndroidSyncBridge
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.hypot

/** All interaction belongs to the current original Host, never to a later rendered step. */
@Composable
internal fun FirstRunScreen(
    flow: FirstRunPresentation,
    host: FirstRunPresentation.Host,
    sync: AndroidSyncBridge,
    tablet: Boolean,
    window: BrowserWorkspaceWindow,
    spaces: List<BrowserSpace>,
    role: FirstRunPresentation.DefaultBrowser,
    macName: String,
    requestDefault: () -> Unit,
    finish: (FirstRunPresentation.Completion) -> Boolean,
    copy: (String) -> Unit,
    haptic: (FirstRunPresentation.Haptic) -> Unit,
    modifier: Modifier = Modifier,
) {
    val value by flow.state.collectAsState()
    val syncState by sync.ui.collectAsState()
    val requestSnapshot = value.request?.presentation?.collectAsState()?.value
    SideEffect { flow.observeRequest(host, value.request, requestSnapshot) }
    val handoffSnapshot = value.handoff?.presentation?.collectAsState()?.value
    SideEffect { flow.observeRecovery(host, value.handoff, handoffSnapshot) }
    SideEffect { if (!value.ownedRequest) flow.observeCode(host, syncState.code) }
    SideEffect { flow.observe(host) }
    // Keep the existing preference publisher as an invalidation signal, but Phone's
    // named FirstRun motions/pauses skip only when animations are disabled.
    val animationsDisabled = LocalBrowserAccessibility.current.let { !ValueAnimator.areAnimatorsEnabled() }
    val scopeControl = remember(flow, host, value.revision, value.codeRevision, value.failureRevision, value.requestBindingRevision) { flow.control(host) }
    DisposableEffect(scopeControl) { onDispose { scopeControl?.retire() } }
    LaunchedEffect(flow, host) { flow.begin(scopeControl) }
    val timer = remember(flow, host, value.revision, animationsDisabled) { flow.timer(host, animationsDisabled) }
    DisposableEffect(timer) { onDispose { timer?.control?.retire() } }
    val currentRole by rememberUpdatedState(role)
    LaunchedEffect(timer) {
        if (timer != null) { delay(timer.delayMillis); flow.advance(timer, currentRole, finish) {
            if (host.current()) haptic(FirstRunPresentation.Haptic.JOINED)
        } }
    }
    fun confirmed(ok: Boolean) { if (ok && host.current()) haptic(FirstRunPresentation.Haptic.CONFIRM) }
    val joined = { if (host.current()) haptic(FirstRunPresentation.Haptic.JOINED); Unit }
    val beginCode: ((dev.yab.sync.SyncIdentityLease) -> Unit, () -> Unit) -> dev.yab.sync.CodeJoinRequest = { success, failure ->
        sync.joinRequest(onJoined = success, onJoinFailed = failure)
    }
    fun goBack(control: FirstRunPresentation.Control?) = flow.backGuardedRequest(control, if (value.ownedRequest) value.codeValue else syncState.code,
        sync::cancelJoin, beginCode, joined)
    key(scopeControl) {
        BackHandler(value.step in setOf(FirstRunPresentation.Step.CODE, FirstRunPresentation.Step.RECOVERY,
            FirstRunPresentation.Step.NO_MAC, FirstRunPresentation.Step.LINKS)) {
            if (value.step == FirstRunPresentation.Step.LINKS) flow.notNow(scopeControl)
            else confirmed(goBack(scopeControl))
        }
    }
    if (value.step == FirstRunPresentation.Step.FINISHED) return
    val density = LocalDensity.current
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    val ground by animateFloatAsState(if (value.groundUp) 1f else 0f,
        tween(if (animationsDisabled) 0 else 300, easing = CubicBezierEasing(0f, 0f, .58f, 1f)), label = "welcome ground")
    var rootY by remember { mutableFloatStateOf(0f) }
    BoxWithConstraints(modifier.fillMaxSize().onGloballyPositioned {
        rootY = it.positionInWindow().y / density.density
    }.testTag("welcome").semantics { paneTitle = "Welcome to Yab" }) {
        // Background owns only its sibling hit path, never a live control's MOVE.
        Box(Modifier.matchParentSize().pointerInput(flow, host, value.step) { awaitPointerEventScope {
            while (true) awaitPointerEvent(PointerEventPass.Final).changes.forEach { it.consume() }
        } })
        val keyboard = WindowInsets.ime.getBottom(density) / density.density
        // adjustResize may already have removed the keyboard. Subtract only the actual overlap.
        val overlap = (rootY + maxHeight.value - (window.height.toFloat() - keyboard)).coerceIn(0f, maxHeight.value)
        val available = (maxHeight.value - overlap - if (tablet) 64f else 16f).coerceAtLeast(1f)
        val width = if (tablet) (maxWidth.value - 48).coerceIn(1f, 520f) else (maxWidth.value - 16).coerceAtLeast(1f)
        Box(Modifier.matchParentSize().alpha(ground).background(Brush.verticalGradient(0f to (if (dark) Color(0xFF1B1826) else Color(0xFFF1EEFB)),
            .62f to (if (dark) Color.Black else Color.White), 1f to (if (dark) Color.Black else Color.White))))
        if (tablet && value.step == FirstRunPresentation.Step.JOINED) TabletJoinSuccessScreen(macName)
        if (value.step != FirstRunPresentation.Step.GUIDE && value.groundUp && !(tablet && overlap > 0) &&
            !(tablet && value.step == FirstRunPresentation.Step.JOINED)) {
            FirstRunBrand(tablet, value.risen, animationsDisabled, Modifier.padding(top = (window.height * .195).dp))
        }
        if (value.step == FirstRunPresentation.Step.LINKS) {
            val backdrop = rememberControl(flow, host, value)
            key(backdrop) {
                Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = .22f))
                    .clickable(enabled = backdrop != null) { flow.notNow(backdrop) }.clearAndSetSemantics { })
            }
        }
        if (value.step == FirstRunPresentation.Step.GUIDE) {
            if (tablet) {
                Surface(Modifier.width(width.dp).align(Alignment.Center), shape = RoundedCornerShape(22.dp),
                    color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                    Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text("Ready to browse", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        Text("Your spaces and tabs are in the sidebar.", fontSize = 17.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                        FirstRunButton(flow, host, value, "Start Browsing", "welcome.finish", action = { flow.finishGuide(it, finish) })
                    }
                }
            } else {
                FirstRunPen(flow, host, value, window, finish, animationsDisabled)
            }
        }
        val liveFrame = value
        val trayDraw = remember(flow) { arrayOfNulls<FirstRunPresentation.State>(1) }
        if (value.trayUp && value.step !in setOf(FirstRunPresentation.Step.WELCOME, FirstRunPresentation.Step.GUIDE)) trayDraw[0] = value
        AnimatedVisibility(value.trayUp && !(tablet && value.step == FirstRunPresentation.Step.JOINED),
            enter = slideInVertically(tween(if (animationsDisabled) 0 else 320, easing = CubicBezierEasing(.2f, .8f, .2f, 1f))) { it },
            exit = slideOutVertically(tween(if (animationsDisabled) 0 else 170, easing = CubicBezierEasing(.4f, 0f, .8f, .4f))) { it },
            modifier = Modifier.align(if (tablet) Alignment.Center else Alignment.BottomCenter)) {
            val value = trayDraw[0] ?: return@AnimatedVisibility
            val drawingOnly = !liveFrame.trayUp || liveFrame.revision != value.revision
            val scroll = rememberScrollState()
            val shape = RoundedCornerShape(38.dp)
            Box(Modifier.padding(bottom = (overlap + if (tablet) 0f else 8f).dp)
                .then(if (!drawingOnly) Modifier else Modifier.clearAndSetSemantics {}.pointerInput(flow, value.revision) {
                    awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
                })) {
                Column(Modifier.width(width.dp).heightIn(max = available.dp).verticalScroll(scroll)
                    .shadow(15.dp, shape, ambientColor = Color.Black.copy(alpha = .14f), spotColor = Color.Black.copy(alpha = .14f))
                    .background(if (dark) Color(0xFF1C1C1E) else Color.White, shape).clip(shape)
                    .animateContentSize(if (animationsDisabled) snap() else spring(dampingRatio = .86f,
                        stiffness = ((2 * PI / .36) * (2 * PI / .36)).toFloat())).testTag("welcome.tray")) {
                    if (value.step in setOf(FirstRunPresentation.Step.CHOOSE, FirstRunPresentation.Step.CODE,
                            FirstRunPresentation.Step.RECOVERY, FirstRunPresentation.Step.NO_MAC) ||
                        value.step == FirstRunPresentation.Step.JOINED && !tablet) {
                        Box(Modifier.fillMaxWidth().height(64.dp)) {
                            if (value.step !in setOf(FirstRunPresentation.Step.CHOOSE, FirstRunPresentation.Step.JOINED)) {
                                val back = rememberControl(flow, host, value, value.codeValue)
                                key(back) { IconButton(onClick = { confirmed(goBack(back)) }, enabled = back != null,
                                    modifier = Modifier.padding(10.dp).size(44.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape)
                                        .testTag("welcome.back")) { Icon(painterResource(R.drawable.first_run_chevron_left), "Back", Modifier.size(19.dp)) } }
                            }
                            Text(when (value.step) { FirstRunPresentation.Step.NO_MAC -> "No Mac yet"
                                FirstRunPresentation.Step.RECOVERY -> "Recovery Key"
                                FirstRunPresentation.Step.JOINED -> if (value.joinedFrom == FirstRunPresentation.Step.RECOVERY) "Recovery Key" else "Join Your Mac"
                                else -> "Join Your Mac" },
                                Modifier.fillMaxWidth().padding(horizontal = 64.dp, vertical = 18.dp).semantics { heading() },
                                fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                        }
                    }
                    when (value.step) {
                        FirstRunPresentation.Step.FOUND -> FoundBody(flow, host, value, macName, spaces, animationsDisabled) {
                            confirmed(flow.joinSaved(it, FirstRunPresentation.FoundCounts.from(spaces)))
                        }
                        FirstRunPresentation.Step.CHOOSE -> Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Note("Yab on ${if (tablet) "your tablet" else "your phone"} carries your Mac’s spaces, tabs and chats, end-to-end encrypted.", Modifier.padding(horizontal = 4.dp))
                            Choice(flow, host, value, "Yab is on my Mac", "Show a code to type there", "welcome.mac", R.drawable.first_run_macbook) {
                                confirmed(flow.chooseMacOwnedRequest(it, beginCode, joined))
                            }
                            Choice(flow, host, value, "No Mac yet", "Browse here, join later", "welcome.noMac", R.drawable.first_run_globe) {
                                confirmed(flow.chooseNoMac(it))
                            }
                        }
                        FirstRunPresentation.Step.CODE -> Column(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 16.dp),
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("Type this code on a Mac that syncs", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                            val code = value.codeValue
                            if (code == null) {
                                if (value.requestError == null) CircularProgressIndicator(Modifier.padding(10.dp).size(32.dp))
                            } else {
                                CodePlates(code)
                                FirstRunCopy(flow, host, value, code, "welcome.copy", copy, haptic, codeOwned = true)
                            }
                            Note("In Settings › Sync on that Mac, choose Add a Device.", Modifier.fillMaxWidth(), centered = true)
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                FirstRunButton(flow, host, value, "Cancel", "welcome.cancel", Modifier.weight(1f), soft = true,
                                    controlKey = code, action = { goBack(it).also { if (it) haptic(FirstRunPresentation.Haptic.CONFIRM) } })
                                FirstRunButton(flow, host, value, "Use Recovery Key…", "welcome.recovery", Modifier.weight(1.5f), soft = true,
                                    action = { flow.useRecovery(it).also { if (it) haptic(FirstRunPresentation.Haptic.CONFIRM) } })
                            }
                        }
                        FirstRunPresentation.Step.RECOVERY -> RecoveryBody(flow, host, value, sync, joined, haptic, animationsDisabled)
                        FirstRunPresentation.Step.NO_MAC -> Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Note("Yab is a Mac browser first. Get it on your Mac, then join from Settings › Sync here.", Modifier.padding(horizontal = 4.dp))
                            Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer, RoundedCornerShape(16.dp)).padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Image(painterResource(R.drawable.spaces_yab_mark), null, Modifier.size(28.dp))
                                Column(Modifier.weight(1f)) { Text("yetanotherbrowser.com", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                                    Text("Open it on your Mac", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                FirstRunCopy(flow, host, value, "https://yetanotherbrowser.com", "welcome.copyLink", copy, haptic)
                            }
                            FirstRunButton(flow, host, value, "Use Without a Mac", "welcome.withoutMac", action = flow::useWithoutMac)
                        }
                        FirstRunPresentation.Step.JOINED -> if (value.joinedFrom == FirstRunPresentation.Step.FOUND) {
                            FoundBody(flow, host, value, macName, spaces, animationsDisabled) { }
                        } else if (value.joinedFrom == FirstRunPresentation.Step.RECOVERY) {
                            RecoveryBody(flow, host, value, sync, joined, haptic, animationsDisabled, success = true)
                        } else Column(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 16.dp), horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("In sync with $macName", fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.testTag("welcome.joinedTitle"), textAlign = TextAlign.Center)
                            Box(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer, RoundedCornerShape(16.dp)).padding(10.dp), contentAlignment = Alignment.Center) {
                                value.lastCode?.let { CodePlates(it, joined = true, animationsDisabled = animationsDisabled) }
                                FirstRunCheck(52f, animationsDisabled, millis = 300, wait = 620)
                            }
                            // The original code body keeps its layout while its controls leave.
                            Spacer(Modifier.height(36.dp)); Note("In Settings › Sync on that Mac, choose Add a Device.", Modifier.alpha(0f).clearAndSetSemantics { }, centered = true)
                            Spacer(Modifier.height(60.dp))
                        }
                        FirstRunPresentation.Step.LINKS -> Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                            Row(Modifier.padding(top = 30.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                Icon(painterResource(R.drawable.first_run_chain_link), null, Modifier.size(30.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                Icon(painterResource(R.drawable.first_run_chevron_right), null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.outline)
                                Image(painterResource(R.drawable.spaces_yab_mark), null, Modifier.size(52.dp))
                            }
                            Text("Open links in Yab?", Modifier.padding(top = 14.dp).semantics { heading() }, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                            Note("Links from Messages and Mail open as a tab, on your Mac too.", Modifier.padding(start = 28.dp, end = 28.dp, top = 8.dp), centered = true)
                            FirstRunButton(flow, host, value, "Make Yab Default", "welcome.makeDefault", Modifier.padding(start = 16.dp, end = 16.dp, top = 22.dp),
                                action = { flow.makeDefault(it, role, requestDefault) })
                            FirstRunButton(flow, host, value, "Not Now", "welcome.linksNotNow", Modifier.padding(top = 4.dp, bottom = 10.dp), plain = true,
                                action = flow::notNow)
                        }
                        else -> Unit
                    }
                    (if (value.handoff != null) value.handoffError else if (value.ownedRequest) value.requestError
                        else syncState.error.takeIf { flow.recoveryErrorCurrent(host) })
                        ?.takeIf { value.step in setOf(FirstRunPresentation.Step.CODE, FirstRunPresentation.Step.RECOVERY) }?.let {
                        Text(it, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

@Composable private fun rememberControl(flow: FirstRunPresentation, host: FirstRunPresentation.Host,
    value: FirstRunPresentation.State, key: Any? = null, recovery: Boolean = false): FirstRunPresentation.Control? {
    val control = remember(flow, host, value.revision, value.codeRevision, value.failureRevision, value.requestBindingRevision, if (recovery) value.recoveryRevision else null, key) {
        flow.control(host, recovery, expected = value)
    }
    DisposableEffect(control) { onDispose { control?.retire() } }
    return control
}

@Composable private fun FirstRunButton(flow: FirstRunPresentation, host: FirstRunPresentation.Host,
    value: FirstRunPresentation.State, text: String, tag: String, modifier: Modifier = Modifier,
    soft: Boolean = false, plain: Boolean = false, controlKey: Any? = null,
    action: (FirstRunPresentation.Control?) -> Boolean) {
    val control = rememberControl(flow, host, value, controlKey)
    key(control) {
        val colors = if (soft) ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            contentColor = MaterialTheme.colorScheme.onSurface) else ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.onSurface,
            contentColor = MaterialTheme.colorScheme.surface)
        if (plain) TextButton(onClick = { action(control) }, enabled = control != null, modifier = modifier.fillMaxWidth().heightIn(min = 44.dp).testTag(tag)) {
            Text(text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        } else Button(onClick = { action(control) }, enabled = control != null, colors = colors,
            modifier = modifier.fillMaxWidth().heightIn(min = 52.dp).testTag(tag), shape = CircleShape) {
            Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        }
    }
}

@Composable private fun Choice(flow: FirstRunPresentation, host: FirstRunPresentation.Host,
    value: FirstRunPresentation.State, title: String, words: String, tag: String, icon: Int,
    action: (FirstRunPresentation.Control?) -> Unit) {
    val control = rememberControl(flow, host, value)
    key(control) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surfaceContainer)
            .clickable(enabled = control != null) { action(control) }.heightIn(min = 64.dp).padding(horizontal = 16.dp, vertical = 10.dp).testTag(tag),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(painterResource(icon), null, Modifier.size(36.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(10.dp)).padding(8.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) { Text(title, fontSize = 17.sp); Text(words, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Icon(painterResource(R.drawable.first_run_chevron_right), null, Modifier.size(13.dp), tint = MaterialTheme.colorScheme.outline)
        }
    }
}

@Composable private fun Note(text: String, modifier: Modifier = Modifier, centered: Boolean = false) {
    Text(text, modifier, fontSize = 15.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = if (centered) TextAlign.Center else TextAlign.Start)
}

@Composable private fun FirstRunBrand(tablet: Boolean, risen: Boolean, animationsDisabled: Boolean, modifier: Modifier) {
    val progress by animateFloatAsState(if (risen) 1f else 0f, if (animationsDisabled) snap() else spring(dampingRatio = .72f,
        stiffness = ((2 * PI / .4) * (2 * PI / .4)).toFloat()), label = "welcome rise")
    Column(modifier.fillMaxWidth().alpha(progress), horizontalAlignment = Alignment.CenterHorizontally) {
        Image(painterResource(R.drawable.spaces_yab_mark), null, Modifier.size(76.dp).graphicsLayer { scaleX = .8f + .2f * progress; scaleY = scaleX })
        Text("Yab", Modifier.padding(top = 20.dp).testTag("welcome.title").semantics { heading() }, fontSize = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = (-1).sp)
        Text(if (tablet) "Your Mac’s tabs, on your tablet" else "Your Mac’s tabs, in your pocket", Modifier.padding(top = 10.dp).testTag("welcome.words"),
            fontSize = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable private fun CodePlates(code: String, joined: Boolean = false, animationsDisabled: Boolean = false) {
    var risen by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { risen = true }
    val letters = code.filter { it != '-' }
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxWidth().height(64.dp).testTag("welcome.code")
        .clearAndSetSemantics { if (!joined) contentDescription = letters.map { "$it" }.joinToString(" ") },
        contentAlignment = Alignment.Center) {
        val gap = 5f; val dash = 10f
        val plate = minOf(34f, ((maxWidth.value - 20 - dash - gap * letters.length) / letters.length.coerceAtLeast(1)).coerceAtLeast(1f))
        val total = letters.length * plate + dash + gap * letters.length
        Row(horizontalArrangement = Arrangement.spacedBy(gap.dp), verticalAlignment = Alignment.CenterVertically) {
            letters.forEachIndexed { index, letter ->
                if (index == letters.length / 2) Text("–", Modifier.width(dash.dp).alpha(if (joined) 0f else 1f),
                    fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.outline)
                val center = index * (plate + gap) + (if (index >= letters.length / 2) dash + gap else 0f) + plate / 2
                var converge by remember { mutableStateOf(false) }
                LaunchedEffect(joined) { if (joined) { delay(if (animationsDisabled) 0 else 360); converge = true } }
                val collapse by animateFloatAsState(if (converge) 1f else 0f,
                    if (animationsDisabled) snap() else spring(dampingRatio = .86f, stiffness = ((2 * PI / .36) * (2 * PI / .36)).toFloat()),
                    label = "welcome plate collapse")
                val rise by animateFloatAsState(if (risen) 1f else 0f,
                    tween(if (animationsDisabled) 0 else 180, delayMillis = if (animationsDisabled) 0 else 200 + index * 40), label = "welcome plate rise")
                val ground by animateColorAsState(if (joined) Color(0xFF34C759) else MaterialTheme.colorScheme.surface,
                    tween(if (animationsDisabled) 0 else 160, delayMillis = if (animationsDisabled) 0 else index * 40), label = "welcome plate tint")
                Text(letter.toString(), Modifier.size(plate.dp, 44.dp).graphicsLayer {
                    translationX = -(center - total / 2) * collapse * density.density
                    translationY = (1 - rise) * 6 * density.density
                    scaleX = 1 - .6f * collapse; scaleY = scaleX; alpha = rise * (1 - collapse)
                }.shadow(1.dp, RoundedCornerShape(10.dp)).background(ground, RoundedCornerShape(10.dp))
                    .wrapContentHeight(Alignment.CenterVertically), fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                    color = if (joined) Color.White else MaterialTheme.colorScheme.onSurface,
                    textAlign = TextAlign.Center, maxLines = 1)
            }
        }
    }
}

@Composable private fun FirstRunCopy(flow: FirstRunPresentation, host: FirstRunPresentation.Host, value: FirstRunPresentation.State,
    text: String, tag: String, put: (String) -> Unit, haptic: (FirstRunPresentation.Haptic) -> Unit,
    codeOwned: Boolean = false, current: () -> Boolean = { true }) {
    var copied by remember(text) { mutableStateOf(false) }
    val control = rememberControl(flow, host, value, text to copied)
    LaunchedEffect(copied) { if (copied) { delay(2_000); copied = false } }
    key(control) { TextButton(onClick = {
        if (current() && (if (codeOwned) flow.copyCode(control, text, put) else flow.copy(control, text, put))) { copied = true; if (host.current()) haptic(FirstRunPresentation.Haptic.COPY) }
    }, enabled = control != null, modifier = Modifier.heightIn(min = 36.dp).testTag(tag)) {
        Icon(painterResource(R.drawable.first_run_clipboard), null, Modifier.size(16.dp))
        Text(if (copied) "Copied" else "Copy", Modifier.padding(start = 6.dp), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    } }
}

@Composable private fun RecoveryBody(flow: FirstRunPresentation, host: FirstRunPresentation.Host, value: FirstRunPresentation.State,
    sync: AndroidSyncBridge, joined: () -> Unit, haptic: (FirstRunPresentation.Haptic) -> Unit, animationsDisabled: Boolean, success: Boolean = false) {
    val input = remember(flow, host, value.revision) { flow.input(host, expected = value) }
    DisposableEffect(input) { onDispose { input?.retire() } }
    val focus = remember(input) { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    var placed by remember(input) { mutableStateOf(false) }
    LaunchedEffect(input, placed) { if (placed) { delay(if (animationsDisabled) 0 else 300); if (input?.current() == true) { focus.requestFocus(); keyboard?.show() } } }
    val control = rememberControl(flow, host, value, value.recovery, recovery = true)
    val originalText = value.recovery
    fun restore() { flow.restoreGuardedRequest(control, originalText, { text, handoff, callback, failure -> sync.joinRecoveryRequest(text, handoff, onJoined = callback, onJoinFailed = failure) }, joined) }
    Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Note("It’s in Yab on your Mac, in Settings › Sync, or in Yab Recovery Key.pdf.", Modifier.padding(horizontal = 4.dp))
        Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer, RoundedCornerShape(22.dp)).padding(start = 16.dp, top = 12.dp, end = 6.dp, bottom = 12.dp),
            verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            key(input) {
                TextField(value = value.recovery, onValueChange = { text ->
                    val clean = text.replace("\n", "")
                    if (flow.editRecovery(input, clean) && text.contains('\n')) {
                        flow.restoreGuardedFromInput(input, clean, { recovery, handoff, callback, failure -> sync.joinRecoveryRequest(recovery, handoff, onJoined = callback, onJoinFailed = failure) }, joined)
                    }
                }, modifier = Modifier.weight(1f).focusRequester(focus).onGloballyPositioned {
                    placed = it.size.width > 0 && it.size.height > 0
                }.testTag("welcome.field"), maxLines = 3, readOnly = success,
                    placeholder = { Text("XXXX-XXXX-…", color = MaterialTheme.colorScheme.outline) },
                    textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace, fontSize = 17.sp, letterSpacing = .68.sp),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = {
                        flow.restoreGuardedFromInput(input, flow.state.value.recovery,
                            { text, handoff, callback, failure -> sync.joinRecoveryRequest(text, handoff, onJoined = callback, onJoinFailed = failure) }, joined)
                    }), colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                        focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent))
            }
            if (success) Box(Modifier.size(40.dp).background(Color(0xFF34C759), CircleShape), contentAlignment = Alignment.Center) {
                FirstRunCheck(40f, animationsDisabled, millis = 400, color = Color.White)
            } else key(control) { IconButton(onClick = ::restore, enabled = control != null && originalText.isNotBlank(), modifier = Modifier.size(40.dp)
                    .background(MaterialTheme.colorScheme.onSurface, CircleShape).testTag("welcome.go")) {
                    Icon(painterResource(R.drawable.first_run_arrow_up), "Join", Modifier.size(18.dp), tint = MaterialTheme.colorScheme.surface)
                } }
        }
    }
}

@Composable private fun FirstRunCheck(size: Float, animationsDisabled: Boolean, millis: Int = 560, wait: Int = 0, color: Color = Color(0xFF34C759)) {
    var drawn by remember { mutableStateOf(false) }
    val progress by animateFloatAsState(if (drawn) 1f else 0f, tween(if (animationsDisabled) 0 else millis, delayMillis = if (animationsDisabled) 0 else wait,
        easing = LinearEasing), label = "joined check")
    LaunchedEffect(Unit) { drawn = true }
    Canvas(Modifier.size(size.dp).clearAndSetSemantics { }) {
        val scale = this.size.width / 52
        fun part(a: Float, b: Float): Float { val p = ((progress - a) / (b - a)).coerceIn(0f, 1f); return 1 - (1 - p) * (1 - p) * (1 - p) }
        val green = color
        drawArc(green, -90f, 360 * part(0f, .6f), false, Offset(3 * scale, 3 * scale), androidx.compose.ui.geometry.Size(46 * scale, 46 * scale), style = Stroke(3.5f * scale, cap = StrokeCap.Round))
        val a = Offset(15f, 27f) * scale; val b = Offset(22.5f, 34.5f) * scale; val c = Offset(37.5f, 19f) * scale
        val one = hypot(b.x - a.x, b.y - a.y); val two = hypot(c.x - b.x, c.y - b.y); val length = part(.45f, 1f) * (one + two)
        if (length > 0) drawLine(green, a, a + (b - a) * (length / one).coerceAtMost(1f), 4 * scale, StrokeCap.Round)
        if (length > one) drawLine(green, b, b + (c - b) * ((length - one) / two).coerceAtMost(1f), 4 * scale, StrokeCap.Round)
    }
}

@Composable private fun FirstRunPen(flow: FirstRunPresentation, host: FirstRunPresentation.Host, value: FirstRunPresentation.State,
    window: BrowserWorkspaceWindow, finish: (FirstRunPresentation.Completion) -> Boolean, animationsDisabled: Boolean) {
    val control = rememberControl(flow, host, value)
    var gone by remember(control) { mutableStateOf(false) }
    val opacity by animateFloatAsState(if (gone) 0f else 1f, tween(150, easing = CubicBezierEasing(0f, 0f, .58f, 1f)), label = "welcome pen erased")
    LaunchedEffect(gone, control) { if (gone) { delay(150); flow.finishGuide(control, finish) } }
    var drawn by remember { mutableStateOf(false) }
    val arrow by animateFloatAsState(if (drawn) 1f else 0f, tween(if (animationsDisabled) 0 else 500, easing = CubicBezierEasing(.2f, .8f, .2f, 1f)), label = "welcome pen")
    val head by animateFloatAsState(if (drawn) 1f else 0f, tween(if (animationsDisabled) 0 else 180, delayMillis = if (animationsDisabled) 0 else 450, easing = LinearEasing), label = "welcome pen head")
    val words by animateFloatAsState(if (drawn) 1f else 0f, tween(if (animationsDisabled) 0 else 300, delayMillis = if (animationsDisabled) 0 else 500, easing = CubicBezierEasing(0f, 0f, .58f, 1f)), label = "welcome pen words")
    LaunchedEffect(Unit) { drawn = true }
    key(control) { Box(Modifier.fillMaxSize().alpha(opacity).clickable(enabled = control != null) { if (!gone) gone = true }
        .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "Swipe up for your Mac’s tabs"
            onClick { flow.finishGuide(control, finish) } }) {
        val density = LocalDensity.current
        Canvas(Modifier.fillMaxSize().clearAndSetSemantics { }) {
            val sx = window.width.toFloat() / 402; val base = window.height.toFloat() - 874
            fun point(x: Float, y: Float) = Offset(x * sx * density.density, (y + base) * density.density)
            val path = Path().apply { moveTo(point(150f, 690f).x, point(150f, 690f).y)
                cubicTo(point(150f, 740f).x, point(150f, 740f).y, point(180f, 770f).x, point(180f, 770f).y, point(200f, 800f).x, point(200f, 800f).y) }
            val measure = PathMeasure().apply { setPath(path, false) }; val segment = Path(); measure.getSegment(0f, measure.length * arrow, segment)
            drawPath(segment, Color(0xFF6236E0), style = Stroke(3 * density.density, cap = StrokeCap.Round))
            val h = Path().apply { moveTo(point(188f, 790f).x, point(188f, 790f).y); lineTo(point(200f, 802f).x, point(200f, 802f).y); lineTo(point(206f, 786f).x, point(206f, 786f).y) }
            measure.setPath(h, false); val headSegment = Path(); measure.getSegment(0f, measure.length * head, headSegment)
            drawPath(headSegment, Color(0xFF6236E0), style = Stroke(3 * density.density, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
        Text("swipe up for your Mac’s tabs", Modifier.offset((60 * window.width / 402).dp, (640 + window.height - 874).dp)
            .alpha(words).testTag("welcome.pen"), fontFamily = FontFamily(Font(R.font.caveat)), fontSize = 26.sp,
            fontWeight = FontWeight.SemiBold, color = Color(0xFF6236E0))
    } }
}


@Composable internal fun FirstRunMountingCover() {
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
        0f to (if (dark) Color(0xFF1B1826) else Color(0xFFF1EEFB)),
        .62f to (if (dark) Color.Black else Color.White), 1f to (if (dark) Color.Black else Color.White)))
        .clearAndSetSemantics {}.pointerInput(Unit) { awaitPointerEventScope {
            while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
        } })
}


@Composable private fun FoundBody(flow: FirstRunPresentation, host: FirstRunPresentation.Host,
    value: FirstRunPresentation.State, macName: String, spaces: List<BrowserSpace>, animationsDisabled: Boolean,
    join: (FirstRunPresentation.Control?) -> Unit) {
    val joined = value.step == FirstRunPresentation.Step.JOINED
    val counts = value.foundCounts ?: FirstRunPresentation.FoundCounts.from(spaces)
    val control = rememberControl(flow, host, value)
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.padding(top = 34.dp).size(96.dp, 66.dp), contentAlignment = Alignment.Center) {
            if (joined) FirstRunCheck(52f, animationsDisabled, millis = 560, wait = 60)
            else Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.onSurface, RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
                Icon(painterResource(R.drawable.first_run_macbook), null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.surface)
            }
        }
        Text(if (joined) "In sync with $macName" else "$macName is ready",
            Modifier.padding(top = 12.dp, start = 24.dp, end = 24.dp).testTag("welcome.foundTitle").semantics { heading() },
            fontSize = 22.sp, fontWeight = FontWeight.Bold, letterSpacing = (-.48).sp, textAlign = TextAlign.Center)
        Note("This device is already connected to your Mac. Your tabs stay end-to-end encrypted.",
            Modifier.padding(horizontal = 24.dp, vertical = 12.dp), centered = true)
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            spaces.filterNot { it.isPrivate }.take(4).forEachIndexed { index, space ->
                val opacity by animateFloatAsState(if (appeared) 1f else 0f,
                    tween(if (animationsDisabled) 0 else 180, delayMillis = if (animationsDisabled) 0 else 200 + index * 50), label = "welcome space")
                Text("${space.emoji} ${space.name}".trim(), Modifier.alpha(opacity)
                    .background(Color(space.color).copy(alpha = .35f), RoundedCornerShape(16.dp)).padding(horizontal = 12.dp, vertical = 9.dp),
                    fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            }
        }
        Text("${value.counted} tabs, ${counts.pins} pins, ${counts.folders} folders",
            Modifier.padding(top = 14.dp).alpha(if (value.counting || joined) 1f else 0f).testTag("welcome.count"),
            fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (value.counting || joined) Box(Modifier.padding(horizontal = 16.dp, vertical = 22.dp).fillMaxWidth().height(50.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = .4f), RoundedCornerShape(50)), contentAlignment = Alignment.Center) {
            Text("Joining…", fontSize = 17.sp, color = MaterialTheme.colorScheme.surface)
        }
        else key(control) { Button(onClick = { join(control) }, enabled = control != null,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 22.dp, bottom = 16.dp).fillMaxWidth().height(50.dp).testTag("welcome.join"),
            shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.onSurface,
                contentColor = MaterialTheme.colorScheme.surface)) { Text("Join", fontSize = 17.sp, fontWeight = FontWeight.SemiBold) } }
    }
}

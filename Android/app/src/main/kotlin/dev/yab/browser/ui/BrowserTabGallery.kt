package dev.yab.browser.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.snap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.foundation.BorderStroke
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import dev.yab.browser.model.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.*

private enum class GalleryPhase { OPENING, OPEN, CLOSING }

/** Local animation producers, never model/input authority. A replacement source
 * can stop only these original jobs and release their matching lift tokens. */
private class GalleryLocalMotions {
    var retired = false
    val jobs = mutableMapOf<Any, Job>()
    val lifts = mutableMapOf<String, Any>()
}

/** Retains the tapped pose while the actual selected page activates beneath it. */
@Composable
internal fun BrowserTabGallery(
    state: BrowserState,
    controller: BrowserController,
    thumbnail: (@Composable (BrowserTab, Modifier) -> Unit)?,
    onChats: (() -> Unit)?,
    stackButton: GalleryRect?,
    tabletSource: BrowserTabletGallerySource? = null,
    pageUnderStrip: Boolean = false,
) {
    key(state.selectedSpaceId, state.surfaceEpoch) { GallerySession(state, controller, thumbnail, onChats, stackButton, tabletSource, pageUnderStrip) }
}

@Composable
private fun GallerySession(
    state: BrowserState,
    controller: BrowserController,
    thumbnail: (@Composable (BrowserTab, Modifier) -> Unit)?,
    onChats: (() -> Unit)?,
    stackButton: GalleryRect?,
    tabletSource: BrowserTabletGallerySource?,
    pageUnderStrip: Boolean,
) {
    val owner = state.selectedSpaceId
    val epoch = state.surfaceEpoch
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val blankControls = tabletSource?.takeIf { state.tab?.isBlank == true && state.tab?.isPrivate == false }
    fun projectCards(source: BrowserState) = tabletSource?.cards(source) ?: source.privateFrontGalleryCards()
    val sceneCards = projectCards(state)
    var cards by remember(owner) { mutableStateOf(sceneCards.reversed()) }
    var phase by remember(owner) { mutableStateOf(GalleryPhase.OPENING) }
    var time by remember(owner) { mutableDoubleStateOf(0.0) }
    var focus by remember(owner) { mutableDoubleStateOf(max(0, cards.size - 2).toDouble()) }
    var chosen by remember(owner) { mutableStateOf<String?>(null) }
    var chosenPage by remember(owner) { mutableStateOf<BrowserTab?>(null) }
    var chosenProfile by remember(owner) { mutableStateOf<WebsiteProfile?>(null) }
    var blankSource by remember(owner) { mutableStateOf<Pair<Long, SettingsPresentationLifetime>?>(null) }
    var blankReturnOwner by remember(owner) { mutableStateOf<BrowserTabletGallerySource?>(null) }
    var from by remember(owner) { mutableStateOf(emptyList<GalleryPose>()) }
    var closing by remember(owner) { mutableStateOf<GalleryClosing?>(null) }
    /** All Tabs' +, what search grows out of. */
    var plusAnchor by remember(owner) { mutableStateOf<FieldAnchor?>(null) }
    var barFrom by remember(owner) { mutableDoubleStateOf(1.0) }
    val lifts = remember(owner) { mutableStateMapOf<String, Double>() }
    val liftJobs = remember(owner) { mutableMapOf<String, Job>() }
    val liftOwners = remember(owner) { mutableMapOf<String, Any>() }
    val localMotions = remember(owner, blankControls) { GalleryLocalMotions() }
    var motionJob by remember(owner) { mutableStateOf<Job?>(null) }
    val latestState by rememberUpdatedState(state)
    var appeared by remember(owner) { mutableStateOf(false) }
    LaunchedEffect(owner) { appeared = true }
    val overlayAlpha by animateFloatAsState(if (appeared && phase != GalleryPhase.CLOSING) 1f else if (reduced) 0f else 1f,
        animationSpec = if (reduced) tween(200) else snap(), label = "galleryReducedFade")
    fun owns() = controller.state.value.let { it.selectedSpaceId == owner && it.surfaceEpoch == epoch && it.surface == BrowserSurface.GALLERY && !it.privateContentBlocked }
    fun ownsInput() = !localMotions.retired && owns() && blankControls?.current() != false
    fun releaseLift(original: GalleryLocalMotions, id: String, token: Any) {
        if (original.lifts[id] === token) original.lifts.remove(id)
        if (liftOwners[id] === token) { liftOwners.remove(id); lifts.remove(id); liftJobs.remove(id) }
    }
    fun cancelSettle(original: GalleryLocalMotions) {
        val job = motionJob
        if (job != null && original.jobs.values.any { it === job }) {
            job.cancel(); if (motionJob === job) motionJob = null
        }
    }
    fun claimLift(original: GalleryLocalMotions, id: String, from: Double): Any? {
        if (original.retired || liftOwners[id]?.let { it !== original.lifts[id] } == true) return null
        liftJobs[id]?.cancel()
        return Any().also { token -> original.lifts[id] = token; liftOwners[id] = token; lifts[id] = from }
    }
    fun launchLocal(original: GalleryLocalMotions, action: suspend () -> Unit): Job {
        val token = Any()
        val job = scope.launch {
            try { if (!original.retired) action() }
            finally { original.jobs.remove(token) }
        }
        // Main.immediate may finish a reduced-motion action before launch returns.
        if (job.isActive && !original.retired) original.jobs[token] = job
        else if (original.retired) job.cancel()
        return job
    }
    DisposableEffect(localMotions) {
        val original = localMotions
        onDispose {
            original.retired = true
            val jobs = original.jobs.values.toList()
            val owned = original.lifts.toMap()
            jobs.forEach { it.cancel() }
            if (jobs.any { it === motionJob }) motionJob = null
            owned.forEach { (id, token) -> releaseLift(original, id, token) }
            original.jobs.clear()
        }
    }
    fun ownsBlankReturn(page: BrowserTab, profile: WebsiteProfile) = owns() && blankSource?.let {
        it.second.active && it.first == controller.historyPresentationLifetime.value && it.second == controller.settingsPresentationLifetime.value
    } == true && controller.state.value.let {
        it.space?.websiteProfile == profile && it.tab?.let { front ->
            front.id == page.id && front.url == page.url && front.isPrivate == page.isPrivate
        } == true && if (!page.isPrivate && blankReturnOwner != null)
            blankReturnOwner?.ownsBlankFront(page, profile) == true
        else projectCards(it).singleOrNull()?.id == page.id
    }
    fun abandonBlankReturn(original: BrowserTabletGallerySource?, page: BrowserTab?): Boolean {
        if (original == null || original.current()) return false
        // Stale animation may repair only its own local pose, never a successor
        // Gallery epoch or a newly captured return action.
        if (owns() && phase == GalleryPhase.CLOSING && blankReturnOwner === original && chosenPage == page) {
            phase = GalleryPhase.OPEN; time = 0.0; chosen = null; chosenPage = null; chosenProfile = null
            blankReturnOwner = null; blankSource = null
        }
        return true
    }
    DisposableEffect(owner) { onDispose { motionJob?.cancel(); liftJobs.values.forEach { it.cancel() } } }
    LaunchedEffect(sceneCards, phase) {
        if (phase != GalleryPhase.CLOSING) {
            val next = sceneCards.reversed()
            val focusedId = cards.getOrNull(focus.roundToInt())?.id
            if (next != cards) {
                val reordered = next.map { it.id } != cards.map { it.id }
                cards = next
                if (reordered) focus = focusedId?.let { id -> next.indexOfFirst { it.id == id }.takeIf { it >= 0 }?.toDouble() }
                        ?: focus.coerceIn(0.0, max(0, next.size - 1).toDouble())
            }
        }
    }
    LaunchedEffect(phase, chosenPage, chosenProfile, state.tab?.id, state.tab?.url, state.space?.websiteProfile, sceneCards, blankControls) {
        if (phase == GalleryPhase.CLOSING) {
            val page = chosenPage
            val profile = chosenProfile
            if (page != null && profile != null) {
                if (page.isBlank) {
                    if (!abandonBlankReturn(blankReturnOwner, page) && owns() && !ownsBlankReturn(page, profile))
                        controller.show(BrowserSurface.GALLERY)
                } else controller.cancelGalleryReturn(owner, epoch, page, profile)
            }
        }
    }
    LaunchedEffect(phase, chosen, owner, reduced, blankControls) {
        if (phase == GalleryPhase.OPEN) return@LaunchedEffect
        val originalBlankOwner = blankReturnOwner
        val originalChosenPage = chosenPage
        if (phase == GalleryPhase.CLOSING && abandonBlankReturn(originalBlankOwner, originalChosenPage)) return@LaunchedEffect
        val began = withFrameNanos { it }
        val duration = if (reduced) .2 else if (phase == GalleryPhase.OPENING) GalleryTiming.openDuration else GalleryTiming.closeDuration
        do { time = withFrameNanos { (it - began) / 1_000_000_000.0 } } while (time < duration && owns())
        if (!owns()) return@LaunchedEffect
        if (phase == GalleryPhase.CLOSING && abandonBlankReturn(originalBlankOwner, originalChosenPage)) return@LaunchedEffect
        if (phase == GalleryPhase.OPENING) { phase = GalleryPhase.OPEN; time = 0.0 }
        else {
            val blank = chosenPage?.takeIf { it.isBlank }
            if (blank == null || chosenProfile?.let { ownsBlankReturn(blank, it) } == true)
                controller.finishGallery(owner, epoch, chosen)
            else if (owns()) controller.show(BrowserSurface.GALLERY)
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize().graphicsLayer { alpha = overlayAlpha }) {
        val top = with(density) { WindowInsets.statusBars.getTop(this).toDp().value }.toDouble()
        val bottom = max(28.0, with(density) { WindowInsets.navigationBars.getBottom(this).toDp().value }.toDouble() + 4)
        val layout = GalleryLayout(maxWidth.value.toDouble(), maxHeight.value.toDouble(), cards.size, top, bottom, stackButton)
        val bar = when (phase) {
            GalleryPhase.OPENING -> if (reduced) 1.0 else GalleryTiming.bar(time)
            GalleryPhase.OPEN -> 1.0
            GalleryPhase.CLOSING -> if (reduced) barFrom else barFrom * (1 - GalleryTiming.bar(time))
        }
        val groundMask = layout.groundMask(bar)
        fun poses(): List<GalleryPose> = cards.indices.map { index ->
            val pose = when (phase) {
                GalleryPhase.OPENING -> if (reduced) GalleryMotion.rest(index, layout, focus) else GalleryMotion.opening(index, layout, time)
                GalleryPhase.OPEN -> GalleryMotion.rest(index, layout, focus)
                GalleryPhase.CLOSING -> if (reduced) from[index] else GalleryMotion.closing(closing!!.role(index), from[index], layout, time)
            }
            lifts[cards[index].id]?.let { pose.copy(rect = pose.rect.shifted(it)) } ?: pose
        }
        fun choose(id: String) {
            if (phase == GalleryPhase.CLOSING || !ownsInput()) return
            val index = cards.indexOfFirst { it.id == id }
            if (index < 0) return
            val captured = poses()
            // Phone keeps the current blank front as a real card. It is
            // already selected, so returning to it needs no selection mutation.
            if (cards[index].isBlank) {
                if (!controller.settingsPresentationLifetime.value.active) return
                val soleCurrent = projectCards(controller.state.value).singleOrNull()?.let {
                        it.id == id && it == cards[index] && it.id == controller.state.value.tab?.id
                    } == true
                val toolbarCurrent = state.space?.websiteProfile?.let {
                    tabletSource?.ownsBlankFront(cards[index], it)
                } == true
                if (!soleCurrent && !toolbarCurrent) return
                blankReturnOwner = tabletSource.takeIf { !cards[index].isPrivate && toolbarCurrent }
                blankSource = controller.historyPresentationLifetime.value to controller.settingsPresentationLifetime.value
            } else if (!controller.selectGalleryTab(id, epoch)) return
            motionJob?.cancel()
            liftJobs.values.forEach { it.cancel() }
            liftJobs.clear()
            from = captured
            closing = GalleryClosing(cards.size, index)
            barFrom = bar
            chosen = id
            chosenPage = cards[index]
            chosenProfile = state.space?.websiteProfile
            lifts.clear()
            time = 0.0
            phase = GalleryPhase.CLOSING
        }
        fun chooseFront() {
            if (!ownsInput()) return
            val id = latestState.tab?.id?.takeIf { id -> cards.any { it.id == id } } ?: cards.lastOrNull()?.id
            if (id == null) controller.finishGallery(owner, epoch, null) else choose(id)
        }
        fun settle(target: Double, velocity: Float = 0f) {
            if (!ownsInput() || localMotions.retired) return
            val original = localMotions
            cancelSettle(original)
            val job = launchLocal(original) {
                if (reduced) { if (!original.retired) focus = target }
                else animate(focus.toFloat(), target.toFloat(), velocity,
                    BrowserMotion.spring(.29f, .94f)) { value, _ -> if (!original.retired) focus = value.toDouble() }
            }
            if (job.isActive && !original.retired) motionJob = job
        }
        fun closeCard(id: String) {
            if (phase != GalleryPhase.OPEN || !ownsInput()) return
            val originalInput = blankControls
            val index = cards.indexOfFirst { it.id == id }
            if (index < 0) return
            val originalBlank = cards[index].takeIf { it.isBlank && !it.isPrivate }
            val originalBlankSource = tabletSource.takeIf { originalBlank != null }
            if (originalBlank != null && state.space?.websiteProfile?.let {
                    originalBlankSource?.ownsBlankFront(originalBlank, it) } != true) return
            val original = localMotions
            cancelSettle(original)
            val fromLift = lifts[id] ?: 0.0
            val token = claimLift(original, id, fromLift) ?: return
            val job = launchLocal(original) {
                try {
                    val target = -layout.card(index, focus).bottom - 40
                    // The last card goes quicker: search comes up the moment it has left.
                    val fly = if (cards.size == 1) 160 else 250
                    if (!reduced) animate(fromLift.toFloat(), target.toFloat(), animationSpec = androidx.compose.animation.core.tween(fly, easing = BrowserMotion.easeIn)) { value, _ ->
                        if (!original.retired && liftOwners[id] === token) lifts[id] = value.toDouble()
                    }
                    if (original.retired || !owns() || originalInput?.current() == false || cards.none { it.id == id }) return@launchLocal
                    if (originalBlank != null && state.space?.websiteProfile?.let {
                            originalBlankSource?.ownsBlankFront(originalBlank, it) } != true) return@launchLocal
                    val nextFocus = (if (index <= focus) focus - 1 else focus).coerceIn(0.0, max(0, cards.size - 2).toDouble())
                    controller.closeGalleryTab(id)
                    if (!original.retired) focus = nextFocus
                    if (controller.state.value.galleryTabs.isEmpty() && owns()) controller.openField(origin = plusAnchor)
                } finally { releaseLift(original, id, token) }
            }
            if (job.isActive && !original.retired && liftOwners[id] === token) liftJobs[id] = job
        }
        fun returnCard(id: String?) {
            if (id == null || !ownsInput() || localMotions.retired) return
            val fromLift = lifts[id] ?: return
            val original = localMotions
            val token = claimLift(original, id, fromLift) ?: return
            val job = launchLocal(original) {
                try {
                    if (!reduced) animate(fromLift.toFloat(), 0f,
                        animationSpec = BrowserMotion.spring(.22f, .88f)) { value, _ ->
                        if (!original.retired && liftOwners[id] === token) lifts[id] = value.toDouble()
                    }
                } finally { releaseLift(original, id, token) }
            }
            if (job.isActive && !original.retired && liftOwners[id] === token) liftJobs[id] = job
        }
        key(blankControls) { BackHandler { chooseFront() } }
        val privateGround = state.space?.isPrivate == true
        val paint = remember(state.space?.look, state.space?.color, privateGround) { browserSpaceSurface(state.space) }
        val wash = BrowserSpacesWash.at(listOf(paint.tint), 0.0, if (privateGround) 0 else null,
            MaterialTheme.colorScheme.background.let { it.red + it.green + it.blue < 1.5f })
        key(blankControls) { Box(
            Modifier.fillMaxSize().clickable { chooseFront() }
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    // Erase only this backdrop's lower band, never the underlying page/cards.
                    val boundary = (groundMask.contentBottom.toFloat() * density.density).coerceIn(0f, size.height)
                    if (boundary < size.height && groundMask.lowerOpacity < 1.0) {
                        drawRect(Color.Black.copy(alpha = (1.0 - groundMask.lowerOpacity).toFloat()),
                            topLeft = Offset(0f, boundary), size = Size(size.width, size.height - boundary),
                            blendMode = BlendMode.DstOut)
                    }
                }) {
            BrowserLookSurfaceBackdrop(wash, paint.grain, Modifier.fillMaxSize())
            if (!privateGround) BrowserTabGroundDots(MaterialTheme.colorScheme.background.let { it.red + it.green + it.blue < 1.5f })
        } }
        key(blankControls) { Box(Modifier.fillMaxSize().testTag("browser.gallery.cards").semantics {
            paneTitle = "All Tabs"
            horizontalScrollAxisRange = ScrollAxisRange({ focus.toFloat() }, { layout.maxFocus.toFloat() })
            scrollToIndex { newestFirstIndex ->
                if (newestFirstIndex !in cards.indices || phase != GalleryPhase.OPEN || !ownsInput()) false
                else { settle((cards.lastIndex - newestFirstIndex).toDouble()); true }
            }
        }.pointerInput(owner, phase, cards.map { it.id }, layout, blankControls) {
            var anchor = 0.0
            var dx = 0.0
            var dy = 0.0
            var axis = 0
            var hit: String? = null
            var startLift = 0.0
            var dragToken: Any? = null
            val tracker = VelocityTracker()
            detectDragGestures(
                onDragStart = { point ->
                    if (!ownsInput()) return@detectDragGestures
                    cancelSettle(localMotions)
                    anchor = focus; dx = 0.0; dy = 0.0; axis = 0
                    tracker.resetTracking()
                    hit = layout.hit(point.x / density.density.toDouble(), point.y / density.density.toDouble(), focus)?.let { cards[it].id }
                    startLift = hit?.let { lifts[it] } ?: 0.0
                    dragToken = hit?.let { claimLift(localMotions, it, startLift) }
                },
                onDrag = { change, amount ->
                    if (phase != GalleryPhase.OPEN || !ownsInput()) return@detectDragGestures
                    tracker.addPosition(change.uptimeMillis, change.position)
                    dx += amount.x / density.density; dy += amount.y / density.density
                    if (axis == 0) axis = if (abs(dx) > abs(dy)) 1 else if (dy < 0 && hit != null) 2 else 3
                    if (axis == 1) focus = layout.resisted(anchor - dx / layout.step)
                    if (axis == 2) hit?.takeIf { liftOwners[it] === dragToken }?.let { id ->
                        lifts[id] = startLift + if (dy < 0) dy else galleryRubber(dy, 60.0) * .3
                    }
                    change.consume()
                },
                onDragEnd = {
                    if (!ownsInput()) return@detectDragGestures
                    val velocity = tracker.calculateVelocity()
                    if (axis == 1) {
                        val vx = velocity.x / density.density
                        val target = GalleryLayout.settle(anchor, anchor - dx / layout.step,
                            anchor - (dx + vx * .2) / layout.step).coerceIn(0.0, layout.maxFocus)
                        settle(target, (-vx / layout.step).toFloat())
                        returnCard(hit)
                    } else if (axis == 2 && hit != null) {
                        if (-(startLift + dy + min(0f, velocity.y / density.density) * .2) >= 120) closeCard(hit!!)
                        else returnCard(hit)
                    }
                },
                onDragCancel = { if (ownsInput()) { settle(focus.coerceIn(0.0, layout.maxFocus)); returnCard(hit) } },
            )
        }) {
            val current = poses()
            val chosenZ = closing?.let { current.getOrNull(it.chosen)?.z }
            closing?.seated?.takeUnless { reduced }?.forEach { (index, role) ->
                val pose = GalleryMotion.seated(role, closing!!.rises, layout, time)
                GalleryCard(cards[index], pose.copy(z = (chosenZ ?: 0.0) + (pose.z + 3.5) / 4), layout, thumbnail, false, {}, {}, pageUnderStrip)
            }
            cards.forEachIndexed { index, tab ->
                val pose = current[index]
                if (phase != GalleryPhase.OPEN || layout.draws(index, focus)) {
                    if (tab.isBlank && !tab.isPrivate) key(blankControls) {
                        GalleryCard(tab, pose, layout, thumbnail, phase != GalleryPhase.CLOSING, { choose(tab.id) }, { closeCard(tab.id) }, pageUnderStrip)
                    } else GalleryCard(tab, pose, layout, thumbnail, phase != GalleryPhase.CLOSING, { choose(tab.id) }, { closeCard(tab.id) }, pageUnderStrip)
                }
            }
        } }
        if (cards.isEmpty()) Text("No open pages", Modifier.align(Alignment.Center))
        key(blankControls) {
            val rects = BrowserFootRects(maxWidth.value.toDouble(), maxHeight.value.toDouble(), browserFootBottom().toDouble())
            val ink = MaterialTheme.colorScheme.onSurface
            SideEffect { plusAnchor = rects.center.takeIf { tabletSource == null }?.let { FieldAnchor(it.x, it.y, it.width, it.height) } }
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = bar.toFloat() }) {
                BrowserFootPlate(rects.left, Modifier.semantics { contentDescription = "Settings" }, enabled = phase == GalleryPhase.OPEN,
                    onClick = { if (ownsInput()) controller.show(BrowserSurface.SETTINGS) }) { Icon(YabGlyphs.SettingsGear1, null, Modifier.size(22.dp), tint = ink) }
                BrowserFootPlate(rects.center, Modifier.semantics { contentDescription = "New Tab" }, enabled = phase != GalleryPhase.CLOSING,
                    onClick = { if (ownsInput()) controller.openField(origin = plusAnchor) }) { Icon(YabGlyphs.PlusMedium, null, Modifier.size(22.dp), tint = ink) }
                BrowserFootPlate(rects.right, Modifier.semantics { contentDescription = "Done" }, color = BrowserDoneBlue, enabled = phase == GalleryPhase.OPEN,
                    onClick = { chooseFront() }) { Icon(YabGlyphs.Checkmark1, null, Modifier.size(28.dp), tint = Color.White) }
            }
        }
    }
}

@Composable
private fun GalleryCard(tab: BrowserTab, pose: GalleryPose, layout: GalleryLayout, thumbnail: (@Composable (BrowserTab, Modifier) -> Unit)?, enabled: Boolean, choose: () -> Unit, close: () -> Unit,
    pageUnderStrip: Boolean = false) {
    val density = LocalDensity.current
    if (pose.rect.width <= 0 || pose.rect.height <= 0 || pose.opacity <= 0) return
    Box(Modifier.offset { IntOffset((pose.rect.x * density.density).roundToInt(), (pose.rect.y * density.density).roundToInt()) }
        .size(pose.rect.width.dp, pose.rect.height.dp).zIndex(pose.z.toFloat())
        .graphicsLayer { alpha = pose.opacity.coerceIn(0.0, 1.0).toFloat(); rotationZ = pose.angle.toFloat() }) {
        Surface(shape = RoundedCornerShape(max(0.0, pose.radius).dp), color = MaterialTheme.colorScheme.surface,
            border = if (pose.rim > .001) BorderStroke(.5.dp, Color.White.copy(alpha = (.22 * pose.rim).coerceIn(0.0, 1.0).toFloat())) else null,
            shadowElevation = (1.5 * pose.rim).coerceAtLeast(0.0).dp,
            modifier = Modifier.fillMaxSize().testTag("browser.gallery.card.${tab.id}").clickable(enabled = enabled, onClick = choose).semantics {
                contentDescription = tab.title
                if (enabled) customActions = listOf(CustomAccessibilityAction("Close ${tab.title}") { close(); true })
            }) {
            Box(Modifier.fillMaxSize()) {
                if (thumbnail != null) {
                    val fullHeight = pose.rect.width * layout.height / max(1.0, layout.width)
                    // On a phone the live page starts under the status bar strip, and the picture is the
                    // page alone: draw it where the page is, so the card grows into it without a jump.
                    if (pageUnderStrip) Column(Modifier.fillMaxWidth().requiredHeight(fullHeight.dp).offset(y = (-pose.cropTop * fullHeight).dp)) {
                        Box(Modifier.fillMaxWidth().height((layout.contentTop * fullHeight).dp)
                            .background(if (tab.isPrivate) Color(0xFF0E0D12) else MaterialTheme.colorScheme.background))
                        thumbnail(tab, Modifier.fillMaxWidth().weight(1f))
                    } else thumbnail(tab, Modifier.fillMaxWidth().requiredHeight(fullHeight.dp)
                        .offset(y = (-pose.cropTop * fullHeight).dp))
                }
                else BrowserFavicon(tab, 42.dp, Modifier.align(Alignment.Center))
                if (pose.veil > 0) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = pose.veil.coerceIn(0.0, 1.0).toFloat())))
            }
        }
        if (pose.icon > .001 || pose.title > .001) Row(Modifier.offset(x = (18 * pose.labelScale).dp, y = (-(20 + 8 * pose.labelScale)).dp).height(20.dp)
            .graphicsLayer { scaleX = pose.labelScale.coerceAtLeast(.01).toFloat(); scaleY = scaleX; transformOrigin = TransformOrigin(0f, 1f) }, verticalAlignment = Alignment.CenterVertically) {
            BrowserFavicon(tab, 20.dp, Modifier.testTag("browser.gallery.favicon.${tab.id}").graphicsLayer { alpha = pose.icon.coerceIn(0.0, 1.0).toFloat() })
            if (pose.title > .001 && pose.titleWidth > 0) Text(tab.title, Modifier.padding(start = 6.5.dp).width(pose.titleWidth.dp)
                .graphicsLayer { alpha = pose.title.toFloat() }, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Only the lone current Private blank joins this scene; all other blank filters stay unchanged. */
internal fun BrowserState.privateFrontGalleryCards(): List<BrowserTab> {
    val front = tab
    val ordinary = galleryTabs
    return if (!privateContentBlocked && space?.isPrivate == true && front?.isPrivate == true && front.isBlank &&
        space?.tabs?.singleOrNull()?.let { it.id == front.id && it.isPrivate } == true && ordinary.isEmpty())
        listOf(front) else ordinary
}

/** What the right button shows: the two tabs used last after the one in front, and how many
 * All Tabs would show. One page, in front: the stack shows it, so what is open is always in
 * sight, and All Tabs is where its card closes it. Nothing at all: it is + as before. */
internal data class BrowserStackContents(val front: BrowserTab?, val back: BrowserTab?, val count: Int, val lone: Boolean)
internal fun BrowserState.stackContents(): BrowserStackContents {
    val tabs = galleryTabs
    val behind = if (tabs.firstOrNull()?.id == tab?.id) tabs.drop(1) else tabs
    return BrowserStackContents(behind.firstOrNull() ?: tabs.firstOrNull(), behind.drop(1).firstOrNull(), tabs.size, tabs.size == 1 && behind.isEmpty())
}

@Composable
internal fun BrowserStackGlyph(cards: List<BrowserTab>, thumbnail: (@Composable (BrowserTab, Modifier) -> Unit)?) {
    Box(Modifier.fillMaxSize().semantics { contentDescription = "Tabs, hold for new tab" }, contentAlignment = Alignment.Center) {
        if (cards.isEmpty()) Icon(YabGlyphs.PlusMedium, null)
        else cards.withIndex().reversed().forEach { (index, tab) ->
            val front = index == 0
            Surface(shape = RoundedCornerShape(4.dp), color = Color.White,
                border = BorderStroke(.5.dp, Color.White.copy(alpha = .22f)), shadowElevation = 1.5.dp,
                modifier = Modifier.offset(x = (if (front) 2 else -4).dp, y = (if (front) -1 else 2).dp)
                    .size(22.dp, 24.dp).graphicsLayer { rotationZ = if (front) 8f else -12f; alpha = if (front) 1f else .87f }
                    .clearAndSetSemantics {}) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    BrowserFavicon(tab, 12.dp)
                    thumbnail?.invoke(tab, Modifier.fillMaxSize())
                    if (!front) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .08f)))
                }
            }
        }
    }
}

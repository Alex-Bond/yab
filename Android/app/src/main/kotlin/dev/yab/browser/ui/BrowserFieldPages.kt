package dev.yab.browser.ui

import android.animation.ValueAnimator
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PagerDefaults
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.yab.browser.model.*
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

internal val FieldPagesPositionKey = SemanticsPropertyKey<Float>("FieldPagesPosition")

/** Current NewTabSpaces page ordering. The presentation survives an Eyes reversal; native
 * selection and authorization still pass through the controller's live owner checks. */
/** A page's list and the screen share one finger, as a sheet and its list do: down at the
 * list's top takes the screen down with the finger, and up again brings it back first. */
internal class BrowserSpacesListPull : NestedScrollConnection {
    var lower: (Double, Boolean, Double) -> Unit = { _, _, _ -> }
    private var pulled = 0f
    override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
        if (pulled <= 0f || source != NestedScrollSource.UserInput || available.y >= 0f) return Offset.Zero
        val taken = maxOf(available.y, -pulled)
        pulled += taken
        lower((pulled / DP).toDouble(), false, 0.0)
        return Offset(0f, taken)
    }
    override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
        if (source != NestedScrollSource.UserInput || available.y <= 0f || abs(available.y) < abs(available.x)) return Offset.Zero
        pulled += available.y
        lower((pulled / DP).toDouble(), false, 0.0)
        return Offset(0f, available.y)
    }
    override suspend fun onPreFling(available: Velocity): Velocity {
        if (pulled <= 0f) return Velocity.Zero
        val distance = pulled
        pulled = 0f
        lower((distance / DP).toDouble(), true, (available.y / DP).toDouble())
        return available
    }
    companion object { var DP = 1f }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun BrowserFieldPages(state: BrowserState, controller: BrowserController, modifier: Modifier,
    interactive: Boolean, spacesMotion: BrowserSpacesPresentation?, onChats: (() -> Unit)?,
    onUnlockPrivate: ((Boolean) -> Unit) -> Unit,
    fieldChatsContent: (@Composable (Modifier, Boolean) -> Unit)?,
    onChatsPageChanged: (Boolean) -> Unit,
    wash: BrowserFieldWashPlacement?,
    sheet: Boolean = false, onSheetWash: ((BrowserSpacesWash, Double) -> Unit)? = null,
    more: (@Composable (Modifier, Boolean, Color, Color) -> Unit)? = null,
    sheetLower: ((Double, Boolean, Double) -> Unit)? = null,
    publicPage: @Composable (BrowserSpace, Boolean, () -> Boolean, BrowserSpaceRowSwipeScope) -> Unit) {
    val typing = state.surface == BrowserSurface.FIELD
    val onlyPrivate = typing && !state.fieldIsNewTab && state.fieldPagePrivate
    val spaces = state.spaces.filterNot(BrowserSpace::isPrivate)
    val pages = buildList {
        // Private is a way to search, its tabs in the stack: no page among the spaces.
        if (onlyPrivate || !sheet && (!typing || state.fieldIsNewTab)) add(FieldPage(BrowserFieldPageSelection.PRIVATE, "Private", FieldPageKind.PRIVATE))
        if (!onlyPrivate) {
            if (onChats != null || fieldChatsContent != null) add(FieldPage(BrowserFieldPageSelection.CHATS, "Chats", FieldPageKind.CHATS))
            spaces.forEach { add(FieldPage(BrowserFieldPageSelection.space(it.id), it.name, FieldPageKind.SPACE, it.id)) }
        }
    }
    if (pages.isEmpty()) return
    // Changing Eyes or the selected space must not destroy the outgoing page's pose.
    val owner = remember(state.surfaceEpoch, state.fieldOriginSpace, state.fieldOriginTab, onlyPrivate) { controller.captureFieldPresentation() }
    val selection = remember(state.surfaceEpoch, onlyPrivate) { BrowserFieldPageSelection(pages, state.selectedSpaceId, onlyPrivate || typing && state.fieldIsPrivate).also {
        if (state.fieldChats) it.picked(BrowserFieldPageSelection.CHATS)
    } }
    val initial = pages.indexOfFirst { it.key == selection.target }.coerceAtLeast(0)
    val pager = rememberPagerState(initialPage = initial, pageCount = { pages.size })
    val rowSwipes = remember(state.surfaceEpoch, onlyPrivate) { BrowserSpaceRowSwipeScope() }
    DisposableEffect(rowSwipes) { onDispose { rowSwipes.close() } }
    LaunchedEffect(selection.target, pager.isScrollInProgress) { if (pager.isScrollInProgress || rowSwipes.row != null) rowSwipes.close() }
    var requested by remember(state.surfaceEpoch, onlyPrivate) { mutableStateOf<String?>(null) }
    var eyesSeen by remember(state.surfaceEpoch, onlyPrivate) { mutableStateOf(state.fieldIsPrivate) }
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val keyboard = LocalSoftwareKeyboardController.current
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val animations = LocalFieldPageAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()
    val liveState by controller.state.collectAsState()
    fun sourceCurrent(): Boolean = controller.state.value.let {
        !it.loading && !it.privateContentBlocked && if (typing) owner?.let(controller::fieldPresentationCurrent) == true
        else it.surfaceEpoch == state.surfaceEpoch && it.selectedSpaceId == state.selectedSpaceId &&
            it.space?.websiteProfile == state.space?.websiteProfile && it.tab?.id == state.tab?.id
    }
    // Read at the press: a row's handler can outlive the composition that made it.
    val liveInteractive by rememberUpdatedState(interactive)
    fun actionsCurrent() = liveInteractive && sourceCurrent() && controller.state.value.surface == state.surface &&
        controller.state.value.surfaceEpoch == state.surfaceEpoch && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    // A closing Spaces card keeps its original vertical regrab route. Ordinary
    // selection/actions remain disabled until the same card is interactive again.
    fun sheetCurrent() = !typing && spacesMotion != null && state.surface == BrowserSurface.SPACES &&
        sourceCurrent() && controller.state.value.surface == BrowserSurface.SPACES &&
        controller.state.value.surfaceEpoch == state.surfaceEpoch && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    fun applyPage(page: FieldPage) {
        if (!actionsCurrent()) return
        selection.picked(page.key)
        if (typing && !onlyPrivate) {
            val privately = page.kind == FieldPageKind.PRIVATE
            eyesSeen = privately
            if (controller.state.value.fieldIsPrivate != privately) controller.fieldPrivacy(privately)
        }
        when (page.kind) {
            FieldPageKind.PRIVATE -> if (!typing) controller.openField(privately = true)
            FieldPageKind.CHATS -> { controller.restField(state.surfaceEpoch); keyboard?.hide() }
            FieldPageKind.SPACE -> page.space?.let { if (it != controller.state.value.selectedSpaceId) controller.selectSpace(it) }
        }
    }
    fun request(key: String) {
        if (!actionsCurrent()) return
        val page = pages.singleOrNull { it.key == key } ?: return
        applyPage(page); requested = page.key
        keyboard?.hide()
    }
    SideEffect {
        selection.configure(pages, state.selectedSpaceId)
        onChatsPageChanged(selection.target == BrowserFieldPageSelection.CHATS)
    }
    LaunchedEffect(state.fieldIsPrivate, onlyPrivate) {
        if (typing && state.fieldIsPrivate != eyesSeen) {
            eyesSeen = state.fieldIsPrivate
            requested = selection.eyes(state.fieldIsPrivate)
        }
    }
    LaunchedEffect(state.selectedSpaceId) {
        if (!state.fieldIsPrivate && selection.target != BrowserFieldPageSelection.CHATS) {
            val target = pages.firstOrNull { it.space == state.selectedSpaceId }?.key
            // A native drag already picked this space. Do not echo it as an animation
            // competing with the finger that is still moving the pager.
            if (target != null && target != selection.target) requested = target
        }
    }
    LaunchedEffect(requested, pages.map(FieldPage::key), reduced, animations) {
        val target = requested ?: return@LaunchedEffect
        val index = pages.indexOfFirst { it.key == target }
        if (index < 0) { if (requested == target) requested = null; return@LaunchedEffect }
        try {
            if (reduced || !animations) pager.scrollToPage(index)
            else pager.animateScrollToPage(index, animationSpec = BrowserMotion.space(false))
        } finally {
            // A user drag can cancel an animation. It must not leave selection gated.
            if (requested == target) requested = null
        }
    }
    LaunchedEffect(pager.currentPage, pager.isScrollInProgress, requested) {
        // A short drag can change currentPage in the same frame that scrolling ends.
        // Commit that settled page too, rather than leaving selection on the old space.
        if (requested == null) pages.getOrNull(pager.currentPage)?.let { page ->
            if (page.key != selection.target) applyPage(page)
        }
    }
    val position = (pager.currentPage + pager.currentPageOffsetFraction).toDouble().coerceIn(0.0, pages.lastIndex.toDouble())
    val privateIndex = pages.indexOfFirst { it.kind == FieldPageKind.PRIVATE }.takeIf { it >= 0 }
    val darkTheme = MaterialTheme.colorScheme.background.let { it.red + it.green + it.blue < 1.5f }
    val paints = remember(spaces.map { Triple(it.id, it.look, it.color) }) { spaces.associate { it.id to browserSpaceSurface(it) } }
    val tints = pages.map { page -> when (page.kind) {
        FieldPageKind.PRIVATE -> BrowserSpacesRgb(28.0, 28.0, 32.0)
        FieldPageKind.CHATS -> BrowserSpacesRgb(226.0, 224.0, 232.0)
        FieldPageKind.SPACE -> paints.getValue(spaces.first { it.id == page.space }.id).tint
    } }
    val paint = BrowserSpacesWash.at(tints, position, privateIndex, darkTheme)
    val near = position.roundToInt().coerceIn(0, pages.lastIndex)
    val grain = (pages[near].space?.let { paints[it]?.grain } ?: 0.0) * (1 - paint.privateDarkness)
    if (onSheetWash != null) SideEffect { onSheetWash(paint, grain) }
    BrowserSpacesListPull.DP = LocalDensity.current.density
    val listPull = remember(sheetLower, spacesMotion != null) { BrowserSpacesListPull() }
    SideEffect { listPull.lower = { dy, ended, velocity ->
        if (sheetCurrent()) spacesMotion?.lower?.invoke(dy, ended, velocity) else if (typing && sheet) sheetLower?.invoke(dy, ended, velocity)
    } }
    Box(modifier
        .onGloballyPositioned { rowSwipes.page = it.boundsInRoot() }
        .testTag("browser.field.pages").semantics { this[FieldPagesPositionKey] = position.toFloat() }
        .drawWithContent { if (sourceCurrent()) drawContent() }) {
        if (wash != null && wash.geometry.extended) BrowserFieldPagesWash(paint, grain, wash)
        else if (onSheetWash == null) BrowserLookSurfaceBackdrop(paint, grain, Modifier.matchParentSize())
        Column(Modifier.fillMaxSize().then(if (wash != null) browserFieldBodyClip(wash) else Modifier)) {
        if (pages.size > 1) FieldPageInputGate(actionsCurrent(), Modifier.padding(top = 12.dp)) {
            BrowserSpaceCapsule(pages.map(FieldPage::name), pages.indexOfFirst { it.key == selection.target }.coerceAtLeast(0), position, darkTheme,
                modifier = Modifier.padding(horizontal = 8.dp),
                onPick = { pages.getOrNull(it)?.let { page -> request(page.key) } },
                onAbout = { if (actionsCurrent()) controller.openAbout() },
                onSettings = { if (actionsCurrent()) controller.show(BrowserSurface.SETTINGS) },
                onSheetDrag = { dy, ended, velocity ->
                    if (sheetCurrent()) spacesMotion?.lower?.invoke(dy, ended, velocity) else if (typing && sheet) sheetLower?.invoke(dy, ended, velocity)
                },
                onSheetCancel = { if (sheetCurrent()) spacesMotion?.cancelLower?.invoke() else if (typing && sheet) sheetLower?.invoke(0.0, true, 0.0) },
                privateDarkness = if (darkTheme) 1f else paint.privateDarkness.toFloat(),
                more = more?.let { slot -> { buttonModifier, ink, plate -> slot(buttonModifier, selection.target == BrowserFieldPageSelection.CHATS, ink, plate) } })
        }
        if (pages.size > 1) Spacer(Modifier.height(6.dp))
        HorizontalPager(pager, Modifier.weight(1f).fillMaxWidth().nestedScroll(listPull), verticalAlignment = Alignment.Top,
            userScrollEnabled = interactive && sourceCurrent(), key = { pages[it].key },
            flingBehavior = PagerDefaults.flingBehavior(pager, snapAnimationSpec = BrowserMotion.space(reduced || !animations))) { index ->
            val page = pages[index]
            val effective = actionsCurrent() && !pager.isScrollInProgress && pager.currentPage == index && requested == null
            fun pageCurrent() = actionsCurrent() && !pager.isScrollInProgress && pager.currentPage == index && requested == null &&
                pages.getOrNull(index)?.key == page.key
            FieldPageInputGate(effective, Modifier.fillMaxSize()) {
                when (page.kind) {
                    FieldPageKind.PRIVATE -> BrowserPrivatePage(
                        liveState.spaces.firstOrNull(BrowserSpace::isPrivate)?.tabs.orEmpty().filter { it.place == TabPlace.TODAY && !it.isBlank },
                        liveState.settings.lockPrivate && liveState.privateLocked, effective, { typing && sourceCurrent() }, ::pageCurrent,
                        authorizationCurrent = { controller.state.value.let { !it.settings.lockPrivate || !it.privateLocked } },
                        onUnlock = { result ->
                            val attempt = if (pageCurrent()) controller.captureFieldPrivateUnlock() else null
                            if (attempt == null) result(false) else runCatching {
                                onUnlockPrivate { accepted -> scope.launch {
                                    val current = pageCurrent() && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && controller.fieldPrivateUnlockCurrent(attempt)
                                    if (current) result(controller.completeFieldPrivateUnlock(attempt, accepted) && accepted)
                                    else { controller.cancelFieldPrivateUnlock(attempt); result(false) }
                                } }
                            }.onFailure { controller.cancelFieldPrivateUnlock(attempt); result(false) }
                        }, onPick = { if (pageCurrent()) controller.selectTab(it.id) })
                    FieldPageKind.CHATS -> if (fieldChatsContent != null) fieldChatsContent(Modifier.fillMaxSize(), effective)
                        else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            TextButton(enabled = effective, onClick = { if (pageCurrent()) { controller.dismissSurface(); onChats?.invoke() } }) { Text("Open Chats") }
                        }
                    FieldPageKind.SPACE -> spaces.firstOrNull { it.id == page.space }?.let { publicPage(it, effective, ::pageCurrent, rowSwipes) }
                }
            }
        }
    }
    }
}

/** The logical 600pt foot has no grain or head lightening. Only its visible intersection
 * is laid out; the actual owning pane clips it before the shared cards alpha is applied. */
@Composable
private fun BoxScope.BrowserFieldPagesWash(paint: BrowserSpacesWash, grain: Double, wash: BrowserFieldWashPlacement) {
    val anchor = remember { BrowserFieldWashAnchor() }
    val g = wash.geometry
    Box(Modifier.matchParentSize().onPlaced { anchor.coordinates = it }.drawWithContent {
        wash.projection(anchor.coordinates)?.let { p ->
            clipRect(p.clipLeft.toFloat(), p.clipTop.toFloat(), p.clipRight.toFloat(), p.clipBottom.toFloat()) {
                translate(p.translateX.toFloat(), p.translateY.toFloat()) { this@drawWithContent.drawContent() }
            }
        }
    }.wrapContentSize(Alignment.TopStart, unbounded = true).requiredSize(g.width.dp, g.decorationHeight.dp)) {
        Column(Modifier.fillMaxSize()) {
            BrowserLookSurfaceBackdrop(paint, grain, Modifier.fillMaxWidth().height(g.mainHeight.dp))
            val foot = paint.foot
            Box(Modifier.fillMaxWidth().height(g.visibleFootHeight.dp)
                .background(Color((foot.red / 255).toFloat(), (foot.green / 255).toFloat(), (foot.blue / 255).toFloat()))) {
                if (paint.darkOverlay > 0) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = paint.darkOverlay.toFloat())))
            }
        }
    }
}

package dev.yab.browser.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.*
import dev.yab.browser.field.*
import java.time.Instant
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.max

@Composable
internal fun BrowserField(
    state: BrowserState,
    controller: BrowserController,
    wide: Boolean,
    onAskQuestion: ((String, BrowserTab?) -> Unit)?,
    onAskPage: ((BrowserTab) -> Unit)?,
    onChats: (() -> Unit)?,
    onOpenOnMac: ((BrowserTab) -> Unit)?,
    macTodayContent: (@Composable (String) -> Unit)? = null,
    spacesMotion: BrowserSpacesPresentation? = null,
    fieldPresentation: BrowserFieldPresentation? = null,
    onUnlockPrivate: ((Boolean) -> Unit) -> Unit = { it(false) },
    fieldChatsContent: (@Composable (Modifier, Boolean) -> Unit)? = null,
    tabletViewport: TabletOmniboxViewport? = null,
    placement: BrowserFieldPlacementLease? = null,
    editorValue: BrowserFieldEditorValue? = null,
    agentName: String = "Claude",
    onNewChat: (() -> Unit)? = null,
    sheetAllowed: Boolean = false,
) {
    val typing = state.surface == BrowserSurface.FIELD
    val interactive = (fieldPresentation?.interactive ?: (spacesMotion?.interactive != false)) && placement?.current() != false
    val density = LocalDensity.current
    var inputAnchor by remember { mutableStateOf<FieldAnchor?>(null) }
    var chatsPage by remember(state.surfaceEpoch) { mutableStateOf(state.fieldChats) }
    val fieldChats = chatsPage && tabletViewport == null
    val sheetMotion = fieldPresentation?.sheet
    val sheetLayout = tabletViewport == null && (sheetMotion != null || spacesMotion != null && sheetAllowed)
    /** Chats' own search, over the foot, with the keyboard. */
    val chatsAsking = sheetMotion != null && fieldChats && !state.fieldResting
    var spaceFilter by remember(state.surfaceEpoch) { mutableStateOf(SpacesFilter.EVERYTHING) }
    val archiveBinding = remember(state.surfaceEpoch) { BrowserFieldChatArchiveBinding() }
    DisposableEffect(archiveBinding) { onDispose { archiveBinding.close() } }
    val archiveAction = archiveBinding.action
    val hasWords = typing && !fieldChats && !state.fieldShowsAddress && state.fieldText.isNotBlank()
    val isPrivate = if (typing) state.fieldIsPrivate else state.space?.isPrivate == true
    val tabletRecent = if (tabletViewport != null && !state.fieldShowsAddress && !isPrivate && state.fieldText.isEmpty())
        state.galleryTabs.filter { !it.isPrivate && !it.isBlank }.take(5) else emptyList()
    val bestFill = remember(state.space?.look, state.space?.color, state.space?.isPrivate, isPrivate) { browserFieldBestFill(state.space, isPrivate) }
    val colors = MaterialTheme.colorScheme
    val context = LocalContext.current
    val keyboard = LocalSoftwareKeyboardController.current
    val windowInfo = LocalWindowInfo.current
    val windowFocused = windowInfo.isWindowFocused
    val inputFocus = fieldPresentation?.inputFocus
    val scope = rememberCoroutineScope()
    val reducedInk = LocalBrowserAccessibility.current.reduceMotion
    val fieldAnimations = LocalFieldPageAnimationsEnabled.current ?: android.animation.ValueAnimator.areAnimatorsEnabled()
    val privacyInk = remember(state.surfaceEpoch) { BrowserFieldPrivacyInk(isPrivate) }
    val privacyClock = remember(privacyInk) { BrowserFieldPageClock() }
    var privateFraction by remember(privacyInk) { mutableFloatStateOf(privacyInk.value.toFloat()) }
    LaunchedEffect(privacyInk, isPrivate, reducedInk, fieldAnimations) {
        privacyInk.target(isPrivate, privacyClock.event(privacyInk.running), reducedInk, fieldAnimations)
        privateFraction = privacyInk.value.toFloat()
        while (privacyInk.running) withFrameNanos { privateFraction = privacyInk.advance(privacyClock.frame(it)).toFloat() }
    }
    val fieldOwner = listOf(state.surfaceEpoch, state.selectedSpaceId, state.tab?.id, state.fieldIsNewTab, state.fieldIsPrivate)
    val inputLease = remember(fieldOwner, typing, placement) { if (placement == null) controller.captureFieldInput() else placement.input }
    fun currentInput() = interactive && placement?.current() != false && inputLease?.let(controller::fieldInputCurrent) == true
    val editorNodes = editorValue?.nodes ?: remember { BrowserFieldEditorNode() }
    // Retire callbacks synchronously during replacement render, before the old
    // CoreTextField's removal can report its blur/deselection to the retained value.
    val editorNode = remember(editorNodes, fieldOwner, placement, inputLease, inputFocus) { editorNodes.bind() }
    val focus = remember(editorNode) { FocusRequester() }
    val inputCoordinates = remember(editorNode) { arrayOfNulls<LayoutCoordinates>(1) }
    var inputReady by remember(editorNode) { mutableStateOf(false) }
    fun attachedInput() = inputCoordinates[0]?.let { it.isAttached && it.size.width > 0 && it.size.height > 0 } == true
    DisposableEffect(editorNode) { onDispose { editorNode.retire(); editorNode.released { inputFocus?.released() } } }
    var value by remember(fieldOwner, editorValue) { editorValue?.value ?: mutableStateOf(TextFieldValue(state.fieldText,
        if (state.fieldIsNewTab) TextRange(state.fieldText.length) else TextRange(0, state.fieldText.length))) }
    LaunchedEffect(state.fieldText, inputLease, interactive, placement, editorNode) {
        value = reconcileFieldEditorValue(value, state.fieldText, controller.state.value.fieldText,
            editorNode.current() && currentInput())
    }
    val ratesSource = LocalFieldRateSource.current ?: remember(context.applicationContext) { AndroidFieldRates.get(context) }
    val rates by ratesSource.state.collectAsState()
    var minute by remember { mutableLongStateOf(Instant.now().epochSecond / 60) }
    LaunchedEffect(fieldOwner) { while (true) { delay(60_000); minute = Instant.now().epochSecond / 60 } }
    val original = remember(state.fieldText, rates, minute, typing, state.fieldShowsAddress, fieldChats) { if (typing && !fieldChats && !state.fieldShowsAddress) FieldCalculator.answer(state.fieldText, rates = rates) else null }
    var swapped by remember(fieldOwner, state.fieldText) { mutableStateOf(false) }
    var copied by remember(fieldOwner, state.fieldText) { mutableStateOf(false) }
    val answer = if (swapped && original != null) FieldCalculator.reverse(original, state.fieldText, rates) ?: original else original
    var lastAnswer by remember(fieldOwner) { mutableStateOf<FieldAnswer?>(null) }
    SideEffect { answer?.let { lastAnswer = it } }
    val canSwap = original?.let { FieldCalculator.reverse(it, state.fieldText, rates) != null } == true
    var pasteTarget by remember(fieldOwner, placement) { mutableStateOf<FieldAnswerTarget?>(null) }
    DisposableEffect(fieldOwner, placement) { onDispose { pasteTarget?.revoke() } }
    DisposableEffect(inputFocus) { onDispose { inputFocus?.released() } }
    val focusPreparation = remember(fieldOwner, typing, interactive, chatsPage, chatsAsking, placement) { mutableStateOf(false) }
    LaunchedEffect(fieldOwner, typing, interactive, chatsPage, chatsAsking, placement) {
        if (typing && currentInput() && (!fieldChats || chatsAsking)) {
            // Queue the isolated page bookmark before the native field takes focus.
            val capture = async(start = CoroutineStart.UNDISPATCHED) { controller.captureFieldAnswerTarget() }
            focusPreparation.value = true
            val target = capture.await()
            if (currentInput()) pasteTarget = target else target?.revoke()
        } else { pasteTarget?.revoke(); pasteTarget = null }
    }
    val focusPrepared = focusPreparation.value
    LaunchedEffect(fieldOwner, typing, interactive, chatsPage, chatsAsking, placement, editorNode, inputFocus, focusPrepared, inputReady, windowFocused, state.fieldResting) {
        if (typing && focusPrepared && inputReady && windowFocused && windowInfo.isWindowFocused && editorNode.current() && currentInput() && (!fieldChats || chatsAsking) &&
            !state.fieldResting && !controller.state.value.fieldResting && attachedInput()) {
            val focused = focus.requestFocus()
            if (focused && editorNode.current() && currentInput() && attachedInput() && windowInfo.isWindowFocused &&
                !state.fieldResting && !controller.state.value.fieldResting && inputFocus?.ownsFocus != false) keyboard?.show()
        }
    }
    LaunchedEffect(state.fieldText, rates, minute) { if (original?.kind == FieldAnswer.Kind.MONEY) ratesSource.warm() }
    LaunchedEffect(copied) { if (copied) { delay(1300); copied = false } }
    fun currentField(): Boolean = controller.state.value.let { current ->
        currentInput() && current.surface == BrowserSurface.FIELD && current.surfaceEpoch == state.surfaceEpoch &&
            current.selectedSpaceId == state.selectedSpaceId && current.tab?.id == state.tab?.id &&
            current.fieldIsNewTab == state.fieldIsNewTab && current.fieldIsPrivate == state.fieldIsPrivate &&
            current.fieldText == state.fieldText && !current.privateContentBlocked
    }
    fun copyAnswer() {
        if (currentField()) answer?.takeIf { it.copy.isNotEmpty() }?.let { copyFieldValue(context, it.copy); copied = true; focus.requestFocus(); keyboard?.show() }
    }
    fun chooseRecent(tab: BrowserTab) {
        if (currentField() && controller.state.value.space?.tabs?.any { it == tab && !it.isPrivate && !it.isBlank } == true)
            controller.selectTab(tab.id)
    }
    val fieldSuggestions = if (hasWords) controller.suggestions(state.fieldText) else emptyList()
    val bestTab = fieldSuggestions.firstOrNull { it.tabId != null }
    val bestAsk = !isPrivate && onAskQuestion != null && bestTab == null && browserFieldQuestion(state.fieldText)
    fun ask() { if (currentField() && !isPrivate) onAskQuestion?.invoke(state.fieldText, state.tab?.takeIf { !state.fieldIsNewTab && !it.isBlank }) }
    fun browserSheetRows(): List<BrowserSheetRow> = if (!hasWords) emptyList() else buildList {
        val search = BrowserSheetRow("typed-search", state.fieldText, YabGlyphs.MagnifyingGlass) { if (currentField()) controller.submitField() }
        val about = state.tab?.takeIf { !state.fieldIsNewTab && !it.isBlank }
        val askRow = if (onAskQuestion != null && !isPrivate) BrowserSheetRow("typed-ask", "Ask $agentName", YabGlyphs.MacAgentFace,
            "\u201C${state.fieldText}\u201D" + if (about == null) "" else " \u00B7 About Page", ::ask) else null
        if (bestAsk) askRow?.let(::add)
        else if (bestTab != null) add(BrowserSheetRow("best-tab", bestTab.title, YabGlyphs.SquareBehindSquare1, bestTab.subtitle) {
            if (currentField()) bestTab.tabId?.let(controller::selectTab) })
        else add(search)
        if (bestTab != null) add(search)
        fieldSuggestions.filterNot { it == bestTab }.forEach { suggestion ->
            add(BrowserSheetRow(suggestion.tabId ?: suggestion.url, suggestion.title, if (suggestion.tabId == null) YabGlyphs.History else YabGlyphs.SquareBehindSquare1, suggestion.subtitle) {
                if (currentField()) { if (suggestion.tabId != null) controller.selectTab(suggestion.tabId) else { controller.fieldLeavesUpward(); controller.openUrl(suggestion.url, newTab = state.fieldIsNewTab) } }
            })
        }
        if (bestAsk) add(search) else askRow?.let(::add)
    }
    fun mathKey(symbol: String) {
        if (currentField()) {
            val start = minOf(value.selection.start, value.selection.end).coerceIn(0, value.text.length)
            val end = maxOf(value.selection.start, value.selection.end).coerceIn(start, value.text.length)
            val text = value.text.replaceRange(start, end, symbol)
            value = TextFieldValue(text, TextRange(start + symbol.length))
            controller.fieldText(text); focus.requestFocus(); keyboard?.show()
        }
    }
    fun submit() { if (currentField()) {
        if (tabletViewport != null && tabletRecent.isNotEmpty()) chooseRecent(tabletRecent.first())
        else if (fieldChats) { controller.restField(state.surfaceEpoch); keyboard?.hide() }
        else if (answer?.takesReturn == true) copyAnswer()
        else if (tabletViewport == null && bestTab != null) bestTab.tabId?.let(controller::selectTab)
        else if (tabletViewport == null && bestAsk) ask()
        else controller.submitField()
    } }
    val closeOriginal = fieldPresentation?.close ?: spacesMotion?.close ?: controller::dismissSurface
    val close: () -> Unit = { if (placement?.current() != false) closeOriginal() }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val restingGeometry = BrowserFieldGeometry(maxWidth.value.toDouble().coerceAtLeast(80.0), maxHeight.value.toDouble(), 0.0,
            textScale = density.fontScale.toDouble(), lineHeight = 20.3 * density.fontScale, resting = true,
            statusTop = WindowInsets.statusBars.getTop(density) / density.density.toDouble())
        val restingPose = BrowserFieldPose(restingGeometry, restingGeometry.plate, restingGeometry.stack,
            spacesMotion?.let { ((it.reveal - .05) / .45).coerceIn(0.0, 1.0) } ?: 1.0, 1.0, 1.0)
        val presentation = fieldPresentation ?: BrowserFieldPresentation(restingPose, interactive, 1f, 0f, 1f, 1f, close, {})
        val ink = androidx.compose.ui.graphics.lerp(colors.onSurface, Color.White, privateFraction)
        val publicPlate = if (colors.background.luminance() < .2f) colors.surface.copy(alpha = .9f) else Color.White.copy(alpha = .86f)
        val plateColor = androidx.compose.ui.graphics.lerp(publicPlate, Color(0xFF303138), privateFraction)
        val fieldInput: @Composable (Modifier) -> Unit = { inputModifier ->
                    Row(inputModifier.semantics { this[FieldPrivateInkKey] = privateFraction }.onGloballyPositioned { coordinates ->
                        val r = coordinates.boundsInRoot()
                        inputAnchor = FieldAnchor((r.left / density.density).toDouble(), (r.top / density.density).toDouble(),
                            (r.width / density.density).toDouble(), (r.height / density.density).toDouble())
                    }.padding(start = if (tabletViewport != null) 16.dp else if (sheetMotion != null) SearchSheet.FieldLeading.dp else if (!typing || state.fieldIsNewTab) 18.dp else 14.dp, end = if (tabletViewport != null) 0.dp else 2.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (tabletViewport == null) {
                        if (!sheetLayout && fieldChats && state.fieldIsNewTab && !isPrivate && archiveAction != null) key(archiveAction) {
                            IconButton(onClick = { if (currentField()) archiveAction.perform() }, enabled = interactive && archiveAction.current(),
                                modifier = Modifier.size(30.dp).offset(x = (-7).dp)
                                    .background(if (archiveAction.archived) ink else Color.Transparent, CircleShape).testTag("browser.field.archive")) {
                                Icon(YabGlyphs.MacArchivebox, if (archiveAction.archived) "Show Chats" else "Show Archived Chats", Modifier.size(20.dp),
                                    tint = if (archiveAction.archived) Color.White else ink.copy(alpha = .6f))
                            }
                        }
                        else if (typing && state.fieldShowsAddress && state.tab?.isBlank == false) BrowserFavicon(state.tab!!, 16.dp, Modifier.testTag("browser.field.favicon"))
                        else Icon(YabGlyphs.MagnifyingGlass, null, Modifier.size(18.dp).testTag("browser.field.search-glyph"), tint = ink.copy(alpha = .6f))
                        Spacer(Modifier.width(if (!sheetLayout && fieldChats && archiveAction != null) 2.dp else if (sheetLayout || !typing || state.fieldIsNewTab) 14.dp else 8.dp))
                        }
                        val displayedValue = if (!interactive && isPrivate && state.fieldIsNewTab) TextFieldValue("") else value
                        key(placement, inputLease, editorNode) {
                        BasicTextField(value = displayedValue, onValueChange = { next -> editorNode.change(::currentInput) {
                            value = next
                            inputLease?.let { controller.fieldText(next.text, it) }
                        } },
                            modifier = Modifier.weight(1f).then(if (tabletViewport == null) Modifier.fillMaxHeight().wrapContentHeight(Alignment.CenterVertically) else Modifier.height(26.dp))
                                .onPreviewKeyEvent { event ->
                                    if (tabletViewport != null && event.type == KeyEventType.KeyUp && event.key == Key.Escape && editorNode.current() && currentInput()) {
                                        close(); true
                                    } else false
                                }
                                .onGloballyPositioned { coordinates ->
                                    if (editorNode.current()) {
                                        inputCoordinates[0] = coordinates
                                        val ready = coordinates.isAttached && coordinates.size.width > 0 && coordinates.size.height > 0
                                        if (inputReady != ready) inputReady = ready
                                    }
                                }
                                .focusRequester(focus).onFocusChanged {
                                    if (it.isFocused) {
                                        if (editorNode.current() && currentInput() && editorNode.acquired()) {
                                            inputFocus?.acquired()
                                            inputLease?.let { lease -> controller.focusFieldInput(lease, inputAnchor) }
                                        }
                                    } else editorNode.released { inputFocus?.released() }
                                }.testTag("browser.field.input"),
                            enabled = interactive, singleLine = true,
                            textStyle = TextStyle(color = ink, fontSize = if (tabletViewport == null) 17.sp else 20.sp), cursorBrush = SolidColor(if (isPrivate) Color.White else colors.primary),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = if (tabletViewport == null && bestAsk) ImeAction.Send else ImeAction.Search),
                            keyboardActions = KeyboardActions(onSearch = { if (editorNode.current()) submit() }, onSend = { if (editorNode.current()) submit() }),
                            decorationBox = { editor -> Box(contentAlignment = Alignment.CenterStart) {
                                if (displayedValue.text.isEmpty()) Text(if (tabletViewport != null) "Search or enter address" else if (isPrivate) (if (sheetLayout) "Search\u2026" else "Search privately") else if (fieldChats) (if (archiveAction?.archived == true) "Search archive" else "Search chats") else "Search, ask or give a task",
                                    color = ink.copy(alpha = if (isPrivate) .65f else .45f), fontSize = if (tabletViewport == null) 17.sp else 20.sp, maxLines = 1, overflow = TextOverflow.Clip)
                                editor()
                            } })
                        }
                        if (tabletViewport != null && !state.fieldPagePrivate) Spacer(Modifier.width(12.dp))
                        if (if (tabletViewport != null) !state.fieldPagePrivate else !(sheetLayout && fieldChats) && state.fieldText.isEmpty() && (state.fieldIsNewTab || !state.fieldPagePrivate)) BrowserEyesButton(
                            shut = state.fieldPrivate, color = ink,
                            onToggle = { if (currentField()) { sheetMotion?.eyesTurned(); controller.fieldPrivacy(!state.fieldPrivate) } }, enabled = interactive,
                            animationsEnabled = fieldAnimations,
                            owner = placement,
                            modifier = Modifier.then(if (tabletViewport != null) Modifier.heightIn(min = 44.dp) else Modifier).graphicsLayer {
                                alpha = presentation.pose.eyes.toFloat()
                                scaleX = (.8 + .2 * presentation.pose.eyes).toFloat(); scaleY = scaleX
                            })
                        if (tabletViewport == null && state.fieldText.isNotEmpty()) key(placement) { IconButton(enabled = interactive, onClick = { if (currentField()) controller.fieldText("") }) {
                            Icon(YabGlyphs.CircleX, "Clear address", Modifier.size(20.dp), tint = ink.copy(alpha = .65f))
                        } }
                    }
        }
        CompositionLocalProvider(LocalBrowserRowInk provides if (isPrivate) Color.White else null) {
            if (tabletViewport != null && placement != null) {
                val rows = buildList {
                    if (hasWords) {
                        add(TabletOmniboxRow("search:${state.fieldText}", "Search ${state.settings.searchEngine.title}", state.fieldText,
                            "Search", YabGlyphs.MagnifyingGlass) { if (currentField()) controller.submitField() })
                        controller.suggestions(state.fieldText).forEach { suggestion ->
                            add(TabletOmniboxRow("suggestion:${suggestion.tabId ?: suggestion.url}:${state.fieldText}", suggestion.title,
                                suggestion.subtitle, if (suggestion.tabId == null) "Open" else "Switch to Tab",
                                if (suggestion.tabId == null) YabGlyphs.History else YabGlyphs.SquareBehindSquare1) {
                                if (currentField()) { if (suggestion.tabId != null) controller.selectTab(suggestion.tabId)
                                    else controller.openUrl(suggestion.url, newTab = state.fieldIsNewTab) }
                            })
                        }
                        if (onAskQuestion != null) add(TabletOmniboxRow("ask:${state.fieldText}", "Ask", state.fieldText,
                            "Ask", YabGlyphs.Sparkle) {
                            if (currentField()) onAskQuestion(state.fieldText, state.tab?.takeIf { !state.fieldIsNewTab && !it.isBlank })
                        })
                    } else if (!state.fieldShowsAddress && !isPrivate && state.fieldText.isEmpty()) {
                        tabletRecent.forEachIndexed { index, tab ->
                            add(TabletOmniboxRow("recent:${tab.id}", tab.title.ifBlank { tab.host }, null,
                                if (index == 0) "Open" else "Recent", YabGlyphs.History) {
                                chooseRecent(tab)
                            })
                        }
                    }
                }
                val answerRow = answer?.takeUnless { state.fieldShowsAddress }?.let { result ->
                    TabletOmniboxRow("answer:${state.fieldText}:$swapped", result.result, result.resultNote,
                        if (copied) "Copied" else "Copy", if (copied) YabGlyphs.Checkmark1Small else YabGlyphs.MacYabCopyframeText, ::copyAnswer)
                }
                BrowserTabletOmnibox(tabletViewport, state.fieldResting, state.fieldShowsAddress, isPrivate,
                    placement, interactive, rows, answerRow, fieldInput, close)
            } else if (sheetLayout) {
                val motion = sheetMotion
                val width = maxWidth.value.toDouble()
                val height = maxHeight.value.toDouble()
                val live = fieldPresentation?.keyboard ?: 0.0
                LaunchedEffect(live) { delay(300); if (live > 80) BrowserSheetKeyboard.last = live }
                val sheetKeyboard = max(live, BrowserSheetKeyboard.last)
                val highest = with(density) { WindowInsets.statusBars.getTop(this).toDp().value.toDouble() } + 2
                val sheetGeometry = BrowserSheetGeometry(width, height, sheetKeyboard, highest)
                val recent = remember(state.history, state.tab?.url) { browserSheetRecent(state) }
                if (motion != null) {
                    val plain = !hasWords && recent.isEmpty()
                    val body by androidx.compose.animation.core.animateFloatAsState(SearchSheet.body(plain).toFloat(), BrowserMotion.spring(.36f), label = "sheet body")
                    SideEffect { motion.body = body }
                }
                val publicSpace = state.space?.takeUnless(BrowserSpace::isPrivate) ?: state.spaces.firstOrNull { !it.isPrivate }
                val startPaint = remember(publicSpace?.look, publicSpace?.color) { browserSpaceSurface(publicSpace) }
                val sheetDark = colors.background.luminance() < .5f
                var sheetWash by remember(state.surfaceEpoch) { mutableStateOf(BrowserSpacesWash.at(listOf(startPaint.tint), 0.0, null, sheetDark) to startPaint.grain) }
                val own = remember(publicSpace?.look, publicSpace?.color) { browserSpaceOwnColor(publicSpace) }
                val open by remember(motion) { derivedStateOf { motion == null || motion.expand >= .999f } }
                val sheetFoot by remember(motion) { derivedStateOf { motion != null && motion.expand > .7f } }
                val footShown = if (motion != null) sheetFoot else (spacesMotion?.reveal ?: 1.0) > .5
                val reduced = LocalBrowserAccessibility.current.reduceMotion
                val actions = BrowserSheetActions(close = close, rest = { controller.restField(state.surfaceEpoch) },
                    ask = { controller.restField(state.surfaceEpoch, false) })
                fun lower(dy: Double, ended: Boolean, velocity: Double) {
                    val sheet = motion ?: return
                    if (fieldChats) return
                    if (!ended) { sheet.hold(); sheet.pulling = true
                        sheet.expand = (1 - dy / sheetGeometry.span(sheet.pose())).toFloat().coerceIn(0f, 1f)
                    } else {
                        sheet.pulling = false
                        if (velocity < -SearchSheet.Flick || sheet.expand > .75f && velocity < SearchSheet.Flick) sheet.travel(scope, 1f, reduced)
                        else actions.ask()
                    }
                }
                BrowserSearchSheetLayout(motion, sheetKeyboard, highest, presentation.backdrop, presentation.pillAlpha * presentation.contents,
                    interactive, privateFraction, hasWords, !isPrivate && (state.fieldText.isEmpty() || state.fieldShowsAddress), state.fieldResting || !typing,
                    fieldChats, chatsAsking, own, sheetWash.first, sheetWash.second, actions, reduced,
                    spaces = {
                        val room = browserFootBottom().dp + 48.dp + 16.dp
                        CompositionLocalProvider(LocalSpacesFootRoom provides room) {
                            BrowserFieldPages(state, controller, Modifier.fillMaxSize(), interactive && open, spacesMotion, onChats,
                                onUnlockPrivate, fieldChatsContent?.let { original -> { modifier, enabled ->
                                    CompositionLocalProvider(LocalBrowserFieldChatArchive provides archiveBinding) { original(modifier, enabled) }
                                } }, onChatsPageChanged = { chatsPage = it }, wash = null, sheet = true,
                                onSheetWash = { paint, grain -> sheetWash = paint to grain },
                                more = { buttonModifier, chats, ink, plate ->
                                    BrowserSpacesMoreMenu(ink, plate, chats, archiveAction?.archived == true,
                                        onArchived = { wanted -> archiveAction?.takeIf { it.archived != wanted }?.perform() },
                                        filter = spaceFilter, onFilter = { spaceFilter = it },
                                        macTabs = state.settings.macTabs, onMacTabs = controller::showMacTabs, modifier = buttonModifier)
                                }, sheetLower = ::lower) { space, enabled, current, rowSwipes ->
                                SpaceContents(space, state, controller, onOpenOnMac, onAskPage, wide, macTodayContent, enabled, current, rowSwipes, spaceFilter)
                            }
                        }
                    },
                    lines = {
                        CompositionLocalProvider(LocalBrowserRowInk provides if (isPrivate) Color.White else null) {
                            Box(Modifier.fillMaxSize()) {
                                if (hasWords) LazyColumn(Modifier.fillMaxSize().clip(RoundedCornerShape(14.dp)).testTag("browser.field.rows")) {
                                    answer?.let { shownAnswer -> item("answer") { key(placement, inputLease) {
                                        FieldAnswerPlate(shownAnswer, copied, canSwap, pasteTarget?.ready == true, !state.fieldIsNewTab,
                                            onCopy = ::copyAnswer,
                                            onQuestion = { if (currentField()) { copyFieldValue(context, shownAnswer.question); copied = false; focus.requestFocus(); keyboard?.show() } },
                                            onSwap = { if (currentField()) { swapped = !swapped; copied = false; focus.requestFocus(); keyboard?.show() } },
                                            onPaste = {
                                                val chosen = shownAnswer.copy; val target = pasteTarget
                                                if (currentField() && chosen.isNotEmpty() && target?.ready == true) scope.launch {
                                                    if (!currentField()) return@launch
                                                    val inserted = target.insert(chosen)
                                                    if (currentField()) {
                                                        controller.dismissSurface()
                                                        if (!inserted) controller.message("Select a text field on the page first")
                                                    }
                                                }
                                            }, modifier = Modifier.padding(bottom = 8.dp), actionable = true, dark = isPrivate, current = ::currentField,
                                            bestFill = bestFill.takeIf { shownAnswer.takesReturn })
                                    } } }
                                    itemsIndexed(browserSheetRows(), key = { _, row -> row.key }) { index, row -> key(placement) {
                                        BrowserFieldBestRow(if (index == 0) bestFill.takeUnless { answer?.takesReturn == true } else null) {
                                            BrowserTypedRow(row.title, row.icon, row.detail, row.action)
                                        }
                                    } }
                                } else BlurTurn(privateFraction, {
                                    Column(Modifier.fillMaxWidth()) {
                                        recent.forEach { visit -> key(visit.url) {
                                            BrowserRecentRow(visit, colors.onSurface) { if (currentField()) controller.openFieldPage(visit.url) }
                                        } }
                                    }
                                }, {
                                    Text("You’re browsing privately", Modifier.align(Alignment.Center), color = Color.White.copy(alpha = .6f), fontSize = 16.sp)
                                })
                                if (typing && FieldCalculator.mathKeys(state.fieldText)) key(placement) { FieldMathKeys(modifier = Modifier.align(Alignment.BottomCenter), onKey = ::mathKey) }
                            }
                        }
                    },
                    input = { inputModifier, veil ->
                        val fill = androidx.compose.ui.graphics.lerp(colors.onSurface.copy(alpha = .1f), Color(0xD024222C), privateFraction)
                        Box(inputModifier.clip(CircleShape).background(fill)) {
                            key(placement?.controls) { fieldInput(Modifier.fillMaxSize().graphicsLayer { alpha = veil() }.testTag("browser.field.pill")) }
                        }
                    },
                    askingField = {
                        // Chats' search: the field grows out of its button over the foot as the keyboard rises.
                        val to = FieldRect(8.0, height - sheetKeyboard - 8 - 48, max(0.0, width - 16 - 48 - 7), 48.0)
                        val from = BrowserFootRects(width, height, browserFootBottom().toDouble()).center
                        var grown by remember { mutableStateOf(false) }
                        LaunchedEffect(Unit) { grown = true }
                        val grow by androidx.compose.animation.core.animateFloatAsState(if (grown) 1f else 0f,
                            androidx.compose.animation.core.tween(300, easing = BrowserMotion.easeOut), label = "chat search")
                        val rect = from.mix(to, grow.toDouble())
                        Surface(Modifier.offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp), shape = CircleShape, color = plateColor, shadowElevation = 3.dp) {
                            key(placement?.controls) { fieldInput(Modifier.fillMaxSize().testTag("browser.field.pill")) }
                        }
                        Surface(Modifier.offset((to.right + 7).dp, to.y.dp).size(48.dp).graphicsLayer { alpha = grow }, shape = CircleShape, color = plateColor, shadowElevation = 3.dp) {
                            IconButton(onClick = { controller.fieldText(""); actions.rest() }, modifier = Modifier.fillMaxSize()) {
                                Icon(YabGlyphs.CrossMedium, "Close", tint = ink)
                            }
                        }
                    },
                    foot = { shown ->
                        if (footShown) BrowserSpacesFootBar(fieldChats, interactive && (motion == null || open),
                            shown = { spacesMotion?.let { ((it.reveal - .5) / .5).coerceIn(0.0, 1.0).toFloat() } ?: shown() },
                            onSettings = { controller.show(BrowserSurface.SETTINGS) },
                            onNewChat = { onNewChat?.invoke() },
                            onPlus = { if (typing) actions.ask() else controller.openField(fromSpaces = true) },
                            onSearchChats = { if (typing) actions.ask() else controller.openField(fromSpaces = true, chats = true) },
                            onDone = close)
                    })
            } else {
            BrowserFieldLayout(presentation, isPrivate, plateColor, privateFraction,
                spaceWash = state.spaces.any { !it.isPrivate },
                content = { cardModifier, wash ->
                    // Phone's expanded field uses Metrics.NewTab.highest = 56 points.
                    // Taller native cutouts keep their own safe inset.
                    val statusHeight = with(density) { WindowInsets.statusBars.getTop(this).toDp() }
                    Column(cardModifier.statusBarsPadding().padding(top = (56.dp - statusHeight).coerceAtLeast(0.dp))) {
                        Box(Modifier.weight(1f).fillMaxWidth()) {
                            FieldPageInputGate(!hasWords, Modifier.fillMaxSize()) {
                                BrowserFieldPages(state, controller, Modifier.fillMaxSize(), interactive && !hasWords, spacesMotion, onChats,
                                    onUnlockPrivate, fieldChatsContent?.let { original -> { modifier, enabled ->
                                        CompositionLocalProvider(LocalBrowserFieldChatArchive provides archiveBinding) { original(modifier, enabled) }
                                    } }, onChatsPageChanged = { chatsPage = it }, wash = wash) { space, enabled, current, rowSwipes ->
                                    SpaceContents(space, state, controller, onOpenOnMac, onAskPage, wide, macTodayContent, enabled, current, rowSwipes)
                                }
                            }
                        if (hasWords) {
                            Column(Modifier.fillMaxSize().then(browserFieldBodyClip(wash)), verticalArrangement = Arrangement.Bottom) {
                            val reduced = LocalBrowserAccessibility.current.reduceMotion
                            AnimatedVisibility(answer != null,
                                enter = if (reduced) fadeIn(androidx.compose.animation.core.tween(200)) else fadeIn(BrowserMotion.spring(0.34f)) + scaleIn(BrowserMotion.spring(0.34f), initialScale = 0.97f, transformOrigin = TransformOrigin(0.5f, 1f)) + expandVertically(BrowserMotion.springLayout(0.34f), expandFrom = Alignment.Bottom, clip = false),
                                exit = if (reduced) fadeOut(androidx.compose.animation.core.tween(200)) else fadeOut(BrowserMotion.spring(0.34f)) + scaleOut(BrowserMotion.spring(0.34f), targetScale = 0.97f, transformOrigin = TransformOrigin(0.5f, 1f)) + shrinkVertically(BrowserMotion.springLayout(0.34f), shrinkTowards = Alignment.Bottom, clip = false)) {
                            (answer ?: lastAnswer)?.let { visibleAnswer -> key(placement, inputLease) { FieldAnswerPlate(visibleAnswer, copied, canSwap, pasteTarget?.ready == true, !state.fieldIsNewTab,
                                onCopy = ::copyAnswer,
                                onQuestion = { if (currentField()) answer?.let { copyFieldValue(context, it.question); copied = false; focus.requestFocus(); keyboard?.show() } },
                                onSwap = { if (currentField()) { swapped = !swapped; copied = false; focus.requestFocus(); keyboard?.show() } },
                                onPaste = {
                                    val chosen = answer?.copy.orEmpty(); val target = pasteTarget
                                    if (currentField() && chosen.isNotEmpty() && target?.ready == true) scope.launch {
                                        if (!currentField()) return@launch
                                        val inserted = target.insert(chosen)
                                        // Later typing or a replacement field owns its own close/result.
                                        if (currentField()) {
                                            controller.dismissSurface()
                                            if (!inserted) controller.message("Select a text field on the page first")
                                        }
                                    }
                                }, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp), actionable = answer != null, dark = isPrivate, current = ::currentField,
                                bestFill = bestFill.takeIf { answer?.takesReturn == true }) } }
                            }
                            Surface(Modifier.weight(1f, fill = false).fillMaxWidth().padding(horizontal = 8.dp).testTag("browser.field.rows"),
                                shape = RoundedCornerShape(22.dp), color = if (isPrivate) Color(0xFF242328) else if (MaterialTheme.colorScheme.background.luminance() < .2f) Color(0xFF2C2C2E).copy(alpha = .9f) else Color.White.copy(alpha = .84f),
                                border = androidx.compose.foundation.BorderStroke(.5.dp, Color.White.copy(alpha = if (isPrivate) .14f else .6f)), shadowElevation = 10.dp) {
                            LazyColumn(Modifier.fillMaxWidth().padding(8.dp), reverseLayout = true) {
                                fun androidx.compose.foundation.lazy.LazyListScope.searchRow(best: Boolean) {
                                    item("typed-search") { key(placement) {
                                        BrowserFieldBestRow(if (best) bestFill.takeUnless { answer?.takesReturn == true } else null) {
                                            BrowserTypedRow(state.fieldText, YabGlyphs.MagnifyingGlass) { if (currentField()) controller.submitField() }
                                        }
                                    } }
                                }
                                fun androidx.compose.foundation.lazy.LazyListScope.askRow(best: Boolean) {
                                    if (onAskQuestion != null && !isPrivate) item("typed-ask") { key(placement) {
                                        val about = state.tab?.takeIf { !state.fieldIsNewTab && !it.isBlank }
                                        BrowserFieldBestRow(if (best) bestFill.takeUnless { answer?.takesReturn == true } else null) {
                                            BrowserTypedRow("Ask $agentName", YabGlyphs.MacAgentFace, "“${state.fieldText}”" + if (about == null) "" else " · About Page", ::ask)
                                        }
                                    } }
                                }
                                if (bestAsk) askRow(true)
                                else if (bestTab != null) item("best-tab") { key(placement) {
                                    BrowserFieldBestRow(bestFill.takeUnless { answer?.takesReturn == true }) {
                                        BrowserTypedRow(bestTab.title, YabGlyphs.SquareBehindSquare1, bestTab.subtitle) { if (currentField()) bestTab.tabId?.let(controller::selectTab) }
                                    }
                                } }
                                else searchRow(true)
                                if (bestTab != null) searchRow(false)
                                items(fieldSuggestions.filterNot { it == bestTab }.reversed(), key = { it.tabId ?: it.url }) { suggestion -> key(placement) {
                                    BrowserTypedRow(suggestion.title, if (suggestion.tabId == null) YabGlyphs.History else YabGlyphs.SquareBehindSquare1, suggestion.subtitle) {
                                        if (currentField()) { if (suggestion.tabId != null) controller.selectTab(suggestion.tabId) else { controller.fieldLeavesUpward(); controller.openUrl(suggestion.url, newTab = state.fieldIsNewTab) } }
                                    }
                                } }
                                if (bestAsk) searchRow(false) else askRow(false)

                            }
                            }
                            }
                        }
                        }
                        if (typing && !fieldChats && FieldCalculator.mathKeys(state.fieldText)) key(placement) { FieldMathKeys(modifier = browserFieldBodyClip(wash), onKey = { symbol ->
                            if (currentField()) {
                                val start = minOf(value.selection.start, value.selection.end).coerceIn(0, value.text.length)
                                val end = maxOf(value.selection.start, value.selection.end).coerceIn(start, value.text.length)
                                val text = value.text.replaceRange(start, end, symbol)
                                value = TextFieldValue(text, TextRange(start + symbol.length))
                                controller.fieldText(text); focus.requestFocus(); keyboard?.show()
                            }
                        }) }
                    }
                },
                input = { inputModifier -> key(placement?.controls) { fieldInput(inputModifier) } },
                close = { closeModifier -> key(placement) { Surface(closeModifier, shape = CircleShape,
                    color = plateColor, shadowElevation = 1.dp) {
                    IconButton(onClick = close, enabled = interactive, modifier = Modifier.fillMaxSize().testTag("browser.field.close")) {
                        Icon(YabGlyphs.CrossMedium, "Close", tint = ink)
                    }
                } } })
            }
        }
    }
}

/** A row under the sheet's field, in the omnibox's order. */
internal class BrowserSheetRow(val key: String, val title: String, val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val detail: String? = null, val action: () -> Unit)

/** Recent pages when the field is empty, as many as the sheet's rows. */
internal fun browserSheetRecent(state: BrowserState): List<BrowserVisit> = state.history.asSequence()
    .filter { it.url != state.tab?.url }.distinctBy { HistoryPresentation.pretty(it.url) }.take(SearchSheet.Rows).toList()

internal fun browserSheetPlain(state: BrowserState) = browserSheetRecent(state).isEmpty()

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun SpaceContents(space: BrowserSpace, state: BrowserState, controller: BrowserController, onMac: ((BrowserTab) -> Unit)?, onAsk: ((BrowserTab) -> Unit)?, wide: Boolean, macTodayContent: (@Composable (String) -> Unit)?, enabled: Boolean = true, current: () -> Boolean = { true }, rowSwipes: BrowserSpaceRowSwipeScope? = null, filter: SpacesFilter = SpacesFilter.EVERYTHING) {
    val workspaceEntry = rememberWorkspaceEntry(controller)
    val pins = space.tabs.filter { !it.isPrivate && it.place == TabPlace.PINNED && filter != SpacesFilter.TODAY }
    val kept = space.tabs.filter { !it.isPrivate && it.place == TabPlace.KEPT && filter != SpacesFilter.TODAY }
    val today = space.tabs.filter { !it.isPrivate && it.place == TabPlace.TODAY && !it.isBlank && filter != SpacesFilter.PINS }
    val folders = space.folders.takeIf { filter != SpacesFilter.TODAY }.orEmpty()
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    var allPins by remember(space.id) { mutableStateOf(false) }
    val grid = BrowserSpacePinGrid.of(pins.size, allPins)
    val scroll = rememberLazyListState()
    val keptRows = remember(space, filter) { if (filter == SpacesFilter.TODAY) emptyList() else folderRows(space) }
    val folderMove = browserFolderMove(space.id, space.folders.filter { it.open }.map { it.id }.toSet())
    var revealTab by remember(space.id) { mutableStateOf<String?>(null) }
    val keys = buildList {
        if (pins.isNotEmpty()) add("pins")
        keptRows.forEach { add(it.key) }
        if (kept.isNotEmpty() || folders.isNotEmpty() || today.isNotEmpty()) add("today-line")
        today.forEach { add("tab:${it.id}") }
    }
    LaunchedEffect(revealTab, keys) {
        val original = revealTab ?: return@LaunchedEffect
        val rowKey = "tab:$original"
        val index = keys.indexOf(rowKey)
        // LazyColumn otherwise anchors the old Today line and hides the newly
        // kept row above it. Reveal only this accepted original row, after layout.
        withFrameNanos { }
        if (index >= 0 && enabled && current()) {
            val info = scroll.layoutInfo
            val visible = info.visibleItemsInfo.any { it.key == rowKey && it.offset >= info.viewportStartOffset && it.offset + it.size <= info.viewportEndOffset }
            if (!visible) scroll.animateScrollToItem(index)
        }
        if (revealTab == original) revealTab = null
    }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), state = scroll, contentPadding = PaddingValues(bottom = LocalSpacesFootRoom.current ?: 16.dp)) {
        if (pins.isNotEmpty()) item(key = "pins") {
            Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp).padding(top = 16.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                (0 until grid.shown).chunked(grid.columns).forEach { cells ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        cells.forEach { index ->
                            if (grid.more > 0 && index == grid.shown - 1) {
                                Surface(Modifier.weight(1f).height(52.dp).clickable(enabled = enabled) { if (current()) allPins = true },
                                    shape = RoundedCornerShape(14.dp), color = Color.White.copy(alpha = .55f), border = androidx.compose.foundation.BorderStroke(.5.dp, Color.Black.copy(alpha = .04f))) {
                                    Box(contentAlignment = Alignment.Center) { Text("+${grid.more}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold) }
                                }
                            } else {
                                val tab = pins[index]
                                key(tab.id) {
                                    var held by remember(tab) { mutableStateOf(false) }
                                    var beside by remember(tab) { mutableStateOf<WorkspaceActionLease?>(null) }
                                    Box(Modifier.weight(1f)) {
                                        key(workspaceEntry) {
                                            Surface(Modifier.fillMaxWidth().height(52.dp).testTag("browser.pin.${tab.id}")
                                                .combinedClickable(enabled = enabled,
                                                    onClick = { if (current()) controller.selectTab(tab.id) },
                                                    onLongClick = { if (current() && (workspaceEntry == null || controller.workspaceEntryCurrent(workspaceEntry))) {
                                                        beside = workspaceEntry?.let { controller.captureWorkspaceActions(it, tab) }; held = true
                                                    } }).semantics { contentDescription = tab.shortTitle },
                                                shape = RoundedCornerShape(14.dp), color = Color.White.copy(alpha = if (tab.id == space.currentTabId) 1f else .55f),
                                                shadowElevation = if (tab.id == space.currentTabId) 3.dp else 0.dp,
                                                border = androidx.compose.foundation.BorderStroke(.5.dp, Color.Black.copy(alpha = if (tab.id == space.currentTabId) .08f else .04f))) {
                                                Box(contentAlignment = Alignment.Center) { BrowserFavicon(tab, 24.dp, Modifier.testTag("browser.pin.favicon.${tab.id}")) }
                                            }
                                        }
                                        HeldTabMenu(tab, state, controller, onMac, onAsk, wide, held, enabled, current, beside) { held = false }
                                    }
                                }
                            }
                        }
                        repeat(grid.columns - cells.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
        if (kept.isNotEmpty() || folders.isNotEmpty()) {
            items(keptRows, key = { it.key }) { row ->
                val movement = Modifier.animateItem(fadeInSpec = BrowserMotion.rowIn(reduced),
                    placementSpec = folderMove?.let { BrowserMotion.folderRows(it, reduced) } ?: BrowserMotion.rowPlacement(reduced), fadeOutSpec = BrowserMotion.rowOut(reduced))
                if (row.folder != null) Row(movement.fillMaxWidth().testTag("browser.folder.${row.folder.id}").clickable(enabled = enabled) { if (current()) controller.toggleFolder(space.id, row.folder.id) }
                    .padding(start = (8 + row.depth * 32).dp, end = 8.dp, top = 7.dp, bottom = 7.dp).heightIn(min = 38.dp), verticalAlignment = Alignment.CenterVertically) {
                    BrowserSpaceFolderMark(row.folder, space, MaterialTheme.colorScheme.background.luminance() < .2f, 22.dp)
                    val count = space.tabs.count { !it.isPrivate && it.folderId == row.folder.id }
                    Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(row.folder.name, fontSize = 16.sp, lineHeight = 19.2.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(if (count == 1) "1 tab" else "$count tabs", fontSize = 13.sp, lineHeight = 15.6.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Icon(if (row.folder.open) YabGlyphs.ChevronDownSmall else YabGlyphs.ChevronRight, null, Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                } else row.tab?.let { tab -> BrowserTabRow(tab, state.tab?.id == tab.id, controller, onMac, onAsk, wide, movement.padding(start = (row.depth * 32).dp), enabled, current, rowSwipes, { revealTab = it }) }
            }
        }
        if (kept.isNotEmpty() || folders.isNotEmpty() || today.isNotEmpty()) item(key = "today-line") {
            Row(Modifier.fillMaxWidth().height(40.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (kept.isNotEmpty() || folders.isNotEmpty()) HorizontalDivider(Modifier.weight(1f), thickness = .5.dp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .12f)) else Spacer(Modifier.weight(1f))
                if (today.isNotEmpty()) TextButton(enabled = enabled, onClick = { if (current()) controller.clearToday() },
                    contentPadding = PaddingValues(start = 10.dp, end = 0.dp), colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurface)) {
                    Text("Clear", fontSize = 12.sp, lineHeight = 15.sp)
                }
            }
        }
        items(today, key = { "tab:${it.id}" }) { tab ->
            BrowserTabRow(tab, state.tab?.id == tab.id, controller, onMac, onAsk, wide,
                Modifier.animateItem(fadeInSpec = BrowserMotion.rowIn(reduced), placementSpec = folderMove?.let { BrowserMotion.folderRows(it, reduced) } ?: BrowserMotion.rowPlacement(reduced), fadeOutSpec = BrowserMotion.rowOut(reduced)), enabled, current, rowSwipes, { revealTab = it })
        }
        if (macTodayContent != null && enabled && current() && state.settings.macTabs && filter != SpacesFilter.PINS && state.selectedSpaceId == space.id) item(key = "mac-today") { macTodayContent(space.id) }
    }
}

private fun folderRows(space: BrowserSpace): List<BrowserKeptRow> = BrowserKeptTree.rows(space)

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun BrowserTabRow(tab: BrowserTab, selected: Boolean, controller: BrowserController, onMac: ((BrowserTab) -> Unit)?, onAsk: ((BrowserTab) -> Unit)?, wide: Boolean, modifier: Modifier = Modifier, enabled: Boolean = true, current: () -> Boolean = { true }, rowSwipes: BrowserSpaceRowSwipeScope? = null, onPlaceChanged: (String) -> Unit = {}) {
    val state by controller.state.collectAsState()
    val workspaceEntry = rememberWorkspaceEntry(controller)
    var held by remember(tab) { mutableStateOf(false) }
    var beside by remember(tab) { mutableStateOf<WorkspaceActionLease?>(null) }
    Box(modifier) {
        BrowserSpaceRowSwipe(tab, rowSwipes, enabled, current = {
            current() && controller.state.value.spaces.flatMap { it.tabs }.singleOrNull { it.id == tab.id } == tab
        }, keep = {
            if (tab.place == TabPlace.KEPT) controller.unkeepTab(tab.id) else controller.keepTab(tab.id)
            if (controller.state.value.space?.tabs?.singleOrNull { it.id == tab.id }?.place != tab.place) onPlaceChanged(tab.id)
        },
            pin = { controller.pinTab(tab.id) },
            close = { controller.closeTab(tab.id) }) {
        key(workspaceEntry) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(if (selected) Color.White.copy(alpha = if (MaterialTheme.colorScheme.background.luminance() < .2f) .12f else .6f) else Color.Transparent).combinedClickable(enabled = enabled,
            onClick = { if (current() && rowSwipes?.close() != true) controller.selectTab(tab.id) }, onLongClick = { if (current() && (workspaceEntry == null || controller.workspaceEntryCurrent(workspaceEntry))) {
                beside = workspaceEntry?.let { controller.captureWorkspaceActions(it, tab) }; held = true
            } }).padding(horizontal = 8.dp, vertical = 7.dp).heightIn(min = 38.dp), verticalAlignment = Alignment.CenterVertically) {
            BrowserFavicon(tab, 22.dp, Modifier.testTag("browser.row.favicon.${tab.id}"))
            Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(tab.shortTitle, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 16.sp, lineHeight = 19.2.sp, letterSpacing = (-.16).sp, fontWeight = FontWeight.Medium)
                Text(tab.host, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp, lineHeight = 15.6.sp)
            }
        }
        }
        }
        HeldTabMenu(tab, state, controller, onMac, onAsk, wide, held, enabled, current, beside) { held = false }
    }
}

/** Pins and list rows use the same Phone TabHold actions; a pin never gains Keep/Unkeep. */
@Composable
private fun HeldTabMenu(tab: BrowserTab, state: BrowserState, controller: BrowserController,
    onMac: ((BrowserTab) -> Unit)?, onAsk: ((BrowserTab) -> Unit)?, wide: Boolean, held: Boolean,
    enabled: Boolean = true, current: () -> Boolean = { true }, beside: WorkspaceActionLease? = null, dismiss: () -> Unit) {
    val context = LocalContext.current
    val source = state.spaces.firstOrNull { space -> space.tabs.any { it == tab } }
    var moving by remember(tab, held) { mutableStateOf(false) }
    val destinations = state.spaces.filter { !it.isPrivate && it.id != source?.id }
    fun act(action: () -> Unit) { if (enabled && current()) { dismiss(); action() } }
    DropdownMenu(held && enabled && current() && source != null && !state.privateContentBlocked, dismiss) {
        if (moving) {
            HeldTabMenuItem("Back", YabGlyphs.ChevronLeft) { if (enabled && current()) moving = false }
            HorizontalDivider()
            destinations.forEach { space ->
                DropdownMenuItem(text = { Text("${space.emoji} ${space.name}", fontSize = 17.sp) },
                    modifier = Modifier.widthIn(min = 236.dp).height(44.dp).testTag("browser.tab.move.${space.id}"),
                    onClick = { act { controller.moveTab(tab.id, space.id) } })
            }
        } else {
        if (wide && !tab.isPrivate && source?.id == state.selectedSpaceId && state.tab?.id != tab.id &&
            beside != null && controller.workspaceActionsCurrent(beside)) key(beside) {
            HeldTabMenuItem("Open Beside", YabGlyphs.MacYabSplitPlus) {
                if (held && enabled && current() && controller.workspaceActionsCurrent(beside)) {
                    dismiss(); controller.openBeside(tab.id, beside)
                }
            }
        }
        HeldTabMenuItem("Copy Link", YabGlyphs.Link) { act { copyLink(context, tab.url); controller.message("Link copied") } }
        HeldTabMenuItem("Share", YabGlyphs.MacYabShare) { act { shareLink(context, tab.url) } }
        if (!tab.isPrivate && source?.isPrivate == false) {
            if (onMac != null) HeldTabMenuItem("Open on Mac", YabGlyphs.MacYabLaptopRight) { act { onMac(tab) } }
            HorizontalDivider()
            HeldTabMenuItem(if (tab.place == TabPlace.PINNED) "Unpin" else "Pin",
                if (tab.place == TabPlace.PINNED) YabGlyphs.MacPinSlash else YabGlyphs.MacPin) {
                act { if (tab.place == TabPlace.PINNED) controller.unpinTab(tab.id) else controller.pinTab(tab.id) }
            }
            if (tab.place != TabPlace.PINNED) HeldTabMenuItem(if (tab.place == TabPlace.TODAY) "Keep" else "Unkeep",
                if (tab.place == TabPlace.TODAY) YabGlyphs.MacYabAnchor else YabGlyphs.MacAnchor) {
                act { if (tab.place == TabPlace.TODAY) controller.keepTab(tab.id) else controller.unkeepTab(tab.id) }
            }
            if (destinations.isNotEmpty()) HeldTabMenuItem("Move to Space", YabGlyphs.MacSquare2Layers3d, submenu = true) {
                if (enabled && current()) moving = true
            }
            if (onAsk != null) HeldTabMenuItem("Ask About Page", YabGlyphs.MacYabChatSpark) { act { onAsk(tab) } }
        }
        HorizontalDivider()
        HeldTabMenuItem("Close Tab", YabGlyphs.MacYabTabX, destructive = true) { act { controller.closeTab(tab.id) } }
        }
    }
}

@Composable
private fun HeldTabMenuItem(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector,
    destructive: Boolean = false, submenu: Boolean = false, action: () -> Unit) {
    val tint = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    DropdownMenuItem(text = { Text(title, color = tint, fontSize = 17.sp) }, onClick = action,
        modifier = Modifier.widthIn(min = 236.dp).height(44.dp), contentPadding = PaddingValues(horizontal = 16.dp),
        leadingIcon = { Icon(icon, null, Modifier.size(20.dp), tint = tint) },
        trailingIcon = if (submenu) ({ Icon(YabGlyphs.ChevronRight, null, Modifier.size(16.dp)) }) else null)
}

/** Keep the original entry across irrelevant recomposition; never capture inside an old action. */
@Composable
internal fun rememberWorkspaceEntry(controller: BrowserController): WorkspaceEntryLease? {
    val state by controller.state.collectAsState()
    val window by controller.workspaceWindow.collectAsState()
    val source by controller.historyPresentationLifetime.collectAsState()
    val lifetime by controller.settingsPresentationLifetime.collectAsState()
    return remember(controller, window.generation, source, lifetime, state.tab, state.workspace,
        state.surface, state.surfaceEpoch, state.selectedSpaceId, state.space?.websiteProfile) { controller.captureWorkspaceEntry() }
}

@Composable
private fun SectionCaption(title: String, modifier: Modifier = Modifier) { Text(title, modifier.padding(horizontal = 8.dp, vertical = 4.dp), fontSize = 12.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant) }

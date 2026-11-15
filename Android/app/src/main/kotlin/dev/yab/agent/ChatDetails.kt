package dev.yab.agent

import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.animation.core.animate
import androidx.compose.foundation.background
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.TransformOrigin
import kotlinx.coroutines.launch
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.activity.compose.BackHandler
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import dev.yab.browser.ui.YabGlyphs
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import dev.yab.browser.ui.LocalBrowserAccessibility
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter


@Composable
fun ChatWorkView(work: ChatWork, retry: (String) -> Unit) {
    var expanded by remember(work.id) { mutableStateOf(false) }
    when (work.kind) {
        // Phone keeps this metadata for Info and the answer's actions, never a raw step list.
        "actions", "worked" -> Unit
        "thought" -> Column(Modifier.testTag("chat.work.thought.${work.id}")) {
            if (work.text.isEmpty()) Text(work.words, style = MaterialTheme.typography.labelMedium)
            else {
                TextButton(onClick = { expanded = !expanded }, modifier = Modifier.semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }) { Text(work.words) }
                if (expanded) SelectionContainer { Text(work.text, style = MaterialTheme.typography.bodySmall) }
            }
        }
        "failure" -> Column(Modifier.testTag("chat.work.failure.${work.id}"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(work.title.ifEmpty { "The agent couldn’t finish." }, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.error)
            if (work.detail.isNotEmpty()) Text(work.detail, style = MaterialTheme.typography.bodyMedium)
            work.question?.let { question -> TextButton(onClick = { retry(question) }) { Text("Try Again") } }
        }
        "report" -> Card(Modifier.fillMaxWidth().testTag("chat.work.report.${work.id}")) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(work.title, style = MaterialTheme.typography.titleSmall)
                Text(work.detail, maxLines = 1, style = MaterialTheme.typography.bodyMedium)
                if (work.text.isNotEmpty()) {
                    TextButton(onClick = { expanded = !expanded }, modifier = Modifier.semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }) { Text(if (expanded) "Hide" else "Show Report") }
                    if (expanded) SelectionContainer { Text(work.text, style = MaterialTheme.typography.bodySmall) }
                }
            }
        }
        "subagents" -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            work.subagents.forEach { agent -> key(agent.id) { LiveAgentCard(agent) } }
        }
        // Read older durable snapshots without exposing their raw work data.
        "subagent" -> LiveAgentCard(ChatLiveAgent(work.id, work.words.ifEmpty { "Subagent" }))
    }
}

@Composable
private fun LiveAgentCard(agent: ChatLiveAgent) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val reduceMotion = LocalBrowserAccessibility.current.reduceMotion
    var now by remember(agent.id, agent.since) { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(agent.id, agent.since, lifecycle, reduceMotion) {
        if (agent.since != null && !reduceMotion) lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) { now = System.currentTimeMillis(); delay(1_000) }
        }
    }
    Card(Modifier.fillMaxWidth().testTag("chat.work.subagent.${agent.id}")) {
        Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.weight(1f)) {
                Text(agent.name, maxLines = 1, style = MaterialTheme.typography.titleSmall)
                Text("Working", style = MaterialTheme.typography.bodyMedium)
            }
            agent.since?.let { began ->
                val whole = ((now - began) / 1000).coerceAtLeast(0)
                Text("${whole / 60}:${(whole % 60).toString().padStart(2, '0')}", fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.labelMedium, modifier = Modifier.testTag("chat.work.clock.${agent.id}"))
            }
        }
    }
}

@Composable
fun ChatInfo(chat: AgentChat, close: () -> Unit, open: (String) -> Unit, copy: (String) -> Unit,
    project: dev.yab.core.sync.SyncProject? = null, projectCurrent: (() -> Boolean)? = null, projectSourceKey: Any? = null,
    onPin: (() -> Unit)? = null, onUnread: (() -> Unit)? = null, onArchive: (() -> Unit)? = null, onRename: (() -> Unit)? = null, onZoom: ((Float) -> Unit)? = null) {
    val density = LocalDensity.current
    val extendBars = LocalConfiguration.current.smallestScreenWidthDp < 600
    val statusTop = with(density) { WindowInsets.statusBars.getTop(this).toDp() }
    val contents = remember(chat.id, chat.messages) { ChatContents.read(chat) }
    val sourceCurrent = projectCurrent ?: { true }
    val reduced = LocalBrowserAccessibility.current.reduceMotion || !android.animation.ValueAnimator.areAnimatorsEnabled()
    val progress = remember(chat.id, projectSourceKey) { Animatable(if (reduced) 1f else 0f) }
    var closing by remember(chat.id, projectSourceKey) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var drag by remember(chat.id, projectSourceKey) { mutableFloatStateOf(0f) }
    var heroCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var heroDragging by remember(chat.id, projectSourceKey) { mutableStateOf(false) }
    val scroll = rememberScrollState()
    val current = { !closing && sourceCurrent() && progress.value >= .999f }
    var canvasHeight by remember { mutableFloatStateOf(1f) }
    val zoomCallback by rememberUpdatedState(onZoom)
    LaunchedEffect(progress, reduced) {
        snapshotFlow { progress.value * (1f - (drag / (canvasHeight * .5f).coerceAtLeast(1f)).coerceIn(0f, 1f)) }
            .collect { zoomCallback?.invoke(if (reduced) 0f else it) }
    }
    LaunchedEffect(progress, reduced) { if (reduced) progress.snapTo(1f) else progress.animateTo(1f, spring(dampingRatio = .86f, stiffness = 420f)) }
    fun dismiss() {
        if (closing || !sourceCurrent()) return
        closing = true
        scope.launch {
            if (!reduced) kotlinx.coroutines.coroutineScope {
                launch { progress.animateTo(0f, tween(300)) }
                launch { animate(drag, 0f, animationSpec = tween(300)) { value, _ -> drag = value } }
            }
            if (sourceCurrent()) close()
        }
    }
    var selected by remember(chat.id, projectSourceKey) { mutableStateOf("Sites") }
    var copied by remember(chat.id, projectSourceKey) { mutableStateOf(false) }
    var linkCopied by remember(chat.id, projectSourceKey) { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1800); copied = false } }
    LaunchedEffect(linkCopied) { if (linkCopied) { delay(1800); linkCopied = false } }
    val tabs = buildList {
        if (contents.sites.isNotEmpty()) add("Sites")
        if (contents.links.isNotEmpty()) add("Links")
        if (contents.media.isNotEmpty()) add("Media")
        if (contents.files.isNotEmpty()) add("Files")
    }
    val onDevice = chat.privateOrigin || chat.messages.lastOrNull { it.role == MessageRole.ASSISTANT }?.origin == AnswerOrigin.DEVICE
    val time = if (chat.updatedAt > 0) {
        val at = Instant.ofEpochMilli(chat.updatedAt).atZone(ZoneId.systemDefault())
        val today = java.time.LocalDate.now()
        when (at.toLocalDate()) {
            today -> "today at " + at.format(DateTimeFormatter.ofPattern("HH:mm"))
            today.minusDays(1) -> "yesterday at " + at.format(DateTimeFormatter.ofPattern("HH:mm"))
            else -> at.format(DateTimeFormatter.ofPattern("MMM d"))
        }
    } else null
    val infoLine = listOfNotNull(project?.name, if (onDevice) "On-device AI" else chat.owner?.provider?.displayName ?: "Yab", time).joinToString(" · ")
    val active = selected.takeIf { it in tabs } ?: tabs.firstOrNull()
    if (sourceCurrent()) {
        BackHandler { dismiss() }
        // Same-root cover: preserves the existing privacy curtain and project owner.
        ChatInfoCanvas(extendBars) {
        Box(Modifier.fillMaxSize().onSizeChanged { canvasHeight = it.height / density.density }) {
            Box(Modifier.matchParentSize().graphicsLayer { alpha = .15f * progress.value * (1f - (drag / (canvasHeight * .5f).coerceAtLeast(1f)).coerceIn(0f, 1f)) }
                .background(Color.Black).clickable(indication = null, interactionSource = remember { MutableInteractionSource() }) {})
        Surface(Modifier.fillMaxSize().graphicsLayer {
            val pose = ChatInfoZoom.pose(size.width / density.density, size.height / density.density,
                if (extendBars) statusTop.value + 6f else 6f, progress.value, drag, reduced)
            alpha = if (reduced) progress.value else (progress.value * 20f).coerceIn(0f, 1f)
            scaleX = pose.scale; scaleY = pose.scale
            translationY = pose.top * density.density
            transformOrigin = TransformOrigin(.5f, 0f)
            clip = true
            shape = ChatInfoClip(pose.visibleHeight / pose.scale * density.density, pose.corner * density.density)
        }.testTag("chat.info"), color = if (MaterialTheme.colorScheme.background.luminance() < .2f) Color.Black else Color(0xFFF2F2F4)) {
            Box(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize().verticalScroll(scroll).padding(horizontal = 16.dp).padding(top = if (extendBars) 115.dp else (115.dp - statusTop).coerceAtLeast(6.dp), bottom = 27.dp),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    ChatFace(104.dp, onDevice = chat.privateOrigin || chat.messages.firstOrNull { it.role == MessageRole.ASSISTANT }?.origin == AnswerOrigin.DEVICE)
                    Text(chat.title, Modifier.padding(top = 14.dp).testTag("chat.info.title"), fontSize = 22.sp, lineHeight = 27.sp, fontWeight = FontWeight.SemiBold)
                    Text(infoLine, Modifier.padding(top = 3.dp).testTag("chat.info.line"), fontSize = 15.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(Modifier.padding(top = 14.dp).background(chatFill(.12f), CircleShape)
                        .height(36.dp).padding(horizontal = 14.dp).testTag("chat.info.where"), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(if (onDevice) YabGlyphs.Phone else YabGlyphs.MacYabLaptop, null, Modifier.size(15.dp))
                        Text(if (onDevice) "on this device" else "on your Mac", fontSize = 14.sp, lineHeight = 17.sp, fontWeight = FontWeight.Medium)
                    }
                    Row(Modifier.fillMaxWidth().padding(top = 40.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                        onPin?.let { InfoAction(if (chat.pinned) "Unpin" else "Pin", if (chat.pinned) YabGlyphs.MacPinSlash else YabGlyphs.MacPin) { if (current()) it() } }
                        onUnread?.let { InfoAction(if (chat.unread) "Read" else "Unread", if (chat.unread) YabGlyphs.MacYabChat else YabGlyphs.MacYabChatDot) { if (current()) it() } }
                        onArchive?.let { InfoAction(if (chat.archived) "Unarchive" else "Archive", YabGlyphs.MacYabArchive) { if (current()) it() } }
                    }
                    if (chat.messages.any { it.role == MessageRole.ASSISTANT && it.text.isNotBlank() } || chat.page != null) Surface(Modifier.fillMaxWidth().padding(top = 38.dp), shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface) {
                        Column {
                            val answer = chat.messages.lastOrNull { it.role == MessageRole.ASSISTANT }?.text.orEmpty()
                            if (answer.isNotBlank()) InfoRow(if (copied) "Copied" else "Copy Answer", if (copied) YabGlyphs.Checkmark1 else YabGlyphs.MacYabCopyframeText) { if (current()) { copy(answer); copied = true } }
                            chat.page?.let { page ->
                                if (answer.isNotBlank()) HorizontalDivider(Modifier.padding(start = 56.dp, end = 16.dp), thickness = .5.dp)
                                InfoRow(page.title, YabGlyphs.Globe, value = runCatching { java.net.URI(page.url).host?.removePrefix("www.") }.getOrNull(), chevron = true, site = page.url) { if (current()) open(page.url) }
                                HorizontalDivider(Modifier.padding(start = 56.dp, end = 16.dp), thickness = .5.dp)
                                InfoRow(if (linkCopied) "Link Copied" else "Copy Page Link", if (linkCopied) YabGlyphs.Checkmark1 else YabGlyphs.Link) { if (current()) { copy(page.url); linkCopied = true } }
                            }
                        }
                    }
                    if (contents.steps > 0) Text("${contents.steps} steps", Modifier.padding(top = 16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                    if (tabs.isNotEmpty()) {
                        Row(Modifier.fillMaxWidth().padding(top = 38.dp, bottom = 12.dp)
                            .background(Color(0xFF767680).copy(alpha = .12f), RoundedCornerShape(9.dp)).padding(2.dp).testTag("chat.info.tabs")) {
                            tabs.forEach { tab ->
                                val chosen = tab == active
                                Surface(Modifier.weight(1f), shape = RoundedCornerShape(7.dp), color = if (chosen) MaterialTheme.colorScheme.surface else Color.Transparent,
                                    shadowElevation = if (chosen) 1.dp else 0.dp) {
                                    Box(Modifier.heightIn(min = 28.dp).clickable { if (current()) selected = tab }.padding(horizontal = 4.dp, vertical = 5.dp), contentAlignment = Alignment.Center) {
                                        Text(tab, fontSize = 13.sp, fontWeight = if (chosen) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1)
                                    }
                                }
                            }
                        }
                        Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface) {
                            Column(Modifier.fillMaxWidth()) {
                                when (active) {
                                    "Sites" -> contents.sites.forEachIndexed { index, site ->
                                        if (index > 0) HorizontalDivider(Modifier.padding(start = 62.dp), thickness = .5.dp)
                                        InfoLinkRow(site.host, "${site.visits} visits", site.url) { if (current()) open(site.url) }
                                    }
                                    "Links" -> contents.links.forEachIndexed { index, link ->
                                        if (index > 0) HorizontalDivider(Modifier.padding(start = 62.dp), thickness = .5.dp)
                                        InfoLinkRow(link.title, link.url.substringAfter("://"), link.url) { if (current()) open(link.url) }
                                    }
                                    "Media" -> contents.media.chunked(3).forEach { row ->
                                        Row(Modifier.fillMaxWidth().padding(bottom = 2.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                                            row.forEach { file -> Box(Modifier.weight(1f).aspectRatio(1f)) { ChatImage(file, Modifier.fillMaxSize(), crop = true) } }
                                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                                        }
                                    }
                                    "Files" -> contents.files.forEachIndexed { index, file ->
                                        if (index > 0) HorizontalDivider(Modifier.padding(start = 62.dp), thickness = .5.dp)
                                        val kind = file.name.substringAfterLast('.', file.mime.substringAfter('/')).uppercase()
                                        InfoLinkRow(file.name, "$kind · ${android.text.format.Formatter.formatShortFileSize(androidx.compose.ui.platform.LocalContext.current, file.size.toLong())}", null) {}
                                    }
                                }
                            }
                        }

                    }
                }
                // Only the noninteractive hero owns this downward pull. A scrolled Info
                // keeps its ordinary list input; an upward hero drag scrolls the same list.
                if (scroll.value == 0 || heroDragging) Box(Modifier.fillMaxWidth().height(350.dp).onGloballyPositioned { heroCoordinates = it }
                    .pointerInput(chat.id, projectSourceKey, reduced) {
                        val velocity = VelocityTracker()
                        var admitted = false
                        var scrolls = false
                        detectVerticalDragGestures(onDragStart = { position ->
                            admitted = current()
                            heroDragging = admitted
                            scrolls = scroll.value > 0
                            velocity.resetTracking()
                            velocity.addPosition(android.os.SystemClock.uptimeMillis(), heroCoordinates?.localToRoot(position) ?: position)
                        }, onVerticalDrag = { change, amount ->
                            if (admitted && current()) {
                                velocity.addPosition(change.uptimeMillis, heroCoordinates?.localToRoot(change.position) ?: change.position)
                                val follow = (drag / (canvasHeight * .5f).coerceAtLeast(1f)).coerceIn(0f, 1f)
                                val delta = amount * (if (reduced) 1f else 1f - .2f * follow) / density.density
                                if (scrolls || drag == 0f && delta < 0f) {
                                    scrolls = true
                                    scope.launch { if (current()) scroll.scrollBy(-amount) }
                                } else drag = (drag + delta).coerceAtLeast(0f)
                                change.consume()
                            }
                        }, onDragEnd = {
                            heroDragging = false
                            if (admitted && current() && !scrolls && (drag > 90f || velocity.calculateVelocity().y / density.density > 600f)) dismiss()
                            else scope.launch { animate(drag, 0f, animationSpec = spring(dampingRatio = 1f, stiffness = 420f)) { value, _ -> drag = value } }
                        }, onDragCancel = {
                            heroDragging = false
                            scope.launch { animate(drag, 0f, animationSpec = spring(dampingRatio = 1f, stiffness = 420f)) { value, _ -> drag = value } }
                        })
                    }.clearAndSetSemantics {})
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(top = if (extendBars) 58.dp else 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    ChatRoundButton("Back to chat", YabGlyphs.ChevronLeft, { dismiss() }, glass = true)
                    onRename?.let { ChatRoundButton("Rename Chat", YabGlyphs.MacPencil, { if (current()) it() }, glass = true) }
                }
            }
        }
            Box(Modifier.align(Alignment.TopCenter).padding(top = if (extendBars) statusTop + 6.dp else 6.dp).graphicsLayer {
                alpha = if (reduced) 0f else (1f - progress.value * 3f).coerceIn(0f, 1f)
            }.clearAndSetSemantics {}) {
                ChatFace(44.dp, onDevice = chat.privateOrigin || chat.messages.firstOrNull { it.role == MessageRole.ASSISTANT }?.origin == AnswerOrigin.DEVICE)
            }
        }
        }
    }
}

@Composable
private fun InfoAction(title: String, glyph: ImageVector, action: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Surface(Modifier.size(72.dp), shape = CircleShape, color = MaterialTheme.colorScheme.surface) {
            IconButton(onClick = action) { Icon(glyph, title, Modifier.size(24.dp)) }
        }
        Text(title, Modifier.padding(top = 10.dp), fontSize = 15.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun InfoRow(title: String, glyph: ImageVector, value: String? = null, chevron: Boolean = false, site: String? = null, action: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable(onClick = action).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        if (site != null) ChatSiteMark(site, 24.dp) else Icon(glyph, null, Modifier.size(24.dp))
        Text(title, Modifier.weight(1f).padding(start = 16.dp), fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        value?.let { Text(it, Modifier.padding(start = 8.dp), fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
        if (chevron) Icon(YabGlyphs.ChevronRight, null, Modifier.padding(start = 8.dp).size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun InfoLinkRow(title: String, detail: String, url: String?, action: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable(enabled = url != null, onClick = action).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        if (url != null) ChatSiteMark(url, 32.dp) else Icon(YabGlyphs.PageText, null, Modifier.size(32.dp).background(Color(0xFF767680).copy(alpha = .08f), RoundedCornerShape(8.dp)).padding(6.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (url != null) Icon(YabGlyphs.ChevronRight, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

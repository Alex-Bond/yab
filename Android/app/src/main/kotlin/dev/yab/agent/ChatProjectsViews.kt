package dev.yab.agent

import android.animation.ValueAnimator
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.core.sync.SyncProject
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.regex.Pattern

/** A rendered control never borrows the next publication or the next visible cover. */
internal class ProjectUiLifetime(private val original: () -> Boolean) {
    internal var retired = false
        private set
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!runCatching(original).getOrDefault(false)) { retired = true; return false }
        return true
    }
}

@Composable
fun ProjectCircle(project: SyncProject, size: Dp, modifier: Modifier = Modifier) {
    val dark = MaterialTheme.colorScheme.surface.luminanceForProject() < .5f
    val colors = when (project.tint) {
        "green" -> if (dark) listOf(0xFF2E5A3B, 0xFF1F4A2C) else listOf(0xFFCDEED6, 0xFF9FDCB1)
        "orange" -> if (dark) listOf(0xFF6A4320, 0xFF55331A) else listOf(0xFFFFD9A8, 0xFFFFB877)
        "purple" -> if (dark) listOf(0xFF463A70, 0xFF362B5C) else listOf(0xFFE4DCFF, 0xFFC3B4FF)
        "pink" -> if (dark) listOf(0xFF6A2F45, 0xFF562437) else listOf(0xFFFFD6E5, 0xFFFFB0CB)
        "yellow" -> if (dark) listOf(0xFF5E5220, 0xFF4A4018) else listOf(0xFFFFF0B3, 0xFFFFE07A)
        "teal" -> if (dark) listOf(0xFF1F5553, 0xFF174341) else listOf(0xFFC9F0EE, 0xFF94DDD9)
        "gray" -> if (dark) listOf(0xFF3A3A3C, 0xFF2C2C2E) else listOf(0xFFE8E8ED, 0xFFD1D1D6)
        else -> if (dark) listOf(0xFF2D3E6E, 0xFF22305A) else listOf(0xFFC9D8FF, 0xFF9DB6FF)
    }
    val symbol = project.emoji.ifEmpty { Pattern.compile("\\X").matcher(project.name).let { if (it.find()) it.group().uppercase() else "" } }
    Box(modifier.size(size).background(Brush.linearGradient(colors.map { Color(it) }), CircleShape)
        .clearAndSetSemantics { }, contentAlignment = Alignment.Center) {
        Text(symbol, fontSize = (size.value * .5f).sp, fontWeight = FontWeight.SemiBold)
    }
}
private fun Color.luminanceForProject(): Float = red * .2126f + green * .7152f + blue * .0722f

@Composable
fun ProjectPins(projects: List<SyncProject>, chats: List<AgentChat>, enabled: Boolean,
    current: () -> Boolean, open: (SyncProject) -> Unit) {
    Column(Modifier.fillMaxWidth().testTag("newtab.projects"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (row in projects.chunked(3)) Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (project in row) key(project.id) {
                val members = chats.filter { it.project == project.id }
                val working = members.any(FieldChatsPageModel::working)
                val peek = if (working) "Answering" else members.firstOrNull { it.unread }?.let { "${it.title} ${FieldChatsPageModel.preview(it)}" }
                Column(Modifier.weight(1f).padding(top = if (peek == null) 12.dp else 44.dp, bottom = 8.dp)
                    .clip(RoundedCornerShape(14.dp)).clickable(enabled = enabled) { if (current()) open(project) }
                    .semantics(mergeDescendants = true) { contentDescription = project.name; if (members.any { it.unread }) stateDescription = "unread" }
                    .testTag("newtab.project.${project.id}"), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box {
                        ProjectCircle(project, 72.dp)
                        if (members.any { it.unread }) Box(Modifier.align(Alignment.TopEnd).size(9.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
                        if (peek != null) Text(peek, Modifier.align(Alignment.TopCenter).offset(x = 12.dp, y = (-36).dp)
                            .widthIn(max = 132.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(14.dp))
                            .padding(horizontal = 10.dp, vertical = 5.dp).testTag("newtab.project.peek"), fontSize = 12.sp, maxLines = 2,
                            overflow = TextOverflow.Ellipsis)
                    }
                    Text(project.name, Modifier.padding(top = 7.dp), fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                }
            }
            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
        }
    }
}

@Composable
fun ProjectPageCard(project: SyncProject, chats: List<AgentChat>, modifier: Modifier, enabled: Boolean,
    current: () -> Boolean, open: () -> Unit) {
    Column(modifier.fillMaxWidth().heightIn(min = 150.dp).clip(RoundedCornerShape(22.dp))
        .background(MaterialTheme.colorScheme.surfaceContainerLow).clickable(enabled = enabled) { if (current()) open() }
        .padding(14.dp).testTag("newtab.project.${project.id}"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ProjectCircle(project, 38.dp)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(project.name, Modifier.weight(1f), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 2)
            if (chats.any { it.unread }) Box(Modifier.size(7.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
        }
        Text(chats.firstOrNull()?.let { "${it.title}: ${FieldChatsPageModel.preview(it)}" } ?: "No chats yet",
            fontSize = 13.sp, maxLines = 3, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(if (chats.any(FieldChatsPageModel::working)) "working" else if (chats.size == 1) "1 chat" else "${chats.size} chats",
            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Used inside each original chat's held menu, never a latest-chat lookup. */
@Composable
fun MoveToProjectMenu(repository: AgentRepository, chat: AgentChat, originalCurrent: () -> Boolean) {
    val snapshot by repository.projects.collectAsState()
    var actionRevision by remember(repository, chat.id) { mutableLongStateOf(0) }
    var busy by remember(repository, chat.id) { mutableStateOf(false) }
    val originalRevision = actionRevision
    key(snapshot.generation, chat.id, chat.owner, chat.project, originalRevision) {
        var expanded by remember { mutableStateOf(false) }
        val lifetime = remember { ProjectUiLifetime { actionRevision == originalRevision && originalCurrent() } }
        DisposableEffect(lifetime) { onDispose { lifetime.retire() } }
        val actions = rememberCoroutineScope()
        val targets = mutableListOf<Pair<String?, String>>().apply { addAll(snapshot.listed.map { it.id to it.name }) }
        if (snapshot.listed.any { it.id == chat.project }) targets += null to "Remove from Project"
        val leases = targets.associate { (id, _) -> id to repository.captureProjectMove(chat, id, lifetime::current) }
        if (repository.canMoveToProject(chat) && lifetime.current()) {
            DropdownMenuItem(text = { Text("Move to Project ›") }, onClick = { if (lifetime.current()) expanded = true })
            if (expanded && lifetime.current()) Column {
                for ((id, name) in targets) key(id) {
                    val lease = leases[id]
                    DropdownMenuItem(text = { Text(name) }, enabled = id != chat.project && lease != null,
                        onClick = { expanded = false; if (!busy && lifetime.current() && lease != null) {
                            busy = true
                            actions.launch { try { if (lifetime.current() && repository.moveToProject(lease)) actionRevision++ } finally { busy = false } }
                        } })
                }
            }
        }
    }
}

/** Root places this above its browser body and keeps the same RAM presentation at both entry points.
 * This is a same-window cover. It never obtains a new window, account or native session lease. */
@Composable
fun ChatProjectsCover(repository: AgentRepository, presentation: ChatProjectsPresentation,
    modifier: Modifier = Modifier, actionCurrent: (() -> Boolean)? = null, onOpenWebsite: ((String) -> Unit)? = null,
    approvals: ApprovalController? = null, authentication: ApprovalAuthentication? = null,
    localModels: LocalModelManager? = null) {
    val snapshot by repository.projects.collectAsState()
    val state by repository.state.collectAsState()
    val frame by presentation.frame.collectAsState()
    val draft by presentation.draft.collectAsState()
    val actions = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(snapshot, state.connection) { presentation.observe(snapshot, state.connection) }
    val original = frame ?: return
    if (!presentation.current(original, snapshot, state.connection)) return
    LaunchedEffect(original.owner) {
        if (presentation.current(original, repository.projects.value, repository.state.value.connection)) {
            focusManager.clearFocus(force = true); keyboard?.hide()
        }
    }
    val project = snapshot.project(original.project) ?: return
    val control = remember(original, snapshot, actionCurrent) { presentation.control(snapshot, { repository.state.value.connection },
        { repository.projects.value }, { actionCurrent?.invoke() == true }) } ?: return
    fun current() = control.current()
    val list = state.copy(privateContext = false).listed().filter { it.project == project.id }
    val canStart = repository.canStartInProject(project.id)
    val start = remember(control, canStart) { repository.captureProjectStart(project.id, ::current) }
    fun openChat(chat: AgentChat) {
        if (!current() || repository.state.value.copy(privateContext = false).listed().singleOrNull { it.id == chat.id } != chat) return
        repository.setPrivacy(false); repository.open(chat.id)
        repository.state.value.current?.takeIf { FieldChatsPageModel.sameOwner(it, chat) }?.let { presentation.conversation(control, it) }
    }
    fun newChat(send: Boolean) {
        if (!current() || start == null) return
        val words = if (send) presentation.draft.value.trim() else ""
        if (send && words.isEmpty()) return
        val id = repository.newChatInProject(start, initialDraft = words) ?: return
        val chat = repository.state.value.current?.takeIf { it.id == id } ?: return
        presentation.clearDraft(control)
        if (!presentation.conversation(control, chat)) return
        val nested = presentation.frame.value ?: return
        if (words.isNotEmpty()) actions.launch {
            val originalAction = ProjectUiLifetime { actionCurrent?.invoke() == true }
            fun owned() = originalAction.current() && presentation.conversationCurrent(nested, repository.state.value.current,
                repository.projects.value, repository.state.value.connection)
            if (owned()) repository.send(chatId = id, sourceCurrent = ::owned)
        }
    }
    fun backFromChat() {
        val chat = repository.state.value.current ?: return
        if (!current() || !presentation.conversationCurrent(original, chat, repository.projects.value, repository.state.value.connection)) return
        if (presentation.backFromChat(control)) {
            val live = repository.state.value.current
            if (actionCurrent?.invoke() == true && presentation.frame.value?.owner === original.owner &&
                presentation.frame.value?.conversation == null && live?.id == chat.id && live.owner == chat.owner &&
                live.privateOrigin == chat.privateOrigin) repository.back()
        }
    }
    BackHandler { when { original.conversation != null -> backFromChat()
        original.info -> presentation.info(control, false)
        else -> presentation.close(control) } }
    MaterialTheme(colorScheme = chatColorScheme(), shapes = chatShapes()) {
    ProjectMenuRoot(true, modifier) {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).testTag("project.page")) {
        // A lower sibling absorbs the uncovered root without consuming descendant gestures.
        Box(Modifier.matchParentSize().clickable(indication = null, interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }) { })
        Box(if (current()) Modifier.fillMaxSize() else Modifier.fillMaxSize().clearAndSetSemantics { }) {
        if (original.conversation != null) {
            val chat = state.current
            val chatSource = remember(original, snapshot, control) { { control.current() && repository.projects.value == snapshot && presentation.conversationCurrent(original, repository.state.value.current,
                repository.projects.value, repository.state.value.connection) } }
            if (presentation.conversationCurrent(original, chat, snapshot, state.connection) && chat != null) key(original, snapshot.generation, chat.id, chat.owner) { AgentScreen(repository, false, modifier = Modifier.fillMaxSize(),
                onOpenWebsite = onOpenWebsite?.let { open -> { url -> if (current() && presentation.close(control)) open(url) } }, approvals = approvals, authentication = authentication, localModels = localModels,
                collectInScreen = false, projectCurrent = chatSource, showApprovalPrompt = false,
                onProjectBack = ::backFromChat) }
        } else key(control) {
            if (original.info) {
                ProjectInfo(project, list.size, canStart, current = ::current,
                    close = { presentation.info(control, false) }, newChat = { presentation.info(control, false, focus = true) })
            } else {
                Column(Modifier.fillMaxSize().imePadding()) {
                    Box(Modifier.fillMaxWidth().padding(top = 6.dp, bottom = 10.dp)) {
                        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                            ChatRoundButton("Back to Chats", dev.yab.browser.ui.YabGlyphs.ChevronLeft,
                                { if (current()) presentation.close(control) }, buttonTag = "project.back", glass = true)
                            if (canStart) ChatRoundButton("New Chat", dev.yab.browser.ui.YabGlyphs.MacSquareAndPencil,
                                { if (current()) newChat(false) }, buttonTag = "project.new", glass = true)
                        }
                        Column(Modifier.align(Alignment.TopCenter).widthIn(max = 220.dp).clickable { if (current()) presentation.info(control, true) }
                            .testTag("project.title"), horizontalAlignment = Alignment.CenterHorizontally) {
                            ProjectCircle(project, 56.dp)
                            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(project.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                                Icon(dev.yab.browser.ui.YabGlyphs.ChevronRight, null, Modifier.size(11.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    LazyColumn(Modifier.weight(1f)) {
                        items(list, key = { it.id }) { chat ->
                            var actionRevision by remember(original.owner, chat.id) { mutableLongStateOf(0) }
                            var busy by remember(original.owner, chat.id) { mutableStateOf(false) }
                            val originalRevision = actionRevision
                            key(control, chat.id, chat.owner, chat.project, originalRevision) {
                                fun rowCurrent() = !busy && actionRevision == originalRevision && current() &&
                                    repository.state.value.copy(privateContext = false).listed().singleOrNull { it.id == chat.id } == chat
                                fun rowSource(): Boolean = current() && repository.state.value.chats.singleOrNull { it.id == chat.id }?.let {
                                    it.owner == chat.owner && !it.privateOrigin && it.project == chat.project
                                } == true
                                fun mutation(block: suspend (ChatMutationLease) -> Unit) {
                                    if (!rowCurrent()) return
                                    busy = true
                                    actions.launch { try { if (rowSource()) block(ChatMutationLease(chat, original.owner.account,
                                        original.owner.device, original.owner.epoch, ::rowSource)) }
                                        finally { actionRevision++; busy = false } }
                                }
                                ProjectChatRow(repository, chat, ::rowCurrent, ::rowSource, open = { openChat(chat) }, copy = {
                                    if (rowCurrent()) FieldChatsPageModel.answer(chat)?.text?.let { clipboard.setText(AnnotatedString(it)) }
                                }, pin = { mutation { repository.pin(chat.id, expected = it) } },
                                    unread = { mutation { repository.markUnread(chat.id, !chat.unread, expected = it) } },
                                    archive = { mutation { repository.archive(chat.id, expected = it) } })
                            }
                        }
                        if (list.isEmpty()) item { Text(if (canStart) "No chats yet. Ask something below." else "No chats yet.",
                            Modifier.fillMaxWidth().padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                    if (canStart) {
                        val focus = remember(original.owner) { FocusRequester() }
                        LaunchedEffect(original.focus) { if (original.focus > 0) {
                            if (ValueAnimator.areAnimatorsEnabled()) delay(500)
                            if (current()) focus.requestFocus()
                        } }
                        ConversationComposer(draft, { words -> if (current()) {
                            if (words.endsWith("\n")) { presentation.draft(control, words.dropLast(1)); newChat(true) }
                            else presentation.draft(control, words)
                        } }, { if (current()) newChat(true) }, true, focus,
                            placeholder = "New chat in ${project.name}", editorTag = "project.field", sendTag = "project.send",
                            glass = true, horizontalInset = 16.dp, bottomInset = 8.dp)
                    }
                }
            }
        }
        }
        if (!current()) Box(Modifier.matchParentSize().clickable(indication = null,
            interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }) { }.clearAndSetSemantics { })
    }
    }
}

}

@Composable
private fun ProjectInfo(project: SyncProject, count: Int, canStart: Boolean, current: () -> Boolean, close: () -> Unit, newChat: () -> Unit) {
    val status = with(androidx.compose.ui.platform.LocalDensity.current) { WindowInsets.statusBars.getTop(this).toDp() }
    Box(Modifier.fillMaxSize().background(if (MaterialTheme.colorScheme.background.luminanceForProject() < .2f) Color.Black else Color(0xFFF2F2F4)).testTag("project.info")) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp,
            top = (129.dp - status).coerceAtLeast(6.dp), bottom = 27.dp)) {
            item { Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                ProjectCircle(project, 104.dp)
                Text(project.name, Modifier.padding(top = 14.dp).testTag("project.info.title"), fontSize = 22.sp, lineHeight = 27.sp, fontWeight = FontWeight.SemiBold)
                Text(if (count == 1) "1 chat" else "$count chats", Modifier.padding(top = 3.dp), fontSize = 15.sp, lineHeight = 18.sp, color = chatGray(.6f))
                if (canStart) Column(Modifier.padding(top = 28.dp).clickable { if (current()) newChat() }
                    .testTag("project.info.new"), horizontalAlignment = Alignment.CenterHorizontally) {
                    Surface(Modifier.size(72.dp), shape = CircleShape, color = MaterialTheme.colorScheme.surface) {
                        Box(contentAlignment = Alignment.Center) { Icon(dev.yab.browser.ui.YabGlyphs.MacSquareAndPencil, null, Modifier.size(24.dp)) }
                    }
                    Text("New Chat", Modifier.padding(top = 10.dp), fontSize = 15.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold)
                }
            } }
            item { Text("INSTRUCTIONS", Modifier.padding(start = 16.dp, top = 28.dp, bottom = 8.dp).semantics { heading() }, fontSize = 13.sp, lineHeight = 16.sp, color = chatGray(.6f)) }
            item { Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface) { SelectionContainer { Text(project.instructions.ifEmpty { "None" },
                Modifier.fillMaxWidth().padding(16.dp).testTag("project.info.instructions"), fontSize = 17.sp, lineHeight = 20.3.sp) } } }
            item { Text("MEMORY", Modifier.padding(start = 16.dp, top = 28.dp, bottom = 8.dp).semantics { heading() }, fontSize = 13.sp, lineHeight = 16.sp, color = chatGray(.6f)) }
            item { Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface) { Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).padding(horizontal = 16.dp).testTag("project.info.memory"), verticalAlignment = Alignment.CenterVertically) {
                Icon(dev.yab.browser.ui.YabGlyphs.MacYabBookopen, null, Modifier.padding(end = 16.dp).size(24.dp))
                Text("Remember from These Chats", Modifier.weight(1f), fontSize = 17.sp)
                Text(if (project.memoryOn) "On" else "Off", fontSize = 17.sp, color = chatGray(.6f))
            } } }
            item { Text("Instructions and memory are edited on your Mac.", Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                fontSize = 13.sp, lineHeight = 16.sp, color = chatGray(.6f)) }
        }
        ChatRoundButton("Back to Project", dev.yab.browser.ui.YabGlyphs.ChevronLeft, { if (current()) close() },
            Modifier.padding(horizontal = 12.dp, vertical = 22.dp), buttonTag = "project.info.back", glass = true)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProjectChatRow(repository: AgentRepository, chat: AgentChat, current: () -> Boolean, sourceCurrent: () -> Boolean, open: () -> Unit,
    copy: () -> Unit, pin: () -> Unit, unread: () -> Unit, archive: () -> Unit) {
    var phase by remember { mutableLongStateOf(0) }
    val originalPhase = phase
    var menu by remember { ProjectLocalState(false) { phase++ } }
    var swiped by remember { mutableStateOf(false) }
    fun owns() = current() && phase == originalPhase
    val threshold = LocalViewConfiguration.current.touchSlop * 3
    var rowWidth by remember { mutableIntStateOf(0) }
    Row(Modifier.fillMaxWidth().heightIn(min = 74.dp).onSizeChanged { rowWidth = it.width }
        .pointerInput(chat.id, chat.owner, chat.project, rowWidth, originalPhase) {
        var distance = 0f
        detectHorizontalDragGestures(onDragStart = { distance = 0f }, onHorizontalDrag = { change, amount ->
            if (owns()) { distance += amount; change.consume() }
        }, onDragEnd = { if (owns() && distance < -threshold) {
            if (rowWidth > 0 && distance < -rowWidth * .6f && !FieldChatsPageModel.working(chat)) archive()
            else swiped = true
        } })
    }.combinedClickable(onClick = { if (owns()) open() }, onLongClick = { if (owns()) menu = true })
        .padding(start = 6.dp, end = 16.dp, top = 10.dp, bottom = 10.dp).testTag("project.chat.${chat.id}"), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(10.dp), contentAlignment = Alignment.Center) {
            if (chat.unread) Box(Modifier.size(9.dp).background(ChatVisuals.blue, CircleShape))
        }
        ChatRowMark(chat, 44.dp, Modifier.padding(horizontal = 10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) { Text(chat.title, Modifier.weight(1f), fontSize = 17.sp, lineHeight = 20.3.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                Text(FieldChatsPageModel.status(chat, emptyMap(), System.currentTimeMillis()), fontSize = 15.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Icon(dev.yab.browser.ui.YabGlyphs.ChevronRight, null, Modifier.padding(start = 6.dp).size(11.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant) }
            Text(FieldChatsPageModel.preview(chat), maxLines = 2, fontSize = 15.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        ProjectDropdownMenu(menu && owns(), { if (owns()) menu = false }, owned = true, current = ::owns, sourceKey = originalPhase) {
            DropdownMenuItem(text = { Text("Open Chat") }, onClick = { if (owns()) { menu = false; open() } })
            if (FieldChatsPageModel.answer(chat) != null) DropdownMenuItem(text = { Text("Copy Answer") }, onClick = { if (owns()) { menu = false; copy() } })
            DropdownMenuItem(text = { Text(if (chat.pinned) "Unpin Chat" else "Pin Chat") }, onClick = { if (owns()) { menu = false; pin() } })
            DropdownMenuItem(text = { Text(if (chat.unread) "Mark as Read" else "Mark as Unread") }, onClick = { if (owns()) { menu = false; unread() } })
            MoveToProjectMenu(repository, chat) { owns() && sourceCurrent() }
            DropdownMenuItem(text = { Text("Archive Chat") }, enabled = !FieldChatsPageModel.working(chat), onClick = { if (owns()) { menu = false; archive() } })
        }
    }
    if (swiped && owns()) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
        if (repository.canMoveToProject(chat)) { var move by remember { ProjectLocalState(false) { phase++ } }
            ProjectSwipeAction("Project", dev.yab.browser.ui.YabGlyphs.Folder1, MaterialTheme.colorScheme.secondary) { if (owns()) move = true }
            ProjectDropdownMenu(move && owns(), { if (owns()) move = false }, owned = true, current = ::owns, sourceKey = originalPhase) { MoveToProjectMenu(repository, chat) { owns() && sourceCurrent() } }
        }
        ProjectSwipeAction(if (chat.pinned) "Unpin" else "Pin", dev.yab.browser.ui.YabGlyphs.MacPin, Color(0xFFFF9F0A)) { if (owns()) { pin(); swiped = false } }
        if (!FieldChatsPageModel.working(chat)) ProjectSwipeAction("Archive", dev.yab.browser.ui.YabGlyphs.MacYabArchive, Color(0xFF8E8E93)) { if (owns()) { archive(); swiped = false } }
    }
    HorizontalDivider(Modifier.padding(start = 80.dp, end = 16.dp),
        color = if (MaterialTheme.colorScheme.background.luminanceForProject() < .2f) MaterialTheme.colorScheme.outlineVariant else Color(0xFFE3E3E6))
}

@Composable
fun ChatProjectPill(repository: AgentRepository, chat: AgentChat, current: () -> Boolean, sourceKey: Any? = null,
    onAccepted: () -> Unit = {}) {
    val snapshot by repository.projects.collectAsState()
    val project = snapshot.listed.singleOrNull { it.id == chat.project } ?: return
    if (!chat.ephemeral || chat.owner != null || chat.messages.isNotEmpty() || !repository.canStartInProject()) return
    var actionRevision by remember(repository, chat.id) { mutableLongStateOf(0) }
    var busy by remember(repository, chat.id) { mutableStateOf(false) }
    var menu by remember(repository, chat.id) { ProjectLocalState(false) { actionRevision++; onAccepted() } }
    val originalRevision = actionRevision
    key(chat.id, chat.project, snapshot.generation, originalRevision, sourceKey) {
        val original = remember { ProjectUiLifetime { actionRevision == originalRevision && current() } }
        DisposableEffect(original) { onDispose { original.retire() } }
        val actions = rememberCoroutineScope()
        val choices = snapshot.listed.map { it.id to it.name } + (null to "No Project")
        val leases = choices.associate { (id, _) -> id to repository.captureDraftProject(chat, id, original::current) }
        Box {
            TextButton(onClick = { if (original.current()) menu = true }, modifier = Modifier.testTag("chat.projectPill")) {
                ProjectCircle(project, 20.dp); Text(project.name, Modifier.padding(start = 6.dp), fontSize = 13.sp)
            }
            ProjectDropdownMenu(menu && original.current(), { if (original.current()) menu = false },
                owned = true, current = original::current, sourceKey = listOf(originalRevision, sourceKey)) {
                for ((id, name) in choices) { val lease = leases[id]
                    DropdownMenuItem(text = { Text(name) }, enabled = id != chat.project && lease != null,
                        onClick = { if (!busy && lease != null && original.current()) {
                            busy = true
                            actions.launch { try { if (original.current() && repository.setDraftProject(lease)) { menu = false; actionRevision++; onAccepted() } } finally { busy = false } }
                        } })
                }
            }
        }
    }
}


@Composable
private fun ProjectSwipeAction(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, fill: Color, action: () -> Unit) {
    Surface(shape = RoundedCornerShape(22.dp), color = fill) {
        Column(Modifier.widthIn(min = 66.dp).clickable(onClick = action).padding(horizontal = 12.dp, vertical = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, null, Modifier.size(22.dp), tint = Color.White)
            Text(title, Modifier.padding(top = 4.dp), color = Color.White, fontSize = 12.sp)
        }
    }
}

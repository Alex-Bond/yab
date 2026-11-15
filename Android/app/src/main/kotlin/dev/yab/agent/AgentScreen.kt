package dev.yab.agent

import java.util.concurrent.atomic.AtomicBoolean
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import dev.yab.browser.ui.YabGlyphs
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Icon
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.FlowPreview

@OptIn(FlowPreview::class, ExperimentalFoundationApi::class)
@Composable
fun AgentScreen(
    repository: AgentRepository,
    privateContext: Boolean,
    page: PageContext? = null,
    modifier: Modifier = Modifier,
    onOpenWebsite: ((String) -> Unit)? = null,
    approvals: ApprovalController? = null,
    authentication: ApprovalAuthentication? = null,
    localModels: LocalModelManager? = null,
    initialConversationId: String? = null,
    onOpenTasks: (() -> Unit)? = null,
    onPark: (() -> Unit)? = null,
    onSend: ((String, ModelSelection) -> Unit)? = null,
    onRetry: ((String, String) -> Unit)? = null,
    collectInScreen: Boolean = true,
    newChatIdeas: (@Composable () -> Unit)? = null,
    onSelectMac: ((String?) -> Unit)? = null,
    projectCurrent: (() -> Boolean)? = null, onProjectBack: (() -> Unit)? = null,
    showApprovalPrompt: Boolean = true,
) {
    val repositoryState by repository.state.collectAsState()
    val renderedProjects by repository.projects.collectAsState()
    // Privacy is a rendering boundary, including the frame before LaunchedEffect runs.
    val state = repositoryState.copy(privateContext = privateContext,
        activeChat = repositoryState.activeChat.takeIf { id -> repositoryState.chats.any { it.id == id && it.privateOrigin == privateContext } },
        error = repositoryState.error.takeIf { repositoryState.privateContext == privateContext })
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val uris = LocalUriHandler.current
    val clipboard = LocalClipboardManager.current
    val reader = remember(context) { AndroidAttachmentReader(context) }
    var projectPhase by remember(repository, privateContext, projectCurrent) { mutableLongStateOf(0) }
    val originalPhase = projectPhase
    fun phaseChanged() { if (projectCurrent != null) projectPhase++ }
    var query by remember(repository, privateContext, projectCurrent) { ProjectLocalState("", ::phaseChanged) }
    var archived by remember(repository, privateContext, projectCurrent) { ProjectLocalState(false, ::phaseChanged) }
    var settings by remember(repository, privateContext, projectCurrent) { ProjectLocalState(false, ::phaseChanged) }
    var rename by remember(repository, privateContext, projectCurrent) { ProjectLocalState<AgentChat?>(null, ::phaseChanged) }
    var renameText by remember(repository, privateContext) { mutableStateOf("") }
    var deleting by remember(repository, privateContext, projectCurrent) { ProjectLocalState<AgentChat?>(null, ::phaseChanged) }
    var attachmentOwner by remember(repository, privateContext) { mutableStateOf<AttachmentLease?>(null) }
    var infoZoom by remember(repository, privateContext) { mutableFloatStateOf(0f) }
    var info by remember(repository, privateContext, projectCurrent) { ProjectLocalState<String?>(null, ::phaseChanged) }
    var translatedMessage by remember(repository, privateContext, state.connection.account, projectCurrent) { ProjectLocalState<Pair<String, String>?>(null, ::phaseChanged) }
    var initialConversationOpened by remember(initialConversationId) { mutableStateOf(false) }
    LaunchedEffect(info) { if (info == null) infoZoom = 0f }
    val rendered = state.current
    val lease = remember(repository, rendered?.id, rendered?.owner, privateContext, state.connection.account, state.connection.epoch) { AtomicBoolean(true) }
    DisposableEffect(lease) { onDispose { lease.set(false) } }
    val originalProjectSource = projectCurrent
    fun projectBaseCurrent(): Boolean {
        if (originalProjectSource == null) return true
        val current = repository.state.value.current
        return lease.get() && runCatching(originalProjectSource).getOrDefault(false) &&
            (if (rendered == null) current == null else current?.id == rendered.id &&
                current.owner == rendered.owner && current.privateOrigin == rendered.privateOrigin && current.project == rendered.project) &&
            repository.projects.value == renderedProjects
    }
    val projectMenuKey = listOf(originalPhase, renderedProjects.generation, rendered?.id, rendered?.owner)
    fun projectAllowed() = projectBaseCurrent() && (originalProjectSource == null || projectPhase == originalPhase)
    fun projectMutation(chat: AgentChat): ChatMutationLease? = if (originalProjectSource == null) null else
        ChatMutationLease(chat, state.connection.account, renderedProjects.device, state.connection.epoch, ::projectBaseCurrent)
    fun back() { if (projectAllowed()) { if (onProjectBack != null) onProjectBack() else repository.back() } }
    val openWebsite: (String) -> Unit = { url ->
        val current = repository.state.value.current
        if (projectAllowed() && lease.get() && rendered != null && current?.id == rendered.id && current.owner == rendered.owner && current.privateOrigin == privateContext && AgentMarkdown.safeUrl(url)) {
            if (onOpenWebsite != null) onOpenWebsite(url)
            else try { uris.openUri(url) } catch (_: Exception) { repository.showError("This link could not be opened") }
        }
    }
    LaunchedEffect(repository, collectInScreen) { if (collectInScreen) repository.run() }
    LaunchedEffect(privateContext) { if (projectAllowed()) repository.setPrivacy(privateContext) }
    LaunchedEffect(initialConversationId, state.chats, state.connection.account, projectCurrent) {
        if (projectAllowed() && !initialConversationOpened && initialConversationId != null) initialConversationOpened = repository.focusConversation(initialConversationId)
    }
    BackHandler(enabled = state.current != null) { back() }
    fun attachFrom(urisToRead: List<android.net.Uri>, photo: Boolean) {
        val owner = attachmentOwner ?: return
        attachmentOwner = null
        if (!projectAllowed() || repository.attachmentLease(owner.chat) != owner) return
        scope.launch { if (projectBaseCurrent()) {
            try { val selected = urisToRead.map { reader.read(it, photo) }; if (projectAllowed()) repository.attach(owner.chat, selected, owner) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { if (projectAllowed() && repository.attachmentLease(owner.chat) == owner) repository.showError(error.message ?: "The attachment could not be read") }
         } }
    }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { attachFrom(it, false) }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { attachFrom(it, true) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicturePreview()) { bitmap ->
        val owner = attachmentOwner
        attachmentOwner = null
        if (projectAllowed() && bitmap != null && owner != null && repository.attachmentLease(owner.chat) == owner) scope.launch { if (projectBaseCurrent()) {
            try { repository.attach(owner.chat, listOf(reader.photo(bitmap)), owner) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { if (projectAllowed() && repository.attachmentLease(owner.chat) == owner) repository.showError(error.message ?: "The photo could not be attached") }
         } }
    }
    val modelPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null && localModels != null) scope.launch { if (projectBaseCurrent()) { localModels.import(uri)  } }
    }

    val darkChat = MaterialTheme.colorScheme.background.luminance() < .2f
    val chatColors = chatColorScheme()
    MaterialTheme(colorScheme = chatColors, shapes = chatShapes(), typography = MaterialTheme.typography.copy(
        bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 17.sp, lineHeight = 22.sp))) {
    ProjectMenuRoot(originalProjectSource != null, modifier) {
    Column(Modifier.fillMaxSize().graphicsLayer {
        val amount = if (info == null) 0f else infoZoom
        scaleX = 1f - .06f * amount; scaleY = scaleX
    }.then(if (info != null) Modifier.clearAndSetSemantics {} else Modifier).background(MaterialTheme.colorScheme.background).imePadding()) {
        if (state.privateContext) Text("Private · conversations stay on this device", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(16.dp))
        val chat = state.current
        if (chat == null) {
            val listSource = remember(repository, privateContext, query, archived, state.connection.account, state.connection.epoch, projectCurrent) { Any() }
            val listLifetime = remember(listSource) { AtomicBoolean(true) }
            DisposableEffect(listLifetime) { onDispose { listLifetime.set(false) } }
            fun rowCurrent(row: AgentChat) = listLifetime.get() && projectAllowed() && lease.get() &&
                repository.state.value.copy(privateContext = privateContext).listed(query, archived).singleOrNull { it.id == row.id } == row
            fun allowed(row: AgentChat, action: FieldChatAction): Boolean = rowCurrent(row) && when (action) {
                FieldChatAction.COPY_ANSWER -> !FieldChatsPageModel.answer(row)?.text.isNullOrBlank()
                FieldChatAction.PIN -> !row.pinned
                FieldChatAction.UNPIN -> row.pinned
                FieldChatAction.MARK_READ -> row.unread
                FieldChatAction.MARK_UNREAD -> !row.unread
                FieldChatAction.RENAME -> true
                FieldChatAction.ARCHIVE -> !row.archived && !FieldChatsPageModel.working(row)
                FieldChatAction.UNARCHIVE -> row.archived && !FieldChatsPageModel.working(row)
                FieldChatAction.ARCHIVE_OLDER -> !archived
                FieldChatAction.STOP -> row.delivery == DeliveryState.ANSWERING && row.owner?.let { owner ->
                    state.connection.macs.any { it.id == owner.mac && it.controlsChats && owner.account == state.connection.account } } == true
                FieldChatAction.DELETE -> false
            }
            FieldChatsPage(state.listed(query, archived), query, archived, listSource, true, ::projectAllowed,
                onSelect = { row -> if (rowCurrent(row)) {
                    repository.open(row.id)
                    scope.launch { if (projectBaseCurrent()) repository.markUnread(row.id, false, expected = projectMutation(row)) }
                } }, onNewChat = { if (projectAllowed()) repository.newChat(page, ephemeral = page != null) },
                onArchive = { if (projectAllowed()) archived = it }, canAct = ::allowed,
                onAction = { command -> if (command.sourceKey === listSource && allowed(command.chat, command.action)) scope.launch {
                    val row = command.chat
                    if (command.sourceKey !== listSource || !allowed(row, command.action)) return@launch
                    val expected = projectMutation(row)
                    when (command.action) {
                        FieldChatAction.COPY_ANSWER -> FieldChatsPageModel.answer(row)?.text?.let { clipboard.setText(AnnotatedString(it)) }
                        FieldChatAction.PIN, FieldChatAction.UNPIN -> repository.pin(row.id, expected = expected)
                        FieldChatAction.MARK_READ, FieldChatAction.MARK_UNREAD -> repository.markUnread(row.id, command.action == FieldChatAction.MARK_UNREAD, expected = expected)
                        FieldChatAction.RENAME -> command.title?.let { repository.rename(row.id, it, expected = expected) }
                        FieldChatAction.ARCHIVE, FieldChatAction.UNARCHIVE -> repository.archive(row.id, expected = expected)
                        FieldChatAction.ARCHIVE_OLDER -> for (older in command.older) {
                            if (!projectBaseCurrent() || !allowed(older, FieldChatAction.ARCHIVE)) break
                            repository.archive(older.id, expected = projectMutation(older))
                        }
                        FieldChatAction.STOP -> repository.stop(row.id, expected = expected)
                        FieldChatAction.DELETE -> Unit
                    }
                } }, deleteQuestion = { FieldChatDeleteQuestion("Archive Chat") },
                modifier = Modifier.weight(1f), showArchiveControl = false,
                macNames = state.connection.macs.associate { it.id to it.name })
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                ChatRoundButton(if (archived) "Chats" else "Archive", YabGlyphs.MacYabArchive, { if (projectAllowed()) archived = !archived })
                ChatSearchField(query, { if (projectAllowed()) query = it }, Modifier.weight(1f).padding(horizontal = 8.dp))
                var listMenu by remember(listSource) { mutableStateOf(false) }
                Column {
                    ChatRoundButton("Chat options", YabGlyphs.DotGrid1x3Horizontal, { if (projectAllowed()) listMenu = true })
                    ProjectDropdownMenu(listMenu, { listMenu = false }, owned = originalProjectSource != null, current = ::projectAllowed, sourceKey = listSource) {
                        DropdownMenuItem(text = { Text("AI settings") }, onClick = { if (projectAllowed()) { listMenu = false; settings = true } })
                        onOpenTasks?.takeUnless { state.privateContext }?.let { action ->
                            DropdownMenuItem(text = { Text("Read-only tasks on Mac") }, onClick = { if (projectAllowed()) { listMenu = false; action() } })
                        }
                    }
                }
            }
            Spacer(Modifier.size(16.dp))
        } else {
            var menu by remember(chat.id, projectCurrent) { ProjectLocalState(false, ::phaseChanged) }
            var chooseModel by remember(chat.id, projectCurrent) { ProjectLocalState(false, ::phaseChanged) }
            val pending = chat.pendingSend?.takeIf { it.account == state.connection.account && it.epoch == state.connection.epoch }
            val provider = chat.owner?.provider ?: pending?.takeIf { it.state in setOf(MacSendState.WAITING, MacSendState.PROCESSING, MacSendState.TAKEN) }?.provider ?: state.preferences.provider
            val mac = if (pending?.state in setOf(MacSendState.WAITING, MacSendState.PROCESSING)) state.connection.macs.firstOrNull { it.id == pending?.mac }
                else if (chat.owner != null) state.connection.macs.firstOrNull { it.id == chat.owner.mac && chat.owner.account == state.connection.account }
                else state.connection.route(provider)
            val statusTarget = MacRouting.chatTarget(chat, state.connection, state.preferences.provider)
            var waitNow by remember(pending?.id) { mutableStateOf(System.currentTimeMillis()) }
            LaunchedEffect(pending?.id, pending?.state) {
                while (pending?.state == MacSendState.WAITING) { waitNow = System.currentTimeMillis(); delay(30_000) }
            }
            val deviceAnswer = chat.privateOrigin || pending == null && chat.owner == null && !chat.forceMac && (chat.page != null || chat.ephemeral) && state.preferences.pageAnswers == PageAnswerMode.DEVICE
            val terminalOwnerless = chat.owner == null && pending?.state in setOf(MacSendState.EXPIRED, MacSendState.FAILED)
            val nextOnDevice = terminalOwnerless && !chat.forceMac && (chat.page != null || chat.ephemeral) && state.preferences.pageAnswers == PageAnswerMode.DEVICE && state.attachments[chat.id].isNullOrEmpty()
            var selection by remember(chat.id, mac?.id, provider) { mutableStateOf(ModelSelection()) }
            val models = if (deviceAnswer || nextOnDevice) emptyList() else mac?.models.orEmpty().filter { it.provider == provider }
            var chooseMac by remember(chat.id, state.connection.account, projectCurrent) { ProjectLocalState(false, ::phaseChanged) }
            val chatProject = renderedProjects.listed.singleOrNull { it.id == chat.project }
            val avatarOnDevice = chat.privateOrigin || chat.messages.firstOrNull { it.role == MessageRole.ASSISTANT }?.origin == AnswerOrigin.DEVICE
            val projectFace: (@Composable () -> Unit)? = if (chatProject == null) null else ({
                androidx.compose.foundation.layout.Box {
                    ChatFace(44.dp, onDevice = avatarOnDevice)
                    ProjectCircle(chatProject, 22.dp, Modifier.align(Alignment.TopEnd).offset(x = 9.dp, y = (-5).dp))
                }
            })
            ConversationHeader(if (chat.title == "New chat") "New Chat" else chat.title, state.chats.count { it.unread && it.id != chat.id && !it.archived },
                onBack = { if (projectAllowed()) back() }, onInfo = { if (projectAllowed()) info = chat.id }, onDevice = avatarOnDevice, face = projectFace) {
                Column {
                    ChatRoundButton("More", YabGlyphs.DotGrid1x3Horizontal, { if (projectAllowed()) menu = true })
                    ProjectDropdownMenu(expanded = menu, onDismissRequest = { if (projectAllowed()) { menu = false  } }, owned = originalProjectSource != null, current = ::projectAllowed, sourceKey = projectMenuKey) {
                        ChatMenuItem(title = if (chat.pinned) "Unpin Chat" else "Pin Chat", icon = if (chat.pinned) YabGlyphs.MacPinSlash else YabGlyphs.MacPin, onClick = { if (projectAllowed()) { menu = false; scope.launch { if (projectBaseCurrent()) { repository.pin(chat.id, expected = projectMutation(chat))  } }  } })
                        ChatMenuItem(title = "Rename Chat", icon = YabGlyphs.MacPencil, onClick = { if (projectAllowed()) { menu = false; rename = chat; renameText = chat.title  } })
                        ChatMenuItem(title = if (chat.unread) "Mark as Read" else "Mark as Unread", icon = if (chat.unread) YabGlyphs.MacYabChat else YabGlyphs.MacYabChatDot, onClick = { if (projectAllowed()) { menu = false; scope.launch { if (projectBaseCurrent()) { repository.markUnread(chat.id, !chat.unread, expected = projectMutation(chat))  } }  } })
                        ChatMenuItem(title = "Copy Answer", icon = YabGlyphs.MacYabCopyframeText, onClick = { if (projectAllowed()) { menu = false; clipboard.setText(AnnotatedString(chat.messages.lastOrNull { it.role == MessageRole.ASSISTANT }?.text.orEmpty()))  } })
                        if (originalProjectSource != null) MoveToProjectMenu(repository, chat, ::projectAllowed)
                        onPark?.let { park -> ChatMenuItem(title = "Hide Chat", icon = YabGlyphs.MacYabArchive, onClick = { if (projectAllowed()) { menu = false; park() } }) }
                        if (!chat.privateOrigin && models.isNotEmpty()) DropdownMenuItem(text = { Text("Model and reasoning") },
                            onClick = { if (projectAllowed()) { menu = false; chooseModel = true } })
                        ChatMenuItem(title = if (chat.archived) "Unarchive Chat" else "Archive Chat", icon = YabGlyphs.MacYabArchive, onClick = { if (projectAllowed()) { menu = false; scope.launch { if (projectBaseCurrent()) { repository.archive(chat.id, expected = projectMutation(chat)); if (projectAllowed()) back()  } }  } })
                        ChatMenuItem(title = "Chat Info", icon = YabGlyphs.MacInfoCircle, onClick = { if (projectAllowed()) { menu = false; info = chat.id  } })
                        if (chat.owner != null && mac?.controlsChats == true && chat.delivery == DeliveryState.ANSWERING) DropdownMenuItem(text = { Text("Stop on Mac") }, onClick = { if (projectAllowed()) { menu = false; scope.launch { if (projectBaseCurrent()) { repository.stop(chat.id, expected = projectMutation(chat))  } }  } })
                    }
                }
            }
            if (!deviceAnswer && mac != null && pending?.state == MacSendState.WAITING) {
                MacRouting.waiting(mac, pending.sentAt, waitNow)?.let { Text(it, Modifier.padding(horizontal = 20.dp), style = MaterialTheme.typography.bodySmall) }
                Row(Modifier.padding(horizontal = 12.dp)) {
                    TextButton(onClick = { if (projectAllowed()) { scope.launch { if (projectBaseCurrent()) { repository.dontSend(chat.id) { lease.get() && projectBaseCurrent() }  } }  } }) { Text("Don't Send") }
                    MacRouting.other(state.connection.macs, pending)?.let { other ->
                        TextButton(onClick = { if (projectAllowed()) { scope.launch { if (projectBaseCurrent()) { repository.askOnOtherMac(chat.id, other.id) { lease.get() && projectBaseCurrent() }  } }  } }) { Text("Ask on ${other.name}") }
                    }
                }
            }
            if (!deviceAnswer && pending?.state in setOf(MacSendState.EXPIRED, MacSendState.FAILED)) TextButton(
                onClick = { if (projectAllowed()) { scope.launch { if (projectBaseCurrent()) { repository.sendAgain(chat.id) { lease.get() && projectBaseCurrent() }  } }  } }, modifier = Modifier.padding(horizontal = 12.dp)) { Text("Send Again") }
            if (!deviceAnswer && chat.owner == null && chat.delivery !in setOf(DeliveryState.ANSWERING, DeliveryState.QUEUED) && onSelectMac != null && state.connection.macs.count { provider in it.providers } > 1) {
                Column {
                    TextButton(onClick = { if (projectAllowed()) { chooseMac = true  } }) { Text("Choose Mac") }
                    ProjectDropdownMenu(chooseMac, { chooseMac = false }, owned = originalProjectSource != null, current = ::projectAllowed, sourceKey = projectMenuKey) {
                        DropdownMenuItem(text = { Text("Auto") }, onClick = { if (projectAllowed()) { chooseMac = false; onSelectMac(null)  } })
                        state.connection.macs.filter { provider in it.providers }.forEach { option ->
                            DropdownMenuItem(text = { Text("${option.name} · ${MacRouting.state(option)}") }, onClick = { if (projectAllowed()) { chooseMac = false; onSelectMac(option.id)  } })
                        }
                    }
                }
            }
            val scroll = key(chat.id) { rememberLazyListState(initialFirstVisibleItemIndex = chat.reading?.let { reading -> chat.messages.indexOfFirst { it.id == reading.message }.coerceAtLeast(0) } ?: 0,
                initialFirstVisibleItemScrollOffset = chat.reading?.offset ?: 0) }
            LaunchedEffect(chat.id, scroll, projectCurrent, if (projectCurrent == null) 0L else originalPhase) {
                snapshotFlow { Triple(scroll.firstVisibleItemIndex, scroll.firstVisibleItemScrollOffset, !scroll.canScrollForward) }.distinctUntilChanged().debounce(300).collect { (index, offset, bottom) ->
                    if (!projectAllowed()) return@collect
                    val current = repository.state.value.current?.takeIf { it.id == chat.id } ?: return@collect
                    current.messages.getOrNull(index)?.let { repository.reading(chat.id, ChatReading(it.id, offset, bottom)) }
                }
            }
            LaunchedEffect(chat.id, chat.messages.size) {
                val follow = if (scroll.layoutInfo.totalItemsCount == 0) chat.reading?.atBottom != false else !scroll.canScrollForward
                if (chat.messages.isNotEmpty() && follow) scroll.animateScrollToItem(chat.messages.lastIndex)
            }
            val carryOn = remember(chat.messages) {
                var previous: AnswerOrigin? = null
                buildSet<String> { for (message in chat.messages) if (message.role == MessageRole.ASSISTANT) {
                    if (previous == AnswerOrigin.DEVICE && message.origin == AnswerOrigin.MAC) add(message.id)
                    if (message.origin != null) previous = message.origin
                } }
            }
            LazyColumn(state = scroll, modifier = Modifier.weight(1f).fillMaxWidth().testTag("chat.transcript"), contentPadding = androidx.compose.foundation.layout.PaddingValues(top = 4.dp, bottom = 10.dp)) {
                if (chat.messages.isEmpty() && chat.draft.isBlank() && chat.owner == null && !chat.privateOrigin) item(key = "page-ideas") { newChatIdeas?.invoke() }
                itemsIndexed(chat.messages, key = { _, message -> message.id }) { messageIndex, message ->
                    val retryWork: (String) -> Unit = { words ->
                        val current = repository.state.value.current
                        if (projectAllowed() && lease.get() && current?.id == chat.id && current.owner == chat.owner && current.privateOrigin == privateContext) {
                            if (originalProjectSource != null) scope.launch { if (projectBaseCurrent()) { repository.draft(words); if (projectAllowed()) repository.send(chatId = chat.id, sourceCurrent = ::projectBaseCurrent) } }
                            else if (onRetry != null) onRetry(chat.id, words) else scope.launch { if (projectBaseCurrent()) { repository.retry(chat.id, words) } }
                        }
                    }
                    val workOnly = message.role in setOf(MessageRole.WORK, MessageRole.FAILURE) && message.work != null
                    if (workOnly && !(message.work?.kind == "subagents" && chat.delivery == DeliveryState.QUEUED)) {
                        Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp).testTag("chat.message.${message.id}")) {
                            ChatWorkView(checkNotNull(message.work), retryWork)
                        }
                    } else if (!workOnly) {
                    if (message.id in carryOn) Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp).padding(top = 2.dp, bottom = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
                        Icon(YabGlyphs.MacAgentFace, null, Modifier.size(13.dp), tint = chatGray(.6f))
                        Text("${chat.owner?.provider?.displayName ?: provider.displayName} carries on, on your Mac", fontSize = 12.5.sp, fontWeight = FontWeight.Medium, color = chatGray(.6f))
                    }
                    val user = message.role == MessageRole.USER
                    val next = chat.messages.getOrNull(messageIndex + 1)
                    val tail = next == null || (next.role == MessageRole.USER) != user
                    var selectingText by remember(chat.id, message.id, projectCurrent) { mutableStateOf(false) }
                    BackHandler(enabled = selectingText) { selectingText = false }
                    var messageMenu by remember(chat.id, message.id, projectCurrent) { ProjectLocalState(false, ::phaseChanged) }
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = if (tail) 10.dp else 2.dp).testTag("chat.message.${message.id}"), horizontalArrangement = if (user) Arrangement.End else Arrangement.Start) {
                        Column(Modifier.sizeIn(maxWidth = minOf(600.dp, LocalConfiguration.current.screenWidthDp.dp - 32.dp))
                            .combinedClickable(onClick = { if (projectAllowed()) selectingText = false }, onLongClick = { if (projectAllowed()) messageMenu = true })) {
                            val streaming = chat.delivery == DeliveryState.ANSWERING && message.id == chat.messages.lastOrNull()?.id
                            ConversationMessageBody(message, tail, darkChat, streaming, openWebsite, retryWork, selecting = selectingText,
                                onHeld = { if (projectAllowed()) messageMenu = true })
                            ProjectDropdownMenu(messageMenu && message.text.isNotBlank(), { messageMenu = false }, owned = originalProjectSource != null,
                                current = ::projectAllowed, sourceKey = listOf(projectMenuKey, message.id)) {
                                ChatMenuItem(title = "Copy", icon = YabGlyphs.MacYabCopyframeText, onClick = { if (projectAllowed()) { messageMenu = false; clipboard.setText(AnnotatedString(message.work?.takeIf { it.kind == "actions" }?.text?.takeIf(String::isNotEmpty) ?: message.text))  } })
                                ChatMenuItem(title = "Select Text", icon = YabGlyphs.MacYabText, onClick = { if (projectAllowed()) { messageMenu = false; selectingText = true } })
                                ChatMenuItem(title = "Translate", icon = YabGlyphs.Translate, onClick = { if (projectAllowed()) { messageMenu = false; translatedMessage = chat.id to message.text  } })
                                ChatMenuItem(title = "Share", icon = YabGlyphs.MacYabShare, onClick = { if (projectAllowed()) { messageMenu = false; context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, message.text), "Share message"))  } })
                                if (user) ChatMenuItem(title = "Edit", icon = YabGlyphs.MacPencil, onClick = { if (projectAllowed()) { messageMenu = false; scope.launch { if (projectBaseCurrent()) { repository.draft(message.text)  } }  } })
                                else message.work?.takeIf { it.kind == "actions" }?.question?.let { question ->
                                    DropdownMenuItem(text = { Text("Ask Again") }, onClick = { if (projectAllowed()) { messageMenu = false; retryWork(question)  } })
                                }
                            }
                        }
                    }
                    }
                }
                if (chat.delivery == DeliveryState.ANSWERING || chat.delivery == DeliveryState.QUEUED) item {
                    Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        CircularProgressIndicator(Modifier.sizeIn(maxWidth = 20.dp, maxHeight = 20.dp), strokeWidth = 2.dp)
                        Text(if (chat.delivery == DeliveryState.QUEUED) "Queued for your Mac" else "Answering…")
                    }
                }
            }
            if (chat.ephemeral && chat.messages.any { it.role == MessageRole.ASSISTANT }) TextButton(onClick = { if (projectAllowed()) { scope.launch { if (projectBaseCurrent()) { repository.promote(chat.id)  } }  } }) { Text("Keep conversation") }
            for (choice in chat.choices) TextButton(onClick = { if (projectAllowed()) { if (originalProjectSource != null) scope.launch { if (projectBaseCurrent()) { repository.draft(choice); if (projectAllowed()) repository.send(chatId = chat.id, sourceCurrent = ::projectBaseCurrent) } }
                else if (onRetry != null) onRetry(chat.id, choice) else scope.launch { if (projectBaseCurrent()) { repository.retry(chat.id, choice) } }  } }) { Text(choice) }
            for (file in state.attachments[chat.id].orEmpty()) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Text(file.file.name, modifier = Modifier.weight(1f), maxLines = 1)
                TextButton(onClick = { if (projectAllowed()) { repository.removeAttachment(chat.id, file.file.digest)  } }) { Text("Remove") }
            }
            if (terminalOwnerless && (nextOnDevice || statusTarget.mac?.id != mac?.id || statusTarget.provider != provider)) Text(
                if (nextOnDevice) "New message on this device" else mac?.let { "New message on ${it.name} · ${provider.displayName}" } ?: "New message needs an available Mac",
                style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 20.dp))
            chat.page?.let { source ->
                Row(Modifier.padding(start = 33.dp, bottom = 0.dp).background(chatFill(.1f), RoundedCornerShape(15.dp))
                    .clickable { openWebsite(source.url) }.height(28.dp).padding(horizontal = 10.dp).testTag("chat.pagePill"),
                    horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    ChatSiteMark(source.url, 14.dp, chat.privateOrigin)
                    Text(source.title, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                }
            }
            if (originalProjectSource != null) ChatProjectPill(repository, chat, ::projectAllowed, sourceKey = projectMenuKey, onAccepted = ::phaseChanged)
            val projectEditorFocus = remember(chat.id) { FocusRequester() }
            LaunchedEffect(chat.id, originalProjectSource) {
                if (originalProjectSource != null && chat.ephemeral && chat.messages.isEmpty() && projectAllowed()) projectEditorFocus.requestFocus()
            }
            var attachmentMenu by remember(chat.id, projectCurrent) { ProjectLocalState(false, ::phaseChanged) }
            ConversationComposer(chat.draft,
                onText = { words -> if (projectAllowed()) scope.launch { if (projectBaseCurrent()) repository.draft(words) } },
                onSend = { if (projectAllowed()) { if (chat.project != null && originalProjectSource == null) Unit
                    else if (originalProjectSource != null) scope.launch { if (projectBaseCurrent()) repository.send(selection, chat.id, ::projectBaseCurrent) }
                    else if (onSend != null) onSend(chat.id, selection) else scope.launch { if (projectBaseCurrent()) repository.send(selection, chat.id) } } },
                enabled = chat.delivery != DeliveryState.QUEUED && (chat.delivery != DeliveryState.ANSWERING || chat.owner != null),
                focus = projectEditorFocus, placeholder = if (chat.messages.isEmpty()) "Ask anything" else "Ask a follow-up…",
                attachments = if (!repository.canAttach(chat)) null else { {
                    Column {
                        IconButton(onClick = { if (projectAllowed()) attachmentMenu = true }, modifier = Modifier.size(32.dp).background(chatFill(.1f), androidx.compose.foundation.shape.CircleShape)) { Icon(YabGlyphs.PlusMedium, "Add to Chat", Modifier.size(16.dp), tint = chatGray(.6f)) }
                        ProjectDropdownMenu(attachmentMenu, { attachmentMenu = false }, owned = originalProjectSource != null, current = ::projectAllowed, sourceKey = projectMenuKey) {
                            DropdownMenuItem(text = { Text("Photos") }, onClick = { if (projectAllowed()) { attachmentMenu = false; attachmentOwner = repository.attachmentLease(chat.id); if (attachmentOwner != null) photos.launch("image/*") } })
                            DropdownMenuItem(text = { Text("Files") }, onClick = { if (projectAllowed()) { attachmentMenu = false; attachmentOwner = repository.attachmentLease(chat.id); if (attachmentOwner != null) files.launch(arrayOf("*/*")) } })
                            DropdownMenuItem(text = { Text("Camera") }, onClick = { if (projectAllowed()) { attachmentMenu = false; attachmentOwner = repository.attachmentLease(chat.id); if (attachmentOwner != null) camera.launch(null) } })
                        }
                    }
                } })
            if (chooseModel) ProjectAlertDialog(owned = originalProjectSource != null, current = ::projectAllowed, sourceKey = projectMenuKey, onDismissRequest = { if (projectAllowed()) { chooseModel = false  } }, title = { Text("Model and reasoning") }, text = {
                LazyColumn {
                    item { dev.yab.browser.ui.SettingsNote(provider.displayName) }
                    item { dev.yab.browser.ui.SettingsChoiceRow("Default model", selection.model == null) { if (projectAllowed()) selection = ModelSelection() } }
                    items(models, key = { it.id }) { model -> dev.yab.browser.ui.SettingsChoiceRow(model.name, selection.model == model.id) { if (projectAllowed()) selection = ModelSelection(model.id) } }
                    val selected = models.firstOrNull { it.id == selection.model }
                    if (selected != null) {
                        item { dev.yab.browser.ui.SettingsNote("Reasoning") }; item { dev.yab.browser.ui.SettingsChoiceRow("Auto", selection.effort == null) { if (projectAllowed()) selection = selection.copy(effort = null) } }
                        items(selected.efforts) { effort -> dev.yab.browser.ui.SettingsChoiceRow(effort, selection.effort == effort) { if (projectAllowed()) selection = selection.copy(effort = effort) } }
                    }
                }
            }, confirmButton = { TextButton(onClick = { if (projectAllowed()) { chooseModel = false  } }) { Text("Done") } })
        }
    }
    if (settings) {
        val dismissAi = { if (projectAllowed()) { settings = false } }
        val aiContent: @Composable () -> Unit = {
            AiSettings(repository, localModels,
                onImport = { if (projectAllowed()) modelPicker.launch(arrayOf("application/octet-stream", "*/*")) },
                actionCurrent = ::projectAllowed)
        }
        if (originalProjectSource != null) {
            ProjectAlertDialog(owned = true, current = ::projectAllowed, sourceKey = projectMenuKey,
                onDismissRequest = dismissAi, title = { Text("AI") },
                text = { Column(Modifier.verticalScroll(androidx.compose.foundation.rememberScrollState())) { aiContent() } },
                confirmButton = { TextButton(onClick = dismissAi) { Text("Done") } })
        } else AiSettingsSheet(onDismiss = dismissAi, content = aiContent)
    }
    rename?.let { chat -> ProjectAlertDialog(owned = originalProjectSource != null, current = ::projectAllowed, sourceKey = projectMenuKey, onDismissRequest = { if (projectAllowed()) { rename = null  } }, title = { Text("Rename Chat") }, text = { OutlinedTextField(renameText, { if (projectAllowed()) renameText = it }) },
        confirmButton = { TextButton(onClick = { if (projectAllowed()) { scope.launch { if (projectBaseCurrent()) { repository.rename(chat.id, renameText, expected = projectMutation(chat))  } }; rename = null  } }) { Text("Save") } },
        dismissButton = { TextButton(onClick = { if (projectAllowed()) { rename = null  } }) { Text("Cancel") } }) }
    deleting?.let { chat -> ProjectAlertDialog(owned = originalProjectSource != null, current = ::projectAllowed, sourceKey = projectMenuKey, onDismissRequest = { if (projectAllowed()) { deleting = null  } }, title = { Text(if (chat.owner == null) "Delete this chat?" else "Delete this chat on your Mac too?") },
        confirmButton = { TextButton(onClick = { if (projectAllowed()) { scope.launch { if (projectBaseCurrent()) { repository.delete(chat.id, expected = projectMutation(chat))  } }; deleting = null  } }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { if (projectAllowed()) { deleting = null  } }) { Text("Cancel") } }) }
    info?.let { id -> state.current?.takeIf { it.id == id }?.let { current -> ChatInfo(current, close = { if (projectAllowed()) info = null }, open = openWebsite,
        copy = { if (projectAllowed()) clipboard.setText(AnnotatedString(it)) },
        project = renderedProjects.listed.singleOrNull { it.id == current.project },
        projectCurrent = { projectAllowed() && lease.get() }, projectSourceKey = projectMenuKey,
        onPin = { if (projectAllowed()) scope.launch { if (projectBaseCurrent()) repository.pin(current.id, expected = projectMutation(current)) } },
        onUnread = { if (projectAllowed()) scope.launch { if (projectBaseCurrent()) repository.markUnread(current.id, !current.unread, expected = projectMutation(current)) } },
        onArchive = { if (projectAllowed()) scope.launch { if (projectBaseCurrent()) { repository.archive(current.id, expected = projectMutation(current)); if (projectAllowed()) { info = null; back() } } } },
        onRename = { if (projectAllowed()) { rename = current; renameText = current.title } },
        onZoom = { if (projectAllowed() && lease.get()) infoZoom = it }) } }
    translatedMessage?.takeIf { state.current?.id == it.first }?.let { (_, words) -> MessageTranslation(words, close = { if (projectAllowed()) translatedMessage = null },
        projectCurrent = if (originalProjectSource == null) null else ::projectAllowed, projectSourceKey = projectMenuKey) }
    state.error?.let { error -> ProjectAlertDialog(owned = originalProjectSource != null, current = ::projectAllowed, sourceKey = projectMenuKey, onDismissRequest = { if (projectAllowed()) repository.clearError() }, title = { Text("Yab") }, text = { Text(error) }, confirmButton = { TextButton(onClick = { if (projectAllowed()) repository.clearError() }) { Text("OK") } }) }
    if (showApprovalPrompt && approvals != null && !privateContext) {
        val reviewState by approvals.state.collectAsState()
        if (reviewState.deferred.isNotEmpty()) TextButton(onClick = { if (projectAllowed()) { reviewState.requests.firstOrNull()?.let { approvals.select(it.id) }  } }) { Text("Review ${reviewState.requests.size} approvals") }
        ApprovalPrompt(approvals, authentication, observeInScreen = collectInScreen)
    }
    }
    }
}

@Composable
fun ApprovalPrompt(controller: ApprovalController, authentication: ApprovalAuthentication?, observeInScreen: Boolean = true) {
    ApprovalTrayPrompt(controller, authentication, observeInScreen)
}

/** AI settings over the chat, the same rows as Settings › AI. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AiSettingsSheet(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.background) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text("AI", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            TextButton(onClick = onDismiss) { Text("Done") }
        }
        Column(Modifier.fillMaxWidth().verticalScroll(androidx.compose.foundation.rememberScrollState())
            .padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 32.dp)) { content() }
    }
}

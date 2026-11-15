package dev.yab.android

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.lifecycleScope
import dev.yab.agent.*
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.model.FieldInputLease
import dev.yab.browser.ui.BindBrowserFieldChatArchive
import dev.yab.browser.ui.LocalBrowserFieldChatArchive
import dev.yab.sync.AccountRecordsSnapshot
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

private data class FieldChatAccount(val account: String?, val device: String?, val epoch: Long, val removed: Boolean)
private fun chatDestinations(connection: RemoteConnection, account: String?) =
    connection.macs.takeIf { connection.account == account }.orEmpty().map { it.id to it.controlsChats }.sortedBy { it.first }
private class FieldChatSource(val input: FieldInputLease?, val account: FieldChatAccount, val query: String, val archived: Boolean,
    val destinations: List<Pair<String, Boolean>>) {
    var retired = false
}

/** The inline list has no repository startup or inference side effects. Every user intent
 * retains the original Field/account and chat snapshot until its final callback. */
@Composable
internal fun FieldChatsHost(browser: BrowserController, agent: AgentRepository,
    accountRecords: StateFlow<AccountRecordsSnapshot>, remoteConnection: StateFlow<RemoteConnection>,
    enabled: Boolean, modifier: Modifier = Modifier,
    projectPresentation: ChatProjectsPresentation? = null, projectHostCurrent: (() -> Boolean)? = null,
    projectViewCurrent: (() -> Boolean)? = null,
    onOpen: (AgentChat) -> Unit) {
    val browserState by browser.state.collectAsState()
    val agentState by agent.state.collectAsState()
    val accountState by accountRecords.collectAsState()
    val connection by remoteConnection.collectAsState()
    val projectSnapshot by agent.projects.collectAsState()
    val foreground by browser.settingsPresentationLifetime.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val actions = LocalLifecycleOwner.current.lifecycleScope
    val context = LocalContext.current
    val account = FieldChatAccount(accountState.account, accountState.device, accountState.epoch, accountState.removed)
    val input = remember(browser, browserState.surfaceEpoch, browserState.selectedSpaceId, browserState.space?.websiteProfile,
        browserState.tab?.id, browserState.fieldIsNewTab, browserState.fieldIsPrivate, account) { browser.captureFieldInput() }
    var archived by remember(input, account) { mutableStateOf(false) }
    val query = if (browserState.surface == BrowserSurface.FIELD) browserState.fieldText else ""
    val destinations = chatDestinations(connection, account.account)
    val source = remember(input, account, query, archived, destinations) { FieldChatSource(input, account, query, archived, destinations) }
    val latestEnabled by rememberUpdatedState(enabled)
    DisposableEffect(source) { onDispose { source.retired = true } }
    fun current(): Boolean {
        val identity = accountRecords.value
        val state = browser.state.value
        return !source.retired && !source.account.removed && !identity.removed &&
            FieldChatAccount(identity.account, identity.device, identity.epoch, identity.removed) == source.account &&
            source.input?.let(browser::fieldInputCurrent) == true && !state.fieldIsPrivate && state.space?.isPrivate != true &&
            (if (state.surface == BrowserSurface.FIELD) state.fieldText else "") == source.query &&
            archived == source.archived &&
            chatDestinations(remoteConnection.value, source.account.account) == source.destinations &&
            lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    }
    fun listed(): List<AgentChat> {
        val state = agent.state.value
        return state.copy(privateContext = false, connection = state.connection.copy(account = source.account.account,
            epoch = source.account.epoch)).listed(source.query, source.archived).filter { !source.archived || it.archived }
    }
    fun active() = latestEnabled && current()
    val fieldArchive = LocalBrowserFieldChatArchive.current
    BindBrowserFieldChatArchive(source, archived, ::active) { if (active()) archived = !source.archived }
    fun rowCurrent(chat: AgentChat): Boolean = active() && listed().singleOrNull { it.id == chat.id } == chat
    fun allowed(chat: AgentChat, action: FieldChatAction): Boolean {
        if (!rowCurrent(chat)) return false
        val busy = chat.delivery == DeliveryState.ANSWERING
        return when (action) {
            FieldChatAction.COPY_ANSWER -> !FieldChatsPageModel.answer(chat)?.text.isNullOrBlank()
            FieldChatAction.PIN -> !chat.pinned
            FieldChatAction.UNPIN -> chat.pinned
            FieldChatAction.MARK_READ -> chat.unread
            FieldChatAction.MARK_UNREAD -> !chat.unread
            FieldChatAction.RENAME -> true
            FieldChatAction.ARCHIVE -> !chat.archived && !busy
            FieldChatAction.UNARCHIVE -> chat.archived && !busy
            FieldChatAction.ARCHIVE_OLDER -> !source.archived
            FieldChatAction.STOP -> chat.owner?.let { owner -> chat.delivery == DeliveryState.ANSWERING &&
                remoteConnection.value.takeIf { it.account == owner.account }?.macs?.any { it.id == owner.mac && it.controlsChats } == true } == true
            FieldChatAction.DELETE -> agent.canDelete(chat)
        }
    }
    val projectLifetime = remember(source, projectSnapshot, foreground.generation, foreground.privateBoundary, projectHostCurrent) {
        ProjectUiLifetime { current() && agent.projects.value == projectSnapshot &&
            projectHostCurrent?.invoke() == true }
    }
    DisposableEffect(projectLifetime) { onDispose { projectLifetime.retire() } }
    // Covers survive their own Field blur, but keep the original account, foreground and public namespace.
    val coverCurrent = remember(account, foreground.privateBoundary, projectViewCurrent ?: projectHostCurrent,
        browserState.selectedSpaceId, browserState.space?.websiteProfile) {
        val originalForeground = foreground
        val originalSpace = browserState.selectedSpaceId
        val originalProfile = browserState.space?.websiteProfile
        val host = projectViewCurrent ?: projectHostCurrent
        val guard: () -> Boolean = { val identity = accountRecords.value; val state = browser.state.value; val lifetime = browser.settingsPresentationLifetime.value
            !identity.removed && !account.removed && FieldChatAccount(identity.account, identity.device, identity.epoch, identity.removed) == account &&
                lifetime.privateBoundary == originalForeground.privateBoundary &&
                state.selectedSpaceId == originalSpace && state.space?.websiteProfile == originalProfile && state.space?.isPrivate == false &&
                !state.fieldIsPrivate && host?.invoke() == true
        }
        guard
    }
    // Observe row updates for composition; callbacks read the fresh authoritative state.
    val rows = agentState.copy(privateContext = false, connection = agentState.connection.copy(account = account.account,
        epoch = account.epoch)).listed(query, archived).filter { !archived || it.archived }
    FieldChatsPage(rows, query, archived, source, enabled, ::current,
        onSelect = { captured -> if (rowCurrent(captured)) {
            agent.setPrivacy(false); agent.open(captured.id)
            agent.state.value.current?.takeIf { FieldChatsPageModel.sameOwner(it, captured) }?.let(onOpen)
        } },
        onNewChat = { if (active()) {
            agent.setPrivacy(false); agent.newChat()
            agent.state.value.current?.let(onOpen)
        } },
        onArchive = { if (active()) archived = it }, canAct = ::allowed,
        onAction = { command ->
            if (command.sourceKey === source && allowed(command.chat, command.action) &&
                command.older.all { allowed(it, FieldChatAction.ARCHIVE) }) actions.launch {
                if (command.sourceKey !== source || !allowed(command.chat, command.action)) return@launch
                val expected = ChatMutationLease(command.chat, source.account.account, source.account.device, source.account.epoch, ::active)
                when (command.action) {
                    FieldChatAction.COPY_ANSWER -> FieldChatsPageModel.answer(command.chat)?.text?.let {
                        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Answer", it))
                    }
                    FieldChatAction.PIN, FieldChatAction.UNPIN -> agent.pin(command.chat.id, expected = expected)
                    FieldChatAction.MARK_READ -> agent.markUnread(command.chat.id, false, expected = expected)
                    FieldChatAction.MARK_UNREAD -> agent.markUnread(command.chat.id, true, expected = expected)
                    FieldChatAction.RENAME -> command.title?.takeIf(String::isNotBlank)?.let { agent.rename(command.chat.id, it, expected = expected) }
                    FieldChatAction.ARCHIVE, FieldChatAction.UNARCHIVE -> agent.archive(command.chat.id, expected = expected)
                    FieldChatAction.ARCHIVE_OLDER -> for (captured in command.older) {
                        if (!current() || !rowCurrent(command.chat) || !allowed(captured, FieldChatAction.ARCHIVE)) break
                        agent.archive(captured.id, expected = ChatMutationLease(captured, source.account.account, source.account.device,
                            source.account.epoch, ::active))
                    }
                    FieldChatAction.STOP -> agent.stop(command.chat.id, expected = expected)
                    FieldChatAction.DELETE -> agent.delete(command.chat.id, expected = expected)
                }
            }
        },
        deleteQuestion = { chat ->
            val mac = chat.owner?.let { owner -> connection.takeIf { it.account == owner.account }?.macs?.firstOrNull { it.id == owner.mac } }
            if (chat.owner != null && mac?.controlsChats == true) FieldChatDeleteQuestion("Delete this chat on your Mac too?")
            else FieldChatDeleteQuestion("Delete this chat?", if (chat.owner == null) null else "The conversation is hidden on this device. Your Mac does not support deleting it here.")
        }, modifier = modifier, showArchiveControl = fieldArchive == null,
        macNames = connection.macs.takeIf { connection.account == account.account }.orEmpty().associate { it.id to it.name },
        projects = projectSnapshot.listed.takeIf { projectSnapshot.matches(connection) && !account.removed && projectPresentation != null && projectHostCurrent != null }.orEmpty(),
        projectKey = projectSnapshot.generation,
        onProject = { project -> if (active() && projectLifetime.current()) {
            projectPresentation?.open(projectSnapshot, remoteConnection.value, project.id, coverCurrent)
        } },
        moveProjectContent = if (projectHostCurrent == null) null else { chat, originalPageCurrent -> MoveToProjectMenu(agent, chat) {
            originalPageCurrent() && active() && projectLifetime.current() && agent.state.value.chats.singleOrNull { it.id == chat.id }?.let {
                FieldChatsPageModel.sameOwner(it, chat) && it.project == chat.project
            } == true
        } })
}

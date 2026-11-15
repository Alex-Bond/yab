package dev.yab.agent

import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

interface ChatPersistence {
    suspend fun load(): ChatSnapshot
    suspend fun save(snapshot: ChatSnapshot)
}

class AgentRepository(
    private val store: ChatPersistence,
    private val local: LocalAiAdapter,
    private val remote: RemoteAgentTransport,
) {
    private val mutable = MutableStateFlow(AgentState(connection = remote.connection.value, projects = remote.projects.value))
    val state: StateFlow<AgentState> = mutable.asStateFlow()
    val projects: StateFlow<ChatProjectsSnapshot> get() = remote.projects
    private val writes = Mutex()
    private val sends = Mutex()
    private var hidden = emptySet<String>()
    private var remoteChats = emptyList<RemoteConversation>()
    private fun ownerKey(owner: RemoteOwner) = "${owner.account}/${owner.mac}/${owner.chat}"

    suspend fun load() = writes.withLock {
        if (mutable.value.loaded) return@withLock
        try {
            val snapshot = store.load()
            require(snapshot.version == 1 && snapshot.chats.none { it.privateOrigin || it.page?.isPrivate == true }) { "Saved conversations cannot be read safely" }
            hidden = snapshot.hidden
            mutable.update { state -> state.copy(chats = snapshot.chats.filterNot { saved -> state.chats.any { it.id == saved.id } } + state.chats,
                preferences = snapshot.preferences, loaded = true) }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            mutable.update { it.copy(loaded = true, error = error.message ?: "Saved conversations could not be read") }
        }
    }

    /** The retained browser owns this collector; isolated consumer tests may bind it to a screen. */
    suspend fun run() = coroutineScope {
        load()
        launch { remote.projects.collect { projects -> mutable.update { it.copy(projects = projects) } } }
        launch { remote.connection.collect { connection ->
            mutable.update { state ->
                val active = state.chats.firstOrNull { it.id == state.activeChat }
                state.copy(connection = connection, activeChat = state.activeChat.takeUnless { active?.owner != null && active.owner.account != connection.account },
                    chats = state.chats.map { chat ->
                        val target = chat.owner?.let { it.account to it.mac } ?: chat.pendingSend?.let { it.account to it.mac }
                        if (target != null && (target.first != connection.account || connection.macs.none { it.id == target.second }) && chat.delivery in setOf(DeliveryState.ANSWERING, DeliveryState.QUEUED)) chat.copy(delivery = DeliveryState.IDLE) else chat
                    })
            }
            mutable.value.chats.filter { it.owner?.account == connection.account && it.pendingFlags != ChatFlags() }.forEach { flushFlags(it.id) }
        } }
        launch { remote.sends.collect { sends ->
            adoptSends(sends)
            persist()
        } }
        remote.conversations.collect { updates ->
            remoteChats = updates
            val account = remote.connection.value.account ?: return@collect
            mutable.update { state ->
                var chats = state.chats
                for (incoming in updates.filter { it.owner.account == account }) {
                    if (ownerKey(incoming.owner) in hidden || incoming.clientChat?.let { "local/$it" in hidden } == true) continue
                    val previous = chats.firstOrNull { it.owner == incoming.owner || it.id == incoming.clientChat }
                    if (previous?.privateOrigin == true) continue
                    if (previous?.owner != null && previous.owner != incoming.owner) continue
                    val old = previous ?: AgentChat(id = incoming.clientChat ?: incoming.owner.chat)
                    val pending = old.pendingFlags
                    val flags = ChatFlags(pending.pinned?.takeUnless { incoming.metadataKnown && it == incoming.pinned }, pending.archived?.takeUnless { incoming.metadataKnown && it == incoming.archived },
                        pending.unread?.takeUnless { incoming.metadataKnown && it == incoming.unread }, pending.title?.takeUnless { it == incoming.title })
                    val changed = previous != null && incoming.messages != previous.messages
                    val staleTaken = old.pendingSend?.let { it.state == MacSendState.TAKEN && incoming.updatedAt < (it.tookAt ?: it.sentAt) } == true
                    var incomingMessages = incoming.messages
                    old.pendingSend?.let { pending ->
                        val user = old.messages.lastOrNull { it.role == MessageRole.USER && (it.id == pending.id || it.text == pending.question && it.at >= pending.sentAt - 1000) }
                        if (user != null && incomingMessages.none { it.role == MessageRole.USER && (it.id == pending.id || it.text == pending.question && it.at >= pending.sentAt - 1000) }) incomingMessages = incomingMessages + user
                        if (pending.state in setOf(MacSendState.FAILED, MacSendState.EXPIRED)) old.messages.firstOrNull { it.id == "${pending.id}/status" }?.let { status ->
                            if (incomingMessages.none { it.id == status.id }) incomingMessages = incomingMessages + status
                        }
                    }
                    val chat = old.copy(
                        title = flags.title ?: incoming.title,
                        owner = incoming.owner,
                        messages = incomingMessages,
                        pinned = flags.pinned ?: if (incoming.metadataKnown) incoming.pinned else old.pinned,
                        archived = flags.archived ?: if (incoming.metadataKnown) incoming.archived else old.archived,
                        unread = flags.unread ?: if (state.activeChat == old.id) false else if (incoming.metadataKnown) incoming.unread else old.unread || changed,
                        pendingFlags = flags,
                        delivery = when (old.pendingSend?.state) {
                            MacSendState.WAITING, MacSendState.PROCESSING -> DeliveryState.QUEUED
                            MacSendState.FAILED, MacSendState.EXPIRED -> DeliveryState.FAILED
                            else -> if (staleTaken || incoming.working && incoming.choices.isEmpty()) DeliveryState.ANSWERING else DeliveryState.IDLE
                        },
                        updatedAt = maxOf(incoming.updatedAt, incoming.messages.maxOfOrNull { it.at } ?: 0, previous?.updatedAt ?: 0),
                        remoteState = incoming.remoteState, choices = if (staleTaken || old.pendingSend?.state in setOf(MacSendState.WAITING, MacSendState.PROCESSING)) emptyList() else incoming.choices,
                        // An actual head is authoritative even when a formerly present field is now nil.
                        // Legacy test/local transports without complete metadata keep their saved facts.
                        origin = if (incoming.metadataKnown) incoming.origin else old.origin,
                        routine = if (incoming.metadataKnown) incoming.routine else old.routine,
                        project = if (incoming.metadataKnown) incoming.project else old.project,
                    )
                    chats = chats.filterNot { it.id == chat.id } + chat
                }
                state.copy(chats = chats)
            }
            persist()
            mutable.value.chats.filter { it.owner?.account == account && it.pendingFlags != ChatFlags() }.forEach { flushFlags(it.id) }
        }
    }

    private fun adoptSends(updates: List<RemoteSend>) {
        val connection = remote.connection.value
        val checked = updates.filter { it.account == connection.account && it.epoch == connection.epoch && "local/${it.clientChat}" !in hidden }
        mutable.update { state ->
            var chats = state.chats.map { chat ->
                val previous = chat.pendingSend
                if (previous != null && previous.account == connection.account && checked.none { it.id == previous.id }) chat.copy(pendingSend = null,
                    delivery = if (chat.delivery == DeliveryState.QUEUED || chat.owner == null && chat.delivery == DeliveryState.ANSWERING) DeliveryState.IDLE else chat.delivery) else chat
            }
            for ((id, all) in checked.groupBy { it.clientChat }) {
                val send = all.maxWith(compareBy<RemoteSend> { it.sentAt }.thenBy { it.id })
                val previous = chats.firstOrNull { it.id == id || it.owner?.let { owner -> owner.account == send.account && owner.mac == send.mac && owner.chat == send.chat } == true }
                if (previous?.privateOrigin == true || previous?.owner?.account?.let { it != send.account } == true) continue
                if (previous == null && send.state == MacSendState.CANCELLED) continue
                val old = previous ?: AgentChat(id, title = send.question.take(80).ifBlank { "New chat" }, forceMac = true)
                val head = remoteChats.firstOrNull { it.owner.account == send.account && it.owner.mac == send.mac && it.owner.chat == send.chat }
                val currentHead = head?.takeIf { it.updatedAt >= (send.tookAt ?: send.sentAt) }
                var messages = old.messages
                if (send.state != MacSendState.CANCELLED && messages.none { it.id == send.id || it.role == MessageRole.USER && it.text == send.question && it.at >= send.sentAt - 1000 }) {
                    messages = messages + AgentMessage(send.id, MessageRole.USER, send.question, send.sentAt, files = send.files)
                }
                if (send.state == MacSendState.CANCELLED) messages = messages.filterNot { it.id == send.id || it.id == "${send.id}/status" }
                if (send.state in setOf(MacSendState.EXPIRED, MacSendState.FAILED)) {
                    val words = if (send.state == MacSendState.EXPIRED) "Expired before ${connection.macs.firstOrNull { it.id == send.mac }?.name ?: "your Mac"} received it"
                        else send.reason?.takeIf(String::isNotBlank)?.let { "Your Mac couldn't take this question: $it" } ?: "Your Mac couldn't take this question. Send it again."
                    messages = messages.filterNot { it.id == "${send.id}/status" } + AgentMessage("${send.id}/status", MessageRole.FAILURE, words, send.sentAt)
                }
                val delivery = when (send.state) {
                    MacSendState.WAITING, MacSendState.PROCESSING -> DeliveryState.QUEUED
                    MacSendState.FAILED, MacSendState.EXPIRED -> DeliveryState.FAILED
                    MacSendState.CANCELLED -> DeliveryState.IDLE
                    MacSendState.TAKEN -> if (currentHead != null) { if (currentHead.working && currentHead.choices.isEmpty()) DeliveryState.ANSWERING else DeliveryState.IDLE } else DeliveryState.ANSWERING
                }
                val adopted = old.copy(messages = messages, ephemeral = false, pendingSend = send.takeUnless { it.state == MacSendState.CANCELLED }, delivery = delivery,
                    project = if (head?.metadataKnown == true) head.project else send.project ?: old.project,
                    choices = if (send.state in setOf(MacSendState.WAITING, MacSendState.PROCESSING) || send.state == MacSendState.TAKEN && currentHead == null) emptyList() else head?.choices ?: old.choices,
                    updatedAt = maxOf(old.updatedAt, send.sentAt))
                chats = chats.filterNot { it.id == adopted.id } + adopted
            }
            state.copy(chats = chats)
        }
    }

    fun setPrivacy(privateContext: Boolean) {
        mutable.update { if (it.privateContext == privateContext) it else it.copy(privateContext = privateContext, activeChat = null) }
    }

    fun newChat(page: PageContext? = null, ephemeral: Boolean = false, forceMac: Boolean = false): String {
        val privateOrigin = mutable.value.privateContext || page?.isPrivate == true
        val id = UUID.randomUUID().toString()
        require(!privateOrigin || !forceMac) { "Private conversations stay on this device" }
        val chat = AgentChat(id, privateOrigin = privateOrigin, page = page, updatedAt = System.currentTimeMillis(), ephemeral = ephemeral, forceMac = forceMac)
        mutable.update { it.copy(chats = it.chats + chat, activeChat = id, privateContext = privateOrigin) }
        return id
    }

    fun canStartInProject(project: String? = null): Boolean {
        val state = mutable.value; val connection = remote.connection.value; val snapshot = projects.value
        return !state.privateContext && snapshot.matches(connection) &&
            (project == null || snapshot.listed.any { it.id == project }) &&
            connection.route(state.preferences.provider)?.takesProjects == true
    }
    fun captureProjectStart(project: String, sourceCurrent: () -> Boolean): ChatProjectLease? {
        if (!canStartInProject(project)) return null
        val provider = mutable.value.preferences.provider
        val snapshot = projects.value; val mac = remote.connection.value.route(provider)?.id ?: return null
        return ChatProjectLease(ChatProjectLease.Kind.START, snapshot, null, project, mac, provider) {
            sourceCurrent() && !mutable.value.privateContext && mutable.value.preferences.provider == provider && projects.value == snapshot
        }.takeIf { it.current(projects.value, remote.connection.value) }
    }
    fun newChatInProject(expected: ChatProjectLease, initialDraft: String = ""): String? {
        expected.requireKind(ChatProjectLease.Kind.START)
        if (!expected.current(projects.value, remote.connection.value)) return null
        expected.retire()
        val id = UUID.randomUUID().toString()
        // Keep admitted words on their original chat before a cover or queued send can retire.
        val chat = AgentChat(id, draft = initialDraft, updatedAt = System.currentTimeMillis(), ephemeral = true, forceMac = true, project = expected.project)
        mutable.update { it.copy(chats = it.chats + chat, activeChat = id, privateContext = false) }
        return id
    }
    fun canMoveToProject(chat: AgentChat): Boolean {
        val connection = remote.connection.value
        return !mutable.value.privateContext && !chat.privateOrigin && !chat.ephemeral &&
            mutable.value.chats.singleOrNull { it.id == chat.id } == chat && projects.value.matches(connection) &&
            projects.value.listed.isNotEmpty() && chat.owner?.let { owner -> owner.account == connection.account &&
                owner.chat.startsWith("a:") && connection.macs.any { it.id == owner.mac && it.takesMetadata && it.takesProjects } } == true
    }
    fun captureProjectMove(chat: AgentChat, project: String?, sourceCurrent: () -> Boolean): ChatProjectLease? {
        if (!canMoveToProject(chat) || chat.project == project || project != null && projects.value.listed.none { it.id == project }) return null
        val owner = chat.owner ?: return null
        val snapshot = projects.value
        return ChatProjectLease(ChatProjectLease.Kind.MOVE, snapshot, chat, project, owner.mac, owner.provider) {
            sourceCurrent() && !mutable.value.privateContext && projects.value == snapshot && mutable.value.chats.singleOrNull { it.id == chat.id }?.let {
                it.owner == chat.owner && it.project == chat.project && it.privateOrigin == chat.privateOrigin && it.pendingSend == chat.pendingSend
            } == true
        }.takeIf { it.current(projects.value, remote.connection.value) }
    }
    suspend fun moveToProject(expected: ChatProjectLease): Boolean {
        expected.requireKind(ChatProjectLease.Kind.MOVE)
        val captured = expected.chat ?: return false
        if (!expected.current(projects.value, remote.connection.value)) return false
        return try {
            val accepted = remote.moveToProject(captured.owner ?: return false, expected.project, expected)
            // The Bridge publishes the actual journal head. An old successful response must
            // never overwrite a later head, and its own terminal move has changed generation.
            if (accepted) expected.retire()
            accepted
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (expected.current(projects.value, remote.connection.value)) showError(error.message ?: "The chat could not be moved"); false }
    }
    fun captureDraftProject(chat: AgentChat, project: String?, sourceCurrent: () -> Boolean): ChatProjectLease? {
        if (mutable.value.privateContext || chat.privateOrigin || chat.owner != null || !chat.ephemeral ||
            chat.project == null || chat.page != null || chat.messages.isNotEmpty() || chat.pendingSend != null || mutable.value.current != chat ||
            !canStartInProject(project)) return null
        val provider = mutable.value.preferences.provider
        val mac = remote.connection.value.route(provider)?.id ?: return null
        val snapshot = projects.value
        return ChatProjectLease(ChatProjectLease.Kind.DRAFT, snapshot, chat, project, mac, provider) {
            sourceCurrent() && !mutable.value.privateContext && projects.value == snapshot && mutable.value.preferences.provider == provider && mutable.value.current?.let {
                it.id == chat.id && it.owner == null && it.ephemeral && it.messages.isEmpty() && it.pendingSend == null && it.project == chat.project
            } == true
        }.takeIf { it.current(projects.value, remote.connection.value) }
    }
    suspend fun setDraftProject(expected: ChatProjectLease): Boolean {
        expected.requireKind(ChatProjectLease.Kind.DRAFT)
        val captured = expected.chat ?: return false
        if (!expected.current(projects.value, remote.connection.value)) return false
        expected.retire()
        edit(captured.id) { it.copy(project = expected.project, forceMac = expected.project != null || it.forceMac) }
        return true
    }

    fun open(id: String) { mutable.update { state ->
        if (state.chats.none { it.id == id && it.privateOrigin == state.privateContext }) state
        else state.copy(activeChat = id, chats = state.chats.map { if (it.id == id) it.copy(unread = false, pendingFlags = it.pendingFlags.copy(unread = false)) else it })
    } }
    fun focusConversation(id: String): Boolean {
        val chat = mutable.value.chats.firstOrNull { (it.id == id || it.owner?.chat == id) && it.privateOrigin == mutable.value.privateContext && (it.owner == null || it.owner.account == remote.connection.value.account) } ?: return false
        open(chat.id)
        return true
    }
    fun back() { mutable.update { state -> state.copy(activeChat = null, chats = state.chats.filterNot { it.id == state.activeChat && it.ephemeral }) } }
    fun clearError() { mutable.update { it.copy(error = null) } }
    fun showError(words: String) { mutable.update { it.copy(error = words) } }
    suspend fun draft(words: String) { val id = mutable.value.current?.id ?: return; edit(id) { it.copy(draft = words) }; persist() }
    suspend fun preferences(value: AgentPreferences) { mutable.update { it.copy(preferences = value) }; persist() }
    private fun mutationCurrent(id: String, expected: ChatMutationLease?, pendingRetracted: Boolean = false): Boolean =
        expected == null || expected.chat.id == id && expected.current(mutable.value.chats.firstOrNull { it.id == id }, remote.connection.value, pendingRetracted)
    private suspend fun flushFlags(id: String, expected: ChatMutationLease? = null) {
        if (!mutationCurrent(id, expected)) return
        val chat = mutable.value.chats.firstOrNull { it.id == id } ?: return
        val owner = chat.owner ?: return
        try {
            if (expected == null) remote.patchChat(owner, chat.pendingFlags) else remote.patchChat(owner, chat.pendingFlags, expected)
        } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { /* Retain the local pending override until a supported Mac confirms it. */ }
    }
    private fun withFlags(chat: AgentChat, flags: ChatFlags, promote: Boolean): AgentChat = chat.copy(
        pinned = flags.pinned ?: chat.pinned, archived = flags.archived ?: chat.archived,
        unread = flags.unread ?: chat.unread, title = flags.title ?: chat.title,
        ephemeral = if (promote) false else chat.ephemeral,
        pendingFlags = ChatFlags(flags.pinned ?: chat.pendingFlags.pinned, flags.archived ?: chat.pendingFlags.archived,
            flags.unread ?: chat.pendingFlags.unread, flags.title ?: chat.pendingFlags.title))
    private suspend fun changeFlags(id: String, flags: ChatFlags, promote: Boolean, expected: ChatMutationLease?) {
        if (!mutationCurrent(id, expected)) return
        val before = mutable.value.chats.firstOrNull { it.id == id } ?: return
        if (expected != null) {
            // Do not expose a pending override to the legacy reconnect flusher before this
            // exact session's dispatcher has admitted the new action.
            try {
                val accepted = before.owner?.let { remote.patchChat(it, withFlags(before, flags, promote).pendingFlags, expected) } ?: true
                if (!accepted) {
                    if (mutationCurrent(id, expected)) showError("This Mac cannot change this chat from here")
                    return
                }
            }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                if (mutationCurrent(id, expected)) showError(error.message ?: "The chat could not be changed")
                return
            }
            if (!mutationCurrent(id, expected)) return
        }
        edit(id, expected) { withFlags(it, flags, promote) }
        persist(expected)
        if (expected == null) flushFlags(id)
    }
    suspend fun pin(id: String, expected: ChatMutationLease? = null) {
        val chat = mutable.value.chats.firstOrNull { it.id == id } ?: return
        changeFlags(id, ChatFlags(pinned = !chat.pinned), true, expected)
    }
    suspend fun markUnread(id: String, unread: Boolean, expected: ChatMutationLease? = null) =
        changeFlags(id, ChatFlags(unread = unread), false, expected)
    suspend fun archive(id: String, expected: ChatMutationLease? = null) {
        val chat = mutable.value.chats.firstOrNull { it.id == id } ?: return
        changeFlags(id, ChatFlags(archived = !chat.archived), true, expected)
    }
    suspend fun rename(id: String, title: String, expected: ChatMutationLease? = null) {
        if (title.isNotBlank()) changeFlags(id, ChatFlags(title = title.trim().take(300)), true, expected)
    }
    suspend fun archiveOlder(id: String) {
        val listed = mutable.value.listed(); val index = listed.indexOfFirst { it.id == id }
        if (index < 0) return
        for (chat in listed.drop(index + 1).filter { !it.pinned && !it.archived && it.delivery !in setOf(DeliveryState.ANSWERING, DeliveryState.QUEUED) }) archive(chat.id)
    }
    suspend fun promote(id: String) { edit(id) { it.copy(ephemeral = false) }; persist() }
    suspend fun reading(id: String, reading: ChatReading) { edit(id) { it.copy(reading = reading) }; persist() }
    suspend fun retry(id: String, words: String) {
        if (mutable.value.current?.id != id || words.isBlank()) return
        draft(words); send(chatId = id)
    }
    fun canDelete(chat: AgentChat): Boolean = chat.owner == null || chat.delivery !in setOf(DeliveryState.ANSWERING, DeliveryState.QUEUED)

    fun canAttach(chat: AgentChat): Boolean {
        if (chat.privateOrigin || chat.delivery == DeliveryState.QUEUED || chat.owner == null && chat.delivery == DeliveryState.ANSWERING) return false
        val connection = remote.connection.value
        val pending = chat.pendingSend
        if (pending != null && (pending.account != connection.account || pending.epoch != connection.epoch || pending.state in setOf(MacSendState.WAITING, MacSendState.PROCESSING))) return false
        val mac = if (pending != null) connection.macs.firstOrNull { it.id == pending.mac && pending.provider in it.providers }
        else if (chat.owner != null) chat.owner.let { owner ->
            if (owner.account != connection.account) return false
            connection.macs.firstOrNull { it.id == owner.mac }
        } else connection.route(mutable.value.preferences.provider)
        return mac?.takesFiles == true
    }

    fun attachmentLease(id: String): AttachmentLease? {
        val chat = mutable.value.current?.takeIf { it.id == id && canAttach(it) } ?: return null
        val connection = remote.connection.value; val account = connection.account ?: return null
        val provider = chat.owner?.provider ?: chat.pendingSend?.provider ?: mutable.value.preferences.provider
        val mac = chat.owner?.mac ?: chat.pendingSend?.mac ?: connection.route(provider)?.id ?: return null
        return AttachmentLease(id, chat.owner, account, connection.epoch, chat.pendingSend?.fingerprint, mac, provider)
    }

    fun attach(id: String, files: List<PreparedAttachment>, expected: AttachmentLease? = null) {
        val chat = mutable.value.current?.takeIf { it.id == id } ?: return
        require(expected == null || attachmentLease(id) == expected) { "The conversation or Mac changed while choosing files" }
        require(canAttach(chat)) { "Files need a public conversation and a Mac that takes files" }
        val all = mutable.value.attachments[id].orEmpty() + files
        AttachmentLimits.validate(all.map { it.bytes.size })
        mutable.update { it.copy(attachments = it.attachments + (id to all)) }
    }
    fun removeAttachment(id: String, digest: String) {
        mutable.update { it.copy(attachments = it.attachments + (id to it.attachments[id].orEmpty().filterNot { file -> file.file.digest == digest })) }
    }

    suspend fun send(selection: ModelSelection = ModelSelection(), chatId: String? = null, sourceCurrent: (() -> Boolean)? = null) {
        if (sourceCurrent?.invoke() == false) return
        val tapped = mutable.value.current?.takeIf { chatId == null || it.id == chatId } ?: return
        val tappedConnection = remote.connection.value
        val tappedAccount = tappedConnection.account
        val tappedEpoch = tappedConnection.epoch
        val tappedPreferences = mutable.value.preferences
        val tappedRoute = if (tapped.owner == null) tappedConnection.route(tappedPreferences.provider)?.id else null
        val tappedFiles = mutable.value.attachments[tapped.id].orEmpty()
        sends.withLock {
        if (sourceCurrent?.invoke() == false) { showError("The page changed. Ask again from the current page."); return@withLock }
        val before = mutable.value
        val currentConnection = remote.connection.value
        val chat = before.current?.takeIf { it.id == tapped.id && it.privateOrigin == tapped.privateOrigin && it.owner == tapped.owner &&
            it.draft == tapped.draft && it.forceMac == tapped.forceMac && it.pendingSend == tapped.pendingSend && it.project == tapped.project &&
            (it.privateOrigin || tappedAccount == currentConnection.account && tappedEpoch == currentConnection.epoch) &&
            (it.owner != null || before.preferences == tappedPreferences && (it.privateOrigin || currentConnection.selectedMac == tappedConnection.selectedMac && currentConnection.route(tappedPreferences.provider)?.id == tappedRoute)) &&
            before.attachments[it.id].orEmpty() == tappedFiles } ?: return@withLock
        val text = chat.draft.trim()
        val files = before.attachments[chat.id].orEmpty()
        if (text.isEmpty() && files.isEmpty()) return@withLock
        if (chat.delivery == DeliveryState.QUEUED || chat.delivery == DeliveryState.ANSWERING && chat.owner == null) return@withLock
        val onDevice = chat.privateOrigin || (chat.project == null && chat.owner == null && !chat.forceMac && (chat.page != null || chat.ephemeral) && before.preferences.pageAnswers == PageAnswerMode.DEVICE && files.isEmpty())
        if (chat.privateOrigin && files.isNotEmpty()) { showError("Private conversations stay on this device"); return@withLock }
        val command = if (!onDevice) {
            val connection = currentConnection
            val account = connection.account ?: run { showError("Join your Mac to ask its agent"); return@withLock }
            val provider = chat.owner?.provider ?: before.preferences.provider
            val mac = if (chat.owner != null) connection.macs.firstOrNull { it.id == chat.owner.mac && chat.owner.account == account }
                else connection.route(provider)
            if (mac == null) { showError("Choose an available Mac for this agent"); return@withLock }
            val project = chat.project.takeIf { chat.owner == null }
            val projectLease = project?.let {
                if (sourceCurrent == null || !canStartInProject(it)) { showError(ChatProjectLease.CHANGED); return@withLock }
                val snapshot = projects.value
                ChatProjectLease(ChatProjectLease.Kind.SEND, snapshot, chat, it, mac.id, provider) {
                    sourceCurrent() && projects.value == snapshot && !mutable.value.privateContext && mutable.value.chats.singleOrNull { live -> live.id == chat.id }?.let { live ->
                        live.owner == chat.owner && live.project == chat.project && !live.privateOrigin
                    } == true
                }.takeIf { lease -> lease.current(projects.value, currentConnection) } ?: return@withLock
            }
            AgentSendCommand(UUID.randomUUID().toString(), chat.id, account, mac.id, provider, chat.owner,
                LocalQuestion(text, chat.page, chat.messages), files, selection, connection.epoch, project, projectLease)
        } else null
        val user = AgentMessage(command?.id ?: UUID.randomUUID().toString(), MessageRole.USER, text, System.currentTimeMillis(), files = files.map { it.file })
        edit(chat.id) { it.copy(
            messages = it.messages + user,
            draft = "",
            title = if (it.messages.isEmpty()) text.ifEmpty { files.first().file.name }.take(80) else it.title,
            delivery = DeliveryState.ANSWERING,
            pendingSend = null,
            updatedAt = user.at,
            ephemeral = it.ephemeral && it.messages.none { message -> message.role == MessageRole.ASSISTANT },
        ) }
        try {
            if (onDevice) {
                val reply = local.answer(LocalQuestion(text, chat.page, chat.messages))
                require(reply.isNotBlank()) { "On-device AI returned no answer. This question stayed on this device." }
                edit(chat.id) { it.copy(messages = it.messages + AgentMessage(UUID.randomUUID().toString(), MessageRole.ASSISTANT, reply,
                    System.currentTimeMillis(), AnswerOrigin.DEVICE), delivery = DeliveryState.IDLE, unread = mutable.value.activeChat != chat.id) }
            } else {
                val receipt = remote.send(checkNotNull(command))
                receipt.owner?.let { owner -> require(owner.account == command.account && owner.mac == command.mac && owner.provider == command.provider) { "The Mac returned a different conversation owner" } }
                edit(chat.id) { current ->
                    val observed = receipt.send?.let { sent -> remote.sends.value.firstOrNull { it.id == sent.id && it.account == command.account && it.epoch == command.expectedEpoch } }
                    val adopted = current.pendingSend?.takeIf { it.id == command.id }
                    current.copy(owner = receipt.owner ?: current.owner, ephemeral = false, pendingSend = if (receipt.send != null && observed == null) null else adopted ?: observed,
                        delivery = if (receipt.send != null && observed == null) DeliveryState.IDLE else if (adopted != null) current.delivery else when (observed?.state) {
                            MacSendState.TAKEN -> DeliveryState.ANSWERING
                            MacSendState.FAILED, MacSendState.EXPIRED -> DeliveryState.FAILED
                            MacSendState.CANCELLED -> DeliveryState.IDLE
                            else -> DeliveryState.QUEUED
                        })
                }
            }
            mutable.update { state ->
                val remaining = state.attachments[chat.id].orEmpty().filterNot { attached -> files.any { it === attached } }
                state.copy(attachments = if (remaining.isEmpty()) state.attachments - chat.id else state.attachments + (chat.id to remaining))
            }
        } catch (cancelled: CancellationException) {
            fail(chat.id, "This answer was interrupted. Ask again to continue.")
            throw cancelled
        } catch (error: Exception) {
            fail(chat.id, error.message ?: if (onDevice) "This device could not answer. The question stayed here." else "The question could not be sent to your Mac")
        } finally { persist() }
        }
    }

    private fun actionCurrent(chat: AgentChat, expected: RemoteSend, sourceCurrent: (() -> Boolean)? = null): Boolean = sourceCurrent?.invoke() != false && mutable.value.current?.let { current ->
        current.id == chat.id && !current.privateOrigin && current.owner == chat.owner && current.draft == chat.draft &&
            remote.connection.value.let { it.account == expected.account && it.epoch == expected.epoch }
    } == true

    suspend fun dontSend(id: String, sourceCurrent: (() -> Boolean)? = null) {
        val tapped = mutable.value.current?.takeIf { it.id == id && !it.privateOrigin } ?: return
        val expected = tapped.pendingSend?.takeIf { it.state == MacSendState.WAITING } ?: return
        sends.withLock {
            if (!actionCurrent(tapped, expected, sourceCurrent) || mutable.value.current?.pendingSend != expected) return@withLock
            try {
                val draft = remote.cancelSend(expected) { actionCurrent(tapped, expected, sourceCurrent) } ?: error("Your Mac already took this request")
                if (!actionCurrent(tapped, expected, sourceCurrent)) return@withLock
                edit(id) { chat -> chat.copy(draft = draft.words, pendingSend = null, delivery = DeliveryState.IDLE,
                    messages = chat.messages.filterNot { it.id == expected.id || it.id == "${expected.id}/status" }) }
                mutable.update { it.copy(attachments = it.attachments + (id to draft.files)) }; persist()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (actionCurrent(tapped, expected, sourceCurrent)) showError(failure.message ?: "This request could not be taken back") }
        }
    }

    suspend fun askOnOtherMac(id: String, mac: String, sourceCurrent: (() -> Boolean)? = null) {
        val tapped = mutable.value.current?.takeIf { it.id == id && !it.privateOrigin } ?: return
        val expected = tapped.pendingSend?.takeIf { it.state == MacSendState.WAITING } ?: return
        sends.withLock {
            if (!actionCurrent(tapped, expected, sourceCurrent) || mutable.value.current?.pendingSend != expected) return@withLock
            try {
                val target = remote.connection.value.macs.firstOrNull { it.id == mac && it.id != expected.mac && it.availability.phase == MacPhase.UP && expected.provider in it.providers && (expected.files.isEmpty() || it.takesFiles) }
                    ?: error("This Mac is no longer ready")
                val next = UUID.randomUUID().toString()
                val sent = remote.redirectPending(expected, target.id, next) { actionCurrent(tapped, expected, sourceCurrent) } ?: error("Your Mac already took this request")
                if (!actionCurrent(tapped, expected, sourceCurrent)) return@withLock
                require(sent.clientChat == next && sent.mac == target.id && sent.account == expected.account && sent.epoch == expected.epoch)
                val fresh = mutable.value.chats.firstOrNull { it.id == next } ?: AgentChat(next, title = sent.question.take(80).ifBlank { "New chat" }, messages = listOf(AgentMessage(sent.id, MessageRole.USER, sent.question, sent.sentAt, files = sent.files)),
                    delivery = DeliveryState.QUEUED, updatedAt = sent.sentAt, forceMac = true, pendingSend = sent, project = sent.project)
                edit(id) { it.copy(pendingSend = null, delivery = DeliveryState.IDLE, messages = it.messages.filterNot { message -> message.id == expected.id }) }
                mutable.update { it.copy(chats = it.chats.filterNot { chat -> chat.id == next } + fresh, activeChat = next) }; persist()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (actionCurrent(tapped, expected, sourceCurrent)) showError(failure.message ?: "This question could not start on that Mac") }
        }
    }

    suspend fun sendAgain(id: String, sourceCurrent: (() -> Boolean)? = null) {
        val tapped = mutable.value.current?.takeIf { it.id == id && !it.privateOrigin } ?: return
        val expected = tapped.pendingSend?.takeIf { it.state in setOf(MacSendState.FAILED, MacSendState.EXPIRED) } ?: return
        sends.withLock {
            if (!actionCurrent(tapped, expected, sourceCurrent) || mutable.value.current?.pendingSend != expected) return@withLock
            try {
                val sent = remote.resendSend(expected) { actionCurrent(tapped, expected, sourceCurrent) } ?: error("This request changed")
                if (!actionCurrent(tapped, expected, sourceCurrent)) return@withLock
                require(sent.mac == expected.mac && sent.clientChat == expected.clientChat && sent.account == expected.account && sent.epoch == expected.epoch)
                edit(id) { chat -> chat.copy(ephemeral = false, pendingSend = sent, delivery = DeliveryState.QUEUED,
                    messages = chat.messages.filterNot { it.id == sent.id } + AgentMessage(sent.id, MessageRole.USER, sent.question, sent.sentAt, files = sent.files)) }; persist()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (actionCurrent(tapped, expected, sourceCurrent)) showError(failure.message ?: "This question could not be sent again") }
        }
    }

    suspend fun stop(id: String, expected: ChatMutationLease? = null) {
        if (!mutationCurrent(id, expected)) return
        val owner = mutable.value.chats.firstOrNull { it.id == id }?.owner ?: return
        try { if (expected == null) remote.stop(owner) else remote.stop(owner, expected) } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (mutationCurrent(id, expected)) showError(error.message ?: "The Mac could not stop this chat") }
    }

    suspend fun delete(id: String, expected: ChatMutationLease? = null) {
        if (!mutationCurrent(id, expected)) return
        val chat = mutable.value.chats.firstOrNull { it.id == id } ?: return
        if (!canDelete(chat)) { showError("Stop the conversation before deleting it"); return }
        try {
            if (chat.privateOrigin) {
                require(chat.owner == null) { "Private conversations stay on this device" }
                mutable.update { if (!mutationCurrent(id, expected)) it else it.copy(chats = it.chats.filterNot { item -> item.id == id }, activeChat = it.activeChat?.takeUnless { item -> item == id }, attachments = it.attachments - id) }
                return
            }
            var pendingRetracted = false
            val owner = chat.owner
            if (owner != null) {
                if (remote.connection.value.account != owner.account) error("Sync account changed")
                if (remote.connection.value.macs.any { it.id == owner.mac && it.controlsChats }) {
                    if (expected == null) remote.delete(owner) else remote.delete(owner, expected)
                }
            } else if (chat.delivery == DeliveryState.QUEUED) {
                val retracted = if (expected == null) remote.retractPending(chat.id) else remote.retractPending(chat.id, expected)
                if (!retracted) error("Your Mac already took this request. Wait for its conversation.")
                pendingRetracted = true
            }
            if (!mutationCurrent(id, expected, pendingRetracted)) return
            hidden = hidden + (owner?.let(::ownerKey) ?: "local/${chat.id}")
            mutable.update { if (!mutationCurrent(id, expected, pendingRetracted)) it else it.copy(chats = it.chats.filterNot { chat -> chat.id == id }, activeChat = it.activeChat?.takeUnless { chat -> chat == id }, attachments = it.attachments - id) }
            persist(expected)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (mutationCurrent(id, expected)) showError(error.message ?: "The conversation could not be deleted") }
    }

    private fun fail(id: String, text: String) { edit(id) { it.copy(delivery = DeliveryState.FAILED,
        messages = it.messages + AgentMessage(UUID.randomUUID().toString(), MessageRole.FAILURE, text, System.currentTimeMillis())) } }
    private fun edit(id: String, expected: ChatMutationLease? = null, operation: (AgentChat) -> AgentChat) {
        mutable.update { state ->
            if (expected != null && !expected.current(state.chats.firstOrNull { it.id == id }, remote.connection.value)) state
            else state.copy(chats = state.chats.map { chat -> if (chat.id == id) operation(chat) else chat })
        }
    }
    private suspend fun persist(expected: ChatMutationLease? = null) = writes.withLock {
        try {
            if (expected != null && !expected.connectionCurrent(remote.connection.value)) return@withLock
            val state = mutable.value
            if (!state.loaded) return@withLock
            store.save(ChatSnapshot(chats = state.chats.filterNot { it.privateOrigin || it.ephemeral }.map { chat ->
                if (chat.delivery == DeliveryState.ANSWERING && chat.owner == null && chat.pendingSend == null) chat.copy(delivery = DeliveryState.FAILED) else chat
            }, preferences = state.preferences, hidden = hidden))
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (expected == null || expected.connectionCurrent(remote.connection.value)) mutable.update { it.copy(error = "Conversations could not be saved: ${error.message ?: "storage unavailable"}") } }
    }
}

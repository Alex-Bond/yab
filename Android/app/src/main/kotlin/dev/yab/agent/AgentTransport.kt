package dev.yab.agent

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class LocalQuestion(val words: String, val page: PageContext?, val history: List<AgentMessage>)

/** Implementations must process the question on this device. Cloud fallback is forbidden. */
interface LocalAiAdapter {
    suspend fun answer(question: LocalQuestion): String
}

class UnavailableLocalAiAdapter : LocalAiAdapter {
    override suspend fun answer(question: LocalQuestion): String = throw AgentUnavailable(
        "On-device AI is not available on this Android device. This question stayed on this device."
    )
}

class AgentUnavailable(message: String) : IllegalStateException(message)

data class RemoteModel(val id: String, val name: String, val provider: AgentProvider, val efforts: List<String> = emptyList())
data class RemoteMac(
    val id: String,
    val name: String,
    val awake: Boolean,
    val providers: Set<AgentProvider>,
    val takesFiles: Boolean = false,
    val controlsChats: Boolean = false,
    val models: List<RemoteModel> = emptyList(),
    val takesMetadata: Boolean = false,
    val availability: MacAvailability = MacAvailability(if (awake) MacPhase.UP else MacPhase.SILENT),
    val lastSeen: Long? = null,
    val usedAt: Long? = null,
    val frontTab: String? = null,
    val takesProjects: Boolean = false,
)
data class RemoteConnection(val account: String? = null, val macs: List<RemoteMac> = emptyList(), val selectedMac: String? = null, val epoch: Long = 0) {
    fun route(provider: AgentProvider): RemoteMac? {
        val eligible = macs.filter { provider in it.providers }
        return MacRouting.pick(eligible, selectedMac)
    }
}

data class ModelSelection(val model: String? = null, val effort: String? = null)
data class AgentSendCommand(
    val id: String,
    val clientChat: String,
    val account: String,
    val mac: String,
    val provider: AgentProvider,
    val owner: RemoteOwner?,
    val question: LocalQuestion,
    val files: List<PreparedAttachment>,
    val selection: ModelSelection,
    val expectedEpoch: Long? = null,
    val project: String? = null,
    val projectLease: ChatProjectLease? = null,
)
data class AgentSendReceipt(val owner: RemoteOwner? = null, val send: RemoteSend? = null)
data class RemoteConversation(val clientChat: String?, val owner: RemoteOwner, val title: String, val messages: List<AgentMessage>, val working: Boolean,
                              val pinned: Boolean = false, val archived: Boolean = false, val unread: Boolean = false,
                              val updatedAt: Long = 0, val remoteState: String = "done", val choices: List<String> = emptyList(), val metadataKnown: Boolean = false,
                              val origin: String? = null, val routine: String? = null, val project: String? = null)

/** A boundary for the encrypted SyncKit-compatible implementation, not a new unencrypted API. */
interface AgentSyncPort {
    val connection: StateFlow<RemoteConnection>
    val projects: StateFlow<ChatProjectsSnapshot> get() = noRemoteProjects
    /** Optional read-only identity for the approval-only external credential return flow. */
    fun approvalAuthenticationIdentity(): ApprovalAuthenticationIdentity? = null
    val conversations: Flow<List<RemoteConversation>>
    suspend fun send(command: AgentSendCommand): AgentSendReceipt
    suspend fun stop(owner: RemoteOwner)
    suspend fun delete(owner: RemoteOwner)
    suspend fun answerApproval(answer: ApprovalAnswer)
    suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags): Boolean = false
    suspend fun retractPending(clientChat: String): Boolean = false
    // A legacy port must not turn a guarded action into an unguarded suspended write.
    suspend fun stop(owner: RemoteOwner, expected: ChatMutationLease): Unit = throw AgentUnavailable("Guarded chat control is unavailable")
    suspend fun delete(owner: RemoteOwner, expected: ChatMutationLease): Unit = throw AgentUnavailable("Guarded chat control is unavailable")
    suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags, expected: ChatMutationLease): Boolean = throw AgentUnavailable("Guarded chat metadata is unavailable")
    suspend fun retractPending(clientChat: String, expected: ChatMutationLease): Boolean = throw AgentUnavailable("Guarded chat cancellation is unavailable")
    suspend fun moveToProject(owner: RemoteOwner, project: String?, expected: ChatProjectLease): Boolean =
        throw AgentUnavailable("Guarded project moves are unavailable")
    val sends: StateFlow<List<RemoteSend>> get() = noRemoteSends
    suspend fun cancelSend(expected: RemoteSend, sourceCurrent: () -> Boolean): MacSendDraft? = null
    suspend fun redirectPending(expected: RemoteSend, mac: String, clientChat: String, sourceCurrent: () -> Boolean): RemoteSend? = null
    suspend fun resendSend(expected: RemoteSend, sourceCurrent: () -> Boolean): RemoteSend? = null
    val approvalResults: StateFlow<List<ApprovalResult>> get() = noApprovalResults
    fun forgetApprovalResult(id: String) {}
}
private val noApprovalResults = MutableStateFlow<List<ApprovalResult>>(emptyList())
private val noRemoteSends = MutableStateFlow<List<RemoteSend>>(emptyList())
private val noRemoteProjects = MutableStateFlow(ChatProjectsSnapshot())

interface RemoteAgentTransport : AgentSyncPort

/** Checks the captured route a second time immediately before the sync write. */
class SyncProtocolTransport(private val port: AgentSyncPort) : RemoteAgentTransport {
    override val connection get() = port.connection
    override val projects get() = port.projects
    override fun approvalAuthenticationIdentity() = port.approvalAuthenticationIdentity()
    override val conversations get() = port.conversations
    override val approvalResults get() = port.approvalResults
    override val sends get() = port.sends
    override fun forgetApprovalResult(id: String) = port.forgetApprovalResult(id)
    override suspend fun send(command: AgentSendCommand): AgentSendReceipt {
        require(command.question.page?.isPrivate != true) { "Private pages stay on this device" }
        val current = connection.value
        require(current.account == command.account) { "Sync account changed. Send again." }
        require(command.expectedEpoch == null || command.expectedEpoch == current.epoch) { "Sync session changed. Send again." }
        val mac = current.macs.firstOrNull { it.id == command.mac } ?: throw AgentUnavailable("This Mac is no longer available")
        require(command.provider in mac.providers) { "Update Yab on your Mac to use this agent" }
        require(command.files.isEmpty() || mac.takesFiles) { "Update Yab on your Mac to send files" }
        command.project?.let {
            val lease = command.projectLease ?: throw AgentUnavailable(ChatProjectLease.CHANGED)
            lease.requireKind(ChatProjectLease.Kind.SEND)
            require(command.owner == null && lease.project == it && lease.mac == command.mac && lease.provider == command.provider &&
                lease.chat?.id == command.clientChat && lease.current(projects.value, current)) { ChatProjectLease.CHANGED }
        }
        command.selection.model?.let { id ->
            val model = mac.models.firstOrNull { it.id == id && it.provider == command.provider }
                ?: throw AgentUnavailable("This model is no longer offered by your Mac")
            require(command.selection.effort == null || command.selection.effort in model.efforts) { "This reasoning level is no longer offered by your Mac" }
        }
        command.owner?.let {
            require(it.account == command.account && it.mac == command.mac && it.provider == command.provider) { "This conversation's owner changed" }
        }
        AttachmentLimits.validate(command.files.map { it.bytes.size })
        return port.send(command)
    }
    override suspend fun stop(owner: RemoteOwner) { checkOwner(owner); port.stop(owner) }
    override suspend fun delete(owner: RemoteOwner) { checkOwner(owner); port.delete(owner) }
    override suspend fun answerApproval(answer: ApprovalAnswer) {
        require(connection.value.account == answer.request.account) { "Sync account changed" }
        port.answerApproval(answer)
    }
    override suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags): Boolean { checkAccount(owner); return port.patchChat(owner, flags) }
    override suspend fun retractPending(clientChat: String): Boolean = port.retractPending(clientChat)
    override suspend fun stop(owner: RemoteOwner, expected: ChatMutationLease) {
        require(expected.connectionCurrent(connection.value)) { ChatMutationLease.CHANGED }
        expected.requireOwner(owner); checkOwner(owner); port.stop(owner, expected)
    }
    override suspend fun delete(owner: RemoteOwner, expected: ChatMutationLease) {
        require(expected.connectionCurrent(connection.value)) { ChatMutationLease.CHANGED }
        expected.requireOwner(owner); checkOwner(owner); port.delete(owner, expected)
    }
    override suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags, expected: ChatMutationLease): Boolean {
        require(expected.connectionCurrent(connection.value)) { ChatMutationLease.CHANGED }
        expected.requireOwner(owner); checkAccount(owner); return port.patchChat(owner, flags, expected)
    }
    override suspend fun retractPending(clientChat: String, expected: ChatMutationLease): Boolean {
        require(expected.connectionCurrent(connection.value) && expected.chat.id == clientChat && expected.chat.owner == null && !expected.chat.privateOrigin) { ChatMutationLease.CHANGED }
        return port.retractPending(clientChat, expected)
    }
    override suspend fun moveToProject(owner: RemoteOwner, project: String?, expected: ChatProjectLease): Boolean {
        expected.requireKind(ChatProjectLease.Kind.MOVE)
        val chat = expected.chat ?: throw AgentUnavailable(ChatProjectLease.CHANGED)
        require(chat.owner == owner && !chat.privateOrigin && expected.project == project &&
            expected.current(projects.value, connection.value)) { ChatProjectLease.CHANGED }
        return port.moveToProject(owner, project, expected)
    }
    override suspend fun cancelSend(expected: RemoteSend, sourceCurrent: () -> Boolean): MacSendDraft? { checkSend(expected); return port.cancelSend(expected, sourceCurrent) }
    override suspend fun redirectPending(expected: RemoteSend, mac: String, clientChat: String, sourceCurrent: () -> Boolean): RemoteSend? { checkSend(expected); return port.redirectPending(expected, mac, clientChat, sourceCurrent) }
    override suspend fun resendSend(expected: RemoteSend, sourceCurrent: () -> Boolean): RemoteSend? { checkSend(expected); return port.resendSend(expected, sourceCurrent) }
    private fun checkSend(send: RemoteSend) { require(connection.value.let { it.account == send.account && it.epoch == send.epoch } && sends.value.any { it == send }) { "This request changed. Open it again." } }
    private fun checkAccount(owner: RemoteOwner) { require(connection.value.account == owner.account && connection.value.macs.any { it.id == owner.mac }) { "This conversation's account or Mac changed" } }
    private fun checkOwner(owner: RemoteOwner) {
        require(connection.value.account == owner.account) { "Sync account changed" }
        require(connection.value.macs.any { it.id == owner.mac && it.controlsChats }) { "This Mac cannot control this chat from here" }
    }
}

object DisconnectedRemoteTransport : RemoteAgentTransport {
    override val connection = MutableStateFlow(RemoteConnection())
    override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
    override suspend fun send(command: AgentSendCommand): AgentSendReceipt = throw AgentUnavailable("Join your Mac to ask its agent")
    override suspend fun stop(owner: RemoteOwner): Unit = throw AgentUnavailable("Join your Mac first")
    override suspend fun delete(owner: RemoteOwner): Unit = throw AgentUnavailable("Join your Mac first")
    override suspend fun answerApproval(answer: ApprovalAnswer): Unit = throw AgentUnavailable("Join your Mac first")
}

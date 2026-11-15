package dev.yab.agent

import dev.yab.core.sync.ChatAgent
import kotlinx.serialization.Serializable

@Serializable enum class MessageRole { USER, ASSISTANT, NOTE, FAILURE, WORK }
@Serializable enum class AnswerOrigin { DEVICE, MAC }
@Serializable enum class PageAnswerMode { DEVICE, MAC }
/** Keep the existing uppercase stored enum names; only Sync wire names are lowercase. */
@Serializable enum class AgentProvider(val protocol: ChatAgent) {
    CLAUDE(ChatAgent.CLAUDE), CODEX(ChatAgent.CODEX), CURSOR(ChatAgent.CURSOR), GEMINI(ChatAgent.GEMINI);
    val wire: String get() = protocol.wire
    val displayName: String get() = protocol.plan
    companion object {
        fun fromWire(value: String?): AgentProvider? = entries.firstOrNull { it.wire == value }
    }
}
@Serializable enum class DeliveryState { IDLE, ANSWERING, QUEUED, FAILED }

@Serializable
data class AgentPreferences(
    val pageAnswers: PageAnswerMode = PageAnswerMode.DEVICE,
    val provider: AgentProvider = AgentProvider.CLAUDE,
)

@Serializable
data class PageContext(val title: String, val url: String, val text: String, val isPrivate: Boolean = false)

@Serializable
data class ChatFile(val name: String, val mime: String, val size: Int, val digest: String)

/** Accepted ownership is part of the conversation, never inferred from today's preference. */
@Serializable
data class RemoteOwner(val account: String, val mac: String, val chat: String, val provider: AgentProvider)

@Serializable
data class AgentMessage(
    val id: String,
    val role: MessageRole,
    val text: String,
    val at: Long,
    val origin: AnswerOrigin? = null,
    val files: List<ChatFile> = emptyList(),
    val work: ChatWork? = null,
    val cards: List<ChatResultCard> = emptyList(),
    val handed: ChatHanded? = null,
)

@Serializable
data class AgentChat(
    val id: String,
    val title: String = "New chat",
    val messages: List<AgentMessage> = emptyList(),
    val draft: String = "",
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val unread: Boolean = false,
    val privateOrigin: Boolean = false,
    val page: PageContext? = null,
    val owner: RemoteOwner? = null,
    val delivery: DeliveryState = DeliveryState.IDLE,
    val updatedAt: Long = 0,
    val remoteState: String? = null,
    val choices: List<String> = emptyList(),
    val ephemeral: Boolean = false,
    val pendingFlags: ChatFlags = ChatFlags(),
    val reading: ChatReading? = null,
    val forceMac: Boolean = false,
    val pendingSend: RemoteSend? = null,
    /** Raw Mac provenance. Nil is the person's chat; unknown nonnil values stay distinct. */
    val origin: String? = null,
    val routine: String? = null,
    val project: String? = null,
)

@Serializable data class ChatFlags(val pinned: Boolean? = null, val archived: Boolean? = null, val unread: Boolean? = null, val title: String? = null)
@Serializable data class ChatReading(val message: String, val offset: Int, val atBottom: Boolean)
@Serializable data class ChatSnapshot(val version: Int = 1, val chats: List<AgentChat> = emptyList(), val preferences: AgentPreferences = AgentPreferences(), val hidden: Set<String> = emptySet())

data class PreparedAttachment(val file: ChatFile, val bytes: ByteArray)

data class AgentState(
    val chats: List<AgentChat> = emptyList(),
    val activeChat: String? = null,
    val privateContext: Boolean = false,
    val preferences: AgentPreferences = AgentPreferences(),
    val attachments: Map<String, List<PreparedAttachment>> = emptyMap(),
    val connection: RemoteConnection = RemoteConnection(),
    val error: String? = null,
    val loaded: Boolean = false,
    val projects: ChatProjectsSnapshot = ChatProjectsSnapshot(),
) {
    val current: AgentChat? get() = chats.firstOrNull { it.id == activeChat && it.privateOrigin == privateContext &&
        (it.owner == null || it.owner.account == connection.account) && (it.pendingSend == null || it.pendingSend.account == connection.account) }
    fun listed(query: String = "", archived: Boolean = false): List<AgentChat> = chats
        .filter { it.privateOrigin == privateContext && !it.ephemeral && (if (query.isBlank()) it.archived == archived else true) }
        .filter { it.owner == null || it.owner.account == connection.account }
        .filter { it.pendingSend == null || it.pendingSend.account == connection.account }
        .filter { query.isBlank() || it.title.contains(query, true) || it.messages.any { message -> message.text.contains(query, true) } }
        .sortedWith(compareByDescending<AgentChat> { it.pinned }.thenByDescending { it.updatedAt })
}

@Serializable enum class MacSendState { WAITING, PROCESSING, TAKEN, FAILED, EXPIRED, CANCELLED }
/** A checked status of one actual encrypted send, including requests that do not have a Mac chat yet. */
@Serializable data class RemoteSend(val account: String, val epoch: Long, val id: String, val clientChat: String,
    val mac: String, val provider: AgentProvider, val sentAt: Long, val state: MacSendState, val question: String,
    val files: List<ChatFile> = emptyList(), val fingerprint: String, val chat: String? = null, val reason: String? = null, val tookAt: Long? = null,
    val project: String? = null)
data class MacSendDraft(val words: String, val files: List<PreparedAttachment>, val provider: AgentProvider)
data class AttachmentLease(val chat: String, val owner: RemoteOwner?, val account: String, val epoch: Long,
    val pendingFingerprint: String?, val mac: String, val provider: AgentProvider)

object AttachmentLimits {
    const val COUNT = 10
    const val EACH = 10_000_000
    const val TOTAL = 20_000_000
    fun validate(sizes: List<Int>) {
        require(sizes.size <= COUNT) { "Up to 10 files at a time" }
        require(sizes.all { it in 0..EACH }) { "A file can be up to 10 MB" }
        require(sizes.sumOf { it.toLong() } <= TOTAL) { "Up to 20 MB at a time" }
    }
}

package dev.yab.agent

import dev.yab.core.sync.SyncProject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** RAM-only navigation. Project drafts belong to a cover, never to a rendered action key. */
class ChatProjectsPresentation {
    class Owner internal constructor(val presence: ChatProjectPresence, val account: String, val device: String,
        val epoch: Long, private val source: () -> Boolean) {
        private var retired = false
        fun current(snapshot: ChatProjectsSnapshot, connection: RemoteConnection): Boolean {
            if (retired) return false
            val valid = snapshot.account == account && snapshot.device == device && snapshot.epoch == epoch &&
                snapshot.matches(connection) && presence.current(snapshot) && runCatching(source).getOrDefault(false)
            if (!valid) retired = true
            return valid
        }
        internal fun retire() { retired = true }
    }
    class Conversation(val id: String, val privateOrigin: Boolean, val owner: RemoteOwner?) {
        private var acceptedOwner = owner
        private var retired = false
        internal fun current(chat: AgentChat?, account: String): Boolean {
            if (retired) return false
            val valid = chat != null && chat.id == id && !chat.privateOrigin &&
                (acceptedOwner?.let { chat.owner == it } ?: (chat.owner == null || chat.owner.account == account)) &&
                (chat.pendingSend == null || chat.pendingSend.account == account)
            if (!valid) retired = true else if (acceptedOwner == null && chat?.owner != null) acceptedOwner = chat.owner
            return valid
        }
    }
    data class Frame internal constructor(val owner: Owner, val info: Boolean = false, val conversation: Conversation? = null,
        val focus: Long = 0) { val project: String get() = owner.presence.id }
    class Control internal constructor(internal val frame: Frame, internal val snapshot: ChatProjectsSnapshot,
        private val originalCurrent: () -> Boolean) {
        private var retired = false
        fun current(): Boolean {
            if (retired) return false
            if (!runCatching(originalCurrent).getOrDefault(false)) { retired = true; return false }
            return true
        }
    }
    private val mutable = MutableStateFlow<Frame?>(null)
    val frame: StateFlow<Frame?> = mutable.asStateFlow()
    private val navigation = MutableStateFlow(0L)
    val revision: StateFlow<Long> = navigation.asStateFlow()
    private fun publish(next: Frame?) {
        if (mutable.value == next) return
        navigation.value = navigation.value + 1
        mutable.value = next
    }
    private val words = MutableStateFlow("")
    val draft: StateFlow<String> = words.asStateFlow()
    fun open(snapshot: ChatProjectsSnapshot, connection: RemoteConnection, project: String, sourceCurrent: () -> Boolean): Boolean {
        val presence = snapshot.presence(project) ?: return false
        val account = snapshot.account ?: return false; val device = snapshot.device ?: return false
        val owner = Owner(presence, account, device, snapshot.epoch, sourceCurrent)
        if (!owner.current(snapshot, connection)) return false
        mutable.value?.owner?.retire()
        words.value = ""
        publish(Frame(owner))
        return true
    }
    fun current(frame: Frame, snapshot: ChatProjectsSnapshot, connection: RemoteConnection): Boolean =
        mutable.value?.owner === frame.owner && frame.owner.current(snapshot, connection)
    fun observe(snapshot: ChatProjectsSnapshot, connection: RemoteConnection) {
        val frame = mutable.value ?: return
        if (!current(frame, snapshot, connection)) { frame.owner.retire(); publish(null); words.value = "" }
    }
    fun control(snapshot: ChatProjectsSnapshot, connection: () -> RemoteConnection, latest: () -> ChatProjectsSnapshot,
        originalActionCurrent: () -> Boolean = { true }): Control? {
        val frame = mutable.value ?: return null
        if (!current(frame, snapshot, connection())) return null
        return Control(frame, snapshot) { mutable.value === frame && latest() == snapshot &&
            originalActionCurrent() && current(frame, latest(), connection()) }
    }
    fun close(control: Control): Boolean {
        if (!control.current()) return false
        control.frame.owner.retire(); publish(null); words.value = ""; return true
    }
    fun info(control: Control, shown: Boolean, focus: Boolean = false): Boolean {
        if (!control.current() || control.frame.conversation != null) return false
        publish(control.frame.copy(info = shown, focus = control.frame.focus + if (focus) 1 else 0)); return true
    }
    fun draft(control: Control, text: String): Boolean {
        if (!control.current() || control.frame.info || control.frame.conversation != null) return false
        words.value = text; return true
    }
    fun conversation(control: Control, chat: AgentChat): Boolean {
        if (!control.current() || chat.privateOrigin || chat.project != control.frame.project || chat.owner?.account?.let { it != control.frame.owner.account } == true) return false
        publish(control.frame.copy(info = false, conversation = Conversation(chat.id, chat.privateOrigin, chat.owner))); return true
    }
    fun conversationCurrent(frame: Frame, chat: AgentChat?, snapshot: ChatProjectsSnapshot, connection: RemoteConnection): Boolean {
        val expected = frame.conversation ?: return false
        return mutable.value === frame && current(frame, snapshot, connection) && expected.current(chat, frame.owner.account)
    }
    fun backFromChat(control: Control): Boolean {
        if (!control.current() || control.frame.conversation == null) return false
        publish(control.frame.copy(conversation = null)); return true
    }
    fun clearDraft(control: Control): Boolean { if (!control.current()) return false; words.value = ""; return true }
}

/** The Phone's newest-member rank, with unknown and archived project references kept as chats. */
sealed interface FieldProjectCard {
    data class Chat(val chat: AgentChat) : FieldProjectCard
    data class Project(val project: SyncProject, val chats: List<AgentChat>) : FieldProjectCard
}

package dev.yab.agent

import java.io.Closeable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/** The in-app Now line holds one RAM-only conversation, independently of the mail widget. */
data class ParkedChat(val chat: String, val account: String?, val privateOrigin: Boolean, val epoch: Long, val generation: Long = 0)

class ParkedChats(private val repository: AgentRepository, private val scope: CoroutineScope) : Closeable {
    private val mutable = MutableStateFlow<ParkedChat?>(null)
    val state: StateFlow<ParkedChat?> = mutable
    private var generation = 0L
    private var closed = false
    private var presentation: ParkedChatPresentation? = null
    internal fun presentation(expected: ParkedChat): ParkedChatPresentation? {
        if (closed || mutable.value != expected) return null
        val current = presentation?.takeIf { it.owner == expected } ?: return null
        if (current.frame.value.phase == ParkedLinePhase.REVOKED) presentation = ParkedChatPresentation(expected)
        return presentation
    }

    private fun clear() { generation++; presentation?.revoke(); presentation = null; mutable.value = null }
    private val observer: Job = scope.launch {
        repository.state.collect { source ->
            mutable.value?.let { item -> if (resolve(item, source, item.privateOrigin) == null) clear() }
        }
    }

    fun visible(privateContext: Boolean): AgentChat? = mutable.value?.let { visible(it, privateContext) }
    fun visible(expected: ParkedChat, privateContext: Boolean): AgentChat? =
        if (closed || mutable.value != expected) null else resolve(expected, repository.state.value, privateContext)

    /** Replacing the line lets go of the previous quick answer, as on iOS. */
    fun park(): Boolean {
        if (closed) return false
        val source = repository.state.value
        val chat = source.current ?: return false
        val previous = mutable.value
        presentation?.revoke()
        val item = ParkedChat(chat.id, source.connection.account, chat.privateOrigin, source.connection.epoch, ++generation)
        presentation = ParkedChatPresentation(item)
        mutable.value = item
        if (previous != null && previous.chat != chat.id) forgetIfEphemeral(previous, generation)
        return true
    }

    fun restore(privateContext: Boolean): Boolean = mutable.value?.let { restore(it, privateContext) } ?: false
    fun restore(item: ParkedChat, privateContext: Boolean): Boolean {
        if (visible(item, privateContext) == null) return false
        repository.setPrivacy(privateContext)
        if (!repository.focusConversation(item.chat)) return false
        clear()
        return true
    }

    fun letGo(privateContext: Boolean): Boolean = mutable.value?.let { letGo(it, privateContext) } ?: false
    fun letGo(item: ParkedChat, privateContext: Boolean): Boolean {
        if (visible(item, privateContext) == null) return false
        clear()
        forgetIfEphemeral(item, generation)
        return true
    }

    private fun forgetIfEphemeral(item: ParkedChat, scheduledGeneration: Long) {
        scope.launch {
            if (closed || generation != scheduledGeneration || mutable.value?.chat == item.chat) return@launch
            val source = repository.state.value
            val chat = resolve(item, source, item.privateOrigin) ?: return@launch
            if (chat.ephemeral) repository.delete(chat.id)
            else repository.markUnread(chat.id, false)
        }
    }

    override fun close() { closed = true; observer.cancel(); clear() }

    companion object {
        fun resolve(item: ParkedChat, source: AgentState, privateContext: Boolean): AgentChat? {
            if (item.account != source.connection.account || item.epoch != source.connection.epoch || item.privateOrigin != privateContext) return null
            return source.chats.firstOrNull { it.id == item.chat && it.privateOrigin == privateContext &&
                (it.owner == null || it.owner.account == source.connection.account) }
        }
    }
}

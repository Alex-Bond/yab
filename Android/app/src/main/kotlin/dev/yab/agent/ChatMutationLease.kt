package dev.yab.agent

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/** A user action keeps the original chat and source, including a same-account Sync session.
 * sourceCurrent must check live authority/input, not optimistic chat flags changed by this action.
 */
class ChatMutationLease(val chat: AgentChat, val account: String?, val device: String?, val epoch: Long,
    sourceCurrent: () -> Boolean) {
    private val source = sourceCurrent
    fun sourceCurrent(): Boolean = runCatching(source).getOrDefault(false)
    fun connectionCurrent(connection: RemoteConnection): Boolean = connection.account == account &&
        connection.epoch == epoch && sourceCurrent()

    fun matches(live: AgentChat, pendingRetracted: Boolean = false): Boolean =
        live.id == chat.id && live.owner == chat.owner && live.privateOrigin == chat.privateOrigin &&
            (pendingIdentity(live.pendingSend) == pendingIdentity(chat.pendingSend) ||
                pendingRetracted && live.pendingSend == null && chat.pendingSend != null)

    fun current(live: AgentChat?, connection: RemoteConnection, pendingRetracted: Boolean = false): Boolean =
        live != null && matches(live, pendingRetracted) && connectionCurrent(connection)

    internal fun requireOwner(owner: RemoteOwner) {
        require(chat.owner == owner && !chat.privateOrigin && owner.account == account) { CHANGED }
    }
    internal fun requireIdentity(identity: ChatMutationIdentity?) {
        require(identity != null && identity.account == account && identity.device == device && identity.epoch == epoch && sourceCurrent()) { CHANGED }
    }

    private fun pendingIdentity(send: RemoteSend?): List<Any>? = send?.let {
        listOf(it.account, it.epoch, it.id, it.clientChat, it.mac, it.provider, it.fingerprint)
    }
    internal companion object { const val CHANGED = "The chat or its Sync session changed. Open it again." }
}

internal data class ChatMutationIdentity(val account: String, val device: String, val epoch: Long)

/** The production Bridge and queued-dispatch tests use this same admission boundary. */
internal suspend fun <T> dispatchChatMutation(dispatcher: CoroutineDispatcher, expected: ChatMutationLease?,
    identity: () -> ChatMutationIdentity?, operation: suspend () -> T): T = withContext(dispatcher) {
    expected?.requireIdentity(identity())
    operation()
}

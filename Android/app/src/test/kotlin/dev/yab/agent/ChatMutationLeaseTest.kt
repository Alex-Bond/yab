package dev.yab.agent

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatMutationLeaseTest {
    private val owner = RemoteOwner("account", "mac", "a:chat", AgentProvider.CLAUDE)
    private val chat = AgentChat("chat", owner = owner)
    private fun lease(chat: AgentChat = this.chat, current: () -> Boolean = { true }) =
        ChatMutationLease(chat, "account", "phone", 1, current)
    private class Memory(chat: AgentChat) : ChatPersistence {
        var snapshot = ChatSnapshot(chats = listOf(chat))
        var saves = 0
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: ChatSnapshot) { saves++; this.snapshot = snapshot }
    }
    private class Port(private val dispatcher: CoroutineDispatcher) : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Fixture Mac", true,
            setOf(AgentProvider.CLAUDE), controlsChats = true, takesMetadata = true)), epoch = 1))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override val sends = MutableStateFlow(emptyList<RemoteSend>())
        var identity: ChatMutationIdentity? = ChatMutationIdentity("account", "phone", 1)
        var patches = 0
        var controls = 0
        var retractions = 0
        var legacy = 0
        var patchResult = true
        var entered: CompletableDeferred<Unit>? = null
        var finish: CompletableDeferred<Unit>? = null
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("No provider in mutation fixture")
        override suspend fun answerApproval(answer: ApprovalAnswer) = error("No approvals in mutation fixture")
        override suspend fun stop(owner: RemoteOwner) { legacy++ }
        override suspend fun delete(owner: RemoteOwner) { legacy++ }
        override suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags): Boolean { legacy++; return true }
        private suspend fun pause() { entered?.complete(Unit); finish?.await() }
        override suspend fun stop(owner: RemoteOwner, expected: ChatMutationLease) = dispatchChatMutation(dispatcher, expected, { identity }) {
            expected.requireOwner(owner); controls++; pause()
        }
        override suspend fun delete(owner: RemoteOwner, expected: ChatMutationLease) = stop(owner, expected)
        override suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags, expected: ChatMutationLease): Boolean =
            dispatchChatMutation(dispatcher, expected, { identity }) { expected.requireOwner(owner); patches++; pause(); patchResult }
        override suspend fun retractPending(clientChat: String, expected: ChatMutationLease): Boolean =
            dispatchChatMutation(dispatcher, expected, { identity }) { retractions++; pause(); true }
    }
    private suspend fun repository(chat: AgentChat, disk: Memory, port: Port): AgentRepository =
        AgentRepository(disk, UnavailableLocalAiAdapter(), SyncProtocolTransport(port)).also { it.load() }

    @Test fun actualDispatcherAdmissionRejectsQueuedReconnectDeviceChangeAndRevokedSource() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        var writes = 0
        for (replacement in listOf(ChatMutationIdentity("account", "phone", 2), ChatMutationIdentity("account", "other-phone", 1),
            ChatMutationIdentity("other-account", "phone", 1), null)) {
            var identity: ChatMutationIdentity? = ChatMutationIdentity("account", "phone", 1)
            val result = async(start = CoroutineStart.UNDISPATCHED) {
                runCatching { dispatchChatMutation(dispatcher, lease(), { identity }) { writes++ } }
            }
            identity = replacement
            runCurrent()
            assertTrue(result.await().isFailure)
        }
        var current = true
        val revoked = lease { current }
        val result = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching { dispatchChatMutation(dispatcher, revoked, { ChatMutationIdentity("account", "phone", 1) }) { writes++ } }
        }
        current = false; runCurrent()
        assertTrue(result.await().isFailure)
        assertEquals(0, writes)
        val accepted = async(start = CoroutineStart.UNDISPATCHED) {
            dispatchChatMutation(dispatcher, lease(), { ChatMutationIdentity("account", "phone", 1) }) { writes++ }
        }
        runCurrent(); accepted.await(); assertEquals(1, writes)
    }

    @Test fun rejectedQueuedMetadataNeverCreatesAnOverrideForTheReconnectFlusher() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); val disk = Memory(chat)
        val repo = repository(chat, disk, port)
        val action = launch(start = CoroutineStart.UNDISPATCHED) { repo.pin(chat.id, lease()) }
        port.identity = ChatMutationIdentity("account", "phone", 2)
        port.connection.value = port.connection.value.copy(epoch = 2)
        runCurrent(); action.join()
        assertEquals(0, port.patches); assertEquals(0, port.legacy)
        assertFalse(repo.state.value.chats.single().pinned)
        assertEquals(ChatFlags(), repo.state.value.chats.single().pendingFlags)
        assertEquals(0, disk.saves); assertNull(repo.state.value.error)
    }

    @Test fun acceptedRemotePatchCannotApplyLocalFlagsAfterSourceRevocation() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); val disk = Memory(chat)
        port.entered = CompletableDeferred(); port.finish = CompletableDeferred()
        val repo = repository(chat, disk, port)
        var current = true
        val action = launch { repo.rename(chat.id, "Synthetic replacement", lease { current }) }
        runCurrent(); assertTrue(port.entered!!.isCompleted)
        current = false; port.finish!!.complete(Unit)
        runCurrent(); action.join()
        assertEquals(1, port.patches)
        assertEquals(chat, repo.state.value.chats.single())
        assertEquals(0, disk.saves)
    }

    @Test fun falseMetadataAdmissionCannotCreateAnOverrideOrBecomeALegacyReconnectWrite() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); val disk = Memory(chat)
        port.patchResult = false
        val repo = repository(chat, disk, port)
        val action = launch { repo.pin(chat.id, lease()) }
        runCurrent(); action.join()
        assertEquals(1, port.patches)
        assertFalse(repo.state.value.chats.single().pinned)
        assertEquals(ChatFlags(), repo.state.value.chats.single().pendingFlags)
        assertEquals(0, disk.saves)
        port.identity = ChatMutationIdentity("account", "phone", 2)
        port.connection.value = port.connection.value.copy(epoch = 2)
        backgroundScope.launch { repo.run() }; runCurrent()
        assertEquals(0, port.legacy)
        assertEquals(ChatFlags(), repo.state.value.chats.single().pendingFlags)
    }

    @Test fun acceptedRemoteDeleteCannotHideOrRemoveTheChatAfterReconnect() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); val disk = Memory(chat)
        port.entered = CompletableDeferred(); port.finish = CompletableDeferred()
        val repo = repository(chat, disk, port)
        val action = launch { repo.delete(chat.id, lease()) }
        runCurrent(); assertTrue(port.entered!!.isCompleted)
        port.identity = ChatMutationIdentity("account", "phone", 2)
        port.connection.value = port.connection.value.copy(epoch = 2)
        port.finish!!.complete(Unit); runCurrent(); action.join()
        assertEquals(1, port.controls)
        assertEquals(chat, repo.state.value.chats.single())
        assertTrue(disk.snapshot.hidden.isEmpty()); assertEquals(0, disk.saves)
    }

    @Test fun currentGuardedMetadataAndDeleteReachThePortAndPersistTheirActualLocalResult() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); val disk = Memory(chat)
        val repo = repository(chat, disk, port)
        val action = launch {
            repo.pin(chat.id, lease(repo.state.value.chats.single()))
            repo.markUnread(chat.id, true, lease(repo.state.value.chats.single()))
            repo.rename(chat.id, "Synthetic renamed chat", lease(repo.state.value.chats.single()))
            repo.archive(chat.id, lease(repo.state.value.chats.single()))
        }
        runCurrent(); action.join()
        val changed = disk.snapshot.chats.single()
        assertTrue(changed.pinned); assertTrue(changed.unread); assertTrue(changed.archived)
        assertEquals("Synthetic renamed chat", changed.title)
        assertEquals(4, port.patches); assertEquals(0, port.legacy)
        val deletion = launch { repo.delete(chat.id, lease(repo.state.value.chats.single())) }
        runCurrent(); deletion.join()
        assertEquals(1, port.controls)
        assertTrue(repo.state.value.chats.isEmpty()); assertTrue(disk.snapshot.chats.isEmpty())
        assertEquals(setOf("account/mac/a:chat"), disk.snapshot.hidden)
    }

    @Test fun pendingDeleteDoesNotRemoveAConversationAdoptedWhileItsRetractionWasAwaited() = runTest {
        val waiting = RemoteSend("account", 1, "send", "chat", "mac", AgentProvider.CLAUDE, 1,
            MacSendState.WAITING, "Synthetic request", fingerprint = "original")
        val pending = chat.copy(owner = null, pendingSend = waiting, delivery = DeliveryState.QUEUED)
        val port = Port(StandardTestDispatcher(testScheduler)); val disk = Memory(pending)
        port.sends.value = listOf(waiting)
        val repo = repository(pending, disk, port)
        backgroundScope.launch { repo.run() }; runCurrent()
        val captured = repo.state.value.chats.single()
        port.entered = CompletableDeferred(); port.finish = CompletableDeferred()
        val action = launch { repo.delete(captured.id, lease(captured)) }
        runCurrent(); assertTrue(port.entered!!.isCompleted)
        port.conversations.value = listOf(RemoteConversation(captured.id, owner, "Adopted", emptyList(), false))
        runCurrent(); assertEquals(owner, repo.state.value.chats.single().owner)
        port.finish!!.complete(Unit); runCurrent(); action.join()
        assertEquals(owner, repo.state.value.chats.single().owner)
        assertTrue(disk.snapshot.hidden.isEmpty()); assertEquals(1, port.retractions)
    }

    @Test fun privateOwnerAndPendingFingerprintCannotBeBorrowedButOwnFlagsCanChange() {
        val expected = lease()
        assertTrue(expected.matches(chat.copy(pinned = true, pendingFlags = ChatFlags(pinned = true))))
        assertFalse(expected.matches(chat.copy(privateOrigin = true)))
        assertFalse(expected.matches(chat.copy(owner = owner.copy(mac = "other-mac"))))
        val pending = chat.copy(owner = null, pendingSend = RemoteSend("account", 1, "send", "chat", "mac", AgentProvider.CLAUDE, 1,
            MacSendState.WAITING, "Synthetic request", fingerprint = "original"))
        assertFalse(lease(pending).matches(pending.copy(pendingSend = pending.pendingSend!!.copy(fingerprint = "changed"))))
        assertFalse(lease(pending).matches(pending.copy(pendingSend = pending.pendingSend!!.copy(epoch = 2))))
        assertFalse(lease(pending).matches(pending.copy(pendingSend = null)))
        assertTrue(lease(pending).matches(pending.copy(pendingSend = null), pendingRetracted = true))
    }

    @Test fun unsupportedGuardedPortCannotFallBackToLegacyMethodsAndLegacyCallsStillWork() = runTest {
        var legacy = 0
        val port = object : AgentSyncPort {
            override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Fixture", true,
                setOf(AgentProvider.CLAUDE), controlsChats = true)), epoch = 1))
            override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
            override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("No provider")
            override suspend fun stop(owner: RemoteOwner) { legacy++ }
            override suspend fun delete(owner: RemoteOwner) { legacy++ }
            override suspend fun answerApproval(answer: ApprovalAnswer) = error("No approvals")
            override suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags): Boolean { legacy++; return true }
        }
        val transport = SyncProtocolTransport(port)
        for (operation in listOf<suspend () -> Unit>(
            { transport.stop(owner, lease()) }, { transport.delete(owner, lease()) },
            { transport.patchChat(owner, ChatFlags(pinned = true), lease()) },
            { transport.retractPending("chat", lease(chat.copy(owner = null))) })) {
            assertTrue(runCatching { operation() }.exceptionOrNull() is AgentUnavailable)
        }
        assertEquals(0, legacy)
        transport.stop(owner); transport.delete(owner); transport.patchChat(owner, ChatFlags(pinned = true))
        assertEquals(3, legacy)
    }
}

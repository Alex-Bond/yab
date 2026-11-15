package dev.yab.agent

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ParkedChatsTest {
    private class Memory : ChatPersistence {
        var snapshot = ChatSnapshot()
        var saves = 0
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: ChatSnapshot) { this.snapshot = snapshot; saves++ }
    }
    private class Remote : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection(account = "first"))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("A quick local answer must stay local")
        override suspend fun stop(owner: RemoteOwner) = Unit
        override suspend fun delete(owner: RemoteOwner) = Unit
        override suspend fun answerApproval(answer: ApprovalAnswer) = Unit
    }
    private val local = object : LocalAiAdapter { override suspend fun answer(question: LocalQuestion) = "A local answer" }

    @Test fun parkedQuickAnswerRestoresTheSameUnpersistedConversation() = runTest {
        val disk = Memory(); val repository = AgentRepository(disk, local, Remote())
        repository.load()
        val id = repository.newChat(ephemeral = true)
        repository.draft("Explain this"); repository.send()
        val line = ParkedChats(repository, backgroundScope)
        assertTrue(line.park()); runCurrent()
        assertEquals(id, line.visible(false)?.id)
        assertTrue(disk.snapshot.chats.isEmpty())
        assertTrue(line.restore(false)); assertNull(line.state.value)
        assertEquals(id, repository.state.value.current?.id)
        assertEquals("A local answer", repository.state.value.current?.messages?.last()?.text)
        line.close()
    }

    @Test fun lettingGoDeletesOnlyAnUncontinuedQuickAnswer() = runTest {
        val disk = Memory(); val repository = AgentRepository(disk, local, Remote()); repository.load()
        val line = ParkedChats(repository, backgroundScope)
        val quick = repository.newChat(ephemeral = true)
        assertTrue(line.park()); assertTrue(line.letGo(false)); runCurrent()
        assertTrue(repository.state.value.chats.none { it.id == quick })
        assertTrue("local/$quick" in disk.snapshot.hidden)
        val kept = repository.newChat(ephemeral = true)
        repository.promote(kept)
        assertTrue(line.park()); assertTrue(line.letGo(false)); runCurrent()
        assertEquals(kept, repository.state.value.listed().single().id)
        line.close()
    }

    @Test fun replacingTheSingleLineForgetsTheOldQuickAnswer() = runTest {
        val repository = AgentRepository(Memory(), local, Remote()); repository.load()
        val line = ParkedChats(repository, backgroundScope)
        val old = repository.newChat(ephemeral = true); assertTrue(line.park())
        val next = repository.newChat(ephemeral = true); assertTrue(line.park()); runCurrent()
        assertTrue(repository.state.value.chats.none { it.id == old })
        assertEquals(next, line.visible(false)?.id)
        assertEquals(next, repository.state.value.current?.id)
        line.close()
    }

    @Test fun privateParkedContentNeverAppearsOrRestoresInPublic() = runTest {
        val repository = AgentRepository(Memory(), local, Remote()); repository.load(); repository.setPrivacy(true)
        val id = repository.newChat(ephemeral = true)
        val line = ParkedChats(repository, backgroundScope); assertTrue(line.park()); runCurrent()
        repository.setPrivacy(false); runCurrent()
        assertNull(line.visible(false)); assertFalse(line.restore(false)); assertFalse(line.letGo(false))
        assertEquals(id, line.state.value?.chat)
        assertTrue(line.restore(true)); assertEquals(id, repository.state.value.current?.id)
        line.close()
    }

    @Test fun lettingGoOfPrivateAnswerDoesNotWriteItsIdToDiskOrHiddenTombstones() = runTest {
        val disk = Memory(); val repository = AgentRepository(disk, local, Remote())
        repository.load()
        val kept = repository.newChat(); repository.draft("Public draft")
        repository.setPrivacy(true)
        val id = repository.newChat(PageContext("Secret private title", "https://private.example/secret", "Secret private page text", true), ephemeral = true)
        repository.draft("Secret private question"); repository.send()
        val line = ParkedChats(repository, backgroundScope)
        assertTrue(line.park()); runCurrent()
        assertTrue(line.restore(true)); assertTrue(line.park())
        val before = disk.snapshot; val savesBefore = disk.saves
        assertTrue(line.letGo(true)); runCurrent()
        assertTrue(repository.state.value.chats.none { it.id == id })
        assertNull(repository.state.value.activeChat)
        assertFalse(repository.state.value.attachments.containsKey(id))
        assertEquals(savesBefore, disk.saves)
        assertEquals(before, disk.snapshot)
        repository.preferences(repository.state.value.preferences)
        assertEquals(listOf(kept), disk.snapshot.chats.map { it.id })
        assertTrue(disk.snapshot.hidden.isEmpty())
        val saved = Json.encodeToString(disk.snapshot)
        for (secret in listOf(id, "Secret private title", "https://private.example/secret", "Secret private page text", "Secret private question", "A local answer")) assertFalse(saved.contains(secret))
        line.close()
    }

    @Test fun anAccountSwitchRevokesTheOldLineEvenForALocalAnswer() = runTest {
        val remote = Remote(); val repository = AgentRepository(Memory(), local, remote)
        backgroundScope.launch { repository.run() }; runCurrent()
        repository.newChat(ephemeral = true)
        val line = ParkedChats(repository, backgroundScope); assertTrue(line.park()); runCurrent()
        remote.connection.value = RemoteConnection(account = "second"); runCurrent()
        assertNull(line.state.value); assertFalse(line.restore(false))
        line.close()
    }

    @Test fun rejoiningTheSameAccountCannotRestoreAPreviousSessionLine() = runTest {
        val remote = Remote(); val repository = AgentRepository(Memory(), local, remote)
        backgroundScope.launch { repository.run() }; runCurrent()
        repository.newChat(ephemeral = true)
        val line = ParkedChats(repository, backgroundScope); assertTrue(line.park()); runCurrent()
        remote.connection.value = remote.connection.value.copy(epoch = 1); runCurrent()
        assertNull(line.state.value); assertFalse(line.restore(false))
        line.close()
    }
    @Test fun reparkOfTheSameChatRejectsOldRestoreAndDelayedFlightCompletion() = runTest {
        val repository = AgentRepository(Memory(), local, Remote()); repository.load()
        val id = repository.newChat(ephemeral = true)
        val line = ParkedChats(repository, backgroundScope); assertTrue(line.park())
        val first = line.state.value!!; val flight = line.presentation(first)!!
        flight.leave(1.0, 0, false)
        assertTrue(line.park()); val second = line.state.value!!
        assertEquals(id, second.chat); assertNotEquals(first.generation, second.generation)
        flight.advance(500_000_000)
        assertFalse(flight.claimCompletion()); assertFalse(line.letGo(first, false)); assertFalse(line.restore(first, false))
        assertEquals(second, line.state.value); assertTrue(line.restore(second, false))
        line.close()
    }

    @Test fun deferredForgetCannotDeleteTheSameChatReparkedBeforeDispatch() = runTest {
        val disk = Memory(); val repository = AgentRepository(disk, local, Remote()); repository.load()
        val id = repository.newChat(ephemeral = true)
        val line = ParkedChats(repository, backgroundScope); assertTrue(line.park())
        val first = line.state.value!!; assertTrue(line.letGo(first, false))
        assertTrue(line.park()); val replacement = line.state.value!!
        runCurrent()
        assertEquals(replacement, line.state.value); assertEquals(id, line.visible(replacement, false)?.id)
        assertTrue(repository.state.value.chats.any { it.id == id }); assertFalse("local/$id" in disk.snapshot.hidden)
        line.close()
    }

    @Test fun reconnectDuringFlightRevokesCompletionAndItsRetainedPresentation() = runTest {
        val remote = Remote(); val repository = AgentRepository(Memory(), local, remote)
        backgroundScope.launch { repository.run() }; runCurrent()
        repository.newChat(ephemeral = true)
        val line = ParkedChats(repository, backgroundScope); assertTrue(line.park())
        val first = line.state.value!!; val flight = line.presentation(first)!!
        flight.leave(1.0, 0, false)
        remote.connection.value = remote.connection.value.copy(epoch = 9); runCurrent()
        flight.advance(300_000_000)
        assertFalse(flight.claimCompletion()); assertFalse(line.letGo(first, false)); assertNull(line.state.value)
        line.close()
    }

}

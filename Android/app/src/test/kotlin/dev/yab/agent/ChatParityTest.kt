package dev.yab.agent

import dev.yab.core.sync.Record
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatParityTest {
    private class Disk(var saved: ChatSnapshot = ChatSnapshot()) : ChatPersistence {
        override suspend fun load() = saved
        override suspend fun save(snapshot: ChatSnapshot) { saved = snapshot }
    }
    private class Port : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, setOf(AgentProvider.CLAUDE)))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        val sent = mutableListOf<AgentSendCommand>()
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt { sent += command; return AgentSendReceipt(command.owner) }
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) {}
    }
    private fun item(id: String, n: Int, kind: String, name: String = "", text: String = "", detail: String = "") = Record("chatitem", id, buildJsonObject {
        put("chat", "a:chat"); put("n", n); put("kind", kind); put("name", name); put("text", text); put("detail", detail); put("state", "done"); put("began", n + 1); put("ended", n + 2)
    })
    @Test fun projectionKeepsActualTurnKindsCardsAndHumanQuestionInsteadOfBookkeeping() {
        val head = Record("chat", "a:chat", buildJsonObject { put("state", "done"); put("updated", 10) })
        val card = "{\"kind\":\"links\",\"rows\":[{\"title\":\"Found page\",\"url\":\"https://site.test/page\"}]}"
        val steps = listOf(item("q", 0, "asked", text = "Question"), item("t", 1, "thinking", "thought", "Reasoning"), item("c", 2, "command", "shell", "Exact output"),
            item("pick", 3, "chose", text = "This option"), item("a", 4, "message", text = "Answer"), item("card", 5, "card", text = card))
        val messages = ChatTranscript.messages(head, steps, emptyList())
        assertEquals(MessageRole.USER, messages.single { it.id == "pick" }.role)
        assertEquals("Reasoning", messages.single { it.id == "t" }.work?.text)
        val answer = messages.single { it.id == "a" }
        assertEquals("Exact output", answer.work!!.steps.single().text)
        assertEquals("Question", answer.work.question)
        assertEquals("Found page", answer.cards.single().rows!!.single().title)
        assertFalse(messages.any { it.text == card || it.text == "Exact output" })
    }
    @Test fun metadataAndUnreadSurviveUnrelatedSnapshotsAndColdLoadKeepsAnAlreadyCreatedQuestion() = runBlocking {
        val disk = Disk(ChatSnapshot(chats = listOf(AgentChat("saved", title = "Saved"))))
        val port = Port(); val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        val early = repository.newChat(ephemeral = true); repository.draft("Typed before disk load")
        repository.load()
        assertEquals(early, repository.state.value.current!!.id); assertEquals("Typed before disk load", repository.state.value.current!!.draft)
        assertTrue(repository.state.value.chats.any { it.id == "saved" })
        repository.back()
        val job = launch(start = CoroutineStart.UNDISPATCHED) { repository.run() }
        try {
            val owner = RemoteOwner("account", "mac", "a:chat", AgentProvider.CLAUDE)
            val remote = RemoteConversation(null, owner, "Mac title", listOf(AgentMessage("m", MessageRole.ASSISTANT, "Answer", 10)), false)
            port.conversations.value = listOf(remote); yield()
            repository.rename("a:chat", "My local override"); repository.markUnread("a:chat", false)
            port.conversations.value = listOf(remote, remote.copy(owner = owner.copy(chat = "a:other"), title = "Other")); yield()
            val kept = repository.state.value.chats.single { it.id == "a:chat" }
            assertEquals("My local override", kept.title); assertFalse(kept.unread)
        } finally { job.cancelAndJoin() }
    }
    @Test fun mutexQueuedTapCannotBorrowANewChatAndQuickQuestionStaysEphemeralUntilContinued() = runBlocking {
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val local = object : LocalAiAdapter { override suspend fun answer(question: LocalQuestion): String { started.complete(Unit); release.await(); return "Local answer" } }
        val port = Port(); val disk = Disk(); val repository = AgentRepository(disk, local, port)
        repository.load(); val id = repository.newChat(ephemeral = true); repository.draft("First quick question")
        val first = launch { repository.send(chatId = id) }; started.await()
        val waiting = launch(start = CoroutineStart.UNDISPATCHED) { repository.send(chatId = id) }
        val other = repository.newChat(); repository.draft("Other draft")
        release.complete(Unit); first.join(); waiting.join()
        assertTrue(port.sent.isEmpty()); assertEquals("Other draft", repository.state.value.current!!.draft)
        assertFalse(disk.saved.chats.any { it.id == id })
        repository.open(id); repository.draft("Continue"); repository.send(chatId = id)
        assertFalse(repository.state.value.current!!.ephemeral)
        assertTrue(disk.saved.chats.any { it.id == id }); assertEquals(other, disk.saved.chats.first { it.id == other }.id)
    }
    @Test fun structuredMarkdownTablesAndIncompleteStreamingMarksRemainSafe() {
        val blocks = AgentMarkdown.blocks("| Name | Price |\n|---|---|\n| One | $1 |\n\n```sh\necho test\n```")
        assertEquals(2, blocks.first().cells.size); assertEquals(listOf("One", "$1"), blocks.first().cells.last())
        assertEquals("Answer ", AgentMarkdown.settled("Answer **unfinished"))
        assertEquals("Answer ", AgentMarkdown.settled("Answer [unfinished"))
        assertFalse(AgentMarkdown.safeUrl("https://trusted.test@other.test/path"))
        assertFalse(AgentMarkdown.safeUrl("file:///private")); assertTrue(AgentMarkdown.safeUrl("https://site.test/path"))
    }
    @Test fun aQueuedSuggestionCannotSendAfterItsNativeDocumentLeaseExpires() = runBlocking {
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val local = object : LocalAiAdapter {
            override suspend fun answer(question: LocalQuestion): String { started.complete(Unit); release.await(); return "First answer" }
        }
        val port = Port(); val repository = AgentRepository(Disk(), local, port)
        repository.load(); val first = repository.newChat(ephemeral = true); repository.draft("First question")
        val active = launch { repository.send(chatId = first) }; started.await()
        val next = repository.newChat(); repository.draft("Summarize this page")
        var nativeDocumentCurrent = true
        val waiting = launch(start = CoroutineStart.UNDISPATCHED) {
            repository.send(chatId = next, sourceCurrent = { nativeDocumentCurrent })
        }
        nativeDocumentCurrent = false; release.complete(Unit)
        active.join(); waiting.join()
        assertTrue(port.sent.isEmpty())
        assertEquals("Summarize this page", repository.state.value.current!!.draft)
        assertTrue(repository.state.value.current!!.messages.isEmpty())
        assertTrue(repository.state.value.error!!.contains("page changed"))
    }
    @Test fun acceptedConversationNeverBorrowsAnotherMacsAttachmentPermission() {
        val port = Port()
        port.connection.value = RemoteConnection("account", listOf(RemoteMac("another", "Another Mac", true, setOf(AgentProvider.CLAUDE), takesFiles = true)))
        val repository = AgentRepository(Disk(), UnavailableLocalAiAdapter(), port)
        val owned = AgentChat("owned", owner = RemoteOwner("account", "removed-owner", "a:owned", AgentProvider.CLAUDE))
        assertFalse(repository.canAttach(owned))
        assertTrue(repository.canAttach(AgentChat("fresh")))
    }
    @Test fun aWaitingMacAcceptsAnOwnedAnswerAndRetryCannotBorrowTheNextChat() = runBlocking {
        val port = Port(); val disk = Disk(); val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        val collector = launch(start = CoroutineStart.UNDISPATCHED) { repository.run() }
        try {
            val owner = RemoteOwner("account", "mac", "a:waiting", AgentProvider.CLAUDE)
            port.conversations.value = listOf(RemoteConversation(null, owner, "Question from Mac", emptyList(), true, remoteState = "waiting", choices = listOf("First", "Second")))
            yield(); repository.open("a:waiting"); repository.draft("First"); repository.send(chatId = "a:waiting")
            assertEquals(owner, port.sent.single().owner); assertEquals("First", port.sent.single().question.words)
        } finally { collector.cancelAndJoin() }

        val saving = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var hold = false
        val blockedDisk = object : ChatPersistence {
            override suspend fun load() = ChatSnapshot()
            override suspend fun save(snapshot: ChatSnapshot) { if (hold) { saving.complete(Unit); release.await() } }
        }
        val retryPort = Port(); val retry = AgentRepository(blockedDisk, UnavailableLocalAiAdapter(), retryPort)
        retry.load(); val original = retry.newChat(); hold = true
        val pending = launch { retry.retry(original, "Original tapped question") }; saving.await()
        val next = retry.newChat(); val nextDraft = launch(start = CoroutineStart.UNDISPATCHED) { retry.draft("Next chat draft") }
        release.complete(Unit); pending.join(); nextDraft.join()
        assertTrue(retryPort.sent.isEmpty()); assertEquals(next, retry.state.value.current!!.id); assertEquals("Next chat draft", retry.state.value.current!!.draft)
    }
}

package dev.yab.agent

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class AgentRepositoryTest {
    private class Memory : ChatPersistence {
        var value = ChatSnapshot()
        override suspend fun load() = value
        override suspend fun save(snapshot: ChatSnapshot) { value = snapshot }
    }
    private class Remote : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "My Mac", true, setOf(AgentProvider.CLAUDE, AgentProvider.CODEX), takesFiles = true))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        val commands = mutableListOf<AgentSendCommand>()
        val answers = mutableListOf<ApprovalAnswer>()
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt {
            commands += command
            return AgentSendReceipt(RemoteOwner(command.account, command.mac, "a:1", command.provider))
        }
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) { answers += answer }
    }

    @Test fun privateUnavailableModelDoesNotExportOrPersistConversation() = runBlocking {
        val disk = Memory()
        val remote = Remote()
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), remote)
        repository.load()
        repository.setPrivacy(true)
        repository.newChat(PageContext("Private", "https://example.com/private", "private page", true))
        repository.draft("Summarize this")
        repository.send()
        assertTrue(remote.commands.isEmpty())
        assertTrue(disk.value.chats.isEmpty())
        assertEquals(MessageRole.FAILURE, repository.state.value.current!!.messages.last().role)
        repository.setPrivacy(false)
        assertNull(repository.state.value.current)
        assertTrue(repository.state.value.listed().isEmpty())
    }

    @Test fun chosenLocalPublicPageDoesNotFallBackToMacOnFailure() = runBlocking {
        val remote = Remote()
        val repository = AgentRepository(Memory(), UnavailableLocalAiAdapter(), remote)
        repository.load()
        repository.newChat(PageContext("Page", "https://example.com", "The answer is here"))
        repository.draft("What does this say?")
        repository.send()
        assertTrue(remote.commands.isEmpty())
        assertEquals(DeliveryState.FAILED, repository.state.value.current!!.delivery)
    }

    @Test fun draftsSurviveRelaunchAndAcceptedMacProviderDoesNotFollowPreference() = runBlocking {
        val disk = Memory()
        val remote = Remote()
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), remote)
        repository.load()
        val id = repository.newChat()
        repository.draft("Saved draft")
        val reopened = AgentRepository(disk, UnavailableLocalAiAdapter(), remote)
        reopened.load(); reopened.open(id)
        assertEquals("Saved draft", reopened.state.value.current!!.draft)
        reopened.send()
        assertEquals(AgentProvider.CLAUDE, remote.commands.single().provider)
        assertEquals(AgentProvider.CLAUDE, reopened.state.value.current!!.owner!!.provider)
        reopened.preferences(AgentPreferences(provider = AgentProvider.CODEX))
        assertEquals(AgentProvider.CLAUDE, reopened.state.value.current!!.owner!!.provider)
    }

    @Test fun changedAccountCannotUseCapturedConversationOwner() = runBlocking {
        val port = Remote()
        val transport = SyncProtocolTransport(port)
        val command = AgentSendCommand("send", "chat", "old-account", "mac", AgentProvider.CLAUDE, null,
            LocalQuestion("Question", null, emptyList()), emptyList(), ModelSelection())
        try { transport.send(command); fail("A changed account must refuse before a send") } catch (_: IllegalArgumentException) {}
        assertTrue(port.commands.isEmpty())
    }

    @Test fun attachmentLimitsUseSharedIosBoundsAndOverflowSafeTotal() {
        AttachmentLimits.validate(List(10) { 1 })
        for (sizes in listOf(List(11) { 1 }, listOf(10_000_001), listOf(10_000_000, 10_000_000, 1), listOf(Int.MAX_VALUE))) {
            try { AttachmentLimits.validate(sizes); fail("The invalid batch must be refused") } catch (_: IllegalArgumentException) {}
        }
    }

    @Test fun approvalChangedWhileAuthenticationWasOpenCannotSend() = runBlocking {
        val port = Remote()
        val controller = ApprovalController(port) { 1000 }
        val request = ApprovalRequest("id", "account", "mac", 1, 10_000, "Claude", "Send mail?", "To Anna")
        controller.replaceValidated(listOf(request))
        val auth = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
                controller.replaceValidated(listOf(request.copy(revision = 2, summary = "To someone else")))
                return DeviceAuthenticationProof(1000)
            }
        }
        controller.answer("id", true, auth)
        assertTrue(port.answers.isEmpty())
        assertNull("Retired authentication must not write an error into the changed presentation", controller.state.value.error)
        assertNull(controller.state.value.busy)
        val fresh = request.copy(revision = 2, summary = "To someone else")
        val freshLease = checkNotNull(controller.captureDisplayed(fresh))
        assertTrue(controller.isDisplayedCurrent(freshLease))
        var freshProofs = 0
        controller.answer(fresh.id, true, object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
                freshProofs++; return DeviceAuthenticationProof(1000)
            }
        }, displayed = freshLease)
        assertEquals(1, freshProofs)
        assertEquals(fresh, port.answers.single().request)
    }

    @Test fun declinedApprovalRequiresNoBiometricAndIsAccountBound() = runBlocking {
        val port = Remote()
        val controller = ApprovalController(port) { 1000 }
        controller.replaceValidated(listOf(ApprovalRequest("id", "account", "mac", 1, 10_000, "Claude", "Send mail?", "To Anna")))
        controller.answer("id", false, null)
        assertEquals(1, port.answers.size)
        assertFalse(port.answers.single().approved)
        assertNull(port.answers.single().proof)
    }
}

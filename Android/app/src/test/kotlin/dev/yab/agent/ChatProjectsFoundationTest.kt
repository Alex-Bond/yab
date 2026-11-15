package dev.yab.agent

import dev.yab.core.sync.SyncProject
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatProjectsFoundationTest {
    private val first = SyncProject("prj-first", "First", "", "blue", order = "a", created = 1.0, updated = 1.0)
    private val second = first.copy(id = "prj-second", name = "Second", order = "b")
    private val owner = RemoteOwner("account", "mac", "a:chat", AgentProvider.CLAUDE)
    private val owned = AgentChat("chat", owner = owner, project = first.id)
    private class Disk(chats: List<AgentChat> = emptyList()) : ChatPersistence {
        var saved = ChatSnapshot(chats = chats)
        var saves = 0
        override suspend fun load() = saved
        override suspend fun save(snapshot: ChatSnapshot) { saved = snapshot; saves++ }
    }
    private class Port(private val dispatcher: CoroutineDispatcher) : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true,
            setOf(AgentProvider.CLAUDE), takesMetadata = true, takesProjects = true)), epoch = 7))
        override val projects = MutableStateFlow(ChatProjectsSnapshot())
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override val sends = MutableStateFlow(emptyList<RemoteSend>())
        val sent = mutableListOf<AgentSendCommand>()
        val moved = mutableListOf<String?>()
        var entered: CompletableDeferred<Unit>? = null
        var finish: CompletableDeferred<Unit>? = null
        fun publish(values: List<SyncProject>, device: String = "phone", removed: Boolean = false) {
            projects.value = ChatProjectsSnapshot.publish(projects.value, connection.value.account, device,
                connection.value.epoch, values, removed, connection.value)
        }
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = withContext(dispatcher) {
            command.project?.let { require(command.projectLease?.current(projects.value, connection.value) == true) }
            entered?.complete(Unit); finish?.await()
            command.project?.let { require(command.projectLease?.current(projects.value, connection.value) == true) }
            sent += command
            AgentSendReceipt()
        }
        override suspend fun moveToProject(owner: RemoteOwner, project: String?, expected: ChatProjectLease): Boolean = withContext(dispatcher) {
            require(expected.chat?.owner == owner && expected.current(projects.value, connection.value))
            entered?.complete(Unit); finish?.await()
            require(expected.current(projects.value, connection.value))
            moved += project
            val chat = requireNotNull(expected.chat)
            conversations.value = listOf(RemoteConversation(chat.id, owner, chat.title, chat.messages, false,
                chat.pinned, chat.archived, chat.unread, chat.updatedAt, metadataKnown = true, project = project))
            projects.value = ChatProjectsSnapshot.publish(projects.value, projects.value.account, projects.value.device, projects.value.epoch,
                projects.value.projects, connection = connection.value, memberships = listOf(ChatProjectMembership(owner.chat, owner.mac, owner.provider, project)))
            true
        }
        override suspend fun stop(owner: RemoteOwner) = error("No control in project fixture")
        override suspend fun delete(owner: RemoteOwner) = error("No deletion in project fixture")
        override suspend fun answerApproval(answer: ApprovalAnswer) = error("No approval in project fixture")
    }
    private suspend fun repository(port: Port, disk: Disk = Disk()): AgentRepository =
        AgentRepository(disk, UnavailableLocalAiAdapter(), SyncProtocolTransport(port)).also { it.load() }

    @Test fun absentLegacyProjectPublicationCannotOfferOrDispatchAnyProjectAction() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); val repo = repository(port, Disk(listOf(owned)))
        assertFalse(repo.canStartInProject(first.id)); assertFalse(repo.canMoveToProject(owned))
        assertNull(repo.captureProjectStart(first.id) { true })
        assertNull(repo.captureProjectMove(owned, second.id) { true })
        assertTrue(port.sent.isEmpty()); assertTrue(port.moved.isEmpty())
    }

    @Test fun metadataKeepsTheViewPresenceButRemoveReaddAndAccountAbaRetireIt() {
        val initial = ChatProjectsSnapshot.publish(ChatProjectsSnapshot(), "account", "phone", 7, listOf(first))
        val original = requireNotNull(initial.presence(first.id))
        val renamed = ChatProjectsSnapshot.publish(initial, "account", "phone", 7, listOf(first.copy(name = "Renamed")))
        assertSame(original, renamed.presence(first.id)); assertTrue(original.current(renamed))
        assertTrue(renamed.generation > initial.generation)
        val absent = ChatProjectsSnapshot.publish(renamed, "account", "phone", 7, emptyList())
        val returned = ChatProjectsSnapshot.publish(absent, "account", "phone", 7, listOf(first))
        assertFalse(original.current(returned)); assertNotSame(original, returned.presence(first.id))
        val successor = requireNotNull(returned.presence(first.id))
        val other = ChatProjectsSnapshot.publish(returned, "other", "phone", 7, listOf(first))
        val back = ChatProjectsSnapshot.publish(other, "account", "phone", 7, listOf(first))
        assertFalse(successor.current(back))
    }

    @Test fun capabilitiesAndRouteAbaAdvanceControlsWithoutRetiringTheProjectView() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first))
        val repo = repository(port); val original = port.projects.value
        val presence = requireNotNull(original.presence(first.id))
        val lease = requireNotNull(repo.captureProjectStart(first.id) { true })
        port.connection.value = port.connection.value.copy(macs = port.connection.value.macs.map { it.copy(takesProjects = false) })
        port.publish(listOf(first))
        port.connection.value = port.connection.value.copy(macs = port.connection.value.macs.map { it.copy(takesProjects = true) })
        port.publish(listOf(first))
        assertTrue(port.projects.value.generation > original.generation)
        assertSame(presence, port.projects.value.presence(first.id)); assertTrue(presence.current(port.projects.value))
        assertNull(repo.newChatInProject(lease))
        assertNotNull(repo.newChatInProject(requireNotNull(repo.captureProjectStart(first.id) { true })))
    }

    @Test fun currentStartCreatesOnePublicMacDraftAndDoesNotSendUntilThePersonAsks() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first))
        val repo = repository(port)
        val lease = requireNotNull(repo.captureProjectStart(first.id) { true })
        val id = requireNotNull(repo.newChatInProject(lease))
        val chat = requireNotNull(repo.state.value.current)
        assertEquals(id, chat.id); assertEquals(first.id, chat.project)
        assertTrue(chat.forceMac); assertTrue(chat.ephemeral); assertFalse(chat.privateOrigin)
        assertTrue(chat.messages.isEmpty()); assertTrue(port.sent.isEmpty())
        assertNull(repo.newChatInProject(lease)); assertEquals(1, repo.state.value.chats.size)
    }

    @Test fun selectedMacAbaCannotReviveTheOriginalStartWhileFreshChoiceStillWorks() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler))
        port.connection.value = port.connection.value.copy(macs = port.connection.value.macs + port.connection.value.macs.single().copy(id = "other-mac"), selectedMac = "mac")
        port.publish(listOf(first)); val repo = repository(port)
        val lease = requireNotNull(repo.captureProjectStart(first.id) { true })
        port.connection.value = port.connection.value.copy(selectedMac = "other-mac"); port.publish(listOf(first))
        port.connection.value = port.connection.value.copy(selectedMac = "mac"); port.publish(listOf(first))
        assertNull(repo.newChatInProject(lease))
        assertNotNull(repo.newChatInProject(requireNotNull(repo.captureProjectStart(first.id) { true })))
    }

    @Test fun remoteMembershipAbaRetiresActionsWithoutClosingTheOriginalProjectView() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first, second))
        val originalMembership = listOf(ChatProjectMembership(owner.chat, owner.mac, owner.provider, first.id))
        port.projects.value = ChatProjectsSnapshot.publish(port.projects.value, "account", "phone", 7, listOf(first, second), connection = port.connection.value,
            memberships = originalMembership)
        val repo = repository(port, Disk(listOf(owned)))
        backgroundScope.launch { repo.run() }; runCurrent()
        val before = port.projects.value; val presence = requireNotNull(before.presence(first.id))
        val lease = requireNotNull(repo.captureProjectMove(owned, second.id) { true })
        val changed = ChatProjectsSnapshot.publish(before, "account", "phone", 7, listOf(first, second), connection = port.connection.value,
            memberships = listOf(ChatProjectMembership(owner.chat, owner.mac, owner.provider, second.id)))
        port.projects.value = ChatProjectsSnapshot.publish(changed, "account", "phone", 7, listOf(first, second), connection = port.connection.value,
            memberships = originalMembership)
        assertTrue(presence.current(port.projects.value))
        assertFalse(repo.moveToProject(lease)); assertTrue(port.moved.isEmpty())
        val fresh = requireNotNull(repo.captureProjectMove(owned, second.id) { true })
        val action = launch { assertTrue(repo.moveToProject(fresh)) }; runCurrent(); action.join()
        assertEquals(second.id, repo.state.value.chats.single().project)
    }

    @Test fun privateAndRemovedPublicationsOfferNeitherStartNorMove() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first, second))
        val repo = repository(port, Disk(listOf(owned)))
        repo.setPrivacy(true)
        assertNull(repo.captureProjectStart(first.id) { true }); assertFalse(repo.canMoveToProject(owned))
        repo.setPrivacy(false); port.publish(listOf(first, second), removed = true)
        assertFalse(repo.canStartInProject(first.id)); assertFalse(repo.canMoveToProject(owned))
        assertTrue(port.moved.isEmpty()); assertTrue(port.sent.isEmpty())
    }

    @Test fun falseOriginalSourcePermanentlyRetiresStartEvenAfterItReturns() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first))
        val repo = repository(port); var current = true
        val lease = requireNotNull(repo.captureProjectStart(first.id) { current })
        current = false; assertNull(repo.newChatInProject(lease))
        current = true; assertNull(repo.newChatInProject(lease))
        assertNotNull(repo.newChatInProject(requireNotNull(repo.captureProjectStart(first.id) { current })))
    }

    @Test fun draftProjectSwitchPreservesWordsAndOldPillCannotChangeItsSuccessor() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first, second))
        val repo = repository(port)
        val id = requireNotNull(repo.newChatInProject(requireNotNull(repo.captureProjectStart(first.id) { true })))
        repo.draft("Original words")
        val old = requireNotNull(repo.captureDraftProject(requireNotNull(repo.state.value.current), second.id) { true })
        assertTrue(repo.setDraftProject(old)); assertEquals("Original words", repo.state.value.current?.draft)
        assertEquals(second.id, repo.state.value.current?.project); assertFalse(repo.setDraftProject(old))
        val none = requireNotNull(repo.captureDraftProject(requireNotNull(repo.state.value.current), null) { true })
        assertTrue(repo.setDraftProject(none)); assertNull(repo.state.value.current?.project)
        assertEquals(id, repo.state.value.current?.id); assertEquals("Original words", repo.state.value.current?.draft)
    }

    @Test fun projectQuestionUsesMacDespiteDevicePreferenceAndCarriesItsOriginalProject() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first))
        val repo = repository(port)
        val id = requireNotNull(repo.newChatInProject(requireNotNull(repo.captureProjectStart(first.id) { true })))
        repo.draft("A project question")
        val send = launch { repo.send(chatId = id, sourceCurrent = { true }) }
        runCurrent(); send.join()
        val command = port.sent.single()
        assertEquals(first.id, command.project); assertEquals("mac", command.mac); assertNull(command.owner)
        assertEquals("A project question", command.question.words)
        assertNotNull(command.projectLease)
    }

    @Test fun projectSendWithoutOriginalUiAdmissionKeepsWordsAndCreatesNoQuestion() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first))
        val repo = repository(port)
        val id = requireNotNull(repo.newChatInProject(requireNotNull(repo.captureProjectStart(first.id) { true })))
        repo.draft("Do not borrow a source")
        repo.send(chatId = id)
        assertTrue(port.sent.isEmpty()); assertTrue(repo.state.value.current!!.messages.isEmpty())
        assertEquals("Do not borrow a source", repo.state.value.current?.draft)
    }

    @Test fun queuedProjectSendCannotBorrowAChangedEpochOrOriginalSource() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first))
        val repo = repository(port)
        val id = requireNotNull(repo.newChatInProject(requireNotNull(repo.captureProjectStart(first.id) { true })))
        repo.draft("A bounded question"); var current = true
        val send = launch(start = CoroutineStart.UNDISPATCHED) { repo.send(chatId = id, sourceCurrent = { current }) }
        current = false; port.connection.value = port.connection.value.copy(epoch = 8); port.publish(listOf(first))
        runCurrent(); send.join()
        assertTrue(port.sent.isEmpty())
    }

    @Test fun supportedMoveAndRemovePersistTheirActualResultWithoutChangingOtherFlags() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first, second))
        val disk = Disk(listOf(owned.copy(pinned = true, draft = "Keep draft"))); val repo = repository(port, disk)
        backgroundScope.launch { repo.run() }; runCurrent()
        val before = repo.state.value.chats.single()
        val move = launch { assertTrue(repo.moveToProject(requireNotNull(repo.captureProjectMove(before, second.id) { true }))) }
        runCurrent(); move.join()
        val moved = repo.state.value.chats.single()
        assertEquals(second.id, moved.project); assertTrue(moved.pinned); assertEquals("Keep draft", moved.draft)
        val remove = launch { assertTrue(repo.moveToProject(requireNotNull(repo.captureProjectMove(moved, null) { true }))) }
        runCurrent(); remove.join()
        assertNull(disk.saved.chats.single().project); assertEquals(listOf(second.id, null), port.moved)
    }

    @Test fun heldMoveCannotApplyLocalMembershipAfterOriginalCoverRetirement() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first, second))
        val disk = Disk(listOf(owned)); val repo = repository(port, disk); var current = true
        port.entered = CompletableDeferred(); port.finish = CompletableDeferred()
        val lease = requireNotNull(repo.captureProjectMove(owned, second.id) { current })
        val move = launch { repo.moveToProject(lease) }; runCurrent()
        assertTrue(port.entered!!.isCompleted)
        current = false; port.finish!!.complete(Unit); runCurrent(); move.join()
        assertTrue(port.moved.isEmpty()); assertEquals(first.id, repo.state.value.chats.single().project)
        assertEquals(0, disk.saves)
    }

    @Test fun changedProjectOrDeviceCannotBeBorrowedByAnOldMove() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first, second))
        val repo = repository(port, Disk(listOf(owned)))
        val lease = requireNotNull(repo.captureProjectMove(owned, second.id) { true })
        port.publish(listOf(first, second), device = "replacement-phone")
        assertFalse(repo.moveToProject(lease)); assertTrue(port.moved.isEmpty())
        val fresh = requireNotNull(repo.captureProjectMove(owned, second.id) { true })
        port.publish(listOf(first))
        assertFalse(repo.moveToProject(fresh)); assertTrue(port.moved.isEmpty())
    }

    @Test fun pendingProjectAdoptionKeepsTheProjectUntilAnAuthoritativeHeadClearsIt() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first))
        val disk = Disk(); val repo = repository(port, disk)
        backgroundScope.launch { repo.run() }; runCurrent()
        val send = RemoteSend("account", 7, "request", "local", "mac", AgentProvider.CLAUDE, 1,
            MacSendState.WAITING, "A project question", fingerprint = "original", project = first.id)
        port.sends.value = listOf(send); runCurrent()
        assertEquals(first.id, repo.state.value.chats.single().project)
        port.conversations.value = listOf(RemoteConversation("local", owner, "Actual head", emptyList(), false,
            metadataKnown = true, project = null)); runCurrent()
        assertNull(repo.state.value.chats.single().project)
        port.sends.value = listOf(send.copy(state = MacSendState.TAKEN, chat = owner.chat)); runCurrent()
        assertNull(repo.state.value.chats.single().project); assertNull(disk.saved.chats.single().project)
    }

    @Test fun coldPendingProjectPersistsWhileOldAbsentAndNullWireShapesStayEqual() {
        val json = Json { ignoreUnknownKeys = true }
        val send = RemoteSend("account", 7, "request", "local", "mac", AgentProvider.CLAUDE, 1,
            MacSendState.WAITING, "A project question", fingerprint = "original", project = first.id)
        val saved = ChatSnapshot(chats = listOf(AgentChat("local", forceMac = true, project = first.id, pendingSend = send)))
        val cold = json.decodeFromString<ChatSnapshot>(json.encodeToString(saved))
        assertEquals(first.id, cold.chats.single().project)
        assertEquals(first.id, cold.chats.single().pendingSend?.project)
        val absent = json.encodeToString(send.copy(project = null))
        assertFalse(json.parseToJsonElement(absent).jsonObject.containsKey("project"))
        val explicitNull = absent.dropLast(1) + ",\"project\":null}"
        assertEquals(json.decodeFromString<RemoteSend>(absent), json.decodeFromString<RemoteSend>(explicitNull))
    }
    /** AFTER-only new-API state guard. The old-API native consumer below is the BEFORE candidate. */
    @Test fun admittedProjectWordsStayOnOriginalDraftWhenQueuedSourceRetiresAndSuccessorOpens() = runTest {
        val port = Port(StandardTestDispatcher(testScheduler)); port.publish(listOf(first))
        val repo = repository(port); var current = true
        val lease = requireNotNull(repo.captureProjectStart(first.id) { current })
        val original = requireNotNull(repo.newChatInProject(lease, initialDraft = "Original project words"))
        current = false
        val stopped = launch { repo.send(chatId = original, sourceCurrent = { current }) }
        runCurrent(); stopped.join()
        assertTrue(port.sent.isEmpty())
        assertEquals("Original project words", repo.state.value.chats.single { it.id == original }.draft)
        assertTrue(repo.state.value.chats.single { it.id == original }.messages.isEmpty())
        val successor = repo.newChat(forceMac = true); repo.draft("Successor words")
        repo.send(chatId = original, sourceCurrent = { current })
        assertEquals(successor, repo.state.value.current!!.id)
        assertEquals("Successor words", repo.state.value.current!!.draft)
        assertEquals("Original project words", repo.state.value.chats.single { it.id == original }.draft)
        assertTrue(port.sent.isEmpty())
    }

}

package dev.yab.agent

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatProjectProjectionTest {
    private class Disk(var saved: ChatSnapshot = ChatSnapshot()) : ChatPersistence {
        override suspend fun load() = saved
        override suspend fun save(snapshot: ChatSnapshot) { saved = snapshot }
    }

    private class Port : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection("account"))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("No send in project metadata fixture")
        override suspend fun stop(owner: RemoteOwner) = error("No stop in project metadata fixture")
        override suspend fun delete(owner: RemoteOwner) = error("No delete in project metadata fixture")
        override suspend fun answerApproval(answer: ApprovalAnswer) = error("No approval in project metadata fixture")
    }

    private val owner = RemoteOwner("account", "mac", "a:owned", AgentProvider.CLAUDE)
    private fun head(project: String?, known: Boolean = true) = RemoteConversation(
        null, owner, "Remote title", emptyList(), false, metadataKnown = known,
        origin = "agent", routine = "routine-one", project = project)

    @Test fun authoritativeHeadAdoptsProjectAndExplicitlyClearsAFormerProject() = runTest {
        val disk = Disk(); val port = Port()
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent()
        port.conversations.value = listOf(head("prj-flight")); runCurrent()
        assertEquals("prj-flight", repository.state.value.chats.single().project)
        assertEquals("prj-flight", disk.saved.chats.single().project)
        port.conversations.value = listOf(head(null).copy(title = "No longer in a project")); runCurrent()
        assertNull(repository.state.value.chats.single().project)
        assertNull(disk.saved.chats.single().project)
        assertEquals("agent", disk.saved.chats.single().origin)
        assertEquals("routine-one", disk.saved.chats.single().routine)
    }

    @Test fun incompleteMetadataCannotReplaceOrClearTheStoredProject() = runTest {
        val saved = AgentChat(owner.chat, owner = owner, origin = "agent", routine = "routine-one", project = "prj-flight")
        val disk = Disk(ChatSnapshot(chats = listOf(saved))); val port = Port()
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent()
        port.conversations.value = listOf(head("prj-incomplete", known = false).copy(origin = "partial", routine = "partial")); runCurrent()
        assertEquals("prj-flight", disk.saved.chats.single().project)
        port.conversations.value = listOf(head(null, known = false).copy(title = "Incomplete without a project")); runCurrent()
        assertEquals("prj-flight", repository.state.value.chats.single().project)
        assertEquals("agent", disk.saved.chats.single().origin)
        assertEquals("routine-one", disk.saved.chats.single().routine)
    }

    @Test fun versionOneSnapshotsPreserveRawProjectAndKeepAbsentOrNullFieldsOmitted() {
        val json = Json { ignoreUnknownKeys = true }
        val legacy = json.decodeFromString<ChatSnapshot>("""{"version":1,"chats":[{"id":"legacy"}]}""")
        val explicitNull = json.decodeFromString<ChatSnapshot>("""{"version":1,"chats":[{"id":"legacy","project":null}]}""")
        assertEquals(1, legacy.version)
        assertNull(legacy.chats.single().project)
        assertEquals(legacy, explicitNull)
        val legacyWire = json.parseToJsonElement(json.encodeToString(legacy)).jsonObject
        assertFalse(legacyWire["chats"]!!.jsonArray.single().jsonObject.containsKey("project"))
        assertEquals(json.encodeToString(legacy), json.encodeToString(explicitNull))
        val project = ChatSnapshot(chats = listOf(AgentChat("future", origin = "future-origin", routine = "", project = "future-project")))
        assertEquals(project, json.decodeFromString<ChatSnapshot>(json.encodeToString(project)))
        assertEquals(1, project.version)
    }

    @Test fun adoptedProjectSurvivesColdRepositoryLoadWithItsOriginalOwner() = runTest {
        val disk = Disk(); val port = Port()
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent()
        port.conversations.value = listOf(head("prj-flight")); runCurrent()
        val json = Json { ignoreUnknownKeys = true }
        val coldDisk = Disk(json.decodeFromString<ChatSnapshot>(json.encodeToString(disk.saved)))
        val reopened = AgentRepository(coldDisk, UnavailableLocalAiAdapter(), port)
        reopened.load(); reopened.open(owner.chat)
        assertEquals(owner, reopened.state.value.current!!.owner)
        assertEquals("prj-flight", reopened.state.value.current!!.project)
        assertEquals("agent", reopened.state.value.current!!.origin)
        assertEquals("routine-one", reopened.state.value.current!!.routine)
    }

    @Test fun changedAccountAndForeignOwnerCannotRetargetProjectMetadata() = runTest {
        val disk = Disk(); val port = Port()
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent()
        port.conversations.value = listOf(head("prj-flight")); runCurrent()
        port.conversations.value = listOf(head("prj-foreign").copy(clientChat = owner.chat, owner = owner.copy(mac = "other-mac"))); runCurrent()
        assertEquals(owner, disk.saved.chats.single().owner)
        assertEquals("prj-flight", disk.saved.chats.single().project)
        port.connection.value = RemoteConnection("other-account"); runCurrent()
        port.conversations.value = listOf(head("prj-stale").copy(title = "Stale account")); runCurrent()
        assertTrue(repository.state.value.listed().isEmpty())
        assertEquals("prj-flight", disk.saved.chats.single().project)
        assertEquals(owner, disk.saved.chats.single().owner)
    }

    @Test fun privateDraftRejectsIncomingHeadAndPublicAdoptionKeepsLocalMetadata() = runTest {
        val disk = Disk(); val port = Port()
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent()
        repository.setPrivacy(true)
        val privateId = repository.newChat(); repository.draft("Private words")
        port.conversations.value = listOf(head("prj-private-collision").copy(clientChat = privateId)); runCurrent()
        assertTrue(repository.state.value.current!!.privateOrigin)
        assertEquals("Private words", repository.state.value.current!!.draft)
        assertNull(repository.state.value.current!!.owner)
        assertNull(repository.state.value.current!!.project)
        assertTrue(disk.saved.chats.isEmpty())
        repository.setPrivacy(false)
        val local = repository.newChat(); repository.draft("Public draft")
        port.conversations.value = listOf(head("prj-public").copy(clientChat = local)); runCurrent()
        val adopted = repository.state.value.current!!
        assertEquals(local, adopted.id)
        assertEquals("Public draft", adopted.draft)
        assertEquals(owner, adopted.owner)
        assertEquals("prj-public", adopted.project)
        assertEquals("agent", adopted.origin)
        assertEquals("routine-one", adopted.routine)
        assertEquals(listOf(local), disk.saved.chats.map { it.id })
        assertEquals("prj-public", disk.saved.chats.single().project)
    }
}

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
class FieldChatGroupsTest {
    @Test fun nilUnknownPinnedAndRoutinePrecedenceFollowCurrentPhone() {
        val input = listOf(AgentChat("own"), AgentChat("unknown", origin = "future-origin"),
            AgentChat("empty", origin = ""), AgentChat("command", origin = "cli"),
            AgentChat("pinned", origin = "agent", pinned = true),
            AgentChat("routine-pinned", origin = "routine", routine = "r", pinned = true))
        val groups = FieldChatGroups.read(input)
        assertEquals(listOf(FieldChatGroupId.CHATS, FieldChatGroupId.TASKS, FieldChatGroupId.ROUTINES), groups.map { it.id })
        assertEquals(listOf("own", "pinned"), groups[0].chats.map { it.id })
        assertEquals(listOf("unknown", "empty", "command"), groups[1].chats.map { it.id })
        assertEquals(listOf("routine-pinned"), groups[2].chats.map { it.id })
        assertEquals(listOf(FieldChatGroup(FieldChatGroupId.CHATS, emptyList())), FieldChatGroups.read(emptyList()))
    }

    @Test fun routinesKeepFirstListedRunWithRawIdOrExactLegacyTitleFallback() {
        val input = listOf(AgentChat("new", routine = "r"), AgentChat("old", routine = "r"),
            AgentChat("legacy-new", title = "Daily", origin = "routine"),
            AgentChat("legacy-old", title = "Daily", origin = "routine"),
            AgentChat("empty-new", routine = ""), AgentChat("empty-old", routine = ""),
            AgentChat("other", title = "Daily", origin = "agent"))
        val groups = FieldChatGroups.read(input)
        assertEquals(listOf("new", "legacy-new", "empty-new"), groups.single { it.id == FieldChatGroupId.ROUTINES }.chats.map { it.id })
        assertEquals(listOf("other"), groups.single { it.id == FieldChatGroupId.TASKS }.chats.map { it.id })
        assertEquals("", input[4].routine)
    }

    @Test fun searchAndArchiveKeepAllMatchingRunsAndReceiveOnlyCurrentAccountRows() {
        val current = RemoteOwner("account", "mac", "a:one", AgentProvider.CLAUDE)
        val other = current.copy(account = "other", chat = "a:foreign")
        val state = AgentState(connection = RemoteConnection("account"), chats = listOf(
            AgentChat("new", title = "Daily", owner = current, routine = "r", updatedAt = 3),
            AgentChat("old", title = "Daily", owner = current.copy(chat = "a:two"), routine = "r", archived = true, updatedAt = 2),
            AgentChat("foreign", title = "Daily", owner = other, routine = "r", updatedAt = 4),
            AgentChat("private", title = "Daily", privateOrigin = true, routine = "r")))
        val search = state.listed("Daily")
        assertEquals(listOf("new", "old"), search.map { it.id })
        assertEquals(search, FieldChatGroups.read(search, searching = true).single().chats)
        val archive = state.listed(archived = true)
        assertEquals(listOf("old"), archive.map { it.id })
        assertEquals(archive, FieldChatGroups.read(archive, archived = true).single().chats)
        assertEquals(FieldChatGroupId.CHATS, FieldChatGroups.read(archive, archived = true).single().id)
    }

    @Test fun legacySnapshotsDefaultToOwnWhileUnknownNullableMetadataSurvivesSerialization() {
        val json = Json { ignoreUnknownKeys = true }
        val legacy = json.decodeFromString<ChatSnapshot>("""{"chats":[{"id":"old"}]}""")
        assertNull(legacy.chats.single().origin); assertNull(legacy.chats.single().routine)
        val source = ChatSnapshot(chats = listOf(AgentChat("future", origin = "future-origin", routine = "")))
        val restored = json.decodeFromString<ChatSnapshot>(json.encodeToString(source))
        assertEquals(source, restored)
        assertEquals("future-origin", restored.chats.single().origin); assertEquals("", restored.chats.single().routine)
    }

    @Test fun actualRepositoryMergePersistsRawProvenanceClearsAuthoritativeNilAndRefusesForeignOwner() = runTest {
        class Memory : ChatPersistence {
            var saved = ChatSnapshot()
            override suspend fun load() = saved
            override suspend fun save(snapshot: ChatSnapshot) { saved = snapshot }
        }
        class Remote : RemoteAgentTransport {
            override val connection = MutableStateFlow(RemoteConnection("account"))
            override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
            override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("No send in metadata fixture")
            override suspend fun stop(owner: RemoteOwner) = Unit
            override suspend fun delete(owner: RemoteOwner) = error("No delete in metadata fixture")
            override suspend fun answerApproval(answer: ApprovalAnswer) = error("No approval in metadata fixture")
        }
        val disk = Memory(); val remote = Remote()
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), remote)
        backgroundScope.launch { repository.run() }; runCurrent()
        val owner = RemoteOwner("account", "mac", "a:one", AgentProvider.CLAUDE)
        val head = RemoteConversation(null, owner, "Daily", emptyList(), false, metadataKnown = true, origin = "future", routine = "r")
        remote.conversations.value = listOf(head); runCurrent()
        assertEquals("future", repository.state.value.chats.single().origin)
        assertEquals("r", disk.saved.chats.single().routine)
        val reopened = AgentRepository(disk, UnavailableLocalAiAdapter(), remote); reopened.load()
        assertEquals("future", reopened.state.value.chats.single().origin)
        assertEquals("r", reopened.state.value.chats.single().routine)
        remote.conversations.value = listOf(head.copy(clientChat = owner.chat, owner = owner.copy(mac = "other-mac"), origin = "foreign")); runCurrent()
        assertEquals(owner, repository.state.value.chats.single().owner)
        assertEquals("future", disk.saved.chats.single().origin)
        remote.conversations.value = listOf(head.copy(title = "Legacy fixture", metadataKnown = false, origin = null, routine = null)); runCurrent()
        assertEquals("future", disk.saved.chats.single().origin); assertEquals("r", disk.saved.chats.single().routine)
        remote.conversations.value = listOf(head.copy(title = "Old Mac", origin = null, routine = null)); runCurrent()
        assertNull(disk.saved.chats.single().origin); assertNull(disk.saved.chats.single().routine)
        remote.connection.value = RemoteConnection("different-account"); runCurrent()
        remote.conversations.value = listOf(head.copy(title = "stale owner")); runCurrent()
        assertTrue(repository.state.value.listed().isEmpty())
        assertNull(repository.state.value.chats.single().origin)
        val restored = AgentRepository(disk, UnavailableLocalAiAdapter(), remote); restored.load()
        assertNull(restored.state.value.chats.single().routine)
    }
}

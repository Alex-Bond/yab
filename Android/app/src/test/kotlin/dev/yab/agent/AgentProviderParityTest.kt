package dev.yab.agent

import dev.yab.core.sync.ChatAgent
import dev.yab.core.sync.Record
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class AgentProviderParityTest {
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection())
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        val commands = mutableListOf<AgentSendCommand>()
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt {
            commands += command
            return AgentSendReceipt(command.owner)
        }
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) {}
    }
    private fun command(provider: AgentProvider, model: String? = null, effort: String? = null) = AgentSendCommand(
        id = "send", clientChat = "local", account = "account", mac = "mac", provider = provider, owner = null,
        question = LocalQuestion("Synthetic question", null, emptyList()), files = emptyList(),
        selection = ModelSelection(model, effort), expectedEpoch = 7)

    @Test fun providerSelectionWireNamesAndPlanLabelsMatchCurrentPhoneWithoutLegacyRename() {
        val expected = listOf("claude" to "Claude", "codex" to "ChatGPT", "cursor" to "Cursor", "gemini" to "Gemini")
        assertEquals(expected, AgentProvider.entries.map { it.wire to it.displayName })
        assertEquals(ChatAgent.entries.toList(), AgentProvider.entries.map { it.protocol })
        expected.forEach { (wire, name) -> assertEquals(name, AgentProvider.fromWire(wire)?.displayName) }
        assertEquals("\"CLAUDE\"", Json.encodeToString(AgentProvider.CLAUDE))
        assertEquals("\"CODEX\"", Json.encodeToString(AgentProvider.CODEX))
        assertEquals(AgentProvider.CLAUDE, Json.decodeFromString<AgentPreferences>("{}").provider)
        for (unknown in listOf("future", "Cursor", "GEMINI")) assertNull(AgentProvider.fromWire(unknown))
        assertTrue(runCatching { Json.decodeFromString<AgentPreferences>("""{"provider":"FUTURE"}""") }.isFailure)
    }

    @Test fun selectedAndAcceptedNewProvidersSurviveTheActualSnapshotSerializer() {
        for (provider in listOf(AgentProvider.CURSOR, AgentProvider.GEMINI)) {
            val owner = RemoteOwner("account", "mac", "a:chat", provider)
            val pending = RemoteSend("account", 7, "send", "local", "mac", provider, 100,
                MacSendState.WAITING, "Synthetic question", fingerprint = "checked")
            val snapshot = ChatSnapshot(chats = listOf(AgentChat("local", owner = owner, pendingSend = pending)),
                preferences = AgentPreferences(provider = provider))
            val encoded = Json.encodeToString(snapshot)
            assertEquals(snapshot, Json.decodeFromString<ChatSnapshot>(encoded))
            assertEquals(provider.name, Json.parseToJsonElement(encoded).jsonObject["preferences"]!!.jsonObject["provider"]!!.jsonPrimitive.content)
        }
    }

    @Test fun actualTransportKeepsNewProviderAndItsModelGroupAndRefusesUnknownOfferedModels(): Unit = runBlocking {
        for (provider in listOf(AgentProvider.CURSOR, AgentProvider.GEMINI)) {
            val other = if (provider == AgentProvider.CURSOR) AgentProvider.GEMINI else AgentProvider.CURSOR
            val port = Port()
            port.connection.value = RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, setOf(provider, other), models = listOf(
                RemoteModel("selected", "Selected", provider, listOf("low", "high")),
                RemoteModel("other-group", "Other", other, listOf("high"))))), epoch = 7)
            val transport = SyncProtocolTransport(port)
            transport.send(command(provider, "selected", "high"))
            assertEquals(provider, port.commands.single().provider)
            assertEquals(ModelSelection("selected", "high"), port.commands.single().selection)
            assertTrue(runCatching { transport.send(command(provider, "other-group", "high")) }.isFailure)
            assertTrue(runCatching { transport.send(command(provider, "selected", "future-effort")) }.isFailure)
            assertEquals(1, port.commands.size)
        }
    }

    @Test fun unsupportedLegacyMacPrivateSourceAndChangedSessionCannotSilentlyChooseAnotherProvider(): Unit = runBlocking {
        for (provider in listOf(AgentProvider.CURSOR, AgentProvider.GEMINI)) {
            val port = Port()
            val legacy = RemoteMac("mac", "Mac", true, setOf(AgentProvider.CLAUDE, AgentProvider.CODEX))
            port.connection.value = RemoteConnection("account", listOf(legacy), epoch = 7)
            val transport = SyncProtocolTransport(port)
            assertTrue(runCatching { transport.send(command(provider)) }.isFailure)
            port.connection.value = port.connection.value.copy(macs = listOf(legacy.copy(providers = setOf(provider))))
            val privateQuestion = LocalQuestion("Question", PageContext("Private", "https://fixture.invalid", "Synthetic", true), emptyList())
            assertTrue(runCatching { transport.send(command(provider).copy(question = privateQuestion)) }.isFailure)
            port.connection.value = port.connection.value.copy(epoch = 8)
            assertTrue(runCatching { transport.send(command(provider)) }.isFailure)
            assertTrue(port.commands.isEmpty())
        }
    }

    @Test fun existingOwnerAndPendingSendKeepTheirAgentWhenThePreferenceChanges() {
        for (provider in listOf(AgentProvider.CURSOR, AgentProvider.GEMINI)) {
            val mac = RemoteMac("mac", "Mac", true, AgentProvider.entries.toSet())
            val connection = RemoteConnection("account", listOf(mac), epoch = 7)
            val owner = RemoteOwner("account", "mac", "a:chat", provider)
            val accepted = AgentChat("local", owner = owner)
            assertEquals(provider, MacRouting.chatTarget(accepted, connection, AgentProvider.CLAUDE).provider)
            val pending = RemoteSend("account", 7, "send", "local", "mac", provider, 100,
                MacSendState.WAITING, "Question", fingerprint = "checked")
            assertEquals(provider, MacRouting.chatTarget(AgentChat("local", pendingSend = pending), connection, AgentProvider.CODEX).provider)
        }
    }

    @Test fun transcriptFailureNamesTheActualNewAgentRatherThanClaude() {
        for ((wire, name) in listOf("cursor" to "Cursor", "gemini" to "Gemini")) {
            val head = Record("chat", "a:chat", buildJsonObject {
                put("cli", wire); put("state", "failed"); put("answer", "HTTP 401 unauthorized"); put("updated", 10)
            })
            val messages = ChatTranscript.messages(head, emptyList(), emptyList())
            assertEquals("Sign in to $name again", messages.single().work?.title)
        }
    }
}

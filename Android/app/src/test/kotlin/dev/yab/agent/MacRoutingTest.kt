package dev.yab.agent

import dev.yab.sync.MacRouteStore
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class MacRoutingTest {
    private fun mac(id: String, up: Boolean, used: Long? = null, seen: Long? = null, name: String = id) =
        RemoteMac(id, name, up, setOf(AgentProvider.CLAUDE), lastSeen = seen, usedAt = used)

    @Test fun heardStateUsesTheMacsActualSleepOrQuitAndExpiresFreshPresence() {
        assertEquals(MacPhase.UP, MacAvailability.heard(false, null, 1000, 1000, 150_999).phase)
        assertEquals(MacAvailability(MacPhase.SILENT, 1000), MacAvailability.heard(false, null, 1000, 1000, 151_000))
        assertEquals(MacAvailability(MacPhase.ASLEEP, 1000), MacAvailability.heard(true, "sleep", 1000, 149_000, 150_000))
        assertEquals(MacAvailability(MacPhase.CLOSED, 1000), MacAvailability.heard(true, "quit", 1000, 149_000, 150_000))
        assertEquals(MacAvailability(MacPhase.SILENT), MacAvailability.heard(false, null, null, null, 150_000))
        assertEquals("No word yet", MacRouting.state(mac("New Mac", false)))
    }

    @Test fun eligibleManualChoiceWinsElseRecentAwakeThenRecentWithIosNameTieBreak() {
        val sleeping = mac("sleep", false, used = 900)
        val first = mac("first", true, used = 100)
        val recent = mac("recent", true, used = 200)
        assertEquals(sleeping, MacRouting.pick(listOf(first, sleeping, recent), sleeping.id))
        assertEquals(recent, MacRouting.pick(listOf(first, sleeping, recent), null))
        assertEquals(sleeping, MacRouting.pick(listOf(first.copy(awake = false, availability = MacAvailability(MacPhase.SILENT)), sleeping), null))
        assertEquals("Alpha", MacRouting.pick(listOf(mac("z", true, seen = 30, name = "Zulu"), mac("a", true, seen = 30, name = "Alpha")), null)!!.name)
        assertEquals(first, MacRouting.pick(listOf(first), "left-account"))
    }

    @Test fun routeFiltersProviderBeforeApplyingManualAndAutomaticChoice() {
        val claude = mac("claude", true, used = 1)
        val codex = mac("codex", true, used = 2).copy(providers = setOf(AgentProvider.CODEX))
        val connection = RemoteConnection("account", listOf(claude, codex), selectedMac = codex.id)
        assertEquals(claude, connection.route(AgentProvider.CLAUDE)); assertEquals(codex, connection.route(AgentProvider.CODEX))
    }

    @Test fun everyPendingStatusKeepsItsOriginalMacAndProviderWhenTheNextWorkRouteChanges() {
        val original = mac("original", false)
        val next = mac("next", true).copy(providers = setOf(AgentProvider.CODEX))
        val connection = RemoteConnection("account", listOf(original, next), selectedMac = next.id, epoch = 7)
        for (phase in MacSendState.entries) {
            val send = RemoteSend("account", 7, "send", "local", original.id, AgentProvider.CLAUDE, 1000, phase, "Question", fingerprint = phase.name)
            val chat = AgentChat("local", pendingSend = send)
            val status = MacRouting.chatTarget(chat, connection, AgentProvider.CODEX)
            assertEquals(AgentProvider.CLAUDE, status.provider); assertEquals(original, status.mac)
            assertNull(MacRouting.chatTarget(chat, connection.copy(macs = listOf(next)), AgentProvider.CODEX).mac)
            assertEquals(next, connection.route(AgentProvider.CODEX))
            assertEquals(next, MacRouting.chatTarget(chat, connection.copy(epoch = 8), AgentProvider.CODEX).mac)
        }
        val accepted = AgentChat("accepted", owner = RemoteOwner("account", original.id, "a:accepted", AgentProvider.CLAUDE))
        assertNull(MacRouting.chatTarget(accepted, connection.copy(macs = listOf(next)), AgentProvider.CODEX).mac)
        assertEquals(next, MacRouting.chatTarget(AgentChat("new"), connection, AgentProvider.CODEX).mac)
    }

    @Test fun acceptedConversationKeepsItsOwnerWhenAnotherMacIsPreferred() = runBlocking {
        val owner = RemoteOwner("account", "first", "a:existing", AgentProvider.CLAUDE)
        val commands = mutableListOf<AgentSendCommand>()
        val remote = object : RemoteAgentTransport {
            override val connection = MutableStateFlow(RemoteConnection("account", listOf(mac("first", false), mac("second", true, 200)), selectedMac = "second"))
            override val conversations = MutableStateFlow(listOf(RemoteConversation(null, owner, "Accepted", emptyList(), false)))
            override suspend fun send(command: AgentSendCommand): AgentSendReceipt { commands += command; return AgentSendReceipt(owner) }
            override suspend fun stop(owner: RemoteOwner) {}
            override suspend fun delete(owner: RemoteOwner) {}
            override suspend fun answerApproval(answer: ApprovalAnswer) {}
        }
        val disk = object : ChatPersistence { override suspend fun load() = ChatSnapshot(); override suspend fun save(snapshot: ChatSnapshot) {} }
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), remote)
        val collector = launch(start = CoroutineStart.UNDISPATCHED) { repository.run() }
        try {
            repository.open("a:existing"); repository.draft("Carry on"); repository.send(chatId = "a:existing")
            assertEquals(owner.mac, commands.single().mac); assertEquals(owner, commands.single().owner)
        } finally { collector.cancelAndJoin() }
    }

    @Test fun handChoicePersistsOnlyForItsOwnAccountAndClearsExplicitly() {
        val directory = Files.createTempDirectory("mac-route").toFile(); val file = directory.resolve("route.json")
        try {
            MacRouteStore(file, "one").save("selected-mac")
            assertEquals("selected-mac", MacRouteStore(file, "one").read())
            assertNull(MacRouteStore(file, "another").read())
            MacRouteStore(file, "one").save(null); assertNull(MacRouteStore(file, "one").read())
        } finally { directory.deleteRecursively() }
    }
}

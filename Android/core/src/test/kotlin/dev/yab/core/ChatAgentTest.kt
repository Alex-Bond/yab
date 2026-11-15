package dev.yab.core

import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Literal current SyncKit v1 envelopes, not a simulated CLI or account. */
class ChatAgentTest {
    private val phone = Clock("phone", now = { 100 })
    private fun request(fields: JsonObjectBuilder.() -> Unit) = Record("send", "request").updated(buildJsonObject {
        put("device", "mac"); put("clientDevice", "phone"); put("clientChat", "local"); put("at", 1_800_000_000)
        fields()
    }, phone)

    @Test fun currentPhoneAgentNamesAndModelGroupsAreExactAndUnknownNamesNeverChooseClaude() {
        assertEquals(1, ChatAgent.VERSION)
        val expected = listOf("claude" to "Claude", "codex" to "ChatGPT", "cursor" to "Cursor", "gemini" to "Gemini")
        assertEquals(expected, ChatAgent.entries.map { it.wire to it.plan })
        expected.forEach { (wire, group) -> assertEquals(group, ChatAgent.fromWire(wire)?.plan) }
        for (unknown in listOf(null, "", "Cursor", "GEMINI", "cursor ", "future")) assertNull(ChatAgent.fromWire(unknown))
    }

    @Test fun cursorAndGeminiReadOnlyThroughTheExplicitNewAgentEnvelope() {
        for (wire in listOf("cursor", "gemini")) {
            val explicit = request { put("kind", "agent"); put("cli", wire); put("agentText", "Synthetic question"); put("question", "Question") }
            val parsed = checkNotNull(ChatSend.read(explicit, "phone"))
            assertEquals(wire, parsed.cli); assertEquals("Synthetic question", parsed.prompt)
            assertNull(parsed.chat); assertEquals(ChatSend.State.WAITING, parsed.state)
            assertNull(explicit["text"])
            // There is no plain-text field for a rolled-back Mac to run with its default agent.
            val legacyText = request { put("kind", "agent"); put("cli", wire); put("text", "Synthetic question") }
            assertNull(ChatSend.read(legacyText, "phone"))
            val mixed = request { put("kind", "agent"); put("cli", wire); put("text", "Legacy"); put("agentText", "Explicit") }
            assertNull(ChatSend.read(mixed, "phone"))
            assertNull(ChatSend.read(explicit, "foreign-phone"))
        }
    }

    @Test fun legacyRequestsAndKnownAgentRequestsKeepTheirOriginalWireVersion() {
        val legacy = checkNotNull(ChatSend.read(request { put("text", "Legacy question") }, "phone"))
        assertNull(legacy.cli); assertEquals("Legacy question", legacy.prompt)
        for (wire in listOf("claude", "codex")) {
            val value = request { put("kind", "agent"); put("cli", wire); put("agentText", "Question") }
            assertEquals(wire, ChatSend.read(value, "phone")?.cli)
        }
        for (wire in listOf("future", "Cursor", "gemini ")) {
            assertNull(ChatSend.read(request { put("kind", "agent"); put("cli", wire); put("agentText", "Question") }, "phone"))
        }
    }

    @Test fun newAgentsDoNotBypassTheExistingPromptByteCapOrClaimWriter() {
        for (wire in listOf("cursor", "gemini")) {
            val oversized = request { put("kind", "agent"); put("cli", wire); put("agentText", "界".repeat(174_763)) }
            assertNull(ChatSend.read(oversized, "phone"))
            val waiting = request { put("kind", "agent"); put("cli", wire); put("agentText", "Question") }
            val wrongClaim = waiting.updated(JsonObject(waiting.visible + ("state" to JsonPrimitive("processing"))), Clock("foreign", now = { 101 }))
            assertNull(ChatSend.read(wrongClaim, "phone"))
            val realClaim = waiting.updated(JsonObject(waiting.visible + ("state" to JsonPrimitive("processing"))), Clock("mac", now = { 101 }))
            assertEquals(ChatSend.State.PROCESSING, ChatSend.read(realClaim, "phone")?.state)
        }
    }
}

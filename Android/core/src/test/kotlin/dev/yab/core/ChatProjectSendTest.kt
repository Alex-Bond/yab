package dev.yab.core

import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** The same existing read API exercises the old project refusal, without depending on a new constructor. */
class ChatProjectSendTest {
    private val phone = Clock("android", now = { 100 })
    private val mac = Clock("mac", now = { 101 })
    private fun request(omit: Set<String> = emptySet(), extra: JsonObjectBuilder.() -> Unit = {}): Record = Record("send", "project-request").updated(buildJsonObject {
        put("device", "mac"); put("clientDevice", "android"); put("clientChat", "draft")
        put("at", 1_800_000_000.0)
        if ("kind" !in omit) put("kind", "agent")
        if ("cli" !in omit) put("cli", "claude")
        if ("agentText" !in omit) put("agentText", "A public project question")
        if ("project" !in omit) put("project", "prj-example")
        extra()
    }, phone)

    @Test fun validProjectRequestAndItsActualMacClaimRemainReadable() {
        val source = request()
        assertNotNull("PROJECT_SEND_MUST_REMAIN_READABLE", ChatSend.read(source, "android"))
        val taken = source.updated(JsonObject(source.visible + mapOf("state" to JsonPrimitive("taken"), "chat" to JsonPrimitive("a:real"))), mac)
        val parsed = requireNotNull(ChatSend.read(taken, "android"))
        assertEquals(ChatSend.State.TAKEN, parsed.state)
        assertEquals("a:real", parsed.chat)
        assertEquals(JsonPrimitive("prj-example"), parsed.record.visible["project"])
    }

    @Test fun invalidProjectValuesAndContinuationSpoofsAreRefused() {
        for (value in listOf<JsonElement>(JsonPrimitive(1), JsonPrimitive("wrong"), JsonPrimitive("prj-a/b"))) {
            assertNull(ChatSend.read(request { put("project", value) }, "android"))
        }
        assertNull(ChatSend.read(request { put("chat", "a:sender-forged") }, "android"))
        assertNull(ChatSend.read(request(setOf("agentText")) { put("text", "A continuation") }, "android"))
        assertNull(ChatSend.read(request(setOf("kind")), "android"))
        assertNull(ChatSend.read(request(setOf("cli")), "android"))
    }

    @Test fun projectAndReceiptWritersCannotBeBorrowedFromAnotherDevice() {
        val source = request()
        val foreignProject = source.updated(JsonObject(source.visible + ("project" to JsonPrimitive("prj-other"))), Clock("stranger", now = { 102 }))
        assertNull(ChatSend.read(foreignProject, "android"))
        val foreignClaim = source.updated(JsonObject(source.visible + mapOf("state" to JsonPrimitive("taken"), "chat" to JsonPrimitive("a:real"))), Clock("stranger", now = { 102 }))
        assertNull(ChatSend.read(foreignClaim, "android"))
        assertNull(ChatSend.read(source, "other-android"))
    }

    @Test fun ordinaryAbsentProjectEnvelopeAndCancellationStayUnchanged() {
        val source = request(setOf("project"))
        assertEquals(ChatSend.State.WAITING, requireNotNull(ChatSend.read(source, "android")).state)
        assertFalse(source.visible.containsKey("project"))
        assertNotNull(ChatSend.read(request { put("project", JsonNull) }, "android"))
        val project = request()
        val cancelled = project.updated(JsonObject(project.visible + ("state" to JsonPrimitive("cancelled"))), phone)
        assertEquals(ChatSend.State.CANCELLED, requireNotNull(ChatSend.read(cancelled, "android")).state)
        assertNull(ChatSend.read(project.updated(JsonObject(project.visible + ("state" to JsonPrimitive("cancelled"))), mac), "android"))
    }
}

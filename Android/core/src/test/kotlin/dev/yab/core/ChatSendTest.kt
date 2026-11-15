package dev.yab.core

import dev.yab.core.sync.*
import java.security.MessageDigest
import java.util.Base64
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatSendTest {
    private val phone = Clock("android", now = { 100 })
    private val mac = Clock("mac", now = { 101 })
    private fun record(extra: JsonObjectBuilder.() -> Unit = {}) = Record("send", "request").updated(buildJsonObject {
        put("device", "mac"); put("clientDevice", "android"); put("clientChat", "local-chat"); put("at", 1_800_000_000.125)
        put("kind", "agent"); put("cli", "claude"); put("agentText", "Page context and question"); put("question", "Human question"); extra()
    }, phone)
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun file(bytes: ByteArray) = buildJsonObject {
        put("name", "file.txt"); put("type", "text/plain"); put("size", bytes.size); put("digest", hash(bytes))
        put("parts", buildJsonArray { repeat(maxOf(1, (bytes.size + 47_999) / 48_000)) { add("request/0/$it") } })
    }

    @Test fun actualMacReceiptsAreDistinctAndCannotBeAssertedByAnotherWriter() {
        val source = record()
        assertEquals(ChatSend.State.WAITING, ChatSend.read(source, "android")!!.state)
        for ((word, state) in listOf("processing" to ChatSend.State.PROCESSING, "taken" to ChatSend.State.TAKEN,
            "failed" to ChatSend.State.FAILED, "expired" to ChatSend.State.EXPIRED)) {
            val changed = source.updated(JsonObject(source.visible + mapOf("state" to JsonPrimitive(word), "reason" to JsonPrimitive("Actual reason"))), mac)
            assertEquals(state, ChatSend.read(changed, "android")!!.state)
            assertEquals("Actual reason", ChatSend.read(changed, "android")!!.reason)
            assertNull(ChatSend.read(source.updated(JsonObject(source.visible + ("state" to JsonPrimitive(word))), Clock("other", now = { 102 })), "android"))
        }
        val cancelled = source.updated(JsonObject(source.visible + ("state" to JsonPrimitive("cancelled"))), phone)
        assertEquals(ChatSend.State.CANCELLED, ChatSend.read(cancelled, "android")!!.state)
        assertNull(ChatSend.read(source.updated(JsonObject(source.visible + ("state" to JsonPrimitive("cancelled"))), mac), "android"))
        assertNull(ChatSend.read(source.removed(Stamp(102, device = "android")), "android"))
        assertNull(ChatSend.read(source, "another-phone"))
    }

    @Test fun actionOpenUnknownStateAndMalformedEnvelopesAreNotQueuedChatRequests() {
        for (extra in listOf<JsonObjectBuilder.() -> Unit>({ put("action", "delete") }, { put("kind", "open"); put("url", "https://site.test") },
            { put("state", "future-state") }, { put("cli", "unrecognized") }, { put("choice", 1) }, { put("at", "yesterday") })) {
            assertNull(ChatSend.read(record(extra), "android"))
        }
        val changedOwner = record().let { it.updated(JsonObject(it.visible + ("device" to JsonPrimitive("other-mac"))), mac) }
        assertNull(ChatSend.read(changedOwner, "android"))
    }

    @Test fun attachmentReconstructionChecksEveryPartSizeDigestAndSendIdentity() {
        val bytes = ByteArray(48_007) { (it % 251).toByte() }
        val request = ChatSend.read(record { put("files", buildJsonArray { add(file(bytes)) }) }, "android")!!
        val parts = (0 until bytes.size step 48_000).mapIndexed { n, start ->
            val id = "request/0/$n"
            Record("sendpart", id).updated(buildJsonObject { put("send", "request"); put("data", Base64.getEncoder().encodeToString(bytes.copyOfRange(start, minOf(start + 48_000, bytes.size)))) }, phone)
        }.associateBy { it.key }
        assertArrayEquals(bytes, request.assemble(parts::get).single().second)
        assertThrows(Exception::class.java) { request.assemble { key -> parts[key]?.takeUnless { it.id.endsWith("/1") } } }
        val bad = parts.mapValues { (_, part) -> part.updated(JsonObject(part.visible + ("data" to JsonPrimitive("AA=="))), phone) }
        assertThrows(IllegalArgumentException::class.java) { request.assemble(bad::get) }
        val other = parts.mapValues { (_, part) -> part.updated(JsonObject(part.visible + ("send" to JsonPrimitive("different-send"))), phone) }
        assertThrows(IllegalArgumentException::class.java) { request.assemble(other::get) }
    }

    @Test fun zeroByteFilesRetainTheirSingleAuthenticatedEmptyPartAndBoundsCannotBeForged() {
        val bytes = byteArrayOf()
        val request = ChatSend.read(record { put("files", buildJsonArray { add(file(bytes)) }) }, "android")!!
        val part = Record("sendpart", "request/0/0").updated(buildJsonObject { put("send", "request"); put("data", "") }, phone)
        assertArrayEquals(bytes, request.assemble { part }.single().second)
        val foreign = JsonObject(file(bytes) + ("parts" to JsonArray(listOf(JsonPrimitive("different/0/0")))))
        assertNull(ChatSend.read(record { put("files", buildJsonArray { add(foreign) }) }, "android"))
        assertNull(ChatSend.read(record { put("files", buildJsonArray { repeat(11) { add(file(bytes)) } }) }, "android"))
        assertNull(ChatSend.read(record { put("files", buildJsonArray { add(JsonObject(file(bytes) + ("size" to JsonPrimitive(10_000_001)))) }) }, "android"))
    }

    @Test fun aLateMacClaimRejectsTheWholeCancelAndNewSendTransaction() {
        MemoryJournal("android", now = { 102 }).use { journal ->
            val waiting = record(); journal.receive(listOf(VersionedRecord(waiting, 1)))
            val claimed = waiting.updated(JsonObject(waiting.visible + ("state" to JsonPrimitive("processing"))), mac)
            journal.receive(listOf(VersionedRecord(claimed, 2)))
            val fresh = RecordKey("send", "redirected")
            assertThrows(IllegalArgumentException::class.java) { journal.changeBatch(mapOf(waiting.key to JsonObject(waiting.visible + ("state" to JsonPrimitive("cancelled"))), fresh to waiting.visible), mapOf(waiting.key to waiting, fresh to null)) }
            assertEquals(claimed, journal.record(waiting.key)); assertNull(journal.record(fresh)); assertTrue(journal.pending().isEmpty())
        }
    }
}

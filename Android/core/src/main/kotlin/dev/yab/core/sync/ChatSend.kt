package dev.yab.core.sync

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64
import kotlinx.serialization.json.*

/** The existing SyncKit send envelope. A processing receipt is already claimed, never movable. */
data class ChatSend(val record: Record, val device: String, val clientChat: String, val chat: String?, val cli: String?,
    val question: String, val prompt: String, val at: Double, val state: State, val reason: String?, val files: List<File>, val project: String? = null) {
    enum class State { WAITING, PROCESSING, TAKEN, FAILED, EXPIRED, CANCELLED }
    data class File(val name: String, val type: String, val size: Int, val digest: String, val parts: List<String>)
    val id get() = record.id

    /** Reconstruction refuses missing or changed bytes; a retry cannot silently drop attachments. */
    fun assemble(read: (RecordKey) -> Record?): List<Pair<File, ByteArray>> = files.map { file ->
        val output = ByteArrayOutputStream(file.size)
        for (id in file.parts) {
            val part = read(RecordKey("sendpart", id)) ?: error("This attachment is no longer available")
            require(part.alive() && part.schema == 1 && (part["send"] as? JsonPrimitive)?.takeIf { it.isString }?.content == this.id) { "The attachment changed" }
            val encoded = (part["data"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: error("The attachment is unreadable")
            require(encoded.length <= 64_004) { "The attachment part is too large" }
            val bytes = Base64.getDecoder().decode(encoded)
            require(bytes.size <= 48_000 && output.size().toLong() + bytes.size <= file.size) { "The attachment size changed" }
            output.write(bytes)
        }
        val bytes = output.toByteArray()
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
        require(bytes.size == file.size && hash.equals(file.digest, true)) { "The attachment digest changed" }
        file to bytes
    }

    companion object {
        private fun JsonObject.text(key: String) = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content
        private fun JsonObject.number(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
        fun read(record: Record, sender: String): ChatSend? = runCatching {
            require(record.collection == "send" && record.schema == 1 && record.alive())
            val fields = record.visible
            val device = fields.text("device")?.takeIf(String::isNotBlank) ?: return null
            val clientChat = fields.text("clientChat")?.takeIf(String::isNotBlank) ?: return null
            require(fields.text("clientDevice") == sender)
            require(listOf("device", "clientDevice", "clientChat", "at").all { record.stamps[it]?.device == sender })
            require(listOf("action", "choice", "answerIndex", "choiceQuestion", "url").all { fields[it] == null })
            require(listOf("kind", "chat", "cli", "text", "agentText", "question", "state", "reason").all { fields[it] == null || (fields[it] as? JsonPrimitive)?.isString == true })
            require(fields.text("kind") in setOf(null, "agent"))
            val chat = fields.text("chat")
            require(chat == null || chat.startsWith("a:") && chat.length > 2)
            val cli = fields.text("cli")
            require(cli == null || ChatAgent.fromWire(cli) != null)
            val project = fields.text("project")
            require(fields["project"] == null || project != null && ChatProjects.valid(project) &&
                fields.text("kind") == "agent" && cli != null && fields["text"] == null &&
                (chat == null || record.stamps["chat"]?.device == device) && record.stamps["project"]?.device == sender)
            require(fields["text"] == null || fields["agentText"] == null)
            require(cli == null || fields.text("agentText") != null)
            val prompt = fields.text("text") ?: fields.text("agentText") ?: ""
            val question = fields.text("question") ?: prompt
            require(prompt.toByteArray().size <= 524_288 && question.toByteArray().size <= 524_288)
            val at = fields.number("at")?.takeIf { it.isFinite() && it > 0 && it * 1000 <= Long.MAX_VALUE } ?: return null
            val state = when (fields.text("state")) {
                null -> State.WAITING
                "processing" -> State.PROCESSING
                "taken" -> State.TAKEN
                "failed" -> State.FAILED
                "expired" -> State.EXPIRED
                "cancelled" -> State.CANCELLED
                else -> return null
            }
            if (state != State.WAITING) require(record.stamps["state"]?.device == if (state == State.CANCELLED) sender else device)
            val value = fields["files"]
            val items = if (value == null || value == JsonNull) emptyList() else (value as? JsonArray ?: return null).toList()
            require(items.size <= 10)
            val files = items.mapIndexed { index, value ->
                val file = value as? JsonObject ?: error("Invalid attachment")
                val name = file.text("name")?.substringAfterLast('/')?.takeIf { it.isNotBlank() && it !in setOf(".", "..") } ?: error("Invalid attachment name")
                val size = file.number("size")?.takeIf { it.isFinite() && it in 0.0..10_000_000.0 && it % 1 == 0.0 }?.toInt() ?: error("Invalid attachment size")
                val digest = file.text("digest")?.takeIf { it.matches(Regex("[0-9a-fA-F]{64}")) } ?: error("Invalid attachment digest")
                val parts = (file["parts"] as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: error("Invalid attachment part") } ?: error("Missing attachment parts")
                require(parts.size == maxOf(1, (size + 47_999) / 48_000) && parts.distinct().size == parts.size && parts.all { it.startsWith("${record.id}/$index/") })
                File(name, file.text("type") ?: "application/octet-stream", size, digest, parts)
            }
            require(files.sumOf { it.size.toLong() } <= 20_000_000 && (prompt.isNotBlank() || files.isNotEmpty()))
            ChatSend(record, device, clientChat, chat, cli, question, prompt, at, state, fields.text("reason"), files, project)
        }.getOrNull()
    }
}

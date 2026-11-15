package dev.yab.agent

import kotlinx.serialization.json.*

/** Existing AssistantApprovalDetails.File fields; dimensions are layout metadata, not decoded image bounds. */
internal object ApprovalFileCodec {
    fun read(value: JsonObject): ApprovalFile {
        fun string(name: String) = (value[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun number(name: String) = (value[name] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
        fun dimension(name: String): Int? {
            val raw = value[name]?.takeUnless { it == JsonNull } ?: return null
            val primitive = requireNotNull(raw as? JsonPrimitive) { "Invalid file $name" }
            val number = requireNotNull(primitive.takeUnless { it.isString }?.doubleOrNull) { "Invalid file $name" }
            require(number.isFinite() && number >= Int.MIN_VALUE.toDouble() && number <= Int.MAX_VALUE.toDouble() && number == number.toInt().toDouble()) { "Invalid file $name" }
            return number.toInt()
        }
        val id = string("id") ?: error("Missing file")
        require(id.isNotEmpty() && id.toByteArray().size <= 64 && '.' !in id)
        val kind = string("kind"); require(kind in setOf("pdf", "image", "file"))
        val previews = number("previews") ?: 0.0; require(previews in 0.0..12.0 && previews == previews.toInt().toDouble())
        val total = number("pages") ?: 0.0; require(total.isFinite() && total in 0.0..Int.MAX_VALUE.toDouble() && total == total.toInt().toDouble())
        return ApprovalFile(id, string("name") ?: "", when (kind) {
            "pdf" -> "application/pdf"; "image" -> "image/jpeg"; else -> "application/octet-stream"
        }, number("bytes")?.toLong() ?: 0, total.toInt(), previews.toInt(), dimension("width"), dimension("height"))
    }
}

package dev.yab.core.sync

import java.util.regex.Pattern
import kotlinx.serialization.json.*

/** SyncKit's project record. Project data may be written by any account device. */
data class SyncProject(
    val id: String,
    val name: String,
    val emoji: String,
    val tint: String,
    val instructions: String = "",
    val memoryOn: Boolean = true,
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val order: String,
    val created: Double,
    val updated: Double,
) {
    val fields: JsonObject get() = buildJsonObject {
        put("name", ProjectCharacters.prefix(name, 200))
        put("emoji", ProjectCharacters.prefix(emoji, 16))
        put("tint", tint)
        put("instructions", ProjectCharacters.prefix(instructions, 8000))
        put("memoryOn", memoryOn)
        put("pinned", if (pinned) JsonPrimitive(true) else JsonNull)
        put("archived", if (archived) JsonPrimitive(true) else JsonNull)
        put("order", order)
        put("created", created)
        put("updated", updated)
    }

    companion object {
        fun read(record: Record): SyncProject? {
            if (record.collection != ChatProjects.COLLECTION || !record.alive() || !ChatProjects.valid(record.id)) return null
            val fields = record.visible
            val name = fields.projectText("name") ?: return null
            val created = fields.projectNumber("created") ?: 0.0
            return SyncProject(record.id, name, fields.projectText("emoji") ?: "", fields.projectText("tint") ?: "blue",
                fields.projectText("instructions") ?: "", fields.projectBoolean("memoryOn") != false,
                fields.projectBoolean("pinned") == true, fields.projectBoolean("archived") == true,
                fields.projectText("order") ?: "", created, fields.projectNumber("updated") ?: created)
        }

        /** Pinned order/id uses Swift's canonical string comparison; unpinned ties stay stable. */
        fun all(records: List<Record>): List<SyncProject> = records.mapNotNull(::read).sortedWith { a, b ->
            when {
                a.pinned != b.pinned -> if (a.pinned) -1 else 1
                a.pinned -> wireCompare(a.order, b.order).takeIf { it != 0 } ?: wireCompare(a.id, b.id)
                a.updated > b.updated -> -1
                a.updated < b.updated -> 1
                else -> 0
            }
        }
    }
}

/** Wire compatibility only. This capability does not itself enable an Android project command. */
object ChatProjects {
    const val COLLECTION = "project"
    const val VERSION = 1
    const val FIELD = "chatProjects"
    const val MISSING = "That project isn't on this Mac any more."

    fun valid(id: String?): Boolean = id != null && id.startsWith("prj-") && '/' !in id &&
        ProjectCharacters.countThrough(id, 41) in 5..40

    /** Stricter than Swift's helper: retain Android's schema and self-writer capability discipline. */
    fun supports(record: Record?, device: String): Boolean = record != null && record.collection == "commandcap" &&
        record.id == device && record.schema == 1 && record.alive() && record.visible.projectText("device") == device &&
        record.stamps["device"]?.device == device && record.visible.projectNumber(FIELD) == VERSION.toDouble() &&
        record.stamps[FIELD]?.device == device
}

private fun JsonObject.projectText(name: String): String? = (get(name) as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.projectNumber(name: String): Double? = (get(name) as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
private fun JsonObject.projectBoolean(name: String): Boolean? = (get(name) as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull

/** The existing Android chat policy uses Java's extended-grapheme matcher for Swift Character. */
private object ProjectCharacters {
    private val grapheme = Pattern.compile("\\X")

    fun prefix(value: String, limit: Int): String {
        val matcher = grapheme.matcher(value)
        var end = 0
        var count = 0
        while (count < limit && matcher.find()) { end = matcher.end(); count++ }
        return value.substring(0, end)
    }

    fun countThrough(value: String, limit: Int): Int {
        val matcher = grapheme.matcher(value)
        var count = 0
        while (count < limit && matcher.find()) count++
        return count
    }
}

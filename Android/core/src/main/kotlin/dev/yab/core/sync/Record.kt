package dev.yab.core.sync

import kotlinx.serialization.json.*
import java.text.Normalizer

internal val wireJson = Json { ignoreUnknownKeys = true }

/** Swift String comparisons normalize canonical Unicode before comparing. */
internal fun wireCompare(a: String, b: String): Int {
    // Plain ASCII is its own normal form, and nearly every key is plain ASCII.
    if (a.all { it < '\u0080' } && b.all { it < '\u0080' }) return a.compareTo(b)
    val left = Normalizer.normalize(a, Normalizer.Form.NFC).codePoints().toArray()
    val right = Normalizer.normalize(b, Normalizer.Form.NFC).codePoints().toArray()
    for (i in 0 until minOf(left.size, right.size)) if (left[i] != right[i]) return left[i].compareTo(right[i])
    return left.size.compareTo(right.size)
}

data class Stamp(val wall: Long, val count: Long = 0, val device: String) : Comparable<Stamp> {
    init { require(count in 0..0xffff_ffffL) }
    override fun compareTo(other: Stamp): Int = wall.compareTo(other.wall).takeIf { it != 0 }
        ?: count.compareTo(other.count).takeIf { it != 0 } ?: wireCompare(device, other.device)
    fun toJson(): JsonObject = buildJsonObject { put("wall", wall); put("count", count); put("device", device) }
    companion object {
        fun fromJson(json: JsonObject) = Stamp(json.getValue("wall").jsonPrimitive.long,
            json.getValue("count").jsonPrimitive.long, json.getValue("device").jsonPrimitive.content)
    }
}

class Clock(val device: String, last: Stamp? = null, private val now: () -> Long = System::currentTimeMillis) {
    private var last = last ?: Stamp(0, device = device)
    @Synchronized fun tick(): Stamp {
        val wall = now()
        last = if (wall > last.wall) Stamp(wall, device = device)
            else Stamp(last.wall, (last.count + 1) and 0xffff_ffffL, device)
        return last
    }
    @Synchronized fun observe(stamp: Stamp): Boolean {
        if (stamp.wall > now() + DRIFT) return false
        if (stamp.wall > last.wall || stamp.wall == last.wall && stamp.count > last.count)
            last = Stamp(stamp.wall, stamp.count, device)
        return true
    }
    @Synchronized fun latest(): Stamp = last
    companion object { const val DRIFT = 86_400_000L }
}

data class RecordKey(val collection: String, val id: String) : Comparable<RecordKey> {
    override fun compareTo(other: RecordKey) = wireCompare(collection, other.collection).takeIf { it != 0 } ?: wireCompare(id, other.id)
    override fun toString(): String = "$collection/$id"
}

enum class MergeRule { LAST, MOST, PER_DEVICE }
data class Kind(val name: String, val removalWins: Boolean = false,
                val rules: Map<String, MergeRule> = emptyMap(), val groups: List<List<String>> = emptyList())

object Collections {
    private val place = listOf("parent", "order")
    private val known = listOf(
        Kind("space", groups = listOf(place, listOf("icon", "iconChoice", "iconChoiceID"))), Kind("tab", true, mapOf("seen" to MergeRule.MOST), listOf(place)),
        Kind("folder", groups = listOf(place + "folder")), Kind("pair", true), Kind("bookmark", groups = listOf(place)),
        Kind("visit", rules = mapOf("last" to MergeRule.MOST)), Kind("sendpart", true),
        Kind("login", rules = mapOf("used" to MergeRule.MOST)), Kind("taskcommand", true), Kind("task", true),
        Kind("assistantapproval", true), Kind("assistantanswer", true), Kind("assistantdetail", true),
        Kind("assistantpreview", true), Kind("assistantresult", true)
    ).associateBy { it.name }
    fun kind(collection: String): Kind = known[collection] ?: Kind(collection)
}

data class Record(val collection: String, val id: String, val fields: JsonObject = JsonObject(emptyMap()),
                  val stamps: Map<String, Stamp> = emptyMap(), val deleted: Stamp? = null, val schema: Int = 1,
                  val unknown: JsonObject = JsonObject(emptyMap())) {
    val key: RecordKey get() = RecordKey(collection, id)
    // SyncKit Value decodes every JSON number as Double; 2 and 2.0 are the same field value.
    override fun equals(other: Any?): Boolean = other is Record && collection == other.collection && id == other.id &&
        semanticJson(fields) == semanticJson(other.fields) && stamps == other.stamps && deleted == other.deleted && schema == other.schema && semanticJson(unknown) == semanticJson(other.unknown)
    override fun hashCode(): Int = listOf(collection, id, semanticJson(fields), stamps, deleted, schema, semanticJson(unknown)).hashCode()
    fun alive(kind: Kind = Collections.kind(collection)): Boolean = deleted?.let { !kind.removalWins && stamps.values.any { stamp -> stamp > it } } ?: true
    val visible: JsonObject get() = JsonObject(fields.filter { (name, value) -> value != JsonNull && (deleted == null || stamps[name]?.let { it > deleted } == true) })
    operator fun get(name: String): JsonElement? = visible[name]
    fun total(name: String): Double = (visible[name] as? JsonObject)?.values?.mapNotNull { (it as? JsonPrimitive)?.doubleOrNull }?.sum() ?: 0.0
    fun removed(at: Stamp): Record = copy(deleted = maxOfNullable(deleted, at))

    fun updated(want: JsonObject, clock: Clock, kind: Kind = Collections.kind(collection)): Record {
        val current = visible
        val changes = linkedMapOf<String, JsonElement>()
        for ((name, value) in want) if (value != JsonNull) {
            if (kind.rules[name] == MergeRule.PER_DEVICE) {
                if (value == current[name]) continue
                val parts = (current[name] as? JsonObject)?.toMutableMap() ?: mutableMapOf()
                if (parts[clock.device] == value) continue
                parts[clock.device] = value
                changes[name] = JsonObject(parts)
            } else if (current[name] != value) changes[name] = value
        }
        for (name in current.keys) if (want[name] == null || want[name] == JsonNull) changes[name] = JsonNull
        val gone = !alive(kind)
        if (changes.isEmpty() && !gone || gone && kind.removalWins) return this
        val stamp = clock.tick()
        for (group in kind.groups) if (group.any { changes.containsKey(it) })
            for (name in group) changes.putIfAbsent(name, current[name] ?: JsonNull)
        if (gone) {
            for ((name, value) in current) changes.putIfAbsent(name, value)
            if (changes.isEmpty()) changes["_"] = JsonPrimitive(true)
        }
        return copy(fields = JsonObject(fields + changes), stamps = stamps + changes.keys.associateWith { stamp })
    }

    fun merged(other: Record, kind: Kind = Collections.kind(collection)): Record {
        require(key == other.key) { "Cannot merge different records" }
        val values = fields.toMutableMap()
        val clocks = stamps.toMutableMap()
        val grouped = kind.groups.flatten().toSet()
        for (group in kind.groups) {
            val a = group.mapNotNull { stamps[it] }.maxOrNull()
            val b = group.mapNotNull { other.stamps[it] }.maxOrNull()
            if (b != null && (a == null || b > a)) for (name in group) {
                other.fields[name]?.let { values[name] = it } ?: values.remove(name)
                other.stamps[name]?.let { clocks[name] = it } ?: clocks.remove(name)
            }
        }
        for (name in (other.fields.keys + other.stamps.keys) - grouped) {
            val a = stamps[name]; val b = other.stamps[name]
            when (kind.rules[name] ?: MergeRule.LAST) {
                MergeRule.LAST -> if (b != null && (a == null || b > a)) {
                    other.fields[name]?.let { values[name] = it } ?: values.remove(name)
                    clocks[name] = b
                }
                MergeRule.MOST -> {
                    val x = (fields[name] as? JsonPrimitive)?.doubleOrNull
                    val y = (other.fields[name] as? JsonPrimitive)?.doubleOrNull
                    values[name] = listOfNotNull(x, y).maxOrNull()?.let(::JsonPrimitive) ?: other.fields[name] ?: fields[name] ?: JsonNull
                    maxOfNullable(a, b)?.let { clocks[name] = it }
                }
                MergeRule.PER_DEVICE -> {
                    val parts = (fields[name] as? JsonObject)?.toMutableMap() ?: mutableMapOf()
                    for ((device, value) in (other.fields[name] as? JsonObject).orEmpty()) {
                        val mine = parts[device]
                        val x = (mine as? JsonPrimitive)?.doubleOrNull ?: Double.NEGATIVE_INFINITY
                        val y = (value as? JsonPrimitive)?.doubleOrNull ?: Double.NEGATIVE_INFINITY
                        if (mine == null || y > x || y == x && value.toString() > mine.toString()) parts[device] = value
                    }
                    values[name] = JsonObject(parts)
                    maxOfNullable(a, b)?.let { clocks[name] = it }
                }
            }
        }
        return copy(fields = JsonObject(values), stamps = clocks, deleted = maxOfNullable(deleted, other.deleted),
            schema = maxOf(schema, other.schema), unknown = JsonObject((unknown.keys + other.unknown.keys).associateWith { name ->
                listOfNotNull(unknown[name], other.unknown[name]).maxBy { it.toString() }
            }))
    }

    fun toJson(): JsonObject = buildJsonObject {
        for ((name, value) in unknown) put(name, value)
        put("collection", collection); put("id", id); put("fields", fields)
        put("stamps", JsonObject(stamps.mapValues { it.value.toJson() })); deleted?.let { put("deleted", it.toJson()) }; put("schema", schema)
    }
    companion object {
        private val names = setOf("collection", "id", "fields", "stamps", "deleted", "schema")
        fun fromJson(json: JsonObject): Record = Record(json.getValue("collection").jsonPrimitive.content,
            json.getValue("id").jsonPrimitive.content, json.getValue("fields").jsonObject,
            json.getValue("stamps").jsonObject.mapValues { Stamp.fromJson(it.value.jsonObject) },
            json["deleted"]?.takeUnless { it == JsonNull }?.jsonObject?.let(Stamp::fromJson),
            json.getValue("schema").jsonPrimitive.int, JsonObject(json.filterKeys { it !in names }))
        fun parse(text: String): Record = fromJson(wireJson.parseToJsonElement(text).jsonObject)
    }
}

internal fun <T : Comparable<T>> maxOfNullable(a: T?, b: T?): T? = when { a == null -> b; b == null -> a; else -> maxOf(a, b) }

private fun semanticJson(value: JsonElement): JsonElement = when (value) {
    is JsonObject -> JsonObject(value.mapValues { semanticJson(it.value) })
    is JsonArray -> JsonArray(value.map(::semanticJson))
    is JsonPrimitive -> if (!value.isString) value.doubleOrNull?.let { JsonPrimitive(if (it == 0.0) 0.0 else it) } ?: value else value
}

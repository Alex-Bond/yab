package dev.yab.core.sync

import kotlinx.serialization.json.*
import java.io.File
import java.io.FileOutputStream
import java.math.BigDecimal
import java.net.URI
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

/** The production SyncKit read-only task wire contract. It grants no execution authority. */
object TaskRecords {
    const val REQUEST = "taskcommand"
    const val OBSERVATION = "task"
    const val BODY_LIMIT = 524_288
    private val requestNames = setOf("version", "id", "account", "phone", "mac", "space", "tab", "url", "title", "words", "created", "readOnlyEpoch")
    private val observationNames = setOf("version", "task", "requestDigest", "account", "phone", "mac", "revision", "session", "status", "title", "progress", "result", "resultURL")
    private val optional = setOf("tab", "url", "title", "readOnlyEpoch")
    private fun JsonObject.text(name: String): String? = (get(name) as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.required(name: String): String = text(name) ?: error("Invalid task $name")
    private fun identity(value: String) = value.isNotEmpty() && value.toByteArray().size <= 200 && value.none(Char::isISOControl)
    fun uuid(value: String): Boolean = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
    fun web(value: String): String? = runCatching { URI(value).takeIf { value.toByteArray().size <= 8192 && it.scheme?.lowercase() in setOf("http", "https") && !it.host.isNullOrEmpty() && it.rawUserInfo == null && value.none(Char::isISOControl) }?.toASCIIString() }.getOrNull()
    private fun canonical(body: JsonObject): String = body.entries.sortedBy { it.key }.joinToString(",", "{", "}") { (key, value) ->
        JsonPrimitive(key).toString() + ":" + if (key == "created") value.toString().replace(Regex("\\.0+(?=([eE]|$))"), "") else value.toString()
    }
    private fun selected(body: JsonObject, names: Set<String>, nullable: Set<String>): JsonObject {
        require(body.toString().toByteArray().size <= BODY_LIMIT)
        for (name in names - nullable) require(body[name] != null && body[name] != JsonNull) { "Missing task $name" }
        return JsonObject(body.filter { (name, value) -> name in names && value != JsonNull }.mapValues { (name, value) ->
            if (name in setOf("version", "revision", "created")) {
                require(value is JsonPrimitive && !value.isString)
                if (name == "created") { require(value.doubleOrNull?.isFinite() == true); value }
                else Json.parseToJsonElement(BigDecimal(value.content).toBigIntegerExact().toString().also { it.toULong() })
            } else { require(value is JsonPrimitive && value.isString); value }
        })
    }
    fun supports(record: Record?, mac: String): Boolean = record != null && record.collection == "commandcap" && record.id == mac && record.schema == 1 && record.alive() &&
        record.visible.text("device") == mac && record.stamps["device"]?.device == mac &&
        (record["taskRecords"] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull == 1.0 && record.stamps["taskRecords"]?.device == mac
    fun readOnlyEpoch(record: Record?, mac: String): String? {
        if (!supports(record, mac)) return null
        val value = record!!["taskReadOnlyEpoch"] as? JsonPrimitive
        return value?.takeIf { it.isString && uuid(it.content) && record.stamps["taskReadOnlyEpoch"]?.device == mac &&
            (record["taskReadOnly"] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull == 1.0 && record.stamps["taskReadOnly"]?.device == mac }?.content
    }
    private fun read(record: Record, collection: String, writer: String): JsonObject {
        require(record.collection == collection && record.schema == 1 && record.alive() && record.fields.keys == setOf("body") && record.stamps["body"]?.device == writer)
        val text = record.visible.required("body"); require(text.toByteArray().size <= BODY_LIMIT)
        return Json.parseToJsonElement(text).jsonObject
    }
    class Request private constructor(val facts: JsonObject) {
        override fun equals(other: Any?): Boolean = other is Request && body() == other.body()
        override fun hashCode(): Int = body().hashCode()
        val id get() = facts.required("id"); val account get() = facts.required("account"); val phone get() = facts.required("phone")
        val mac get() = facts.required("mac"); val space get() = facts.required("space"); val tab get() = facts.text("tab")
        val url get() = facts.text("url"); val title get() = facts.text("title"); val words get() = facts.required("words")
        val created get() = facts.getValue("created").jsonPrimitive.double; val readOnlyEpoch get() = facts.text("readOnlyEpoch")
        fun body(): String = canonical(facts)
        fun fields(): JsonObject = buildJsonObject { put("body", body()) }
        fun digest(): String = MessageDigest.getInstance("SHA-256").digest(("yab task request v1\n" + body()).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
        companion object {
            fun create(account: String, phone: String, mac: String, space: String, words: String, readOnlyEpoch: String,
                       tab: String? = null, url: String? = null, title: String? = null, id: String = UUID.randomUUID().toString(), created: Long = System.currentTimeMillis() / 1000): Request = decode(buildJsonObject {
                put("version", 1); put("id", id); put("account", account); put("phone", phone); put("mac", mac); put("space", space)
                put("words", words); put("created", created); put("readOnlyEpoch", readOnlyEpoch)
                tab?.let { put("tab", it) }; url?.let { put("url", it) }; title?.let { put("title", it) }
            })
            fun decode(body: JsonObject): Request {
                val request = Request(selected(body, requestNames, optional))
                require(request.facts["version"]?.jsonPrimitive?.intOrNull == 1 && uuid(request.id) && listOf(request.account, request.phone, request.mac, request.space).all(::identity) && request.phone != request.mac)
                require(request.tab?.let(::identity) != false && request.words.isNotBlank() && request.words.toByteArray().size <= BODY_LIMIT && request.created > 0)
                require(request.readOnlyEpoch?.let(::uuid) != false && (request.url == null || web(request.url!!) != null))
                require(request.title?.toByteArray()?.size?.let { it <= BODY_LIMIT } != false && (request.tab != null || request.url == null && request.title == null))
                require(request.body().toByteArray().size <= BODY_LIMIT)
                return request
            }
            fun read(record: Record, account: String, phone: String): Request = decode(TaskRecords.read(record, REQUEST, phone)).also { require(it.id == record.id && it.account == account && it.phone == phone) }
        }
    }
    enum class Status { running, needsYou, waits, failed, done, stopped }
    class Observation private constructor(val facts: JsonObject) {
        override fun equals(other: Any?): Boolean = other is Observation && body() == other.body()
        override fun hashCode(): Int = body().hashCode()
        val task get() = facts.required("task"); val account get() = facts.required("account"); val phone get() = facts.required("phone"); val mac get() = facts.required("mac")
        val revision get() = facts.getValue("revision").jsonPrimitive.content.toULong(); val session get() = facts.text("session")
        val status get() = Status.valueOf(facts.required("status")); val title get() = facts.required("title"); val progress get() = facts.required("progress")
        val result get() = facts.text("result"); val resultURL get() = facts.text("resultURL")
        fun body(): String = canonical(facts)
        fun fields(): JsonObject = buildJsonObject { put("body", body()) }
        fun validate(request: Request) {
            require(facts["version"]?.jsonPrimitive?.intOrNull == 1 && task == request.id && account == request.account && phone == request.phone && mac == request.mac && facts.required("requestDigest") == request.digest() && revision > 0uL)
            require(session?.let(::identity) != false && listOfNotNull(title, progress, result).all { it.toByteArray().size <= BODY_LIMIT } && (resultURL == null || web(resultURL!!) != null))
            require(status != Status.done || session != null && !result.isNullOrEmpty())
            require(status != Status.running || session != null)
            require(status == Status.done || result == null && resultURL == null)
        }
        companion object {
            fun decode(body: JsonObject, request: Request): Observation = Observation(selected(body, observationNames, setOf("session", "result", "resultURL"))).also { it.validate(request) }
            fun read(record: Record, request: Request): Observation = decode(TaskRecords.read(record, OBSERVATION, request.mac), request).also { require(record.id == request.id) }
        }
    }
}

/** Retain the greatest checked revision before UI delivery, independently of CRDT field clocks. */
class TaskRecordInbox(private val file: File, private val account: String, private val phone: String) {
    companion object { private val lock = Any(); private const val LIMIT = 8_388_608 }
    init { synchronized(lock) { read() } }
    private fun read(): Map<String, JsonObject> {
        if (!file.exists()) return emptyMap()
        require(file.length() <= LIMIT)
        val body = Json.parseToJsonElement(file.readText()).jsonObject
        require(body["account"]?.jsonPrimitive?.content == account && body["phone"]?.jsonPrimitive?.content == phone)
        return body.getValue("observations").jsonObject.mapValues { it.value.jsonObject }
    }
    fun current(request: TaskRecords.Request): TaskRecords.Observation? = synchronized(lock) {
        require(request.account == account && request.phone == phone)
        read()[request.id]?.let { TaskRecords.Observation.decode(it, request) }
    }
    fun accept(observation: TaskRecords.Observation, request: TaskRecords.Request): Boolean = synchronized(lock) {
        require(request.account == account && request.phone == phone); observation.validate(request)
        val had = read(); val old = had[request.id]?.let { TaskRecords.Observation.decode(it, request) }
        if (old != null) {
            require(observation.revision >= old.revision) { "Stale task observation" }
            if (observation.revision == old.revision) { require(observation == old) { "Conflicting task revision" }; return@synchronized false }
        }
        val next = buildJsonObject { put("account", account); put("phone", phone); put("observations", JsonObject(had + (request.id to observation.facts))) }
        val bytes = next.toString().toByteArray(); require(bytes.size <= LIMIT)
        val parent = file.absoluteFile.parentFile; check(parent.isDirectory || parent.mkdirs())
        val temporary = File.createTempFile(".task-inbox-", ".tmp", parent)
        try {
            FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            java.nio.channels.FileChannel.open(parent.toPath(), java.nio.file.StandardOpenOption.READ).use { it.force(true) }
            check(current(request) == observation) { "Task observation could not be verified" }
        } finally { temporary.delete() }
        true
    }
}

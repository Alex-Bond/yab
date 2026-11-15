package dev.yab.core.sync

import kotlinx.serialization.json.*
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption

data class VersionedRecord(val record: Record, val version: Long)
data class JournalRow(val record: Record, val dirty: Boolean, val version: Long)

/** The same contract can be backed by Room/SQLite without changing client semantics. */
interface Journal : Closeable {
    val device: String
    val cursor: Long
    fun record(key: RecordKey): Record?
    fun all(collection: String? = null): List<Record>
    fun pending(limit: Int = 500): List<VersionedRecord>
    fun isPending(key: RecordKey): Boolean
    fun change(key: RecordKey, fields: JsonObject): Record
    fun changeConditionally(key: RecordKey, fields: JsonObject, expected: Map<RecordKey, Record?>): Record
    fun changeBatch(fields: Map<RecordKey, JsonObject>, expected: Map<RecordKey, Record?> = emptyMap()): Map<RecordKey, Record>
    fun remove(key: RecordKey): Record?
    fun removeConditionally(key: RecordKey, expected: Map<RecordKey, Record?>): Record?
    /** Applying records and advancing the cursor must commit together. */
    fun receive(records: List<VersionedRecord>, cursor: Long? = null): List<Record>
    fun sent(records: List<VersionedRecord>, cursor: Long? = null)
    fun rebase(key: RecordKey, version: Long)
    /** A saved receipt precedes any external action and survives restart. */
    fun reserveReceipt(id: String): Boolean
    fun hasReceipt(id: String): Boolean
}

open class MemoryJournal(final override val device: String, private val now: () -> Long = System::currentTimeMillis) : Journal {
    protected data class Snapshot(val rows: Map<RecordKey, JournalRow> = emptyMap(), val cursor: Long = 0,
                                  val stamp: Stamp? = null, val receipts: Set<String> = emptySet())
    private var snapshot = Snapshot()
    private var clock = Clock(device, now = now)
    private var closed = false
    private var failed = false
    protected open fun persist(snapshot: Snapshot) {}
    protected fun restore(value: JsonObject) {
        require(value.getValue("format").jsonPrimitive.int == 1) { "Unsupported journal format" }
        require(value.getValue("device").jsonPrimitive.content == device) { "Journal belongs to another device" }
        val rows = value.getValue("rows").jsonArray.map { element ->
            val row = element.jsonObject; val record = Record.fromJson(row.getValue("record").jsonObject)
            record.key to JournalRow(record, row.getValue("dirty").jsonPrimitive.boolean, row.getValue("version").jsonPrimitive.long)
        }
        require(rows.map { it.first }.distinct().size == rows.size) { "Duplicate journal record" }
        snapshot = Snapshot(rows.toMap(), value.getValue("cursor").jsonPrimitive.long,
            value["clock"]?.takeUnless { it == JsonNull }?.jsonObject?.let(Stamp::fromJson),
            value.getValue("receipts").jsonArray.map { it.jsonPrimitive.content }.toSet())
        require(snapshot.cursor >= 0 && rows.all { it.second.version >= 0 })
        clock = Clock(device, snapshot.stamp, now)
    }
    protected fun readRow(row: JsonObject, rows: MutableMap<RecordKey, JournalRow>) {
        val record = Record.fromJson(row.getValue("record").jsonObject)
        val version = row.getValue("version").jsonPrimitive.long
        require(version >= 0)
        rows[record.key] = JournalRow(record, row.getValue("dirty").jsonPrimitive.boolean, version)
    }
    protected fun restored(rows: Map<RecordKey, JournalRow>, cursor: Long, stamp: Stamp?, receipts: Set<String>) {
        require(cursor >= 0)
        snapshot = Snapshot(rows, cursor, stamp, receipts)
        clock = Clock(device, stamp, now)
    }
    protected val current: Snapshot get() = snapshot
    protected fun encode(row: JournalRow): JsonObject = buildJsonObject {
        put("record", row.record.toJson()); put("dirty", row.dirty); put("version", row.version)
    }
    private fun checkOpen() { check(!closed && !failed) { "Journal must be reopened" } }
    private fun commit(value: Snapshot) {
        try { persist(value); snapshot = value } catch (error: Exception) { failed = true; throw error }
    }
    @get:Synchronized final override val cursor: Long get() { checkOpen(); return snapshot.cursor }
    @Synchronized final override fun record(key: RecordKey): Record? { checkOpen(); return snapshot.rows[key]?.record }
    @Synchronized final override fun all(collection: String?): List<Record> { checkOpen(); return snapshot.rows.values.map { it.record }.filter { collection == null || it.collection == collection }.sortedBy { it.key } }
    @Synchronized final override fun pending(limit: Int): List<VersionedRecord> {
        checkOpen(); require(limit >= 0)
        // Dependent command/approval records must follow their file and Wallet records on the socket.
        return snapshot.rows.values.filter { it.dirty }.sortedWith(compareBy<JournalRow> {
            when (it.record.collection) { "sendpart" -> 0; "card", "address" -> 1; "send" -> 3; "assistantanswer" -> 4; else -> 2 }
        }.thenBy { it.record.key }).take(limit).map { VersionedRecord(it.record, it.version) }
    }
    @Synchronized final override fun isPending(key: RecordKey): Boolean { checkOpen(); return snapshot.rows[key]?.dirty == true }
    @Synchronized final override fun change(key: RecordKey, fields: JsonObject): Record {
        checkOpen()
        val old = snapshot.rows[key]
        val changed = (old?.record ?: Record(key.collection, key.id)).updated(fields, clock)
        if (old?.record != changed) commit(snapshot.copy(rows = snapshot.rows + (key to JournalRow(changed, true, old?.version ?: 0)), stamp = clock.latest()))
        return changed
    }
    @Synchronized final override fun changeConditionally(key: RecordKey, fields: JsonObject, expected: Map<RecordKey, Record?>): Record {
        checkOpen()
        require(expected.all { (id, value) -> snapshot.rows[id]?.record == value }) { "Sync records changed" }
        return change(key, fields)
    }
    @Synchronized final override fun changeBatch(fields: Map<RecordKey, JsonObject>, expected: Map<RecordKey, Record?>): Map<RecordKey, Record> {
        checkOpen(); require(expected.all { (id, value) -> snapshot.rows[id]?.record == value }) { "Sync records changed" }
        val rows = snapshot.rows.toMutableMap(); val output = linkedMapOf<RecordKey, Record>(); var changed = false
        for ((key, value) in fields) {
            val old = rows[key]; val record = (old?.record ?: Record(key.collection, key.id)).updated(value, clock)
            output[key] = record
            if (record != old?.record) { rows[key] = JournalRow(record, true, old?.version ?: 0); changed = true }
        }
        if (changed) commit(snapshot.copy(rows = rows, stamp = clock.latest()))
        return output
    }
    @Synchronized final override fun removeConditionally(key: RecordKey, expected: Map<RecordKey, Record?>): Record? {
        checkOpen(); require(expected.all { (id, value) -> snapshot.rows[id]?.record == value }) { "Sync records changed" }
        return remove(key)
    }
    @Synchronized final override fun remove(key: RecordKey): Record? {
        checkOpen(); val old = snapshot.rows[key] ?: return null
        val changed = old.record.removed(clock.tick())
        commit(snapshot.copy(rows = snapshot.rows + (key to JournalRow(changed, true, old.version)), stamp = clock.latest()))
        return changed
    }
    @Synchronized final override fun receive(records: List<VersionedRecord>, cursor: Long?): List<Record> {
        checkOpen(); cursor?.let { require(it >= 0) }
        val rows = snapshot.rows.toMutableMap(); val changed = mutableListOf<Record>()
        for ((record, version) in records) {
            require(version >= 0)
            record.deleted?.let(clock::observe); record.stamps.values.forEach(clock::observe)
            val old = rows[record.key]; val merged = old?.record?.merged(record) ?: record
            rows[record.key] = JournalRow(merged, old?.dirty == true && merged != record, maxOf(version, old?.version ?: 0))
            if (old == null && merged.alive() || old != null && (old.record.visible != merged.visible || old.record.alive() != merged.alive())) changed += merged
        }
        commit(snapshot.copy(rows = rows, cursor = maxOf(snapshot.cursor, cursor ?: 0), stamp = clock.latest()))
        return changed
    }
    @Synchronized final override fun sent(records: List<VersionedRecord>, cursor: Long?) {
        checkOpen(); val rows = snapshot.rows.toMutableMap()
        for ((record, version) in records) {
            require(version >= 0)
            val old = rows[record.key] ?: continue
            rows[record.key] = JournalRow(old.record, old.record != record, maxOf(version, old.version))
        }
        cursor?.let { require(it >= 0) }
        commit(snapshot.copy(rows = rows, cursor = maxOf(snapshot.cursor, cursor ?: 0)))
    }
    @Synchronized final override fun rebase(key: RecordKey, version: Long) {
        checkOpen(); require(version >= 0); val old = snapshot.rows[key] ?: return
        commit(snapshot.copy(rows = snapshot.rows + (key to old.copy(dirty = true, version = version))))
    }
    @Synchronized final override fun reserveReceipt(id: String): Boolean {
        checkOpen(); require(id.isNotEmpty()); if (id in snapshot.receipts) return false
        commit(snapshot.copy(receipts = snapshot.receipts + id)); return true
    }
    @Synchronized final override fun hasReceipt(id: String): Boolean { checkOpen(); return id in snapshot.receipts }
    @Synchronized override fun close() { closed = true }
}

/**
 * A base file of whole rows, one line each, and a log of the commits since,
 * one line each, so a commit costs what it changed rather than the account.
 * A base names its log: one left by an interrupted rewrite is never replayed.
 */
class FileJournal(private val file: File, device: String, private val account: String,
                  now: () -> Long = System::currentTimeMillis) : MemoryJournal(device, now) {
    private val lockFile: RandomAccessFile
    private val lock: java.nio.channels.FileLock
    private var saved: Snapshot? = null
    private var generation = 0L
    private var baseBytes = 0L
    private var logBytes = 0L
    private val folder get() = file.absoluteFile.parentFile
    private fun log(number: Long) = File(folder, "${file.name}.$number.log")
    init {
        require(account.isNotEmpty())
        folder?.let { require(it.isDirectory || it.mkdirs()) { "Cannot create journal directory" } }
        lockFile = RandomAccessFile(File(file.path + ".lock"), "rw")
        lock = try { lockFile.channel.tryLock() ?: error("Journal is already open") } catch (error: Throwable) { lockFile.close(); throw error }
        try {
            if (file.exists()) load()
        } catch (error: Throwable) { lock.release(); lockFile.close(); throw error }
    }
    private fun load() {
        file.bufferedReader(Charsets.UTF_8).use { reader ->
            val head = wireJson.parseToJsonElement(reader.readLine()).jsonObject
            require(head.getValue("account").jsonPrimitive.content == account) { "Journal belongs to another account" }
            if (head.getValue("format").jsonPrimitive.int == 1) { restore(head); return }
            require(head.getValue("format").jsonPrimitive.int == 2) { "Unsupported journal format" }
            require(head.getValue("device").jsonPrimitive.content == device) { "Journal belongs to another device" }
            generation = head.getValue("generation").jsonPrimitive.long
            val rows = HashMap<RecordKey, JournalRow>()
            reader.forEachLine { readRow(wireJson.parseToJsonElement(it).jsonObject, rows) }
            var cursor = head.getValue("cursor").jsonPrimitive.long
            var stamp = head["clock"]?.takeUnless { it == JsonNull }?.jsonObject?.let(Stamp::fromJson)
            val receipts = head.getValue("receipts").jsonArray.mapTo(linkedSetOf()) { it.jsonPrimitive.content }
            var torn = false
            log(generation).takeIf { it.exists() }?.bufferedReader(Charsets.UTF_8)?.use { commits ->
                for (line in commits.lineSequence()) {
                    // Only a commit cut short by the process dying can be unreadable, and it was never reported done.
                    val commit = runCatching { wireJson.parseToJsonElement(line).jsonObject }.getOrNull()
                    if (commit == null) { torn = true; break }
                    commit.getValue("rows").jsonArray.forEach { readRow(it.jsonObject, rows) }
                    cursor = commit.getValue("cursor").jsonPrimitive.long
                    stamp = commit["clock"]?.takeUnless { it == JsonNull }?.jsonObject?.let(Stamp::fromJson)
                    commit.getValue("receipts").jsonArray.mapTo(receipts) { it.jsonPrimitive.content }
                }
            }
            restored(rows, cursor, stamp, receipts)
            baseBytes = file.length(); logBytes = log(generation).length()
            if (!torn) saved = current
        }
    }
    override fun persist(snapshot: Snapshot) {
        val before = saved
        if (before == null || logBytes > maxOf(MIN_LOG, baseBytes)) rewrite(snapshot) else append(before, snapshot)
        saved = snapshot
    }
    private fun append(before: Snapshot, snapshot: Snapshot) {
        val line = StringBuilder("{\"cursor\":").append(snapshot.cursor)
        snapshot.stamp?.let { line.append(",\"clock\":").append(it.toJson()) }
        line.append(",\"receipts\":").append(JsonArray((snapshot.receipts - before.receipts).map(::JsonPrimitive))).append(",\"rows\":[")
        var first = true
        for ((key, row) in snapshot.rows) if (before.rows[key] !== row) {
            if (!first) line.append(','); first = false
            line.append(encode(row))
        }
        val data = line.append("]}\n").toString().toByteArray(Charsets.UTF_8)
        FileOutputStream(log(generation), true).use { it.write(data); it.fd.sync() }
        logBytes += data.size
    }
    private fun rewrite(snapshot: Snapshot) {
        val next = generation + 1
        val temporary = File.createTempFile(".journal-", ".tmp", folder)
        try {
            FileOutputStream(temporary).use { out ->
                val writer = out.bufferedWriter(Charsets.UTF_8)
                writer.write(buildJsonObject {
                    put("format", 2); put("device", device); put("account", account); put("generation", next); put("cursor", snapshot.cursor)
                    snapshot.stamp?.let { put("clock", it.toJson()) }; put("receipts", JsonArray(snapshot.receipts.sorted().map(::JsonPrimitive)))
                }.toString()); writer.write("\n")
                for (row in snapshot.rows.values) { writer.write(encode(row).toString()); writer.write("\n") }
                writer.flush(); out.fd.sync()
            }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            java.nio.channels.FileChannel.open(folder.toPath(), java.nio.file.StandardOpenOption.READ).use { it.force(true) }
        } finally { temporary.delete() }
        log(generation).delete()
        generation = next; baseBytes = file.length(); logBytes = 0
    }
    @Synchronized override fun close() { super.close(); if (lock.isValid) lock.release(); lockFile.close() }
    private companion object { const val MIN_LOG = 4L * 1024 * 1024 }
}

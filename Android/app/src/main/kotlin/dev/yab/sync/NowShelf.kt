package dev.yab.sync

import dev.yab.core.sync.Record
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.UUID

/** Exact mail-only SyncNow/NowShelf facts. No task status or inferred progress. */
@Serializable
internal data class NowMailRow(val id: String, val owner: String, val title: String, val detail: String,
    val who: String, val host: String, val web: String?, val message: String?, val order: Int, val fingerprint: String)

@Serializable
internal data class NowShelfSnapshot(val format: Int = 1, val account: String, val device: String,
    val epoch: String, val rows: List<NowMailRow>) {
    fun link(row: NowMailRow): String {
        require(row in rows)
        return "yab://now?" + linkedMapOf("account" to account, "device" to device, "epoch" to epoch,
            "owner" to row.owner, "id" to row.id, "fingerprint" to row.fingerprint).entries.joinToString("&") { (key, value) -> "$key=${URLEncoder.encode(value, "UTF-8")}" }
    }
}

internal data class NowLink(val account: String, val device: String, val epoch: String, val owner: String,
    val id: String, val fingerprint: String)

internal object NowShelfCodec {
    const val LIMIT = 3
    private val names = setOf("device", "title", "detail", "who", "host", "web", "message", "order")
    private fun JsonObject.text(key: String): String? = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

    fun rows(records: List<Record>, knownMacs: Set<String>): List<NowMailRow> = records.mapNotNull { record ->
        if (record.collection != "now" || record.schema != 1 || !record.alive() || record.id.isBlank() || record.id.length > 1024) return@mapNotNull null
        val fields = record.visible
        val owner = fields.text("device")?.takeIf { it in knownMacs } ?: return@mapNotNull null
        // A merged row must not borrow another device's displayed text or link.
        if (fields.keys.intersect(names).any { record.stamps[it]?.device != owner }) return@mapNotNull null
        val title = fields.text("title")?.takeIf { it.isNotBlank() && it.toByteArray().size <= 2000 } ?: return@mapNotNull null
        fun text(key: String, maximum: Int): String? {
            if (key !in fields) return ""
            return fields.text(key)?.takeIf { it.toByteArray().size <= maximum }
        }
        val detail = text("detail", 4000) ?: return@mapNotNull null
        val who = text("who", 1000) ?: return@mapNotNull null
        val host = text("host", 1000) ?: return@mapNotNull null
        val rawWeb = text("web", 8192) ?: return@mapNotNull null
        val web = rawWeb.takeIf { it.isNotBlank() }?.let(::safeWeb)
        if (rawWeb.isNotBlank() && web == null) return@mapNotNull null
        val message = (text("message", 2000) ?: return@mapNotNull null).takeIf { it.isNotBlank() }
        val orderValue = if ("order" !in fields) 0.0 else (fields["order"] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull ?: return@mapNotNull null
        if (!orderValue.isFinite() || orderValue !in Int.MIN_VALUE.toDouble()..Int.MAX_VALUE.toDouble()) return@mapNotNull null
        val facts = buildJsonObject {
            put("id", record.id); put("owner", owner); put("title", title); put("detail", detail); put("who", who); put("host", host)
            put("web", web); put("message", message); put("order", orderValue.toInt())
            put("stamps", buildJsonObject { for (key in names.sorted()) record.stamps[key]?.let { put(key, it.toJson()) } })
        }
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(facts.toString().toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
        NowMailRow(record.id, owner, title, detail, who, host, web, message, orderValue.toInt(), fingerprint)
    }.sortedWith(compareBy<NowMailRow> { it.order }.thenBy { it.id }).take(LIMIT)

    fun safeWeb(value: String): String? = runCatching {
        if (value.toByteArray().size > 8192 || value.any(Char::isISOControl)) return null
        val uri = URI(value)
        if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrEmpty() || uri.rawUserInfo != null) return null
        uri.toASCIIString()
    }.getOrNull()

    fun parse(address: String): NowLink? = runCatching {
        if (address.length > 16_384 || address.any(Char::isISOControl)) return null
        val uri = URI(address)
        if (!uri.scheme.equals("yab", true) || !uri.host.equals("now", true) || uri.port != -1 || uri.rawUserInfo != null || uri.rawFragment != null || !uri.path.isNullOrEmpty()) return null
        val pairs = uri.rawQuery?.split('&')?.map { part ->
            val pair = part.split('=', limit = 2)
            require(pair.size == 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair[1], "UTF-8")
        } ?: return null
        val fields = pairs.toMap()
        if (pairs.size != fields.size || fields.keys != setOf("account", "device", "epoch", "owner", "id", "fingerprint") || fields.values.any { it.isBlank() || it.any(Char::isISOControl) }) return null
        if (!fields.getValue("fingerprint").matches(Regex("[0-9a-f]{64}")) || UUID.fromString(fields.getValue("epoch")).toString() != fields.getValue("epoch")) return null
        NowLink(fields.getValue("account"), fields.getValue("device"), fields.getValue("epoch"), fields.getValue("owner"), fields.getValue("id"), fields.getValue("fingerprint"))
    }.getOrNull()

    /** The URI contains identities only. Current synced facts supply the destination. */
    fun resolve(link: NowLink, saved: NowShelfSnapshot?, account: String, device: String, current: List<NowMailRow>): String? {
        if (saved == null || saved.account != account || saved.device != device || link.account != account || link.device != device || link.epoch != saved.epoch) return null
        val shown = saved.rows.firstOrNull { it.id == link.id && it.owner == link.owner && it.fingerprint == link.fingerprint } ?: return null
        val actual = current.firstOrNull { it.id == shown.id && it.owner == shown.owner && it.fingerprint == shown.fingerprint } ?: return null
        return actual.web?.let(::safeWeb)
    }
}

/** Account-scoped no-backup mirror, like iOS's App Group shelf. File protection is supplied by Android's app sandbox. */
internal class NowShelfStore(private val file: File) {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    @Synchronized fun read(): NowShelfSnapshot? = runCatching {
        if (!file.isFile || file.length() > 65_536) return null
        json.decodeFromString<NowShelfSnapshot>(file.readText()).takeIf {
            it.format == 1 && it.account.isNotBlank() && it.device.isNotBlank() && it.rows.size <= NowShelfCodec.LIMIT && UUID.fromString(it.epoch).toString() == it.epoch &&
                it.rows.map { row -> row.id }.distinct().size == it.rows.size && it.rows.all { row -> row.owner.isNotBlank() && row.id.isNotBlank() && row.title.isNotBlank() && row.fingerprint.matches(Regex("[0-9a-f]{64}")) && (row.web == null || NowShelfCodec.safeWeb(row.web) != null) }
        }
    }.getOrNull()
    @Synchronized fun write(account: String, device: String, rows: List<NowMailRow>): Boolean {
        val previous = read()
        val next = NowShelfSnapshot(account = account, device = device,
            epoch = previous?.takeIf { it.account == account && it.device == device }?.epoch ?: UUID.randomUUID().toString(), rows = rows.sortedWith(compareBy<NowMailRow> { it.order }.thenBy { it.id }).take(NowShelfCodec.LIMIT))
        if (next == previous) return false
        val parent = file.absoluteFile.parentFile; check(parent.isDirectory || parent.mkdirs())
        val temporary = File.createTempFile(".now-shelf-", ".tmp", parent)
        try {
            val bytes = json.encodeToString(next).toByteArray()
            require(bytes.size <= 65_536)
            FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            FileChannel.open(parent.toPath(), StandardOpenOption.READ).use { it.force(true) }
            check(read() == next) { "Now widget shelf could not be verified" }
        } finally { temporary.delete() }
        return true
    }
    @Synchronized fun clear(): Boolean {
        if (!file.exists()) return false
        check(file.delete()) { "Now widget shelf could not be cleared" }
        return true
    }
    companion object { const val FILE_NAME = "now-widget.json" }
}

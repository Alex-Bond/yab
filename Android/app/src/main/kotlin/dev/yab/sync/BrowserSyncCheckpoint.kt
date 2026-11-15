package dev.yab.sync

import dev.yab.browser.model.BrowserSnapshot
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.nio.file.Files
import java.nio.file.StandardCopyOption

@Serializable
internal data class BrowserSyncCheckpoint(val format: Int = 1, val account: String, val device: String,
                                          val target: BrowserSnapshot, val knownLocalHashes: List<String>, val localSearch: Boolean) {
    /** A disk image we already observed before committing this target is an interrupted save, not a new edit. */
    fun restore(current: BrowserSnapshot): BrowserSnapshot = if (BrowserSnapshotHash.compatible(current).any { it in knownLocalHashes }) target.copy(
        settings = target.settings.copy(syncHistory = target.settings.syncHistory && current.settings.syncHistory),
        historyForgetting = target.historyForgetting.merged(current.historyForgetting),
    ) else current
}

internal object BrowserSnapshotHash {
    private val json = Json { encodeDefaults = true }
    fun of(snapshot: BrowserSnapshot): String = MessageDigest.getInstance("SHA-256").digest(json.encodeToString(snapshot).toByteArray())
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    /** Additive default fields do not turn a pre-upgrade interrupted write into an edit.
     * An explicit new local toggle is never erased by a pre-toggle checkpoint. */
    fun compatible(snapshot: BrowserSnapshot): Set<String> {
        val current = of(snapshot)
        if (!snapshot.settings.swipeAnywhere) return setOf(current)
        val objectValue = json.parseToJsonElement(json.encodeToString(snapshot)).jsonObject
        fun hash(value: JsonObject) = MessageDigest.getInstance("SHA-256").digest(value.toString().toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        val preSwipe = JsonObject(objectValue.mapValues { (key, value) ->
            if (key == "settings") JsonObject(value.jsonObject.filterKeys { it != "swipeAnywhere" }) else value
        })
        val compatible = linkedSetOf(current, hash(preSwipe))
        if (!snapshot.settings.syncHistory || snapshot.settings.macTabs || snapshot.historyForgetting != dev.yab.browser.model.HistoryForgetting() || snapshot.history.any { it.syncedKey != null }) return compatible
        val legacy = JsonObject(preSwipe.filterKeys { it != "historyForgetting" }.mapValues { (key, value) -> when (key) {
            "settings" -> JsonObject(value.jsonObject.filterKeys { it !in setOf("syncHistory", "macTabs") })
            "history" -> JsonArray((value as JsonArray).map { row -> JsonObject(row.jsonObject.filterKeys { it !in setOf("syncedKey", "syncedAt", "syncedDevice") }) })
            else -> value
        } })
        return compatible + hash(legacy)
    }
}

/** Kept beside the account journal in noBackupFilesDir, never alongside another account's checkpoint. */
internal class BrowserSyncCheckpointStore(private val file: File, private val account: String, private val device: String) {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    fun load(): BrowserSyncCheckpoint? {
        if (!file.exists()) return null
        val saved = json.decodeFromString<BrowserSyncCheckpoint>(file.readText())
        require(saved.format == 1 && saved.account == account && saved.device == device) { "Browser Sync checkpoint belongs to another identity" }
        require(saved.target.spaces.none { it.isPrivate || it.tabs.any { tab -> tab.isPrivate } })
        return saved
    }
    fun save(checkpoint: BrowserSyncCheckpoint) {
        require(checkpoint.account == account && checkpoint.device == device)
        require(checkpoint.target.spaces.none { it.isPrivate || it.tabs.any { tab -> tab.isPrivate } })
        val parent = file.absoluteFile.parentFile; check(parent.isDirectory || parent.mkdirs())
        val temporary = File.createTempFile(".browser-sync-", ".tmp", parent)
        try {
            FileOutputStream(temporary).use { it.write(json.encodeToString(checkpoint).toByteArray()); it.fd.sync() }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            java.nio.channels.FileChannel.open(parent.toPath(), java.nio.file.StandardOpenOption.READ).use { it.force(true) }
        } finally { temporary.delete() }
    }
}

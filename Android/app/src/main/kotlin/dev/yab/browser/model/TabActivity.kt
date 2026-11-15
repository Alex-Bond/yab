package dev.yab.browser.model

import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Local provenance, deliberately outside BrowserSnapshot and the sync wire. */
@Serializable
data class TabActivityClock(val wall: Long, val elapsed: Long, val boot: Int?, val process: String? = null) {
    fun since(old: TabActivityClock): Long? {
        if (boot != null && boot < 0 || old.boot != null && old.boot < 0) return null
        val sameBoot = boot != null && boot >= 0 && boot == old.boot
        // A process nonce proves continuity only in RAM; it never substitutes for boot identity
        // after a real process restart. An observed boot mismatch always protects.
        val sameProcess = (boot == null || old.boot == null) && process != null && process == old.process
        if ((!sameBoot && !sameProcess) || wall < old.wall || elapsed < old.elapsed || old.elapsed < 0) return null
        val real = elapsed - old.elapsed
        val date = wall - old.wall
        if (real < 0 || date < 0 || abs(date - real) > 2_000) return null
        return minOf(real, date)
    }
    companion object { val processIdentity: String = UUID.randomUUID().toString() }
}

@Serializable
data class TabActivity(val space: String, val profile: String, val url: String, val clock: TabActivityClock,
    val activityAt: Long? = null)

interface TabActivityRepository {
    suspend fun load(): Map<String, TabActivity>
    suspend fun save(entries: Map<String, TabActivity>)
}

class MemoryTabActivityRepository : TabActivityRepository {
    private var entries = emptyMap<String, TabActivity>()
    override suspend fun load() = entries
    override suspend fun save(entries: Map<String, TabActivity>) { this.entries = entries.toMap() }
}

/** Only the controller's filtered public map enters this separate device-local file. */
class FileTabActivityRepository(private val file: File) : TabActivityRepository {
    @Serializable private data class Disk(val schema: Int = 1, val entries: Map<String, TabActivity> = emptyMap())
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    override suspend fun load(): Map<String, TabActivity> = withContext(Dispatchers.IO) {
        if (!file.isFile || file.length() > 2 * 1024 * 1024) return@withContext emptyMap()
        runCatching { json.decodeFromString<Disk>(file.readText()).takeIf { it.schema == 1 }?.entries.orEmpty() }
            .getOrDefault(emptyMap())
    }
    override suspend fun save(entries: Map<String, TabActivity>) = withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        val data = json.encodeToString(Disk(entries = entries)).toByteArray()
        require(data.size <= 2 * 1024 * 1024) { "Too many local activity observations" }
        val pending = File(file.parentFile, "${file.name}.pending")
        pending.outputStream().use { it.write(data); it.fd.sync() }
        check(pending.renameTo(file)) { "Local activity couldn't be saved" }
    }
}

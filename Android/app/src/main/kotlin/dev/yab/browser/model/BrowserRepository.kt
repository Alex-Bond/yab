package dev.yab.browser.model

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

interface BrowserRepository {
    suspend fun load(): BrowserSnapshot?
    suspend fun save(snapshot: BrowserSnapshot)
}

/** A failed decode preserves the original bytes; the caller can surface the error. */
class FileBrowserRepository(private val file: File) : BrowserRepository {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    override suspend fun load(): BrowserSnapshot? = withContext(Dispatchers.IO) {
        if (!file.exists()) return@withContext null
        json.decodeFromString<BrowserSnapshot>(file.readText()).also {
            require(it.schema == 1) { "This browser profile needs a newer version of Yab." }
            require(it.spaces.isNotEmpty() && it.spaces.any { space -> space.id == it.selectedSpaceId }) { "Browser profile has no valid selection." }
            require(it.spaces.map { space -> space.id }.distinct().size == it.spaces.size) { "Browser profile contains duplicate spaces." }
            val ids = it.spaces.flatMap { space -> space.tabs }.map { tab -> tab.id }
            require(ids.distinct().size == ids.size) { "Browser profile contains duplicate tabs." }
        }
    }

    override suspend fun save(snapshot: BrowserSnapshot) = withContext(Dispatchers.IO) {
        require(snapshot.spaces.none { it.isPrivate || it.tabs.any(BrowserTab::isPrivate) }) { "Private browsing cannot be written to disk." }
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, "${file.name}.pending")
        temporary.outputStream().use { output ->
            output.write(json.encodeToString(snapshot).toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        check(temporary.renameTo(file)) { "Couldn't save your browser profile." }
    }
}

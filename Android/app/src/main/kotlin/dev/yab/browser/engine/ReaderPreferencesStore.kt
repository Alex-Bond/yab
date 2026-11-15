package dev.yab.browser.engine

import dev.yab.browser.model.*
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Device-global local preferences, including Private Reader, as Phone ReaderStyle. Never synced. */
class ReaderPreferencesStore(private val file: File? = null) {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val mutable = MutableStateFlow(load())
    val state = mutable.asStateFlow()
    private val mutableError = MutableStateFlow<String?>(null)
    val error = mutableError.asStateFlow()
    private val mutableThemeRevision = MutableStateFlow(0L)
    val themeChanges = mutableThemeRevision.asStateFlow()
    val themeRevision: Long get() = mutableThemeRevision.value
    fun snapshot() = mutable.value
    fun set(value: ReaderPreferences): Boolean {
        val next = value.normalized()
        if (next == mutable.value) return true
        if (!save(next)) return false
        if (next.theme != mutable.value.theme) mutableThemeRevision.value++
        mutable.value = next
        return true
    }
    private fun load(): ReaderPreferences = try {
        if (file == null || !file.exists()) ReaderPreferences() else {
            require(file.length() <= MAX_BYTES)
            json.decodeFromString<ReaderPreferences>(file.readText()).normalized()
        }
    } catch (_: Exception) { ReaderPreferences() }
    private fun save(value: ReaderPreferences): Boolean {
        val destination = file ?: return true
        val temporary = File(destination.parentFile, "${destination.name}.${UUID.randomUUID()}.next")
        return try {
            destination.parentFile?.mkdirs()
            val data = json.encodeToString(value).toByteArray(Charsets.UTF_8); require(data.size <= MAX_BYTES)
            temporary.outputStream().use { it.write(data); it.fd.sync() }
            Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            mutableError.value = null; true
        } catch (_: Exception) { mutableError.value = "Reader settings could not be saved. Try again."; false }
        finally { temporary.delete() }
    }
    companion object { private const val MAX_BYTES = 64 * 1024 }
}

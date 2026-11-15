package dev.yab.browser.engine

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class ThumbnailOwner(val tab: String, val profile: String, val url: String, val isPrivate: Boolean = false)
@Serializable
data class ThumbnailCapture(val owner: ThumbnailOwner, val session: String, val document: String)

/** Called only by one serial IO writer. A single bounded file contains ownership and JPEG bytes. */
class PublicThumbnailDiskCache(private val folder: File, private val maxFiles: Int = 128,
    private val maxBytes: Long = 32L * 1024 * 1024) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    @Serializable private data class Header(val schema: Int = 1, val capture: ThumbnailCapture)
    data class Stored(val capture: ThumbnailCapture, val jpeg: ByteArray)
    private fun path(tab: String) = File(folder, "${UUID.nameUUIDFromBytes(tab.toByteArray(Charsets.UTF_8))}.thumb")
    private fun valid(owner: ThumbnailOwner) = !owner.isPrivate && owner.tab.isNotBlank() && owner.profile.isNotBlank() &&
        owner.tab.length <= 256 && owner.profile.length <= 256 && owner.url.length <= 16_384 &&
        runCatching { java.net.URI(owner.url).let { it.scheme in setOf("http", "https") && !it.host.isNullOrBlank() } }.getOrDefault(false)
    private fun read(file: File): Stored? = runCatching {
        if (!file.isFile || file.length() !in 5..(MAX_JPEG + MAX_HEADER + 4).toLong()) return null
        DataInputStream(file.inputStream()).use { input ->
            val length = input.readInt()
            if (length !in 1..MAX_HEADER || file.length() - 4 - length !in 1..MAX_JPEG.toLong()) return null
            val bytes = ByteArray(length); input.readFully(bytes)
            val header = json.decodeFromString<Header>(bytes.toString(Charsets.UTF_8))
            if (header.schema != 1 || !valid(header.capture.owner) || header.capture.session.isBlank() || header.capture.document.isBlank()) return null
            val jpeg = ByteArray((file.length() - 4 - length).toInt()); input.readFully(jpeg)
            Stored(header.capture, jpeg)
        }
    }.getOrNull()
    fun get(owner: ThumbnailOwner): Stored? {
        if (!valid(owner)) return null
        return read(path(owner.tab))?.takeIf { it.capture.owner == owner }
    }
    fun put(capture: ThumbnailCapture, jpeg: ByteArray) {
        if (!valid(capture.owner) || capture.session.length !in 1..256 || capture.document.length !in 1..256 || jpeg.size !in 1..MAX_JPEG) return
        val header = json.encodeToString(Header(capture = capture)).toByteArray(Charsets.UTF_8)
        if (header.size > MAX_HEADER) return
        folder.mkdirs()
        val file = path(capture.owner.tab)
        val pending = File(folder, "${file.name}.pending")
        pending.outputStream().use { output -> DataOutputStream(output).apply { writeInt(header.size); write(header); write(jpeg); flush() }; output.fd.sync() }
        check(pending.renameTo(file)) { "Tab preview couldn't be saved" }
        prune()
    }
    fun remove(tab: String) { path(tab).delete(); File(folder, "${path(tab).name}.pending").delete() }
    fun reconcile(owners: Collection<ThumbnailOwner>) {
        val allowed = owners.filter(::valid).associateBy { it.tab }
        folder.listFiles().orEmpty().filter { it.name.endsWith(".thumb") }.forEach { file ->
            val stored = read(file)
            if (stored == null || allowed[stored.capture.owner.tab] != stored.capture.owner) file.delete()
        }
        prune()
    }
    fun purgeProfiles(profiles: Set<String>) {
        folder.listFiles().orEmpty().filter { it.name.endsWith(".thumb") }.forEach { file ->
            val stored = read(file)
            if (stored == null || stored.capture.owner.profile in profiles) file.delete()
        }
    }
    fun clear() { folder.listFiles().orEmpty().filter { it.name.endsWith(".thumb") || it.name.endsWith(".pending") }.forEach { it.delete() } }
    private fun prune() {
        val files = folder.listFiles().orEmpty().filter { it.name.endsWith(".thumb") }.sortedByDescending(File::lastModified)
        var bytes = 0L
        files.forEachIndexed { index, file ->
            bytes += file.length()
            if (index >= maxFiles || bytes > maxBytes) file.delete()
        }
        folder.listFiles().orEmpty().filter { it.name.endsWith(".pending") }.forEach { it.delete() }
    }
    companion object { const val MAX_JPEG = 1024 * 1024; private const val MAX_HEADER = 24 * 1024 }
}

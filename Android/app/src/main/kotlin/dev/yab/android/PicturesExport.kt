package dev.yab.android

import java.io.File
import java.io.OutputStream
import java.nio.file.Files
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Only a newly inserted, app-owned pending image row may implement this capability. */
interface PendingPicture {
    val uri: String
    fun output(): OutputStream
    fun publish()
    fun remove()
}
fun interface PictureLibrary { fun createPending(name: String, mime: String): PendingPicture }

internal fun confirmPictureRemoval(deleted: Int, exists: () -> Boolean?) {
    check(deleted == 1 || deleted == 0 && exists() == false) { "Pictures did not confirm removal of its incomplete image" }
}

/** Copies ORIGINAL completed image bytes. No decoder, screenshot, recompression or second GET. */
object PicturesExport {
    private data class Format(val mime: String, val extension: String)
    private val formats = mapOf("image/png" to Format("image/png", "png"), "image/jpeg" to Format("image/jpeg", "jpg"),
        "image/gif" to Format("image/gif", "gif"), "image/webp" to Format("image/webp", "webp"))
    const val MAX_IMAGE_BYTES = 128L * 1024 * 1024
    fun supports(mime: String): Boolean = formats.containsKey(mime.lowercase())

    suspend fun save(file: File, name: String, mime: String, library: PictureLibrary,
        onPending: (PendingPicture) -> Unit = {}, current: suspend () -> Boolean): String {
        check(current()) { "Image export source changed" }
        val format = formats[mime.lowercase()] ?: error("Use Save for this image format")
        check(!Files.isSymbolicLink(file.toPath()) && file.isFile && file.length() in 1..MAX_IMAGE_BYTES) { "Image is unavailable or too large for Pictures" }
        val length = file.length()
        var pending: PendingPicture? = null
        var completed = false
        try {
            file.inputStream().use { input ->
                val header = ByteArray(16)
                var headerCount = 0
                while (headerCount < header.size) {
                    val count = input.read(header, headerCount, header.size - headerCount)
                    if (count < 0) break
                    if (count == 0) continue
                    headerCount += count
                }
                check(matches(format.mime, header.copyOf(headerCount))) { "The original bytes do not match this image format" }
                check(current()) { "Image export source changed" }
                val row = library.createPending(filename(name, format.extension), format.mime)
                pending = row
                onPending(row)
                row.output().use { output ->
                    output.write(header, 0, headerCount)
                    var received = headerCount.toLong()
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        if (!current()) throw CancellationException("Image export source changed")
                        val count = input.read(buffer)
                        if (count < 0) break
                        received += count
                        check(received <= length) { "Original image changed while saving" }
                        output.write(buffer, 0, count)
                    }
                    check(received == length && file.length() == length) { "Original image did not finish" }
                    output.flush()
                }
                currentCoroutineContext().ensureActive()
                if (!current()) throw CancellationException("Image export source changed before publish")
                row.publish()
                // A late provider completion must not publish into a replacement account/source.
                if (!current()) throw CancellationException("Image export source changed during publish")
                completed = true
                return row.uri
            }
        } finally {
            if (!completed) pending?.let { row -> withContext(NonCancellable) { row.remove() } }
        }
    }

    private fun matches(mime: String, bytes: ByteArray): Boolean = when (mime) {
        "image/png" -> bytes.size >= 8 && bytes.copyOf(8).contentEquals(byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 13, 10, 26, 10))
        "image/jpeg" -> bytes.size >= 3 && bytes[0] == 0xff.toByte() && bytes[1] == 0xd8.toByte() && bytes[2] == 0xff.toByte()
        "image/gif" -> bytes.size >= 6 && bytes.copyOf(6).toString(Charsets.US_ASCII) in setOf("GIF87a", "GIF89a")
        "image/webp" -> bytes.size >= 12 && bytes.copyOfRange(0, 4).toString(Charsets.US_ASCII) == "RIFF" && bytes.copyOfRange(8, 12).toString(Charsets.US_ASCII) == "WEBP"
        else -> false
    }
    private fun filename(suggested: String, extension: String): String {
        val safe = DownloadNames.sanitize(suggested)
        val existing = safe.substringAfterLast('.', "").lowercase()
        if (existing == extension || extension == "jpg" && existing == "jpeg") return safe
        var base = safe.substringBeforeLast('.', safe).ifEmpty { "Image" }
        while ((base + "." + extension).toByteArray().size > 255) {
            base = base.substring(0, base.offsetByCodePoints(base.length, -1))
        }
        return "$base.$extension"
    }
}

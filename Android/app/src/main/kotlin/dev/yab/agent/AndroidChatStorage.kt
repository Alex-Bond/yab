package dev.yab.agent

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.provider.OpenableColumns
import android.util.AtomicFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Public chats only. A corrupt file is preserved and cannot be overwritten by an empty launch. */
class FileChatPersistence(context: Context) : ChatPersistence {
    private val file = AtomicFile(File(context.filesDir, "local-chats.json"))
    private val json = Json { ignoreUnknownKeys = true }
    private var unreadable = false
    override suspend fun load(): ChatSnapshot = withContext(Dispatchers.IO) {
        if (!file.baseFile.exists()) return@withContext ChatSnapshot()
        try {
            require(file.baseFile.length() <= 16 * 1024 * 1024) { "Saved conversations are too large" }
            json.decodeFromString<ChatSnapshot>(file.readFully().toString(Charsets.UTF_8)).also {
                require(it.version == 1 && it.chats.none { chat -> chat.privateOrigin || chat.page?.isPrivate == true }) { "Invalid saved conversation profile" }
                require(it.chats.map { chat -> chat.id }.toSet().size == it.chats.size) { "Duplicate saved conversation identity" }
            }
        } catch (error: Exception) {
            unreadable = true
            throw AgentUnavailable("Saved conversations could not be read. The original file was kept.")
        }
    }
    override suspend fun save(snapshot: ChatSnapshot) = withContext(Dispatchers.IO) {
        check(!unreadable) { "The original unreadable profile is being kept for recovery" }
        require(snapshot.chats.none { it.privateOrigin || it.page?.isPrivate == true }) { "Private conversations cannot be saved" }
        val bytes = json.encodeToString(snapshot).toByteArray()
        require(bytes.size <= 16 * 1024 * 1024) { "Conversation storage is full" }
        val output = file.startWrite()
        try { output.write(bytes); file.finishWrite(output) }
        catch (error: Exception) { file.failWrite(output); throw error }
    }
}

class AndroidAttachmentReader(context: Context) {
    private val resolver = context.applicationContext.contentResolver
    private val photoFolder = File(context.applicationContext.noBackupFilesDir, "chat-photos")
    suspend fun read(uri: Uri, asPhoto: Boolean = false): PreparedAttachment = withContext(Dispatchers.IO) {
        var name = "Attachment"
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameColumn >= 0) name = cursor.getString(nameColumn) ?: name
                val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) require(cursor.getLong(sizeColumn) <= AttachmentLimits.EACH) { "A file can be up to 10 MB" }
            }
        }
        val bytes = resolver.openInputStream(uri)?.use { it.readBytesBounded(AttachmentLimits.EACH) }
            ?: throw AgentUnavailable("This file could not be read")
        if (asPhoto) photo(bytes, name.substringBeforeLast('.') + ".jpg")
        else make(name, resolver.getType(uri) ?: "application/octet-stream", bytes)
    }
    suspend fun photo(bitmap: Bitmap): PreparedAttachment = withContext(Dispatchers.IO) {
        val data = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }.toByteArray()
        photo(data, "Camera photo.jpg")
    }
    private fun photo(bytes: ByteArray, name: String): PreparedAttachment {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "This photo could not be read" }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 4096) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: throw AgentUnavailable("This photo could not be read")
        val orientation = try { bytes.inputStream().use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) } }
        catch (_: Exception) { ExifInterface.ORIENTATION_NORMAL }
        val matrix = Matrix().apply {
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> { postRotate(90f); postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_TRANSVERSE -> { postRotate(270f); postScale(-1f, 1f) }
            }
            val scale = minOf(1f, 2048f / maxOf(decoded.width, decoded.height))
            postScale(scale, scale)
        }
        val image = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        val output = ByteArrayOutputStream()
        image.compress(Bitmap.CompressFormat.JPEG, 85, output)
        if (image !== decoded) image.recycle()
        decoded.recycle()
        return make(name, "image/jpeg", output.toByteArray())
    }
    private fun make(name: String, mime: String, bytes: ByteArray): PreparedAttachment {
        AttachmentLimits.validate(listOf(bytes.size))
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        if (mime.startsWith("image/")) {
            check(photoFolder.isDirectory || photoFolder.mkdirs())
            val cache = AtomicFile(File(photoFolder, digest))
            val output = cache.startWrite()
            try { output.write(bytes); cache.finishWrite(output) } catch (error: Exception) { cache.failWrite(output); throw error }
        }
        return PreparedAttachment(ChatFile(name, mime, bytes.size, digest), bytes)
    }
    private fun java.io.InputStream.readBytesBounded(limit: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val read = read(buffer)
            if (read == -1) break
            require(output.size().toLong() + read <= limit) { "A file can be up to 10 MB" }
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }
}

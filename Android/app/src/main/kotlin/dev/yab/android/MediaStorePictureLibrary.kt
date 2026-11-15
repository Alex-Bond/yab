package dev.yab.android

import android.content.ContentValues
import android.content.Context
import android.os.Environment
import android.provider.MediaStore
import java.io.IOException
import java.io.OutputStream

/** API29+ scoped insertion of OUR new image only. No read-library or storage permission is needed. */
class MediaStorePictureLibrary(context: Context) : PictureLibrary {
    private val resolver = context.applicationContext.contentResolver
    override fun createPending(name: String, mime: String): PendingPicture {
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Yab")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val created = resolver.insert(collection, values) ?: throw IOException("Pictures is unavailable")
        return object : PendingPicture {
            private var removed = false
            override val uri = created.toString()
            @Synchronized override fun output(): OutputStream {
                check(!removed)
                return resolver.openOutputStream(created, "w") ?: throw IOException("Image output is unavailable")
            }
            @Synchronized override fun publish() {
                check(!removed)
                val complete = ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                }
                check(resolver.update(created, complete, null, null) == 1) { "Image could not be published" }
            }
            @Synchronized override fun remove() {
                if (!removed) {
                    val deleted = resolver.delete(created, null, null)
                    confirmPictureRemoval(deleted) {
                        // Only this newly created item URI; never enumerate or inspect the gallery.
                        resolver.query(created, arrayOf(MediaStore.Images.Media._ID), null, null, null)?.use { it.moveToFirst() }
                    }
                    removed = true
                }
            }
        }
    }
}

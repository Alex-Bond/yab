package dev.yab.android

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class PicturesExportTest {
    @Test fun zeroDeleteCountRequiresConfirmedAbsenceOfOnlyTheCreatedRow() {
        confirmPictureRemoval(1) { error("Successful exact-row deletion must not query anything") }
        confirmPictureRemoval(0) { false }
        for (present in listOf(true, null)) assertThrows(IllegalStateException::class.java) { confirmPictureRemoval(0) { present } }
        assertThrows(IllegalStateException::class.java) { confirmPictureRemoval(-1) { false } }
    }
    internal class Row : PendingPicture {
        override val uri = "content://media/external_primary/images/media/123"
        val bytes = ByteArrayOutputStream()
        var closed = false; var published = false; var removed = false
        var failWrite = false; var failPublish = false
        var afterWrite: (() -> Unit)? = null; var afterPublish: (() -> Unit)? = null
        override fun output() = object : OutputStream() {
            override fun write(value: Int) = error("Use buffered original bytes")
            override fun write(value: ByteArray, start: Int, length: Int) {
                if (failWrite) throw IOException("fixture storage failure")
                bytes.write(value, start, length); afterWrite?.invoke()
            }
            override fun close() { closed = true }
        }
        override fun publish() {
            check(closed)
            if (failPublish) throw IOException("fixture publish failure")
            published = true; afterPublish?.invoke()
        }
        override fun remove() { removed = true }
    }
    private val png = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 13, 10, 26, 10) + ByteArray(180_123) { (it % 251).toByte() }

    @Test fun savesEveryOriginalByteWithoutDecodingAndPublishesOnlyAfterOutputCloses(): Unit = runTest {
        val directory = Files.createTempDirectory("pictures-original-").toFile(); val file = File(directory, "original").apply { writeBytes(png) }
        val row = Row(); var chosenName = ""; var chosenMime = ""
        val library = PictureLibrary { name, mime -> chosenName = name; chosenMime = mime; row }
        try {
            assertEquals(row.uri, PicturesExport.save(file, "../../original.bin", "image/png", library) { true })
            assertArrayEquals(png, row.bytes.toByteArray()); assertArrayEquals(png, file.readBytes())
            assertTrue(row.closed && row.published); assertFalse(row.removed)
            assertEquals("original.png", chosenName); assertEquals("image/png", chosenMime)
        } finally { directory.deleteRecursively() }
    }

    @Test fun supportedRasterSignaturesPreserveJpegGifAndWebpBytesAndUnicodeNames(): Unit = runTest {
        val directory = Files.createTempDirectory("pictures-formats-").toFile()
        try {
            for ((mime, header) in listOf("image/jpeg" to byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte()),
                "image/gif" to "GIF89a".toByteArray(), "image/webp" to ("RIFF".toByteArray() + ByteArray(4) + "WEBP".toByteArray()))) {
                val data = header + ByteArray(500) { it.toByte() }; val file = File(directory, "original").apply { writeBytes(data) }
                val row = Row(); var chosen = ""
                PicturesExport.save(file, "🙂".repeat(120), mime, PictureLibrary { name, _ -> chosen = name; row }) { true }
                assertArrayEquals(data, row.bytes.toByteArray()); assertTrue(chosen.toByteArray().size <= 255)
                assertTrue(chosen.endsWith(if (mime == "image/jpeg") ".jpg" else if (mime == "image/gif") ".gif" else ".webp"))
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun unsupportedMimeMismatchOversizeAndRevokedSourceNeverInsertALibraryRow(): Unit = runTest {
        val directory = Files.createTempDirectory("pictures-reject-").toFile(); val file = File(directory, "original").apply { writeBytes(png) }
        var inserts = 0; val library = PictureLibrary { _, _ -> inserts++; Row() }
        try {
            for (mime in listOf("image/svg+xml", "text/html", "image/jpeg")) {
                try { PicturesExport.save(file, "image", mime, library) { true }; fail("Unsupported image was exported") }
                catch (_: IllegalStateException) { }
            }
            try { PicturesExport.save(file, "image", "image/png", library) { false }; fail("Revoked source inserted an image") }
            catch (_: IllegalStateException) { }
            RandomAccessFile(file, "rw").use { it.setLength(PicturesExport.MAX_IMAGE_BYTES + 1) }
            try { PicturesExport.save(file, "image", "image/png", library) { true }; fail("Oversize image inserted") }
            catch (_: IllegalStateException) { }
            assertEquals(0, inserts)
        } finally { directory.deleteRecursively() }
    }

    @Test fun ownershipLossDuringCopyDeletesOnlyItsPendingRowBeforePublish(): Unit = runTest {
        val directory = Files.createTempDirectory("pictures-owner-").toFile(); val file = File(directory, "original").apply { writeBytes(png) }
        var current = true; val row = Row().apply { afterWrite = { current = false } }
        val foreign = Row()
        try {
            try { PicturesExport.save(file, "image", "image/png", PictureLibrary { _, _ -> row }) { current }; fail("Revoked image published") }
            catch (_: CancellationException) { }
            assertTrue(row.removed); assertFalse(row.published); assertFalse(foreign.removed)
            assertArrayEquals(png, file.readBytes())
        } finally { directory.deleteRecursively() }
    }

    @Test fun lateOwnershipLossDuringProviderPublishRollsBackTheExactCreatedImage(): Unit = runTest {
        val directory = Files.createTempDirectory("pictures-publish-").toFile(); val file = File(directory, "original").apply { writeBytes(png) }
        var current = true; val row = Row().apply { afterPublish = { current = false } }
        try {
            try { PicturesExport.save(file, "image", "image/png", PictureLibrary { _, _ -> row }) { current }; fail("Stale provider completion accepted") }
            catch (_: CancellationException) { }
            assertTrue(row.published && row.removed); assertArrayEquals(png, file.readBytes())
        } finally { directory.deleteRecursively() }
    }

    @Test fun providerWriteOrPublishFailureRollsBackAndKeepsOriginalForExplicitSaveRetry(): Unit = runTest {
        val directory = Files.createTempDirectory("pictures-failure-").toFile(); val file = File(directory, "original").apply { writeBytes(png) }
        try {
            for (publish in listOf(false, true)) {
                val row = Row().apply { failWrite = !publish; failPublish = publish }
                try { PicturesExport.save(file, "image", "image/png", PictureLibrary { _, _ -> row }) { true }; fail("Provider failure accepted") }
                catch (_: IOException) { }
                assertTrue(row.removed); assertArrayEquals(png, file.readBytes())
            }
        } finally { directory.deleteRecursively() }
    }
}

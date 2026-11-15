package dev.yab.browser

import dev.yab.browser.engine.*
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class PublicThumbnailDiskCacheTest {
    @Test fun survivesNewStoreAndNeverReadsOrWritesPrivateOrWrongOwners() {
        val folder = Files.createTempDirectory("yab-public-pictures").toFile()
        try {
            val owner = ThumbnailOwner("tab", "work", "https://example.org/page")
            val capture = ThumbnailCapture(owner, "native-session", "document")
            val jpeg = byteArrayOf(1, 2, 3, 4)
            PublicThumbnailDiskCache(folder).put(capture, jpeg)
            val restored = PublicThumbnailDiskCache(folder)
            assertArrayEquals(jpeg, restored.get(owner)!!.jpeg)
            assertEquals(capture, restored.get(owner)!!.capture)
            assertNull(restored.get(owner.copy(profile = "another-container")))
            assertNull(restored.get(owner.copy(url = "https://example.org/next")))
            assertNull(restored.get(owner.copy(tab = "another-tab")))
            assertNull(restored.get(owner.copy(isPrivate = true)))
            val publicBytes = folder.listFiles()!!.single().readBytes()
            restored.put(capture.copy(owner = owner.copy(isPrivate = true, url = "https://private-secret.invalid")), jpeg)
            assertArrayEquals(publicBytes, folder.listFiles()!!.single().readBytes())
            assertFalse(publicBytes.toString(Charsets.UTF_8).contains("private-secret"))
            restored.reconcile(listOf(owner.copy(profile = "changed")))
            assertNull(restored.get(owner)); assertTrue(folder.listFiles()!!.isEmpty())
        } finally { folder.listFiles()?.forEach { it.delete() }; folder.delete() }
    }

    @Test fun boundsCorruptionCloseAndProfileClearLeaveOnlyOwnedValidPictures() {
        val folder = Files.createTempDirectory("yab-bounded-pictures").toFile()
        try {
            val store = PublicThumbnailDiskCache(folder, maxFiles = 2, maxBytes = 16_384)
            val first = ThumbnailOwner("one", "shared", "https://one.example")
            val second = ThumbnailOwner("two", "work", "https://two.example")
            val third = ThumbnailOwner("three", "work", "https://three.example")
            listOf(first, second, third).forEach { store.put(ThumbnailCapture(it, "session", "doc"), ByteArray(100)) }
            assertEquals(2, folder.listFiles()!!.size)
            store.remove(second.tab)
            assertNull(store.get(second))
            store.purgeProfiles(setOf("work"))
            assertNull(store.get(third))
            store.put(ThumbnailCapture(first, "session", "doc"), byteArrayOf(7))
            folder.listFiles()!!.single().writeBytes(byteArrayOf(0x7f, 0x7f, 0x7f, 0x7f))
            assertNull(store.get(first))
            store.reconcile(listOf(first))
            assertTrue(folder.listFiles()!!.isEmpty())
            store.put(ThumbnailCapture(first, "session", "doc"), ByteArray(PublicThumbnailDiskCache.MAX_JPEG + 1))
            assertTrue(folder.listFiles()!!.isEmpty())
        } finally { folder.listFiles()?.forEach { it.delete() }; folder.delete() }
    }
}

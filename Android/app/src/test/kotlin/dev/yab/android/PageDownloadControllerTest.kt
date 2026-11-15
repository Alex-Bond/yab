package dev.yab.android

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PageDownloadControllerTest {
    private val owner = PageDownloadOwner("tab", "public-profile", "native-document", false, "account", 1, Any())
    private class Bytes(bytes: ByteArray) : ByteArrayInputStream(bytes) {
        var closed = false
        override fun close() { closed = true; super.close() }
    }

    @Test fun explicitPicturesSaveUsesReadyOriginalBytesOnceAndKeepsSaveAndShareSeparate(): Unit = runTest {
        val root = Files.createTempDirectory("yab-pictures-controller-").toFile(); val ui = StandardTestDispatcher(testScheduler)
        val bytes = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 13, 10, 26, 10) + ByteArray(70_123) { it.toByte() }
        val row = PicturesExportTest.Row(); var inserts = 0
        val controller = PageDownloadController(File(root, "shared"), this, { it == owner }, ui, ui,
            pictures = PictureLibrary { _, _ -> inserts++; row })
        try {
            assertTrue(controller.startTransfer(Bytes(bytes), owner, "original.png", "image/png", bytes.size.toLong())); runCurrent()
            val id = controller.state.value.id!!
            assertTrue(controller.savePictures(id)); assertFalse(controller.savePictures(id)); runCurrent()
            assertEquals(PageDownloadPhase.SAVED, controller.state.value.phase)
            assertEquals(row.uri, controller.state.value.pictureUri); assertEquals(1, inserts)
            assertArrayEquals(bytes, row.bytes.toByteArray()); assertTrue(row.published); assertFalse(row.removed)
            assertFalse(File(root, "shared/download-$id").exists())
            assertNull(controller.currentExport("stale", PageDownloadExportKind.PICTURES))
        } finally { controller.close(); runCurrent(); root.deleteRecursively() }
    }

    @Test fun picturesProviderFailureReturnsReadyForAnExplicitRetryOfSameOriginalFile(): Unit = runTest {
        val root = Files.createTempDirectory("yab-pictures-retry-").toFile(); val ui = StandardTestDispatcher(testScheduler)
        val bytes = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 13, 10, 26, 10) + ByteArray(90) { it.toByte() }
        val failed = PicturesExportTest.Row().apply { failPublish = true }; val saved = PicturesExportTest.Row()
        val rows = ArrayDeque(listOf(failed, saved))
        val controller = PageDownloadController(File(root, "shared"), this, { it == owner }, ui, ui,
            pictures = PictureLibrary { _, _ -> rows.removeFirst() })
        try {
            assertTrue(controller.startTransfer(Bytes(bytes), owner, "original.png", "image/png", bytes.size.toLong())); runCurrent()
            val id = controller.state.value.id!!
            assertTrue(controller.savePictures(id)); runCurrent()
            assertEquals(PageDownloadPhase.READY, controller.state.value.phase); assertTrue(failed.removed)
            assertTrue(controller.state.value.error!!.contains("use Save"))
            assertTrue(controller.savePictures(id)); runCurrent()
            assertEquals(PageDownloadPhase.SAVED, controller.state.value.phase)
            assertArrayEquals(bytes, saved.bytes.toByteArray()); assertFalse(saved.removed)
        } finally { controller.close(); runCurrent(); root.deleteRecursively() }
    }

    @Test fun cancelledUiReturnAfterPublishedPicturesCannotLoseItsOwnedRowCleanup(): Unit = runTest {
        val root = Files.createTempDirectory("yab-pictures-return-").toFile()
        val underlying = StandardTestDispatcher(testScheduler); val ui = DeferredIo(underlying)
        val retained = CoroutineScope(SupervisorJob(coroutineContext[Job]) + ui)
        val bytes = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 13, 10, 26, 10) + ByteArray(90)
        val row = PicturesExportTest.Row(); var armed = false
        val controller = PageDownloadController(File(root, "shared"), retained, {
            if (row.published && !armed) { armed = true; ui.defer = true }
            it == owner
        }, ui, underlying, pictures = PictureLibrary { _, _ -> row })
        try {
            assertTrue(controller.startTransfer(Bytes(bytes), owner, "original.png", "image/png", bytes.size.toLong())); runCurrent()
            val id = controller.state.value.id!!
            assertTrue(controller.savePictures(id)); runCurrent()
            assertTrue(row.published); assertFalse(row.removed); assertTrue(ui.deferredCount > 0)
            assertEquals(PageDownloadPhase.EXPORTING, controller.state.value.phase)
            // withContext has finished its IO, but its return to UI is still held.
            controller.cancel(id); ui.defer = false; ui.release(); runCurrent()
            assertTrue("The published row was orphaned when its coroutine result was discarded", row.removed)
            assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase); assertNull(controller.state.value.pictureUri)
            assertFalse(File(root, "shared/download-$id").exists())
        } finally { ui.defer = false; ui.release(); controller.close(); retained.cancel(); runCurrent(); root.deleteRecursively() }
    }

    @Test fun originalBytesBecomeReadyWithAnExactSourceAndOnlyAnOwnedTemporaryFile(): Unit = runTest {
        val root = Files.createTempDirectory("yab-download-").toFile()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val controller = PageDownloadController(File(root, "shared"), this, { it == owner }, dispatcher, dispatcher)
        val bytes = ByteArray(180_013) { (it % 251).toByte() }
        val input = Bytes(bytes)
        val unrelated = File(root, "shared/keep-this.txt").apply { parentFile!!.mkdirs(); writeText("unrelated") }
        try {
            assertTrue(controller.startTransfer(input, owner, "../../source.bin", "application/octet-stream", bytes.size.toLong()))
            runCurrent()
            assertEquals(PageDownloadPhase.READY, controller.state.value.phase)
            assertEquals(owner, controller.state.value.owner)
            assertEquals(bytes.size.toLong(), controller.state.value.received)
            assertEquals("source.bin", controller.state.value.name)
            assertTrue(input.closed)
            val export = requireNotNull(controller.beginExport(controller.state.value.id!!, PageDownloadExportKind.SAVE))
            assertArrayEquals(bytes, export.file.readBytes())
            assertTrue(export.file.parentFile!!.name.startsWith("download-"))
            assertEquals("shared", export.file.parentFile!!.parentFile!!.name)
            assertNull(controller.beginExport(export.download, PageDownloadExportKind.SAVE))
            assertNull(controller.currentExport("another-token", PageDownloadExportKind.SAVE))
            controller.exportCancelled(export.token)
            assertEquals(PageDownloadPhase.READY, controller.state.value.phase)
            controller.cancel(); runCurrent()
            assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase)
            assertFalse(export.file.exists())
            assertEquals("unrelated", unrelated.readText())
        } finally { controller.close(); runCurrent(); root.deleteRecursively() }
    }

    @Test fun failedResponseThenCancelAcceptsANewOriginalTransferWithoutReusingFailure(): Unit = runTest {
        val root = Files.createTempDirectory("yab-download-failed-").toFile()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val controller = PageDownloadController(File(root, "shared"), this, { it == owner }, dispatcher, dispatcher)
        try {
            val short = Bytes(byteArrayOf(1, 2))
            assertTrue(controller.startTransfer(short, owner, "truncated.bin", "application/octet-stream", 100))
            runCurrent()
            assertEquals(PageDownloadPhase.FAILED, controller.state.value.phase)
            assertTrue(short.closed)
            assertTrue(controller.state.value.error!!.contains("Try again from this webpage"))
            val old = controller.state.value.id
            val blocked = Bytes(byteArrayOf(9))
            assertFalse(controller.startTransfer(blocked, owner, "blocked", "text/plain", 1))
            runCurrent(); assertTrue(blocked.closed)
            controller.cancel(old); runCurrent()
            assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase)
            assertNull(controller.state.value.error)
            val next = Bytes(byteArrayOf(3, 4, 5))
            assertTrue(controller.startTransfer(next, owner, "fresh.bin", "application/octet-stream", 3))
            runCurrent()
            assertEquals(PageDownloadPhase.READY, controller.state.value.phase)
            assertNotEquals(old, controller.state.value.id)
            assertNull(controller.state.value.error)
            controller.cancel(old); runCurrent()
            assertEquals("An old Cancel must not own the new response", PageDownloadPhase.READY, controller.state.value.phase)
            controller.cancel(); runCurrent()
        } finally { controller.close(); runCurrent(); root.deleteRecursively() }
    }

    @Test fun accountDocumentProfileAndPrivacyRevocationRemoveReadyFilesAndRejectStaleExports(): Unit = runTest {
        for (changed in listOf(owner.copy(account = "another"), owner.copy(accountEpoch = 2), owner.copy(document = "next"),
                owner.copy(profile = "other"), owner.copy(tab = "different"), owner.copy(privateOrigin = true))) {
            val root = Files.createTempDirectory("yab-download-stale-").toFile()
            val dispatcher = StandardTestDispatcher(testScheduler)
            var current = owner
            val controller = PageDownloadController(File(root, "shared"), this, { it == current }, dispatcher, dispatcher)
            try {
                assertTrue(controller.startTransfer(Bytes(byteArrayOf(7)), owner, "result.bin", "application/octet-stream", 1))
                runCurrent()
                val export = requireNotNull(controller.beginExport(controller.state.value.id!!, PageDownloadExportKind.SAVE))
                controller.exportCancelled(export.token)
                current = changed
                assertFalse(controller.isSourceAlive())
                assertNull(controller.beginExport(export.download, PageDownloadExportKind.SHARE))
                controller.revalidate(); runCurrent()
                assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase)
                assertFalse(export.file.exists())
                controller.exportCancelled(export.token)
                assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase)
                val stale = Bytes(byteArrayOf(8))
                assertFalse(controller.startTransfer(stale, owner, "stale", "text/plain", 1))
                runCurrent(); assertTrue(stale.closed)
            } finally { controller.close(); runCurrent(); root.deleteRecursively() }
        }
    }

    @Test fun serviceFailureAndCancellationBeforeTheWriterStartsCloseTheOriginalStream(): Unit = runTest {
        val root = Files.createTempDirectory("yab-download-service-").toFile()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val controller = PageDownloadController(File(root, "shared"), this, { it == owner }, dispatcher, dispatcher)
        try {
            val first = Bytes(byteArrayOf(1))
            assertTrue(controller.startTransfer(first, owner, "first", "text/plain", 1))
            controller.serviceFailed(); runCurrent()
            assertEquals(PageDownloadPhase.FAILED, controller.state.value.phase)
            assertTrue(controller.state.value.error!!.contains("Android could not keep"))
            assertTrue(first.closed)
            controller.cancel(); runCurrent()
            assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase)
            val second = Bytes(byteArrayOf(2))
            assertTrue(controller.startTransfer(second, owner, "second", "text/plain", 1))
            controller.cancel(); runCurrent()
            assertTrue(second.closed)
            assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase)
            assertNull(controller.state.value.error)
            assertTrue(File(root, "shared").listFiles().orEmpty().isEmpty())
        } finally { controller.close(); runCurrent(); root.deleteRecursively() }
    }

    @Test fun delayedOldCompletionCannotUnlinkAChosenShareAfterAccountChangeAndNewDownloadCancellation(): Unit = runTest {
        val root = Files.createTempDirectory("yab-download-share-").toFile()
        val ui = StandardTestDispatcher(testScheduler)
        val io = DeferredIo(ui)
        var current = owner
        val expiries = mutableListOf<Pair<File, Long>>()
        val controller = PageDownloadController(File(root, "shared"), this, { it == current }, ui, io,
            expireShared = { directory, delay -> expiries += directory to delay })
        var oldFile: File? = null
        try {
            val original = byteArrayOf(9, 8, 7, 6)
            val input = object : ByteArrayInputStream(original) {
                private var firstClose = true
                override fun close() {
                    super.close()
                    // The response writer has closed. Defer its real completion IO,
                    // while allowing the UI and the next original response to proceed.
                    if (firstClose) { firstClose = false; io.defer = true }
                }
            }
            assertTrue(controller.startTransfer(input, owner, "chosen-share.bin", "application/octet-stream", original.size.toLong()))
            runCurrent()
            assertEquals(PageDownloadPhase.READY, controller.state.value.phase)
            assertEquals(1, io.deferredCount)
            io.defer = false
            val share = requireNotNull(controller.beginExport(controller.state.value.id!!, PageDownloadExportKind.SHARE))
            oldFile = share.file
            controller.shareLaunched(share.token)
            assertEquals(PageDownloadPhase.SHARED, controller.state.value.phase)
            assertEquals(listOf(share.file.parentFile!! to 60 * 60 * 1000L), expiries)
            controller.exportCancelled(share.token)
            assertEquals("A late picker cancellation cannot revoke a launched share", PageDownloadPhase.SHARED, controller.state.value.phase)
            current = owner.copy(account = "next-account", accountEpoch = 2)
            controller.revalidate()
            assertTrue(share.file.isFile)
            assertEquals(PageDownloadPhase.SHARED, controller.state.value.phase)

            assertTrue(controller.startTransfer(Bytes(byteArrayOf(1, 2)), current, "next.bin", "application/octet-stream", 2))
            controller.shareReturned(share.token)
            assertEquals(share.file.parentFile!! to 5 * 60 * 1000L, expiries.last())
            runCurrent()
            assertEquals(PageDownloadPhase.READY, controller.state.value.phase)
            val next = requireNotNull(controller.beginExport(controller.state.value.id!!, PageDownloadExportKind.SAVE))
            controller.exportCancelled(next.token)
            controller.cancel(share.download)
            assertEquals(PageDownloadPhase.READY, controller.state.value.phase)
            controller.cancel(next.download); runCurrent()
            assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase)
            assertFalse(next.file.exists())

            // Run the actual old completion after the newer response was cancelled.
            // It must neither alter the new state nor bypass the external read lease.
            io.release(); runCurrent()
            assertEquals(PageDownloadPhase.CANCELLED, controller.state.value.phase)
            assertArrayEquals(original, share.file.readBytes())
            assertEquals(2, expiries.size)
            assertTrue(expiries.all { it.first == share.file.parentFile })
        } finally {
            io.defer = false; io.release()
            controller.close(); runCurrent()
            oldFile?.parentFile?.let(PageDownloadFiles::remove)
            root.deleteRecursively()
        }
    }

    private class DeferredIo(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        private val waiting = mutableListOf<Pair<CoroutineContext, Runnable>>()
        var defer = false
        val deferredCount get() = waiting.size
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            if (defer) waiting += context to block else delegate.dispatch(context, block)
        }
        fun release() {
            val pending = waiting.toList(); waiting.clear()
            pending.forEach { (context, block) -> delegate.dispatch(context, block) }
        }
    }

    @Test fun cancellingABlockedOriginalStreamClosesItsWriterBeforeRemovingTheDirectory(): Unit = runBlocking {
        val root = Files.createTempDirectory("yab-download-blocked-").toFile()
        val ui = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + ui)
        val readStarted = CountDownLatch(1)
        val releaseRead = CountDownLatch(1)
        val closed = AtomicBoolean()
        val removedWhileReading = AtomicBoolean()
        var valid = true
        val controller = PageDownloadController(File(root, "shared"), scope, { valid && it == owner }, ui, Dispatchers.IO)
        val source = object : InputStream() {
            override fun read(): Int = error("The controller must use a byte buffer")
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                readStarted.countDown()
                check(releaseRead.await(5, TimeUnit.SECONDS)) { "Cancellation did not close the native stream" }
                removedWhileReading.set(File(root, "shared").listFiles()?.none { it.name.startsWith("download-") } == true)
                throw java.io.IOException("The native stream was closed")
            }
            override fun close() { closed.set(true); releaseRead.countDown() }
        }
        try {
            assertTrue(withContext(ui) { controller.startTransfer(source, owner, "blocked.bin", "application/octet-stream", null) })
            assertTrue(withContext(Dispatchers.IO) { readStarted.await(5, TimeUnit.SECONDS) })
            withContext(ui) { valid = false; controller.revalidate() }
            withTimeout(5_000) { controller.state.first { it.phase == PageDownloadPhase.CANCELLED } }
            assertTrue(closed.get())
            assertFalse("The directory was unlinked while the response writer still ran", removedWhileReading.get())
            assertTrue(File(root, "shared").listFiles().orEmpty().isEmpty())
        } finally {
            releaseRead.countDown()
            withContext(ui) { controller.close() }
            scope.cancel(); ui.close(); root.deleteRecursively()
        }
    }
}

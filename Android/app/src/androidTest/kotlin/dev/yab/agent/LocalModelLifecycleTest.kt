package dev.yab.agent

import android.net.Uri
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

/** Actual native format validation and file ownership, using only the disposable model. */
class LocalModelLifecycleTest {
    private fun models(): LocalModelManager {
        val registry = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(InstrumentationRegistry.getArguments().getString("requireModel") == "true")
        return LocalModelManager(registry.targetContext).also { assertTrue(it.modelFile.isFile) }
    }

    @Test(timeout = 180_000)
    fun invalidImportKeepsOriginalBytesAndValidImportUsesRealNativeValidation(): Unit = runBlocking {
        val manager = models()
        val before = digest(manager.modelFile)
        val invalid = File(manager.modelFile.parentFile, "invalid-${UUID.randomUUID()}.litertlm")
        try {
            invalid.writeText("This is an invalid model fixture.\n".repeat(100))
            manager.import(Uri.fromFile(invalid))
            assertNotNull("An invalid binary was accepted as a model", manager.state.value.error)
            assertEquals(before, digest(manager.modelFile))
            assertTrue(manager.state.value.ready)
            assertFalse(manager.state.value.importing)
            // The URI reads the current inode; atomic replacement happens only
            // after an independent copied file passes actual native initialize.
            manager.import(Uri.fromFile(manager.modelFile))
            assertNull(manager.state.value.error)
            assertEquals(before, digest(manager.modelFile))
            assertTrue(manager.state.value.ready)
        } finally { invalid.delete() }
    }

    @Test(timeout = 120_000)
    fun removingWaitsForTheInferenceFileLeaseAndRestoresOnlyTheOwnedFixture(): Unit = runBlocking {
        val manager = models()
        val backup = File(manager.modelFile.parentFile, "owned-model-${UUID.randomUUID()}.backup")
        val bytes = manager.modelFile.length()
        val before = withContext(Dispatchers.IO) { digest(manager.modelFile) }
        val ownedModel = (LocalModelCatalog.available + LocalModelCatalog.smokeTest).singleOrNull {
            it.bytes == bytes && it.sha256 == before
        }
        checkNotNull(ownedModel) { "The owned model did not match an immutable fixture" }
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var reader: Deferred<Unit>? = null
        var remove: Deferred<Unit>? = null
        var backupComplete = false
        try {
            // App-private SELinux policy may reject hard links. Keep a bounded,
            // independently verified copy without downloading or changing the source.
            withContext(Dispatchers.IO) {
                check(backup.parentFile!!.usableSpace > bytes + 16L * 1024 * 1024) { "Not enough storage for the owned model backup" }
                check(backup.createNewFile()) { "The owned backup already exists" }
                manager.modelFile.inputStream().use { source -> backup.outputStream().use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    var copied = 0L
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = source.read(buffer)
                        if (count < 0) break
                        copied += count
                        check(copied <= ownedModel.bytes) { "The model changed while creating its backup" }
                        output.write(buffer, 0, count)
                    }
                    check(copied == ownedModel.bytes) { "The model backup was incomplete" }
                    output.fd.sync()
                } }
                assertEquals(before, digest(backup))
            }
            backupComplete = true
            val activeReader = async { manager.withInstalledModel { file ->
                assertTrue(file.isFile); entered.complete(Unit); release.await(); assertTrue(file.isFile)
            } }
            reader = activeReader
            withTimeout(10_000) { entered.await() }
            val activeRemove = async { manager.remove() }
            remove = activeRemove
            delay(100)
            assertFalse("Removal bypassed an active inference file lease", activeRemove.isCompleted)
            assertTrue(manager.modelFile.isFile)
            release.complete(Unit)
            withTimeout(10_000) { activeReader.await(); activeRemove.await() }
            assertFalse(manager.modelFile.exists())
            assertFalse(manager.state.value.ready)
        } finally {
            withContext(NonCancellable) {
                release.complete(Unit); reader?.cancelAndJoin(); remove?.cancelAndJoin()
                if (backupComplete) withContext(Dispatchers.IO) {
                    Os.rename(backup.path, manager.modelFile.path)
                    assertEquals(before, digest(manager.modelFile))
                } else backup.delete()
            }
        }
    }

    private fun digest(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { source ->
            val buffer = ByteArray(1024 * 1024)
            while (true) { val read = source.read(buffer); if (read < 0) break; digest.update(buffer, 0, read) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

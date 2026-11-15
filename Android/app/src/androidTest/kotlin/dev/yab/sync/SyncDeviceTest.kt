package dev.yab.sync

import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.core.app.ActivityScenario
import dev.yab.android.EngineTestActivity
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.android.NowWidget
import dev.yab.android.R
import dev.yab.agent.AgentTaskOrigin
import dev.yab.agent.*
import dev.yab.core.crypto.Seal
import dev.yab.core.sync.Clock
import dev.yab.core.sync.Device
import dev.yab.core.sync.PairingClient
import dev.yab.core.sync.Record
import dev.yab.core.sync.RecordKey
import dev.yab.core.sync.TaskRecords
import kotlinx.coroutines.delay
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.Closeable
import java.io.File
import java.security.KeyStore
import java.util.Base64
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Real Keystore and production Worker endpoints. Every identity/alias belongs to this test. */
@RunWith(AndroidJUnit4::class)
class SyncDeviceTest {
    private val target get() = InstrumentationRegistry.getInstrumentation().targetContext

    private class IsolatedContext(base: Context) : ContextWrapper(base), Closeable {
        private val identifier = UUID.randomUUID().toString().replace("-", "")
        private val root = File(base.cacheDir, "sync-test-$identifier").apply { check(mkdirs()) }
        private val name = base.packageName + ".syncfixture" + identifier
        var storageFailure = false
        val identityFile get() = File(root, "no-backup/sync-identity.enc")
        val alias get() = "$name.sync.identity.v1"
        override fun getApplicationContext(): Context = this
        override fun getPackageName(): String = name
        override fun getNoBackupFilesDir(): File = if (storageFailure) File(root, "blocked").apply { if (!exists()) writeText("not a directory") }
            else File(root, "no-backup").apply { mkdirs() }
        override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
        override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        override fun close() {
            storageFailure = false
            SyncIdentityStore(this).forget()
            root.deleteRecursively()
        }
    }

    @Test(timeout = 30_000)
    fun actualKeystoreIdentityReloadUsesRandomizedCiphertextAndNoPlainCredentials() {
        IsolatedContext(target).use { context ->
            val identity = SyncIdentity(Seal.make(), UUID.randomUUID().toString(), "test-token-${UUID.randomUUID()}")
            SyncIdentityStore(context).save(identity)
            val first = context.identityFile.readBytes()
            val loaded = SyncIdentityStore(context).load()!!
            assertArrayEquals(identity.seal.raw(), loaded.seal.raw())
            assertEquals(identity.device, loaded.device); assertEquals(identity.token, loaded.token)
            val bytesAsText = first.toString(Charsets.ISO_8859_1)
            assertFalse(bytesAsText.contains(identity.token!!))
            assertFalse(bytesAsText.contains(Base64.getEncoder().encodeToString(identity.seal.raw())))
            assertFalse(bytesAsText.contains(identity.seal.recovery))
            SyncIdentityStore(context).save(identity)
            assertFalse("AndroidKeyStore must choose a fresh GCM IV on each save", first.contentEquals(context.identityFile.readBytes()))
            assertNotNull(KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(context.alias, null))
        }
    }

    @Test(timeout = 30_000)
    fun corruptCiphertextAndMissingKeyFailClosedWithoutSilentlyReplacingTheAccount() {
        IsolatedContext(target).use { context ->
            val store = SyncIdentityStore(context)
            store.save(SyncIdentity(Seal.make(), UUID.randomUUID().toString(), "saved-token"))
            val original = context.identityFile.readBytes()
            val corrupt = original.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
            context.identityFile.writeBytes(corrupt)
            assertThrows(Exception::class.java) { SyncIdentityStore(context).load() }
            assertArrayEquals("Authentication failure must retain bytes for explicit recovery", corrupt, context.identityFile.readBytes())
            context.identityFile.writeBytes(original)
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(context.alias) }
            assertThrows(IllegalStateException::class.java) { SyncIdentityStore(context).load() }
            assertArrayEquals(original, context.identityFile.readBytes())
            store.forget(); assertNull(store.load())
        }
    }

    @Test(timeout = 30_000)
    fun failedIdentitySaveDoesNotTurnAnUnpersistedTokenIntoTheSavedIdentity() {
        IsolatedContext(target).use { context ->
            val identity = SyncIdentity(Seal.make(), UUID.randomUUID().toString(), "previous-token")
            SyncIdentityStore(context).save(identity)
            val verified = context.identityFile.readBytes()
            context.storageFailure = true
            assertThrows(Exception::class.java) { SyncIdentityStore(context).save(identity.copy(token = "unpersisted-token")) }
            context.storageFailure = false
            assertArrayEquals(verified, context.identityFile.readBytes())
            val reloaded = SyncIdentityStore(context).load()!!
            assertEquals("previous-token", reloaded.token); assertArrayEquals(identity.seal.raw(), reloaded.seal.raw())
        }
    }

    @Test(timeout = 30_000)
    fun insecureSyncIsAnExplicitDebugLoopbackOptIn() = runBlocking {
        IsolatedContext(target).use { context ->
            assertThrows(IllegalArgumentException::class.java) { AndroidSyncBridge(context, "http://127.0.0.1:1") }
            assertThrows(IllegalArgumentException::class.java) { AndroidSyncBridge(context, "http://example.test", allowInsecureForTests = true) }
            assertThrows(IllegalArgumentException::class.java) { AndroidSyncBridge(context, "https://example.test", allowInsecureForTests = true) }
            AndroidSyncBridge(context, "http://127.0.0.1:1", allowInsecureForTests = true).awaitClosedForTests()
        }
    }

    @Test(timeout = 180_000)
    fun replacingAndCancellingRealPairingCannotOverrideTheRecoveredIdentity() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val url = arguments.getString("syncBackendUrl")
        if (arguments.getString("requireSyncBackend") == "true") assertFalse("A real local Worker URL is required", url.isNullOrBlank())
        assumeTrue("This regression requires the owned local Worker", !url.isNullOrBlank())
        val endpoint = url!!.toHttpUrl()
        assertEquals("http", endpoint.scheme); assertEquals("127.0.0.1", endpoint.host)
        val http = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()
        val pairing = PairingClient(url, http, allowInsecureForTests = true)
        suspend fun posted(code: String): PairingClient.Challenge {
            var challenge: PairingClient.Challenge? = null
            withTimeout(20_000) {
                while (challenge == null) {
                    challenge = awaitSyncCallback<PairingClient.Challenge> { pairing.lookUp(code, it) }.getOrNull()
                    if (challenge == null) delay(50)
                }
            }
            return checkNotNull(challenge)
        }
        IsolatedContext(target).use { context ->
            val bridge = AndroidSyncBridge(context, url, allowInsecureForTests = true)
            try {
                bridge.join(); await("first real pairing code") { bridge.ui.value.code != null }
                val first = bridge.ui.value.code!!; posted(first)
                bridge.join(); await("replacement pairing keeps its own code") { bridge.ui.value.code != null && bridge.ui.value.code != first }
                val second = bridge.ui.value.code!!; val challenge = posted(second)
                assertEquals(second, bridge.ui.value.code); assertEquals(challenge.check, bridge.ui.value.check)
                assertEquals("joining", bridge.ui.value.phase); assertNull(SyncIdentityStore(context).load())
                val recovered = Seal.make()
                bridge.cancelJoin(second); bridge.joinRecovery(recovered.recovery)
                await("cancelled pairing cannot clear the recovered live session") { bridge.ui.value.phase == "live" && bridge.ui.value.account == recovered.account }
                posted(first) // Another genuine HTTP round trip; no delayed-success barrier is claimed.
                val saved = SyncIdentityStore(context).load()!!
                assertArrayEquals(recovered.raw(), saved.seal.raw()); assertEquals(saved.device, bridge.ownDevice)
                assertEquals("live", bridge.ui.value.phase); assertEquals(recovered.account, bridge.ui.value.account)
                val lease = checkNotNull(bridge.recoveryLease())
                for (stale in listOf(lease.copy(account = "different"), lease.copy(device = "different"), lease.copy(epoch = lease.epoch - 1)))
                    assertTrue("A mismatched reveal lease cannot export any key", runCatching { bridge.recoveryKey(stale) }.isFailure)
                val sendsBefore = bridge.records.value.filter { it.collection == "send" }
                for (stale in listOf(lease.copy(account = "different"), lease.copy(device = "different"), lease.copy(epoch = lease.epoch - 1))) {
                    val denied = runCatching { bridge.openOnMac("https://fixture.invalid/captured", "Captured page", expected = stale) }.exceptionOrNull()
                    assertEquals("A captured menu must be refused inside the actual Sync dispatcher before recipient lookup",
                        "The page menu Sync owner changed", denied?.message)
                    assertEquals(sendsBefore, bridge.records.value.filter { it.collection == "send" })
                }
                val eligibleOwner = runCatching { bridge.openOnMac("https://fixture.invalid/captured", "Captured page", expected = lease) }.exceptionOrNull()
                assertTrue("The current owner must reach the normal recipient check", eligibleOwner is AgentUnavailable)
                assertEquals(sendsBefore, bridge.records.value.filter { it.collection == "send" })
                // Direct bridge provenance check only; this does not simulate biometric approval.
                assertEquals(recovered.recovery, bridge.recoveryKey(lease))
                bridge.awaitClosedForTests()
                assertNull("Closing immediately invalidates recovery export", bridge.recoveryLease())
                assertArrayEquals(recovered.raw(), SyncIdentityStore(context).load()!!.seal.raw())
            } finally { bridge.awaitClosedForTests(); http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll() }
        }
    }

    /** Genuine owned Worker and Keystore; this is Bridge completion, not Main card pixels. */
    @Test(timeout = 180_000)
    fun actualJoinCompletionObservesDurablePairingAndRecoveryWithoutReconnectReplay() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val url = arguments.getString("syncBackendUrl")
        if (arguments.getString("requireSyncBackend") == "true") assertFalse("An owned local Worker URL is required", url.isNullOrBlank())
        assumeTrue("This Bridge completion scenario requires the owned local Worker", !url.isNullOrBlank())
        val endpoint = url!!.toHttpUrl()
        assertEquals("http", endpoint.scheme); assertEquals("127.0.0.1", endpoint.host)
        val http = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()
        data class Completion(val identity: SyncIdentityLease, val durable: Boolean, val current: Boolean, val onMain: Boolean)
        fun observer(bridge: AndroidSyncBridge, context: IsolatedContext, values: LinkedBlockingQueue<Completion>): (SyncIdentityLease) -> Unit = { lease ->
            // Assertions stay outside this optional observer: production deliberately
            // isolates a presentation exception from a successfully saved account.
            val saved = runCatching { SyncIdentityStore(context).load() }.getOrNull()
            values.add(Completion(lease, saved != null && saved.device == lease.device && saved.seal.account == lease.account,
                bridge.identityLease() == lease, android.os.Looper.myLooper() == android.os.Looper.getMainLooper()))
        }
        IsolatedContext(target).use { firstContext -> IsolatedContext(target).use { recoveredContext -> IsolatedContext(target).use { invalidContext ->
            val first = AndroidSyncBridge(firstContext, url, allowInsecureForTests = true)
            val recovered = AndroidSyncBridge(recoveredContext, url, allowInsecureForTests = true)
            val invalid = AndroidSyncBridge(invalidContext, url, allowInsecureForTests = true)
            val pairedValues = LinkedBlockingQueue<Completion>()
            val recoveryValues = LinkedBlockingQueue<Completion>()
            val invalidValues = LinkedBlockingQueue<Completion>()
            try {
                val seal = Seal.make()
                MacPeer(url, seal, http).use {
                    first.join(onJoined = observer(first, firstContext, pairedValues))
                    await("original real pairing code") { first.ui.value.code != null }
                    val code = checkNotNull(first.ui.value.code)
                    val pair = PairingClient(url, http, allowInsecureForTests = true)
                    var challenge: PairingClient.Challenge? = null
                    withTimeout(20_000) {
                        while (challenge == null) {
                            challenge = awaitSyncCallback<PairingClient.Challenge> { pair.lookUp(code, it) }.getOrNull()
                            if (challenge == null) delay(50)
                        }
                    }
                    assertTrue(pairedValues.isEmpty())
                    assertEquals(first.ui.value.check, challenge!!.check)
                    assertTrue(awaitSyncCallback<Boolean> { pair.answer(challenge!!, seal, it) }.getOrThrow())
                    await("one genuine paired completion") { pairedValues.isNotEmpty() }
                    assertEquals(1, pairedValues.size)
                    val paired = pairedValues.single()
                    assertTrue(paired.durable); assertTrue(paired.current); assertTrue(paired.onMain)
                    assertEquals(first.identityLease(), paired.identity)
                    assertEquals(seal.account, paired.identity.account)
                    assertArrayEquals(seal.raw(), SyncIdentityStore(firstContext).load()!!.seal.raw())
                    await("original account reaches live") { first.ui.value.phase == "live" }
                    first.pause(); await("original account stops") { first.ui.value.phase == "off" }
                    first.start(); await("original account reconnects") { first.ui.value.phase == "live" }
                    assertEquals("Reconnect cannot replay a join observer", 1, pairedValues.size)
                    assertEquals(paired.identity, first.identityLease())
                    recovered.joinRecovery(seal.recovery, onJoined = observer(recovered, recoveredContext, recoveryValues))
                    await("one genuine recovery completion") { recoveryValues.isNotEmpty() }
                    val restored = recoveryValues.single()
                    assertTrue(restored.durable); assertTrue(restored.current); assertTrue(restored.onMain)
                    assertEquals(seal.account, restored.identity.account)
                    assertNotEquals(paired.identity.device, restored.identity.device)
                    assertEquals(recovered.identityLease(), restored.identity)
                    assertArrayEquals(seal.raw(), SyncIdentityStore(recoveredContext).load()!!.seal.raw())
                    invalid.joinRecovery("invalid owned fixture recovery", onJoined = observer(invalid, invalidContext, invalidValues))
                    await("invalid recovery finishes with error") { invalid.ui.value.error != null }
                    assertTrue(invalidValues.isEmpty()); assertNull(invalid.identityLease())
                    assertNull(SyncIdentityStore(invalidContext).load())
                    assertEquals(1, pairedValues.size); assertEquals(1, recoveryValues.size)
                }
            } finally {
                first.awaitClosedForTests(); recovered.awaitClosedForTests(); invalid.awaitClosedForTests()
                http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll()
            }
        } } }
    }

    @Test(timeout = 30_000)
    fun originalCompletedRecoveryFailureNotifiesMainOnceWithoutChangingItsErrorOrIdentity() = runBlocking {
        IsolatedContext(target).use { context ->
            val bridge = AndroidSyncBridge(context, "http://127.0.0.1:1", allowInsecureForTests = true)
            val first = LinkedBlockingQueue<Boolean>(); val second = LinkedBlockingQueue<Boolean>()
            try {
                bridge.joinRecovery("invalid original recovery", onJoined = { first.add(false) }, onJoinFailed = {
                    first.add(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
                    throw IllegalStateException("owned presentation failure")
                })
                await("the original failed operation notifies its observer on Main") { first.isNotEmpty() }
                assertEquals(listOf(true), first.toList())
                val error = bridge.ui.value.error
                assertNotNull(error); assertNull(bridge.ui.value.code); assertNull(bridge.identityLease())
                assertNull(SyncIdentityStore(context).load())
                bridge.joinRecovery("another invalid original recovery", onJoinFailed = {
                    second.add(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
                })
                await("a new failure has its own single observer") { second.isNotEmpty() }
                assertEquals(listOf(true), first.toList()); assertEquals(listOf(true), second.toList())
                assertEquals(error, bridge.ui.value.error); assertNull(bridge.identityLease())
                assertNull(SyncIdentityStore(context).load())
            } finally { bridge.awaitClosedForTests() }
        }
    }

    @Test(timeout = 60_000)
    fun originalPostSaveJournalAttachFailureNotifiesMainWithoutPretendingItJoinedOrErasingItsKey() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        check(arguments.getString("requireSyncBackend") == "true") { "This case requires the owned local Worker" }
        val url = checkNotNull(arguments.getString("syncBackendUrl"))
        val endpoint = url.toHttpUrl()
        assertEquals("http", endpoint.scheme); assertEquals("127.0.0.1", endpoint.host)
        IsolatedContext(target).use { context ->
            val seal = Seal.make()
            val blockedJournal = File(context.noBackupFilesDir, "Sync/${seal.account}/journal.json")
            check(blockedJournal.mkdirs() && blockedJournal.isDirectory)
            val bridge = AndroidSyncBridge(context, url, allowInsecureForTests = true)
            data class Failure(val onMain: Boolean, val durable: Boolean, val leasePresent: Boolean,
                val noCode: Boolean, val errorPresent: Boolean, val oldPublicationRefused: Boolean)
            val failures = LinkedBlockingQueue<Failure>()
            val joined = LinkedBlockingQueue<SyncIdentityLease>()
            try {
                assertNull(bridge.identityLease()); assertNull(SyncIdentityStore(context).load())
                bridge.joinRecovery(seal.recovery, onJoined = { joined.add(it) }, onJoinFailed = {
                    val lease = bridge.identityLease()
                    val saved = SyncIdentityStore(context).load()
                    failures.add(Failure(android.os.Looper.myLooper() == android.os.Looper.getMainLooper(),
                        saved != null && saved.seal.account == seal.account && saved.device == lease?.device,
                        lease?.account == seal.account, bridge.ui.value.code == null, bridge.ui.value.error != null,
                        !bridge.nativeOwnerCurrent(bridge.accountRecords.value)))
                })
                await("the original post-save failure delivers one Main terminal observation") { failures.isNotEmpty() }
                assertEquals(1, failures.size); val failure = failures.single()
                assertTrue(failure.onMain); assertTrue(failure.durable); assertTrue(failure.leasePresent)
                assertTrue(failure.noCode); assertTrue(failure.errorPresent); assertTrue(failure.oldPublicationRefused)
                assertTrue(joined.isEmpty()); assertTrue(blockedJournal.isDirectory)
                assertNotNull(bridge.identityLease()); assertNotNull(SyncIdentityStore(context).load())
            } finally { bridge.awaitClosedForTests() }
        }
    }

    @Test(timeout = 60_000)
    fun localNativePublicationAfterTheOwnedPartialAttachReadsNoNewIdentityAndCannotPretendItJoined() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        check(arguments.getString("requireSyncBackend") == "true") { "This case requires the owned local Worker" }
        val url = checkNotNull(arguments.getString("syncBackendUrl"))
        val endpoint = url.toHttpUrl()
        assertEquals("http", endpoint.scheme); assertEquals("127.0.0.1", endpoint.host)
        IsolatedContext(target).use { context ->
            val seal = Seal.make()
            val blockedJournal = File(context.noBackupFilesDir, "Sync/${seal.account}/journal.json")
            check(blockedJournal.mkdirs() && blockedJournal.isDirectory)
            val bridge = AndroidSyncBridge(context, url, allowInsecureForTests = true)
            val failed = LinkedBlockingQueue<Boolean>()
            val joined = LinkedBlockingQueue<SyncIdentityLease>()
            try {
                bridge.joinRecovery(seal.recovery, onJoined = { joined.add(it) }, onJoinFailed = {
                    failed.add(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
                })
                await("the owned partial attach reports its one original Main failure") { failed.isNotEmpty() }
                assertEquals(listOf(true), failed.toList()); assertTrue(joined.isEmpty())
                val original = checkNotNull(bridge.identityLease())
                val durable = checkNotNull(SyncIdentityStore(context).load())
                assertEquals(seal.account, original.account); assertEquals(original.account, durable.seal.account)
                assertEquals(original.device, durable.device)
                val encryptedBefore = context.identityFile.readBytes()
                val errorBefore = bridge.ui.value.error; assertNotNull(errorBefore)
                val oldPublication = bridge.accountRecords.value
                assertFalse(bridge.nativeOwnerCurrent(oldPublication))
                // This existing local API only publishes the actual current identity. It does not attach/start transport.
                val published = bridge.prepareNativeOwner()
                assertEquals(original.account, published.account); assertEquals(original.device, published.device)
                assertEquals(original.epoch, published.epoch); assertFalse(published.removed)
                assertTrue(bridge.nativeOwnerCurrent(published)); assertEquals(original, bridge.identityLease())
                assertFalse("Local publication after failed attach must not offer a false saved Found/Joined entry",
                    dev.yab.android.firstRunEntryAvailable(bridge))
                val stillSaved = checkNotNull(SyncIdentityStore(context).load())
                assertEquals(original.account, stillSaved.seal.account); assertEquals(original.device, stillSaved.device)
                assertTrue("Local publication must not rewrite the saved encrypted identity", encryptedBefore.contentEquals(context.identityFile.readBytes()))
                assertEquals(errorBefore, bridge.ui.value.error); assertEquals(listOf(true), failed.toList())
                assertTrue(joined.isEmpty()); assertTrue(blockedJournal.isDirectory)
            } finally { bridge.awaitClosedForTests() }
        }
    }

    /** Controlled loopback health gate only, not a Worker or successful pairing substitute. */
    @Test(timeout = 60_000)
    fun originalRequestCancelledWhileHealthWaitsCannotPublishCodeOrCancelAFreshRequest() = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true" && android.os.Build.VERSION.SDK_INT == 36)
        val socket = java.net.ServerSocket(0, 8, java.net.InetAddress.getByName("127.0.0.1"))
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val replacementEntered = java.util.concurrent.CountDownLatch(1)
        val replacementRelease = java.util.concurrent.CountDownLatch(1)
        val legacyEntered = java.util.concurrent.CountDownLatch(1)
        val legacyRelease = java.util.concurrent.CountDownLatch(1)
        val stopped = java.util.concurrent.atomic.AtomicBoolean(false)
        val health = java.util.concurrent.atomic.AtomicInteger()
        val posts = java.util.concurrent.atomic.AtomicInteger()
        val serverFailure = AtomicReference<Throwable>()
        val server = Thread({
            while (!stopped.get()) try {
                socket.accept().use { client ->
                    client.soTimeout = 5_000
                    val reader = client.getInputStream().bufferedReader()
                    val request = reader.readLine() ?: return@use
                    val path = request.split(' ').getOrNull(1)
                    var length = 0; var headers = 0
                    while (true) {
                        val line = reader.readLine() ?: error("Owned health fixture lost its headers")
                        if (line.isEmpty()) break
                        check(++headers <= 64)
                        if (line.startsWith("Content-Length:", ignoreCase = true)) length = line.substringAfter(':').trim().toInt()
                    }
                    check(length in 0..8192)
                    repeat(length) { check(reader.read() != -1) }
                    val body = if (path == "/v1/health") {
                        when (health.incrementAndGet()) {
                            1 -> { entered.countDown(); check(release.await(15, TimeUnit.SECONDS)) }
                            3 -> { replacementEntered.countDown(); check(replacementRelease.await(15, TimeUnit.SECONDS)) }
                            5 -> { legacyEntered.countDown(); check(legacyRelease.await(15, TimeUnit.SECONDS)) }
                        }
                        "{\"ok\":true,\"v\":1,\"androidSync\":1}"
                    } else {
                        check(path?.startsWith("/v1/pair") == true)
                        if (request.startsWith("POST ")) posts.incrementAndGet()
                        "{}"
                    }.toByteArray()
                    val status = if (request.startsWith("POST ")) "204 No Content" else "200 OK"
                    val payload = if (request.startsWith("POST ")) byteArrayOf() else body
                    client.getOutputStream().apply {
                        write("HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(payload); flush()
                    }
                }
            } catch (failure: Exception) {
                if (!stopped.get() && failure !is java.io.IOException) serverFailure.compareAndSet(null, failure)
            }
        }, "owned-pending-code-health").apply { isDaemon = true; start() }
        var completed = false
        try {
            IsolatedContext(target).use { context ->
                val bridge = AndroidSyncBridge(context, "http://127.0.0.1:${socket.localPort}", allowInsecureForTests = true)
                val joined = java.util.concurrent.atomic.AtomicInteger(); val failed = java.util.concurrent.atomic.AtomicInteger()
                try {
                    bridge.prepareNativeOwner()
                    val original = withContext(Dispatchers.Main.immediate) {
                        bridge.joinRequest(onJoined = { joined.incrementAndGet() }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
                    assertNull(bridge.ui.value.code); assertNull(bridge.identityLease()); assertEquals(0, posts.get())
                    assertEquals(CodeJoinRequest.Stage.PENDING, original.presentation.value.stage)
                    assertTrue("The original pending request has no foreign presentation payload",
                        original.presentation.value.let { it.code == null && it.check == null && it.error == null })
                    assertTrue(withContext(Dispatchers.Main.immediate) { original.cancel() })
                    assertFalse(withContext(Dispatchers.Main.immediate) { original.cancel() })
                    val fresh = withContext(Dispatchers.Main.immediate) {
                        bridge.joinRequest(onJoined = { joined.incrementAndGet() }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    assertTrue("The queued replacement starts with its own empty immutable presentation",
                        fresh.presentation.value.let { it.stage == CodeJoinRequest.Stage.PENDING && it.code == null && it.check == null && it.error == null })
                    release.countDown()
                    await("only the fresh request publishes its genuine code and session") {
                        health.get() == 2 && posts.get() == 1 && bridge.ui.value.code != null &&
                            fresh.presentation.value.stage == CodeJoinRequest.Stage.PUBLISHED
                    }
                    val freshCode = checkNotNull(bridge.ui.value.code)
                    val published = fresh.presentation.value
                    assertTrue("The published payload belongs to the fresh actual session",
                        published.stage == CodeJoinRequest.Stage.PUBLISHED && published.code == freshCode && published.check == bridge.ui.value.check)
                    val cancelledOriginal = original.presentation.value
                    assertFalse(original.cancel())
                    assertTrue("The cancelled original snapshot stays unchanged", cancelledOriginal === original.presentation.value)
                    assertTrue("The fresh published snapshot stays unchanged", published === fresh.presentation.value)
                    bridge.prepareNativeOwner()
                    assertTrue("The old request cannot replace the fresh code", freshCode == bridge.ui.value.code); assertEquals(1, posts.get())
                    assertNull(bridge.ui.value.error); assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists())
                    assertEquals(0, joined.get()); assertEquals(0, failed.get())
                    assertTrue(withContext(Dispatchers.Main.immediate) { fresh.cancel() })
                    val replacement = withContext(Dispatchers.Main.immediate) {
                        bridge.joinRequest(onJoined = { joined.incrementAndGet() }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    assertTrue(withContext(Dispatchers.IO) { replacementEntered.await(5, TimeUnit.SECONDS) })
                    assertTrue("After a real Published predecessor the blocked replacement has no predecessor payload",
                        replacement.presentation.value.let { it.stage == CodeJoinRequest.Stage.PENDING && it.code == null && it.check == null && it.error == null })
                    val replacementPending = replacement.presentation.value
                    assertFalse(fresh.cancel()); assertTrue("The old request cannot change its replacement snapshot", replacementPending === replacement.presentation.value)
                    assertTrue(withContext(Dispatchers.Main.immediate) { replacement.cancel() })
                    replacementRelease.countDown()
                    bridge.prepareNativeOwner(); bridge.prepareNativeOwner()
                    assertNull(bridge.ui.value.code); assertEquals("off", bridge.ui.value.phase)
                    assertNull(bridge.ui.value.error); assertEquals(0, joined.get()); assertEquals(0, failed.get())
                    assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists()); assertNull(serverFailure.get())
                    val beforeLegacy = withContext(Dispatchers.Main.immediate) {
                        bridge.joinRequest(onJoined = { joined.incrementAndGet() }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    await("the owned predecessor really publishes before legacy replacement") {
                        health.get() == 4 && posts.get() == 2 && beforeLegacy.presentation.value.stage == CodeJoinRequest.Stage.PUBLISHED
                    }
                    val originalPublished = beforeLegacy.presentation.value
                    assertTrue("The original active ticket/session positively admits its own published snapshot",
                        originalPublished.code != null && originalPublished.check != null && beforeLegacy.permits(originalPublished))
                    withContext(Dispatchers.Main.immediate) { bridge.join() }
                    assertTrue(withContext(Dispatchers.IO) { legacyEntered.await(5, TimeUnit.SECONDS) })
                    assertTrue("The old Published snapshot exists while its callback waits behind legacy health",
                        beforeLegacy.presentation.value === originalPublished)
                    assertTrue("The held legacy request has not replaced the predecessor's visible code yet",
                        bridge.ui.value.code == originalPublished.code)
                    assertFalse("Published data cannot grant action authority after exact ticket/session replacement",
                        beforeLegacy.permits(originalPublished))
                    assertEquals(CodeJoinRequest.Stage.RETIRED, beforeLegacy.presentation.value.stage)
                    assertFalse(beforeLegacy.cancel())
                    legacyRelease.countDown()
                    await("the untouched legacy successor still publishes its own code") {
                        health.get() == 5 && posts.get() == 3 && bridge.ui.value.code != null
                    }
                    val legacyCode = checkNotNull(bridge.ui.value.code)
                    assertFalse(beforeLegacy.cancel())
                    assertTrue("The old owned request cannot clear the genuine legacy successor", bridge.ui.value.code == legacyCode)
                    withContext(Dispatchers.Main.immediate) { bridge.cancelJoin(legacyCode) }
                    bridge.prepareNativeOwner(); bridge.prepareNativeOwner()
                    assertNull(bridge.ui.value.code); assertNull(bridge.ui.value.error)
                    assertEquals(0, joined.get()); assertEquals(0, failed.get())
                    assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists()); assertNull(serverFailure.get())
                    completed = true
                } finally { release.countDown(); replacementRelease.countDown(); legacyRelease.countDown(); bridge.awaitClosedForTests() }
            }
        } finally {
            release.countDown(); replacementRelease.countDown(); legacyRelease.countDown(); stopped.set(true); socket.close(); server.join(1_000); check(!server.isAlive)
            val folder = File(target.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
            File(folder, "pending-code-request.json").writeText(org.json.JSONObject().put("schema", 1).put("completed", completed)
                .put("healthRequests", health.get()).put("pairingPosts", posts.get()).put("controlledLoopbackOnly", true)
                .put("providerProof", false).toString(2))
        }
    }

    /** The new request-capable entry, actual owned Worker/Keystore and original completion observer. */
    @Test(timeout = 180_000)
    fun actualOwnedRequestCompletionIsDurableOnMainAndCannotReplayAfterReconnect() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        check(arguments.getString("requireSyncBackend") == "true")
        val url = checkNotNull(arguments.getString("syncBackendUrl"))
        val endpoint = url.toHttpUrl(); assertEquals("http", endpoint.scheme); assertEquals("127.0.0.1", endpoint.host)
        val http = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()
        data class Completion(val lease: SyncIdentityLease, val durable: Boolean, val current: Boolean, val main: Boolean)
        val values = LinkedBlockingQueue<Completion>(); val failures = java.util.concurrent.atomic.AtomicInteger()
        IsolatedContext(target).use { context ->
            val bridge = AndroidSyncBridge(context, url, allowInsecureForTests = true)
            try {
                bridge.prepareNativeOwner()
                val seal = Seal.make()
                MacPeer(url, seal, http).use {
                    val request = withContext(Dispatchers.Main.immediate) {
                        bridge.joinRequest(onJoined = { lease ->
                            val saved = runCatching { SyncIdentityStore(context).load() }.getOrNull()
                            values.add(Completion(lease, saved?.let { it.seal.account == lease.account && it.device == lease.device } == true,
                                bridge.identityLease() == lease, android.os.Looper.myLooper() == android.os.Looper.getMainLooper()))
                        }, onJoinFailed = { failures.incrementAndGet() })
                    }
                    await("the original new entry publishes its real pairing code") { bridge.ui.value.code != null }
                    val code = checkNotNull(bridge.ui.value.code)
                    val pair = PairingClient(url, http, allowInsecureForTests = true)
                    var challenge: PairingClient.Challenge? = null
                    withTimeout(20_000) {
                        while (challenge == null) {
                            challenge = awaitSyncCallback<PairingClient.Challenge> { pair.lookUp(code, it) }.getOrNull()
                            if (challenge == null) delay(50)
                        }
                    }
                    assertTrue(values.isEmpty()); assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists())
                    assertTrue("The original actual pairing check matches", bridge.ui.value.check == challenge!!.check)
                    assertTrue(awaitSyncCallback<Boolean> { pair.answer(challenge!!, seal, it) }.getOrThrow())
                    await("the new request completes only after its durable successful attachment") { values.size == 1 }
                    val completion = values.single()
                    assertTrue(completion.durable); assertTrue(completion.current); assertTrue(completion.main)
                    assertEquals(seal.account, completion.lease.account); assertEquals(completion.lease, bridge.identityLease())
                    assertTrue("The original disposable account key must be durably retained",
                        java.security.MessageDigest.isEqual(seal.raw(), SyncIdentityStore(context).load()!!.seal.raw()))
                    assertFalse(request.cancel()); assertEquals(0, failures.get())
                    await("the genuinely paired account becomes live") { bridge.ui.value.phase == "live" }
                    bridge.pause(); await("the genuine account pauses") { bridge.ui.value.phase == "off" }
                    bridge.start(); await("the same account reconnects") { bridge.ui.value.phase == "live" }
                    assertEquals(1, values.size); assertEquals(0, failures.get()); assertEquals(completion.lease, bridge.identityLease())
                    assertFalse(request.cancel())
                }
            } finally { bridge.awaitClosedForTests(); http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll() }
        }
    }

    /** Actual guarded admission refuses after a legacy successor began behind the user's handoff. */
    @Test(timeout = 60_000)
    fun originalGuardedRecoveryRejectedBehindHeldLegacyJoinCannotParseOrReplaceItsSuccessor() = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true" && android.os.Build.VERSION.SDK_INT == 36)
        val socket = java.net.ServerSocket(0, 8, java.net.InetAddress.getByName("127.0.0.1"))
        val entered = java.util.concurrent.CountDownLatch(1); val release = java.util.concurrent.CountDownLatch(1)
        val stopped = java.util.concurrent.atomic.AtomicBoolean(false)
        val health = java.util.concurrent.atomic.AtomicInteger(); val posts = java.util.concurrent.atomic.AtomicInteger()
        val serverFailure = AtomicReference<Throwable>()
        val server = Thread({
            while (!stopped.get()) try {
                socket.accept().use { client ->
                    client.soTimeout = 5_000
                    val reader = client.getInputStream().bufferedReader(); val request = reader.readLine() ?: return@use
                    val path = request.split(' ').getOrNull(1); var length = 0; var headers = 0
                    while (true) {
                        val line = reader.readLine() ?: error("Owned Recovery fixture lost headers")
                        if (line.isEmpty()) break
                        check(++headers <= 64)
                        if (line.startsWith("Content-Length:", ignoreCase = true)) length = line.substringAfter(':').trim().toInt()
                    }
                    check(length in 0..8192); repeat(length) { check(reader.read() != -1) }
                    val body = if (path == "/v1/health") {
                        if (health.incrementAndGet() == 2) { entered.countDown(); check(release.await(15, TimeUnit.SECONDS)) }
                        "{\"ok\":true,\"v\":1,\"androidSync\":1}"
                    } else {
                        check(path?.startsWith("/v1/pair") == true)
                        if (request.startsWith("POST ")) posts.incrementAndGet()
                        "{}"
                    }.toByteArray()
                    val status = if (request.startsWith("POST ")) "204 No Content" else "200 OK"
                    val payload = if (request.startsWith("POST ")) byteArrayOf() else body
                    client.getOutputStream().apply {
                        write("HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(payload); flush()
                    }
                }
            } catch (failure: Exception) {
                if (!stopped.get() && failure !is java.io.IOException) serverFailure.compareAndSet(null, failure)
            }
        }, "owned-guarded-recovery-health").apply { isDaemon = true; start() }
        var completed = false
        try {
            IsolatedContext(target).use { context ->
                val bridge = AndroidSyncBridge(context, "http://127.0.0.1:${socket.localPort}", allowInsecureForTests = true)
                val joined = java.util.concurrent.atomic.AtomicInteger(); val failed = java.util.concurrent.atomic.AtomicInteger()
                try {
                    val native = bridge.prepareNativeOwner()
                    val original = withContext(Dispatchers.Main.immediate) { bridge.joinRequest() }
                    await("the original actual session publishes before handoff") {
                        original.presentation.value.stage == CodeJoinRequest.Stage.PUBLISHED && health.get() == 1 && posts.get() == 1
                    }
                    val snapshot = original.presentation.value
                    assertTrue("The exact original session positively admits its own snapshot", original.permits(snapshot))
                    val handoff = withContext(Dispatchers.Main.immediate) { checkNotNull(original.recoveryHandoff(snapshot)) }
                    assertFalse(original.cancel()); assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists())
                    withContext(Dispatchers.Main.immediate) { bridge.join() }
                    assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
                    withContext(Dispatchers.Main.immediate) {
                        bridge.joinRecoveryRequest("deliberately invalid owned test input", handoff,
                            onJoined = { joined.incrementAndGet() }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    release.countDown()
                    await("the held successor publishes and only local Recovery admission is refused") {
                        health.get() == 2 && posts.get() == 2 && bridge.ui.value.code != null &&
                            handoff.presentation.value.phase == RecoveryHandoff.Phase.REFUSED
                    }
                    val successorCode = checkNotNull(bridge.ui.value.code); val successorCheck = bridge.ui.value.check
                    assertNull(bridge.ui.value.error); assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists())
                    assertTrue(bridge.nativeOwnerCurrent(native)); assertEquals(0, joined.get()); assertEquals(0, failed.get())
                    val refused = handoff.presentation.value
                    withContext(Dispatchers.Main.immediate) {
                        bridge.joinRecoveryRequest("deliberately invalid owned test input", handoff,
                            onJoined = { joined.incrementAndGet() }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    bridge.prepareNativeOwner()
                    assertTrue("A consumed refusal never borrows the successor", handoff.presentation.value === refused)
                    assertTrue("The actual successor code/check remain unchanged", bridge.ui.value.code == successorCode && bridge.ui.value.check == successorCheck)
                    assertEquals(2, health.get()); assertEquals(2, posts.get()); assertEquals(0, joined.get()); assertEquals(0, failed.get())
                    withContext(Dispatchers.Main.immediate) { bridge.cancelJoin(successorCode) }
                    bridge.prepareNativeOwner(); bridge.prepareNativeOwner()
                    assertNull(bridge.ui.value.code); assertNull(bridge.ui.value.error); assertNull(bridge.identityLease())
                    assertFalse(context.identityFile.exists()); assertNull(serverFailure.get()); completed = true
                } finally { release.countDown(); bridge.awaitClosedForTests() }
            }
        } finally {
            release.countDown(); stopped.set(true); socket.close(); server.join(1_000); check(!server.isAlive)
            val folder = File(target.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
            File(folder, "guarded-recovery-admission.json").writeText(org.json.JSONObject().put("schema", 1).put("completed", completed)
                .put("healthRequests", health.get()).put("pairingPosts", posts.get()).put("controlledLoopbackOnly", true)
                .put("providerProof", false).toString(2))
        }
    }

    /** Genuine owned Worker + Keystore through the new guarded wrapper, no simulated completion. */
    @Test(timeout = 180_000)
    fun actualOwnedGuardedRecoveryCompletesDurablyOnMainOnceWithoutReconnectReplay() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments(); check(arguments.getString("requireSyncBackend") == "true")
        val url = checkNotNull(arguments.getString("syncBackendUrl")); val endpoint = url.toHttpUrl()
        assertEquals("http", endpoint.scheme); assertEquals("127.0.0.1", endpoint.host)
        val http = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()
        data class Completion(val lease: SyncIdentityLease, val durable: Boolean, val current: Boolean, val main: Boolean)
        val values = LinkedBlockingQueue<Completion>(); val failed = java.util.concurrent.atomic.AtomicInteger()
        IsolatedContext(target).use { context ->
            val bridge = AndroidSyncBridge(context, url, allowInsecureForTests = true)
            try {
                bridge.prepareNativeOwner(); val seal = Seal.make()
                MacPeer(url, seal, http).use {
                    val original = withContext(Dispatchers.Main.immediate) { bridge.joinRequest() }
                    await("the original owned code session is ready for its real Recovery handoff") {
                        original.presentation.value.stage == CodeJoinRequest.Stage.PUBLISHED
                    }
                    val handoff = withContext(Dispatchers.Main.immediate) {
                        checkNotNull(original.recoveryHandoff(original.presentation.value))
                    }
                    assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists()); assertTrue(values.isEmpty())
                    withContext(Dispatchers.Main.immediate) {
                        bridge.joinRecoveryRequest(seal.recovery, handoff, onJoined = { lease ->
                            val saved = runCatching { SyncIdentityStore(context).load() }.getOrNull()
                            values.add(Completion(lease, saved?.let { it.seal.account == lease.account && it.device == lease.device } == true,
                                bridge.identityLease() == lease, android.os.Looper.myLooper() == android.os.Looper.getMainLooper()))
                        }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    await("the guarded real Recovery completes only after durable successful attach") { values.size == 1 }
                    val result = values.single()
                    assertTrue(result.durable); assertTrue(result.current); assertTrue(result.main)
                    assertTrue("The completed identity is the original disposable account and current lease",
                        seal.account == result.lease.account && result.lease == bridge.identityLease())
                    assertTrue("The disposable original account key is retained durably",
                        java.security.MessageDigest.isEqual(seal.raw(), SyncIdentityStore(context).load()!!.seal.raw()))
                    assertEquals(RecoveryHandoff.Phase.COMPLETE, handoff.presentation.value.phase); assertEquals(0, failed.get())
                    assertFalse(original.cancel()); assertNull(handoff.retry())
                    await("the genuine guarded account reaches Live") { bridge.ui.value.phase == "live" }
                    bridge.pause(); await("the genuine account pauses without a new completion") { bridge.ui.value.phase == "off" }
                    bridge.start(); await("the same account reconnects without a new completion") { bridge.ui.value.phase == "live" }
                    assertEquals(1, values.size); assertEquals(0, failed.get())
                    assertTrue("Reconnect retains the original completed lease", result.lease == bridge.identityLease())
                }
            } finally { bridge.awaitClosedForTests(); http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll() }
        }
    }

    /** Controlled admitted health; accepted own cancellation never aborts or adopts another operation. */
    @Test(timeout = 60_000)
    fun originalSubmittedRecoveryCancelledDuringHeldHealthCannotAttachOrAffectItsSuccessor() = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true" && android.os.Build.VERSION.SDK_INT == 36)
        val socket = java.net.ServerSocket(0, 8, java.net.InetAddress.getByName("127.0.0.1"))
        val entered = java.util.concurrent.CountDownLatch(1); val release = java.util.concurrent.CountDownLatch(1)
        val stopped = java.util.concurrent.atomic.AtomicBoolean(false)
        val health = java.util.concurrent.atomic.AtomicInteger(); val posts = java.util.concurrent.atomic.AtomicInteger()
        val serverFailure = AtomicReference<Throwable>()
        val server = Thread({
            while (!stopped.get()) try {
                socket.accept().use { client ->
                    client.soTimeout = 5_000
                    val reader = client.getInputStream().bufferedReader(); val request = reader.readLine() ?: return@use
                    val path = request.split(' ').getOrNull(1); var length = 0; var headers = 0
                    while (true) {
                        val line = reader.readLine() ?: error("Owned cancellation fixture lost headers")
                        if (line.isEmpty()) break
                        check(++headers <= 64)
                        if (line.startsWith("Content-Length:", ignoreCase = true)) length = line.substringAfter(':').trim().toInt()
                    }
                    check(length in 0..8192); repeat(length) { check(reader.read() != -1) }
                    val body = if (path == "/v1/health") {
                        if (health.incrementAndGet() == 2) { entered.countDown(); check(release.await(15, TimeUnit.SECONDS)) }
                        "{\"ok\":true,\"v\":1,\"androidSync\":1}"
                    } else {
                        check(path?.startsWith("/v1/pair") == true)
                        if (request.startsWith("POST ")) posts.incrementAndGet()
                        "{}"
                    }.toByteArray()
                    val status = if (request.startsWith("POST ")) "204 No Content" else "200 OK"
                    val payload = if (request.startsWith("POST ")) byteArrayOf() else body
                    client.getOutputStream().apply {
                        write("HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(payload); flush()
                    }
                }
            } catch (failure: Exception) {
                if (!stopped.get() && failure !is java.io.IOException) serverFailure.compareAndSet(null, failure)
            }
        }, "owned-recovery-cancel-health").apply { isDaemon = true; start() }
        var completed = false
        var accepted = false
        try {
            IsolatedContext(target).use { context ->
                val bridge = AndroidSyncBridge(context, "http://127.0.0.1:${socket.localPort}", allowInsecureForTests = true)
                val joined = java.util.concurrent.atomic.AtomicInteger(); val failed = java.util.concurrent.atomic.AtomicInteger()
                try {
                    val native = bridge.prepareNativeOwner()
                    val original = withContext(Dispatchers.Main.immediate) { bridge.joinRequest() }
                    await("the original code session publishes before actual Recovery cancellation") {
                        original.presentation.value.stage == CodeJoinRequest.Stage.PUBLISHED && health.get() == 1 && posts.get() == 1
                    }
                    val handoff = withContext(Dispatchers.Main.immediate) {
                        checkNotNull(original.recoveryHandoff(original.presentation.value))
                    }
                    val disposable = Seal.make()
                    withContext(Dispatchers.Main.immediate) {
                        bridge.joinRecoveryRequest(disposable.recovery, handoff,
                            onJoined = { joined.incrementAndGet() }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
                    val admitted = handoff.presentation.value
                    assertEquals(RecoveryHandoff.Phase.ADMITTED, admitted.phase)
                    assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists())
                    accepted = withContext(Dispatchers.Main.immediate) { handoff.cancel(admitted) }
                    assertTrue(accepted); assertEquals(RecoveryHandoff.Phase.CANCELLED, handoff.presentation.value.phase)
                    assertEquals(0, joined.get()); assertEquals(0, failed.get())
                    val successor = withContext(Dispatchers.Main.immediate) { bridge.joinRequest() }
                    assertEquals(CodeJoinRequest.Stage.PENDING, successor.presentation.value.stage)
                    release.countDown()
                    await("the cancelled Recovery cannot commit and the exact successor publishes") {
                        health.get() == 3 && posts.get() == 2 && successor.presentation.value.stage == CodeJoinRequest.Stage.PUBLISHED
                    }
                    val current = successor.presentation.value
                    assertTrue("The actual successor owns its original published snapshot", successor.permits(current))
                    assertTrue("The cancelled Recovery cannot replace the successor payload",
                        current.code != null && bridge.ui.value.code == current.code && bridge.ui.value.check == current.check)
                    assertFalse(handoff.cancel(admitted)); assertFalse(handoff.cancel(handoff.presentation.value))
                    withContext(Dispatchers.Main.immediate) {
                        bridge.joinRecoveryRequest(disposable.recovery, handoff,
                            onJoined = { joined.incrementAndGet() }, onJoinFailed = { failed.incrementAndGet() })
                    }
                    bridge.prepareNativeOwner()
                    assertTrue("Late Recovery continuations leave the successor current", successor.permits(current))
                    assertEquals(RecoveryHandoff.Phase.CANCELLED, handoff.presentation.value.phase)
                    assertNull(bridge.ui.value.error); assertNull(bridge.identityLease()); assertFalse(context.identityFile.exists())
                    assertEquals(0, joined.get()); assertEquals(0, failed.get()); assertEquals(3, health.get()); assertEquals(2, posts.get())
                    assertTrue(bridge.nativeOwnerCurrent(native))
                    assertTrue(withContext(Dispatchers.Main.immediate) { successor.cancel() })
                    bridge.prepareNativeOwner(); bridge.prepareNativeOwner()
                    assertNull(bridge.ui.value.code); assertNull(bridge.ui.value.error); assertNull(bridge.identityLease())
                    assertFalse(context.identityFile.exists()); assertNull(serverFailure.get()); completed = true
                } finally { release.countDown(); bridge.awaitClosedForTests() }
            }
        } finally {
            release.countDown(); stopped.set(true); socket.close(); server.join(1_000); check(!server.isAlive)
            val folder = File(target.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
            File(folder, "guarded-recovery-cancel.json").writeText(org.json.JSONObject().put("schema", 1).put("completed", completed)
                .put("originalCancellationAccepted", accepted).put("healthRequests", health.get()).put("pairingPosts", posts.get())
                .put("controlledLoopbackOnly", true).put("providerProof", false).toString(2))
        }
    }

    private suspend fun answerWithActualApprovalLifecycle(first: AndroidSyncBridge, approval: ApprovalRequest) {
        val scenario = ActivityScenario.launch(EngineTestActivity::class.java)
        val lifetime = ApprovalInteractionLifetime()
        var binding: AutoCloseable? = null
        var ticket: ApprovalInteractionTicket? = null
        try {
            scenario.onActivity { activity ->
                binding = lifetime.observe(activity.lifecycle)
                ticket = checkNotNull(lifetime.capture(lifetime.state.value))
            }
            val captured = checkNotNull(ticket)
            assertTrue(runCatching {
                first.answerApproval(ApprovalAnswer(approval, true, null, DeviceAuthenticationProof(System.currentTimeMillis()),
                    expectedEpoch = first.accountEpoch - 1, interaction = captured))
            }.isFailure)
            assertTrue(first.accountRecords.value.records.none { it.collection == "assistantanswer" && it.id == approval.id && it.alive() })
            // Actual resumed fixture lifetime; synthetic proof does not claim biometric hardware acceptance.
            first.answerApproval(ApprovalAnswer(approval, true, null, DeviceAuthenticationProof(System.currentTimeMillis()),
                expectedEpoch = first.accountEpoch, interaction = captured))
        } finally {
            try { InstrumentationRegistry.getInstrumentation().runOnMainSync { binding?.close() } }
            finally { scenario.close() }
        }
    }

    @Test(timeout = 180_000)
    fun actualWorkerPairingRecoverySealedBrowserRoundTripAndRevokedCleanup() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val url = arguments.getString("syncBackendUrl")
        if (arguments.getString("requireSyncBackend") == "true") assertFalse("A real local Worker URL is required", url.isNullOrBlank())
        assumeTrue("Run emulator-check.py --sync-backend for the real Worker scenario", !url.isNullOrBlank())
        val endpoint = url!!.toHttpUrl()
        assertEquals("http", endpoint.scheme); assertEquals("127.0.0.1", endpoint.host)
        val http = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()
        http.newCall(Request.Builder().url(url + "/v1/health").build()).execute().use {
            assertEquals(200, it.code); assertEquals(1, Json.parseToJsonElement(it.body!!.string()).jsonObject["androidSync"]!!.jsonPrimitive.int)
        }
        val seal = Seal.make()
        IsolatedContext(target).use { firstContext -> IsolatedContext(target).use { recoveredContext ->
            var first = AndroidSyncBridge(firstContext, url, allowInsecureForTests = true)
            val recovered = AndroidSyncBridge(recoveredContext, url, allowInsecureForTests = true)
            try {
                MacPeer(url, seal, http).use { mac ->
                    val taskEpoch = UUID.randomUUID().toString()
                    mac.push(listOf(mac.record("commandcap", mac.device) {
                        put("device", mac.device); put("platform", "macos"); put("androidSync", 1); put("open", 1)
                        put("taskRecords", 1); put("taskReadOnly", 1); put("taskReadOnlyEpoch", taskEpoch)
                        put("chatAgent", 1); put("chatMetadata", 1); put("chatControl", 1); put("attachments", 1)
                    }))
                    first.join()
                    await("pairing code published") { first.ui.value.code != null }
                    val pair = PairingClient(url, http, allowInsecureForTests = true)
                    var challenge: PairingClient.Challenge? = null
                    withTimeout(20_000) {
                        while (challenge == null) {
                            challenge = awaitSyncCallback<PairingClient.Challenge> { pair.lookUp(first.ui.value.code!!, it) }.getOrNull()
                            if (challenge == null) delay(100)
                        }
                    }
                    assertEquals("The displayed confirmation must bind this challenge", first.ui.value.check, challenge!!.check)
                    assertTrue(awaitSyncCallback<Boolean> { pair.answer(challenge!!, seal, it) }.getOrThrow())
                    await("paired device live and identity durable") { first.ui.value.phase == "live" && first.ui.value.devices.size >= 2 }
                    val saved = SyncIdentityStore(firstContext).load()!!
                    assertArrayEquals(seal.raw(), saved.seal.raw()); assertEquals(saved.device, first.ownDevice)
                    assertFalse(saved.token.isNullOrBlank())
                    val capability = mac.awaitRecord(RecordKey("commandcap", saved.device))
                    assertEquals("android", capability["platform"]!!.jsonPrimitive.content)
                    assertEquals("android", capability["kind"]!!.jsonPrimitive.content)
                    assertEquals(1, capability["open"]!!.jsonPrimitive.int)
                    assertEquals(1, capability["androidSync"]!!.jsonPrimitive.int)
                    assertTrue(listOf("device", "platform", "kind", "open", "androidSync").all { capability.stamps[it]?.device == saved.device })

                    assertSealedIconAccess(first, mac)

                    // Production Worker -> real Seal -> durable journal -> app shelf -> Android RemoteViews.
                    val nowPrefix = "mail." + UUID.randomUUID().toString()
                    mac.push((0..3).map { order -> mac.record("now", "$nowPrefix.$order") {
                        put("device", mac.device); put("title", "Worker mail $order"); put("detail", "Sealed message $order")
                        put("who", "Fixture sender $order"); put("host", "mail.google.com"); put("order", order)
                        put("web", "https://mail.google.com/mail/u/0/#all/$nowPrefix.$order")
                        put("message", "<$nowPrefix.$order@example.test>")
                    } })
                    val shelfStore = NowShelfStore(File(firstContext.noBackupFilesDir, NowShelfStore.FILE_NAME))
                    await("three genuine Mac mail rows persisted for the widget") { first.nowRows.value.size == 3 && shelfStore.read()?.rows?.size == 3 }
                    val shelf = shelfStore.read()!!
                    assertEquals(listOf(0, 1, 2), shelf.rows.map { it.order })
                    assertTrue(shelf.rows.all { it.owner == mac.device })
                    val nowLink = shelf.link(shelf.rows.first())
                    assertEquals(shelf.rows.first().web, first.resolveNowLink(nowLink))
                    assertNull(first.resolveNowLink(nowLink.replace("owner=${mac.device}", "owner=unrecognized-mac")))
                    assertNativeNowViews(shelf)

                    val space = UUID.randomUUID().toString(); val kept = UUID.randomUUID().toString(); val today = UUID.randomUUID().toString()
                    val label = "sealed-browser-${UUID.randomUUID()}"
                    val page = "https://shared.fixture.invalid/$label"
                    mac.push(listOf(mac.record("space", space) { put("name", label); put("icon", ""); put("order", "V") },
                        mac.record("tab", kept) { put("parent", space); put("kept", true); put("url", page); put("home", page); put("title", label); put("order", "V") },
                        mac.record("tab", today) { put("parent", space); put("device", mac.device); put("url", "https://mac-today.fixture.invalid"); put("order", "W") }))
                    await("Mac browser records decrypted") { first.records.value.any { it.key == RecordKey("tab", kept) } }
                    val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace(space, "Empty")), selectedSpaceId = space)
                    val projected = BrowserSyncCodec.project(snapshot, first.records.value, saved.device)
                    val tabs = projected.spaces.single { it.id == space }.tabs
                    assertEquals(page, tabs.single().url); assertEquals(kept, tabs.single().id)
                    assertTrue("A Mac's Today tab must stay on its owner", tabs.none { it.id == today })

                    first.start()
                    mac.presence()
                    await("Mac read-only producer capability and fresh encrypted presence") { first.taskMacs.value.any { it.id == mac.device && it.epoch == taskEpoch } }
                    val taskOrigin = AgentTaskOrigin(space, kept, page, label)
                    first.updateTaskScope(taskOrigin)
                    val task = first.sendTask("Read only this public source", taskOrigin, mac.device, taskEpoch)
                    assertNull(task.observation)
                    val requestRecord = mac.awaitRecord(RecordKey(TaskRecords.REQUEST, task.id))
                    val authored = TaskRecords.Request.read(requestRecord, seal.account, saved.device)
                    assertEquals(task.request, authored); assertEquals(taskEpoch, authored.readOnlyEpoch)
                    assertEquals(page, authored.url); assertEquals(space, authored.space)
                    fun observation(revision: Int, state: String, result: String? = null): Record = mac.record(TaskRecords.OBSERVATION, authored.id) {
                        put("body", buildJsonObject {
                            put("version", 1); put("task", authored.id); put("requestDigest", authored.digest()); put("account", seal.account); put("phone", saved.device); put("mac", mac.device)
                            put("revision", revision); put("session", UUID.randomUUID().toString()); put("status", state); put("title", "Actual peer observation"); put("progress", "Read-only transport proof")
                            result?.let { put("result", it); put("resultURL", page + "/result") }
                        }.toString())
                    }
                    mac.push(listOf(observation(1, "running")))
                    await("checked running observation from the Worker") { first.tasks.value.firstOrNull { it.id == task.id }?.observation?.revision == 1uL }
                    mac.push(listOf(observation(2, "done", "# Result from the independent transport peer")))
                    await("checked completed observation from the Worker") { first.tasks.value.firstOrNull { it.id == task.id }?.observation?.revision == 2uL }
                    val completed = first.tasks.value.single { it.id == task.id }
                    assertEquals(page + "/result", first.openTaskResult(completed, page + "/result"))
                    assertNull(first.openTaskResult(completed, "javascript:alert(1)"))
                    first.updateTaskScope(null)
                    assertNull(first.openTaskResult(completed, page + "/result"))
                    assertTrue(runCatching { first.sendTask("Private must not queue", taskOrigin.copy(isPrivate = true), mac.device, taskEpoch) }.isFailure)
                    first.updateTaskScope(taskOrigin.copy(space = "wrong-space"))
                    assertTrue(runCatching { first.sendTask("Changed source must not queue", taskOrigin, mac.device, taskEpoch) }.isFailure)
                    first.updateTaskScope(taskOrigin)
                    assertTrue(runCatching { first.sendTask("Old producer must not queue", taskOrigin, mac.device, UUID.randomUUID().toString()) }.isFailure)
                    assertEquals(1, first.records.value.count { it.collection == TaskRecords.REQUEST })

                    val chat = "a:" + UUID.randomUUID().toString()
                    mac.push(listOf(mac.record("chat", chat) {
                        put("kind", "agent"); put("device", mac.device); put("cli", "claude"); put("title", "Real wire chat"); put("state", "waiting"); put("updated", System.currentTimeMillis() / 1000.0)
                        put("choices", buildJsonArray { add("First"); add("Second") }); put("futureField", "preserve me")
                    }, mac.record("chatitem", "$chat/question") {
                        put("chat", chat); put("kind", "message"); put("name", "question"); put("text", "Which page?"); put("n", 0); put("state", "done")
                    }))
                    await("real chat question projected") { first.conversations.value.any { it.owner.chat == chat && it.choices == listOf("First", "Second") } }
                    val owner = RemoteOwner(seal.account, mac.device, chat, AgentProvider.CLAUDE)
                    assertTrue(first.patchChat(owner, ChatFlags(pinned = true, title = "Renamed on Android")))
                    val metadata = mac.awaitRecord(RecordKey("chat", chat))
                    assertEquals("Renamed on Android", metadata["title"]!!.jsonPrimitive.content)
                    assertEquals("preserve me", metadata["futureField"]!!.jsonPrimitive.content)
                    assertEquals(saved.device, metadata.stamps["pinned"]!!.device)
                    val answerSend = UUID.randomUUID().toString()
                    val attachmentBytes = "Actual sealed retry bytes".toByteArray()
                    val attachmentDigest = java.security.MessageDigest.getInstance("SHA-256").digest(attachmentBytes).joinToString("") { "%02x".format(it.toInt() and 255) }
                    val attachment = PreparedAttachment(ChatFile("retry.txt", "text/plain", attachmentBytes.size, attachmentDigest), attachmentBytes)
                    first.send(AgentSendCommand(answerSend, "android-chat", seal.account, mac.device, AgentProvider.CLAUDE, owner, LocalQuestion("First", null, emptyList()), listOf(attachment), ModelSelection(), first.connection.value.epoch))
                    val continued = mac.awaitRecord(RecordKey("send", answerSend))
                    assertEquals("First", continued["text"]!!.jsonPrimitive.content)
                    assertEquals("First", continued["question"]!!.jsonPrimitive.content)
                    await("actual send status keeps the original encrypted owner and epoch") { first.sends.value.any { it.id == answerSend && it.state == MacSendState.WAITING } }
                    val waitingSend = first.sends.value.single { it.id == answerSend }
                    assertEquals(mac.device, waitingSend.mac); assertEquals(first.accountEpoch, waitingSend.epoch)
                    val processing = mac.changed(continued) { put("state", "processing") }
                    mac.push(listOf(processing))
                    await("actual Mac claim prevents taking a queued request back") { first.sends.value.any { it.id == answerSend && it.state == MacSendState.PROCESSING } }
                    assertTrue(runCatching { first.cancelSend(waitingSend) { true } }.isFailure)
                    assertTrue(first.accountRecords.value.records.single { it.key == continued.key }.alive())
                    mac.push(listOf(mac.changed(processing) { put("state", "expired"); put("took", System.currentTimeMillis() / 1000.0) }))
                    await("only an actual encrypted Mac receipt marks the request expired") { first.sends.value.any { it.id == answerSend && it.state == MacSendState.EXPIRED } }
                    val expiredSend = first.sends.value.single { it.id == answerSend }
                    assertTrue(runCatching { first.resendSend(expiredSend.copy(epoch = expiredSend.epoch - 1)) { true } }.isFailure)
                    val manualBefore = first.connection.value.selectedMac
                    val resent = first.resendSend(expiredSend) { true }!!
                    val resentWire = mac.awaitRecord(RecordKey("send", resent.id))
                    assertEquals(mac.device, resent.mac); assertEquals(chat, resent.chat); assertEquals("android-chat", resent.clientChat)
                    assertEquals(manualBefore, first.connection.value.selectedMac)
                    val newParts = resentWire["files"]!!.jsonArray.single().jsonObject["parts"]!!.jsonArray
                    assertTrue(newParts.all { it.jsonPrimitive.content.startsWith(resent.id + "/0/") })
                    assertTrue(runCatching { first.cancelSend(resent) { false } }.isFailure)
                    val restoredDraft = first.cancelSend(resent) { true }!!
                    assertEquals("First", restoredDraft.words); assertArrayEquals(attachmentBytes, restoredDraft.files.single().bytes)
                    val cancelled = mac.awaitRecord(RecordKey("send", resent.id))
                    assertTrue(cancelled.alive()); assertEquals("cancelled", cancelled["state"]!!.jsonPrimitive.content)
                    assertEquals(saved.device, cancelled.stamps["state"]!!.device)

                    assertProviderFixtureTitleProjection(first, mac, seal.account)
                    val approvalId = UUID.randomUUID().toString()
                    val issued = System.currentTimeMillis() / 1000
                    mac.push(listOf(mac.record("assistantapproval", approvalId) { put("body", buildJsonObject {
                        put("id", approvalId); put("account", seal.account); put("mac", mac.device); put("assistant", "claude"); put("session", "fixture-session")
                        put("tab", "chat:fixture"); put("permit", "mail.read"); put("title", "Claude: Search your mail?")
                        put("lines", buildJsonArray { add("In this chat") }); put("issued", issued); put("expires", issued + 120)
                    }.toString()) }, mac.record("assistantdetail", approvalId) { put("body", buildJsonObject {
                        put("id", approvalId); put("text", "Looks for “release notes”\nOnly in this chat")
                    }.toString()) }))
                    await("typed approval context reached Android") { first.approvals.value.any { it.id == approvalId && it.kind == ApprovalKind.MAIL_SEARCH } }
                    val approval = first.approvals.value.single { it.id == approvalId }
                    assertEquals("Allow in This Chat", approval.verb)
                    assertEquals(first.accountEpoch, approval.sourceEpoch)
                    answerWithActualApprovalLifecycle(first, approval)
                    val yes = mac.awaitRecord(RecordKey("assistantanswer", approvalId))
                    val yesBody = Json.parseToJsonElement(yes["body"]!!.jsonPrimitive.content).jsonObject
                    assertTrue(yesBody["proved"]!!.jsonPrimitive.boolean)
                    assertEquals(approval.requestDigest, yesBody["requestDigest"]!!.jsonPrimitive.content)
                    assertEquals(approval.detailDigest, yesBody["detailDigest"]!!.jsonPrimitive.content)
                    mac.push(listOf(mac.record("assistantresult", approvalId) { put("body", buildJsonObject {
                        put("id", approvalId); put("phase", "done"); put("words", "Controlled peer result"); put("at", System.currentTimeMillis() / 1000.0)
                    }.toString()) }))
                    await("actual Worker delivered the owned approval result") { first.approvalResults.value.any { it.id == approvalId && it.phase == ApprovalResultPhase.done } }

                    val arrival = UUID.randomUUID().toString()
                    mac.push(listOf(mac.record("send", arrival) {
                        put("device", saved.device); put("clientDevice", mac.device); put("kind", "open")
                        put("url", page); put("title", label); put("space", space); put("at", System.currentTimeMillis() / 1000.0)
                    }))
                    await("actual Mac handoff offered on Android") { first.arrivals.value.any { it.id == arrival } }
                    var opened = 0
                    assertTrue(first.takeArrival(arrival) { incoming ->
                        assertEquals(page, incoming.url); assertEquals(space, incoming.space); assertEquals(mac.device, incoming.sender); opened++
                    })
                    assertFalse(first.takeArrival(arrival) { opened++ })
                    assertEquals("The durable receipt must prevent replay", 1, opened)
                    val receipt = mac.awaitRecord(RecordKey("send", arrival))
                    assertEquals("taken", receipt["state"]!!.jsonPrimitive.content)
                    assertEquals(saved.device, receipt.stamps["state"]!!.device)

                    val outgoing = UUID.randomUUID().toString()
                    val accountImage = first.accountRecords.value
                    assertEquals(seal.account, accountImage.account); assertEquals(saved.device, accountImage.device)
                    assertTrue(accountImage.records.any { it.key == RecordKey("tab", kept) })
                    val blockedKey = RecordKey("visit", "wrong-account.fixture.invalid")
                    val blockedFacts = mapOf(blockedKey to buildJsonObject { put("url", "https://wrong-account.fixture.invalid"); put("last", 1) })
                    assertTrue(runCatching { first.publishBrowser(blockedFacts, expectedAccount = "another-account", expectedEpoch = accountImage.epoch) }.isFailure)
                    assertTrue(runCatching { first.publishBrowser(blockedFacts, expectedAccount = seal.account, expectedEpoch = accountImage.epoch - 1) }.isFailure)
                    assertTrue(first.accountRecords.value.records.none { it.key == blockedKey })
                    first.publishBrowser(mapOf(RecordKey("tab", outgoing) to buildJsonObject {
                        put("parent", space); put("device", saved.device); put("url", page + "/android"); put("title", label + "-android"); put("order", "X")
                    }), expectedAccount = accountImage.account, expectedEpoch = accountImage.epoch)
                    val wire = mac.awaitRecord(RecordKey("tab", outgoing))
                    assertEquals(page + "/android", wire["url"]!!.jsonPrimitive.content)
                    assertEquals(saved.device, wire.stamps["url"]!!.device)

                    // Actual sealed Worker records feed the separate Mac Today surface, not local Today.
                    mac.presence(tab = today, asleep = true)
                    await("the real Mac presence identifies its asleep front tab") {
                        first.connection.value.macs.any { it.id == mac.device && it.frontTab == today && it.availability.phase == MacPhase.ASLEEP }
                    }
                    val macToday = MacTodayProjection.groups(first.accountRecords.value, first.connection.value, space).single().rows.single()
                    assertEquals(today, macToday.id); assertTrue(macToday.front); assertEquals(mac.device, macToday.mac)
                    assertMacTodayPublicScope(first, snapshot, macToday)
                    mac.push(listOf(mac.record("tab", today) {
                        put("parent", space); put("device", mac.device); put("url", "https://mac-today.fixture.invalid/newer"); put("title", "Newer actual wire page"); put("order", "W"); put("pin", JsonNull)
                    }))
                    await("a newer Mac page reached the durable journal before Close") {
                        first.accountRecords.value.records.firstOrNull { it.key == RecordKey("tab", today) }?.get("url")?.jsonPrimitive?.content == "https://mac-today.fixture.invalid/newer"
                    }
                    assertTrue(runCatching { first.useMacToday(macToday, close = true) { true } }.isFailure)
                    assertTrue(first.accountRecords.value.records.single { it.key == RecordKey("tab", today) }.alive())
                    val currentMacToday = MacTodayProjection.groups(first.accountRecords.value, first.connection.value, space).single().rows.single()
                    assertTrue(runCatching { first.useMacToday(currentMacToday, close = true) { false } }.isFailure)
                    assertEquals(currentMacToday.url, first.useMacToday(currentMacToday, close = true) { true })
                    val closedOnMac = mac.awaitRecord(RecordKey("tab", today))
                    assertFalse(closedOnMac.alive()); assertEquals(saved.device, closedOnMac.deleted?.device)
                    assertEquals(listOf(currentMacToday.copy(closing = true)), MacTodayProjection.groups(first.accountRecords.value, first.connection.value, space, listOf(currentMacToday.copy(closing = true))).single().rows)
                    mac.presence(tab = today)
                    await("awake Mac acknowledges presence after the queued close") { first.connection.value.macs.any { it.id == mac.device && it.awake } }
                    assertTrue(MacTodayProjection.groups(first.accountRecords.value, first.connection.value, space, listOf(currentMacToday.copy(closing = true))).isEmpty())
                    assertTrue(mac.frames.none { it.contains(label) || it.contains("shared.fixture.invalid") || it.contains("Worker mail") || it.contains("Sealed message") })

                    first.awaitClosedForTests()
                    first = AndroidSyncBridge(firstContext, url, allowInsecureForTests = true)
                    first.start()
                    await("Keystore and durable journal restore into a new bridge") {
                        first.ui.value.phase == "live" && first.records.value.any { it.key == RecordKey("tab", outgoing) }
                    }
                    assertEquals(saved.device, first.ownDevice)
                    assertNotEquals("Registration on restart must rotate the saved token", saved.token, SyncIdentityStore(firstContext).load()!!.token)
                    assertEquals("A process-level bridge recreation must retain the tap generation", shelf.epoch, shelfStore.read()!!.epoch)
                    assertEquals(shelf.rows.first().web, first.resolveNowLink(nowLink))
                    first.updateTaskScope(taskOrigin)
                    await("Task inbox revision survives bridge recreation") { first.tasks.value.any { it.id == task.id && it.observation?.revision == 2uL } }
                    // A later CRDT field stamp cannot regress an already checked Mac revision.
                    mac.push(listOf(observation(1, "running")))
                    await("lower revision reached the real journal") { first.records.value.firstOrNull { it.key == RecordKey(TaskRecords.OBSERVATION, task.id) }?.get("body")?.jsonPrimitive?.content?.contains("\"revision\":1") == true }
                    assertEquals(2uL, first.tasks.value.single { it.id == task.id }.observation?.revision)

                    val recoveryLease = checkNotNull(first.recoveryLease())
                    val recovery = first.recoveryKey(recoveryLease)
                    recovered.joinRecovery(recovery)
                    await("Recovery Key rejoins another isolated Android identity") {
                        recovered.ui.value.phase == "live" && recovered.records.value.any { it.key == RecordKey("tab", outgoing) }
                    }
                    val restored = SyncIdentityStore(recoveredContext).load()!!
                    assertArrayEquals(seal.raw(), restored.seal.raw()); assertNotEquals(saved.device, restored.device)
                    assertEquals(seal.account, recovered.ui.value.account)

                    mac.revoke(mac.device)
                    assertNull("A tap must refresh the roster before opening a revoked owner's mail", first.resolveNowLink(nowLink))
                    assertTrue("Revocation must remove stale mail from the persisted shelf", shelfStore.read()?.rows.isNullOrEmpty())
                    assertTrue(first.nowRows.value.isEmpty())
                    assertTrue(first.tasks.value.isEmpty()); assertTrue(first.taskMacs.value.isEmpty())
                    assertTrue(first.approvalResults.value.isEmpty())
                    assertTrue(MacTodayProjection.groups(first.accountRecords.value, first.connection.value, space, listOf(currentMacToday.copy(closing = true))).isEmpty())
                    assertNull(first.openTaskResult(completed, page + "/result"))

                    // The other joined device can revoke this phone after the Mac's token is retired.
                    mac.revoke(saved.device, restored.token!!)
                    await("server revocation reaches Refused") { first.ui.value.phase == "removed" }
                    assertNull("A revoked device cannot reveal a Recovery Key", first.recoveryLease())
                    assertTrue("An earlier unlock lease cannot survive revocation", runCatching { first.recoveryKey(recoveryLease) }.isFailure)
                    first.disconnect()
                    await("Refused device can clear its local identity without a valid token") { first.ui.value.account == null && first.ui.value.phase == "off" }
                    assertNull(SyncIdentityStore(firstContext).load())
                    assertTrue(first.records.value.isEmpty()); assertTrue(first.arrivals.value.isEmpty())
                    assertTrue(first.connection.value.macs.isEmpty()); assertTrue(first.approvals.value.isEmpty())
                    assertTrue(first.nowRows.value.isEmpty()); assertNull(shelfStore.read())
                    assertEquals("Another isolated Android identity must remain joined", seal.account, SyncIdentityStore(recoveredContext).load()!!.seal.account)
                }
            } finally {
                first.awaitClosedForTests(); recovered.awaitClosedForTests()
                http.dispatcher.cancelAll(); http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll()
            }
        } }
    }

    /** Real sealed Worker delivery exercises the production parser, without a provider turn. */
    private suspend fun assertProviderFixtureTitleProjection(sync: AndroidSyncBridge, mac: MacPeer, account: String) {
        val id = UUID.randomUUID().toString()
        val issued = System.currentTimeMillis() / 1000
        val record = mac.record("assistantapproval", id) { put("body", buildJsonObject {
            put("id", id); put("account", account); put("mac", mac.device); put("assistant", "claude")
            put("session", UUID.randomUUID().toString()); put("tab", "chat:provider-title-fixture")
            put("permit", "yes"); put("title", "Claude: Delete synthetic draft?")
            put("lines", buildJsonArray { add("Synthetic fixture only") })
            put("issued", issued); put("expires", issued + 120)
        }.toString()) }
        mac.push(listOf(record))
        await("production parser projected the sealed provider fixture title") { sync.approvals.value.any { it.id == id } }
        val request = sync.approvals.value.single { it.id == id }
        assertEquals("Claude", request.asker)
        assertEquals("Delete synthetic draft?", request.title)
        assertFalse(request.title.endsWith(": Delete synthetic draft?"))
        assertTrue(matchesProviderFixtureApproval(request, account, mac.device))
        assertFalse(matchesProviderFixtureApproval(request.copy(title = "Claude: Delete synthetic draft?"), account, mac.device))
        assertFalse(matchesProviderFixtureApproval(request, "foreign-account", mac.device))
        assertFalse(matchesProviderFixtureApproval(request, account, "foreign-mac"))
        assertFalse(matchesProviderFixtureApproval(request.copy(permit = null), account, mac.device))
        assertFalse(matchesProviderFixtureApproval(request.copy(kind = ApprovalKind.PAYMENT), account, mac.device))
        val clock = Clock(mac.device)
        record.stamps.values.forEach { clock.observe(it) }
        mac.push(listOf(record.removed(clock.tick())))
        await("synthetic parser fixture withdrawn") { sync.approvals.value.none { it.id == id } }
        assertTrue(sync.accountRecords.value.records.none { it.key == RecordKey("assistantanswer", id) && it.alive() })
    }

    /** Real received rows must disappear from all Private field/space states before accepting taps. */
    private suspend fun assertMacTodayPublicScope(sync: AndroidSyncBridge, snapshot: BrowserSnapshot, row: MacTodayRow) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val repository = object : BrowserRepository {
            override suspend fun load() = snapshot.copy(settings = snapshot.settings.copy(macTabs = true))
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}
            override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}
            override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = withContext(Dispatchers.Main.immediate) { BrowserController(repository, engine, scope) }
        val controller = withContext(Dispatchers.Main.immediate) { MacTodayController(browser, sync, scope) }
        try {
            await("public field can display only the genuine Worker Mac row") { controller.state.value.enabled && controller.state.value.groups.flatMap { it.rows }.any { it == row } }
            withContext(Dispatchers.Main.immediate) { browser.openField(privately = true) }
            await("Private field hides Mac rows") { !controller.state.value.enabled && controller.state.value.groups.isEmpty() }
            withContext(Dispatchers.Main.immediate) { controller.close(row) }
            assertTrue(sync.accountRecords.value.records.single { it.key == row.record.key }.alive())
            withContext(Dispatchers.Main.immediate) { browser.openField(privately = false) }
            await("returning to the public field restores the same row") { controller.state.value.enabled && controller.state.value.groups.flatMap { it.rows }.any { it == row } }
            withContext(Dispatchers.Main.immediate) { browser.openUrl("https://private.fixture.invalid", privately = true) }
            await("locked Private space hides Mac rows") { browser.state.value.privateContentBlocked && !controller.state.value.enabled }
            withContext(Dispatchers.Main.immediate) { browser.unlockPrivate(true) }
            await("unlocked Private space still hides Mac rows") { !browser.state.value.privateContentBlocked && !controller.state.value.enabled && controller.state.value.groups.isEmpty() }
            withContext(Dispatchers.Main.immediate) { controller.open(row); controller.close(row) }
            assertTrue(sync.accountRecords.value.records.single { it.key == row.record.key }.alive())
        } finally { withContext(Dispatchers.Main.immediate) { controller.close(); scope.cancel() } }
    }

    /** Native framework inflation of actual received facts. It does not claim launcher-host binding. */
    /** Named suspend boundary keeps these checks out of the end-to-end coroutine's 64 KiB method. */
    private suspend fun assertSealedIconAccess(first: AndroidSyncBridge, mac: MacPeer) {
        // Genuine sealed setting delivery; a controlled peer's grant never changes the launcher.
        val installedIcon = dev.yab.android.AppIcons(target).selected()
        val ticketGrant = mac.record("setting", dev.yab.android.AppIcon.Ticket.grantKey) { put("value", true) }
        val giftReceipt = mac.record("setting", "gift.firstEdition.receipt") { put("value", "b".repeat(64)) }
        mac.push(listOf(ticketGrant, giftReceipt,
            mac.record("setting", dev.yab.android.AppIcon.Charm.grantKey) { put("value", true) },
            mac.record("setting", "invite.charm.left") { put("value", "rose") },
            mac.record("setting", "invite.charm.right") { put("value", "sky") }))
        await("sealed icon grants and palette in the atomic account") {
            val access = dev.yab.android.AppIconAccountFrame.from(first.accountRecords.value).access
            access.imported == setOf(dev.yab.android.AppIcon.Ticket, dev.yab.android.AppIcon.FirstEdition, dev.yab.android.AppIcon.Charm) &&
                access.charm == dev.yab.android.AppIconCharm.of("rose", "sky")
        }
        assertEquals(installedIcon, dev.yab.android.AppIcons(target).selected())
        mac.push(listOf(mac.changed(ticketGrant) { put("value", false) }, mac.changed(giftReceipt) { put("value", "invalid") }))
        await("removed grants leave imported access without altering the native icon") {
            dev.yab.android.AppIconAccountFrame.from(first.accountRecords.value).access.imported == setOf(dev.yab.android.AppIcon.Charm)
        }
        assertEquals(installedIcon, dev.yab.android.AppIcons(target).selected())
    }

    private fun assertNativeNowViews(shelf: NowShelfSnapshot) {
        val failure = AtomicReference<Throwable>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            try {
                val host = FrameLayout(target)
                val view = NowWidget.render(target, shelf, 991, locked = false).apply(target, host)
                val rows = view.findViewById<LinearLayout>(R.id.now_widget_rows)
                assertEquals(3, rows.childCount)
                for ((index, row) in shelf.rows.withIndex()) {
                    val actual = rows.getChildAt(index)
                    assertEquals(row.who, actual.findViewById<TextView>(R.id.now_widget_who).text.toString())
                    assertEquals(row.title, actual.findViewById<TextView>(R.id.now_widget_title).text.toString())
                    assertEquals(row.detail, actual.findViewById<TextView>(R.id.now_widget_detail).text.toString())
                    assertTrue(actual.isClickable)
                }
                assertEquals(View.GONE, view.findViewById<View>(R.id.now_widget_quiet).visibility)
                val width = (360 * target.resources.displayMetrics.density).toInt()
                val height = (260 * target.resources.displayMetrics.density).toInt()
                view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
                view.layout(0, 0, width, height)
                assertTrue("All three rows must fit inside the native widget surface", rows.bottom <= view.height && rows.getChildAt(2).bottom <= rows.height)
                val image = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                view.draw(Canvas(image))
                val output = File(target.getExternalFilesDir(null), "instrumentation/now-widget.png")
                check(output.parentFile!!.isDirectory || output.parentFile!!.mkdirs())
                output.outputStream().use { assertTrue(image.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                image.recycle()

                val locked = NowWidget.render(target, shelf, 991, locked = true).apply(target, host)
                    .findViewById<LinearLayout>(R.id.now_widget_rows)
                for (index in 0 until locked.childCount) {
                    assertEquals(shelf.rows[index].who, locked.getChildAt(index).findViewById<TextView>(R.id.now_widget_who).text.toString())
                    assertEquals(View.GONE, locked.getChildAt(index).findViewById<View>(R.id.now_widget_title).visibility)
                    assertEquals(View.GONE, locked.getChildAt(index).findViewById<View>(R.id.now_widget_detail).visibility)
                }
                val empty = NowWidget.render(target, null, 991, locked = false).apply(target, host)
                assertEquals(View.GONE, empty.findViewById<View>(R.id.now_widget_rows).visibility)
                assertEquals(View.VISIBLE, empty.findViewById<View>(R.id.now_widget_search).visibility)
                assertEquals(View.VISIBLE, empty.findViewById<View>(R.id.now_widget_ask).visibility)
            } catch (error: Throwable) { failure.set(error) }
        }
        failure.get()?.let { throw AssertionError("Native Now RemoteViews did not match the received mail rows", it) }
    }

    private suspend fun await(label: String, predicate: () -> Boolean) {
        try { withTimeout(25_000) { while (!predicate()) delay(25) } }
        catch (error: TimeoutCancellationException) { throw AssertionError("Timed out waiting for $label", error) }
        assertTrue(label, predicate())
    }

    /** Independent authenticated HTTP/WebSocket Mac peer, using only public production routes. */
    internal class MacPeer(private val url: String, private val seal: Seal, private val http: OkHttpClient) : Closeable {
        val device = UUID.randomUUID().toString()
        private val clock = Clock(device)
        private val messages = LinkedBlockingQueue<JsonObject>()
        private val failure = AtomicReference<Throwable>()
        val frames: List<String> get() = synchronized(received) { received.toList() }
        private val received = mutableListOf<String>()
        private val versions = mutableMapOf<String, Long>()
        private val token: String
        private val socket: WebSocket
        init {
            val registration = buildJsonObject { put("secret", seal.secret); put("device", Device(device, "Fixture Mac", "Mac fixture", "macos", "desktop").toJson()) }
            token = http.newCall(Request.Builder().url("$url/v1/accounts/${seal.account}/devices").post(registration.toString().toRequestBody("application/json".toMediaType())).build()).execute().use {
                check(it.code == 200); Json.parseToJsonElement(it.body!!.string()).jsonObject.getValue("token").jsonPrimitive.content
            }
            socket = http.newWebSocket(Request.Builder().url("$url/v1/accounts/${seal.account}/socket").header("Authorization", "Bearer $token").header("X-Yab-Android-Sync", "1").build(), object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { webSocket.send("{\"t\":\"hello\",\"cursor\":0,\"v\":1}") }
                override fun onMessage(webSocket: WebSocket, text: String) { synchronized(received) { received.add(text) }; messages.add(Json.parseToJsonElement(text).jsonObject) }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { failure.set(t) }
            })
            next { it["t"]?.jsonPrimitive?.content == "changes" }
        }
        fun record(collection: String, id: String, facts: JsonObjectBuilder.() -> Unit): Record = Record(collection, id).updated(buildJsonObject(facts), clock)
        fun changed(record: Record, facts: JsonObjectBuilder.() -> Unit): Record = record.updated(JsonObject(record.visible + buildJsonObject(facts)), clock)
        fun push(records: List<Record>) {
            val id = UUID.randomUUID().toString()
            check(socket.send(buildJsonObject { put("t", "push"); put("id", id); put("changes", buildJsonArray { records.forEach { record -> add(buildJsonObject {
                put("name", seal.name(record.key)); put("base", versions[seal.name(record.key)] ?: 0); put("blob", Base64.getEncoder().encodeToString(seal.seal(record)))
            }) } }) }.toString()))
            val accepted = next { it["t"]?.jsonPrimitive?.content == "pushed" && it["id"]?.jsonPrimitive?.content == id }
            assertEquals(records.size, accepted.getValue("accepted").jsonArray.size)
            accepted.getValue("accepted").jsonArray.forEach { item -> versions[item.jsonObject.getValue("name").jsonPrimitive.content] = item.jsonObject.getValue("version").jsonPrimitive.long }
        }
        fun presence(tab: String? = null, asleep: Boolean = false) {
            val record = Record("presence", device, buildJsonObject { put("name", "Fixture Mac"); put("kind", "mac"); put("at", System.currentTimeMillis() / 1000.0); put("asleep", asleep); tab?.let { put("tab", it) } })
            check(socket.send(buildJsonObject { put("t", "presence"); put("blob", Base64.getEncoder().encodeToString(seal.seal(record))) }.toString()))
        }
        fun awaitRecord(key: RecordKey): Record {
            var result: Record? = null
            next { message ->
                if (message["t"]?.jsonPrimitive?.content == "changes") for (item in message.getValue("items").jsonArray) {
                    val wire = item.jsonObject
                    val name = wire.getValue("name").jsonPrimitive.content
                    if (name == seal.name(key)) {
                        versions[name] = wire.getValue("version").jsonPrimitive.long
                        result = seal.open(Base64.getDecoder().decode(wire.getValue("blob").jsonPrimitive.content), name)
                    }
                }
                result != null
            }
            return checkNotNull(result)
        }
        fun revoke(id: String, authorization: String = token) {
            http.newCall(Request.Builder().url("$url/v1/accounts/${seal.account}/devices/$id").header("Authorization", "Bearer $authorization").delete().build()).execute().use { assertEquals(204, it.code) }
        }
        private fun next(predicate: (JsonObject) -> Boolean): JsonObject {
            val deadline = SystemClock.elapsedRealtime() + 25_000
            while (SystemClock.elapsedRealtime() < deadline) {
                failure.get()?.let { throw AssertionError("Actual Worker socket failed", it) }
                val message = messages.poll(100, TimeUnit.MILLISECONDS) ?: continue
                if (predicate(message)) return message
            }
            throw AssertionError("Actual Worker socket did not deliver the expected message")
        }
        override fun close() { socket.cancel() }
    }
}

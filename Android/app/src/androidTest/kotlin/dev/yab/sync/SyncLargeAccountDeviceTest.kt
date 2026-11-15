package dev.yab.sync

import android.content.Context
import android.content.ContextWrapper
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.core.crypto.Seal
import dev.yab.browser.BrowserInstrumentedTest.NoNetworkEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.Closeable
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/** A device joining a Mac with a real history of agent chats: what the Mac has must arrive. */
@RunWith(AndroidJUnit4::class)
class SyncLargeAccountDeviceTest {
    private val target get() = InstrumentationRegistry.getInstrumentation().targetContext

    private class IsolatedContext(base: Context) : ContextWrapper(base), Closeable {
        private val identifier = UUID.randomUUID().toString().replace("-", "")
        private val root = File(base.cacheDir, "sync-large-$identifier").apply { check(mkdirs()) }
        private val name = base.packageName + ".synclarge" + identifier
        override fun getApplicationContext(): Context = this
        override fun getPackageName(): String = name
        override fun getNoBackupFilesDir(): File = File(root, "no-backup").apply { mkdirs() }
        override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
        override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        override fun close() { SyncIdentityStore(this).forget(); root.deleteRecursively() }
    }

    private fun say(line: String) {
        Log.i("YabLargeAccount", line)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("YabLargeAccount", line) })
    }

    @Test(timeout = 1_500_000)
    fun aMacWithThousandsOfChatsArrivesWhole() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val url = arguments.getString("syncBackendUrl")
        if (arguments.getString("requireSyncBackend") == "true") assertFalse("A real local Worker URL is required", url.isNullOrBlank())
        assumeTrue("Run emulator-check.py --sync-backend", !url.isNullOrBlank())
        val chats = arguments.getString("largeChats")?.toInt() ?: 2300
        val items = arguments.getString("largeItems")?.toInt() ?: 32_000
        val visits = 1400
        val budget = (arguments.getString("largeBudget")?.toLong() ?: 300L) * 1000
        val http = OkHttpClient.Builder().callTimeout(60, TimeUnit.SECONDS).build()
        val seal = Seal.make()
        val space = UUID.randomUUID().toString()
        val now = System.currentTimeMillis() / 1000.0
        val text = "word ".repeat(220)
        IsolatedContext(target).use { context ->
            SyncDeviceTest.MacPeer(url!!, seal, http).use { mac ->
                val setup = SystemClock.elapsedRealtime()
                val head = listOf(
                    mac.record("commandcap", mac.device) { put("device", mac.device); put("platform", "macos"); put("androidSync", 1); put("chatAgent", 1); put("chatMetadata", 1); put("chatControl", 1) },
                    mac.record("space", space) { put("name", "Work"); put("icon", "star"); put("order", "1") },
                    mac.record("tab", UUID.randomUUID().toString()) { put("parent", space); put("url", "https://github.com/"); put("title", "GitHub"); put("pin", "1"); put("order", "1") },
                    mac.record("tab", UUID.randomUUID().toString()) { put("parent", space); put("url", "https://linear.app/"); put("title", "Linear"); put("kept", true); put("order", "2") },
                )
                val records = sequence {
                    yieldAll(head)
                    for (n in 0 until visits) yield(mac.record("visit", "example.com/page/$n") { put("url", "https://example.com/page/$n"); put("title", "Page $n"); put("last", now - n * 60) })
                    for (n in 0 until chats) yield(mac.record("chat", "a:chat-$n") { put("kind", "agent"); put("device", mac.device); put("cli", "claude"); put("title", "Chat $n"); put("state", "done"); put("started", now - n); put("updated", now - n) })
                    for (n in 0 until items) yield(mac.record("chatitem", "a:chat-${n % chats}/$n") { put("chat", "a:chat-${n % chats}"); put("n", n); put("kind", "message"); put("text", text); put("state", "done") })
                }
                var total = 0
                records.chunked(300).forEachIndexed { batch, part ->
                    mac.push(part); total += part.size
                    if (batch % 25 == 0) say("pushed $total in ${SystemClock.elapsedRealtime() - setup} ms")
                }
                say("seeded $total records in ${SystemClock.elapsedRealtime() - setup} ms")

                val bridge = AndroidSyncBridge(context, url, allowInsecureForTests = true)
                try {
                    val started = SystemClock.elapsedRealtime()
                    bridge.joinRecovery(seal.recovery)
                    var peak = 0L
                    try {
                        withTimeout(budget) {
                            while (true) {
                                val runtime = Runtime.getRuntime()
                                peak = maxOf(peak, runtime.totalMemory() - runtime.freeMemory())
                                val image = bridge.accountRecords.value
                                if (image.phase == "live" && image.records.count { it.collection == "visit" } >= visits) break
                                delay(250)
                            }
                        }
                    } catch (error: TimeoutCancellationException) {
                        val image = bridge.accountRecords.value
                        throw AssertionError("After ${budget / 1000} s: phase ${bridge.ui.value.phase}, published phase ${image.phase}, ${image.records.size} records, error ${bridge.ui.value.error}", error)
                    }
                    say("live with everything in ${SystemClock.elapsedRealtime() - started} ms, peak heap ${peak / 1_048_576} MB of ${Runtime.getRuntime().maxMemory() / 1_048_576} MB")

                    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                    val file = File(context.filesDir, "browser.json")
                    val controller = withContext(Dispatchers.Main) { BrowserController(FileBrowserRepository(file), NoNetworkEngine(), scope) }
                    val binding = withContext(Dispatchers.Main) { BrowserSyncBinding(controller, bridge, scope) }
                    val arriving = SystemClock.elapsedRealtime()
                    try {
                        withTimeout(budget) {
                            while (controller.state.value.let { state -> state.history.size < visits || state.spaces.none { it.name == "Work" } }) delay(100)
                        }
                        val state = controller.state.value
                        assertEquals("pin and kept tab", setOf("https://github.com/", "https://linear.app/"), state.spaces.first { it.name == "Work" }.tabs.map { it.url }.toSet())
                        say("browser shows the Mac's space and ${state.history.size} visits ${SystemClock.elapsedRealtime() - arriving} ms after that")
                    } finally { withContext(Dispatchers.Main) { binding.close(); scope.cancel() } }

                    val conversations = SystemClock.elapsedRealtime()
                    withTimeout(budget) { while (bridge.conversations.value.size < chats) delay(250) }
                    say("chats listed ${SystemClock.elapsedRealtime() - conversations} ms after that")
                } finally { bridge.awaitClosedForTests() }

                val reopening = SystemClock.elapsedRealtime()
                val again = AndroidSyncBridge(context, url, allowInsecureForTests = true)
                try {
                    again.start()
                    withTimeout(budget) { while (again.accountRecords.value.let { it.phase != "live" || it.records.size < total }) delay(100) }
                    say("reopened on its saved journal in ${SystemClock.elapsedRealtime() - reopening} ms")
                } finally { again.awaitClosedForTests() }
            }
        }
    }
}

package dev.yab.browser

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserSettings
import dev.yab.browser.model.BrowserSnapshot
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.model.BrowserTab
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Real Gecko DOM and the exact APK page.js. The fixture-local port is stubbed;
 * production native-port Reader and presented pixels are separate qualifications. */
@RunWith(AndroidJUnit4::class)
class ReaderReadabilityTest {
    @Test(timeout = 240_000)
    fun visibleProseThresholdsGroupingAndDominantContainerMatchPhone(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val source = instrumentation.targetContext.assets.open("web_extensions/yab/page.js").use { it.readBytes() }
        val html = instrumentation.context.assets.open("reader/readability.html").bufferedReader().use { it.readText() }
            .replace("__SOURCE_BASE64__", Base64.encodeToString(source, Base64.NO_WRAP))
        ReadabilityFixture(html).use { page ->
            BrowserInstrumentedTest().withBrowser { controller, engine ->
                var stage = "PREPARING"
                var titleKind = "UNKNOWN"
                var latestLoading = true
                var sourceCurrent = false
                var completed = false
                var primary: Throwable? = null
                try {
                    val original = BrowserTab(id = "reader-readability-original", url = page.url,
                        title = "Reader readability loading", createdAt = 1)
                    val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Reader readability fixture",
                        tabs = listOf(original), currentTabId = original.id)
                    val profile = space.websiteProfile
                    val epoch = withContext(Dispatchers.Main) {
                        check(!controller.state.value.loading)
                        controller.applySyncedSnapshot(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                            settings = BrowserSettings(welcomed = true)))
                        controller.selectTab(original.id)
                        controller.state.value.surfaceEpoch
                    }
                    fun originalCurrent(): Boolean = controller.state.value.let { state ->
                        state.surface == BrowserSurface.PAGE && state.surfaceEpoch == epoch && !state.privateContentBlocked &&
                            state.tab?.id == original.id && state.tab?.url == original.url && state.space?.id == space.id &&
                            state.space?.websiteProfile == profile
                    }
                    val deadline = android.os.SystemClock.elapsedRealtime() + 60_000
                    stage = "AWAITING_SESSION"
                    while (true) {
                        val ready = withContext(Dispatchers.Main) {
                            sourceCurrent = originalCurrent()
                            check(sourceCurrent) { "Original Reader readability source changed" }
                            engine.hasLiveSession(original.id)
                        }
                        if (ready) break
                        check(android.os.SystemClock.elapsedRealtime() < deadline) { "Original Reader readability session was not mounted" }
                        delay(40)
                    }
                    // This test owns this one initial document. Do not reacquire or
                    // retry it after any action or failed predicate.
                    withContext(Dispatchers.Main) {
                        check(originalCurrent() && engine.hasLiveSession(original.id))
                        engine.navigate(original, original.url, profile)
                    }
                    stage = "AWAITING_TERMINAL"
                    while (true) {
                        val state = controller.state.value
                        sourceCurrent = originalCurrent(); check(sourceCurrent) { "Original Reader readability source changed" }
                        latestLoading = state.page.loading
                        titleKind = when (state.page.title) {
                            "Reader readability loading" -> "LOADING"
                            "Reader readability passed" -> "PASSED"
                            "Reader readability failed" -> "FAILED"
                            else -> "UNKNOWN"
                        }
                        if (!latestLoading && titleKind in setOf("PASSED", "FAILED")) break
                        check(android.os.SystemClock.elapsedRealtime() < deadline) { "Reader readability fixture did not finish" }
                        delay(40)
                    }
                    stage = "READING_RESULT"
                    val result = withContext(Dispatchers.Main) {
                        check(originalCurrent())
                        engine.readText(checkNotNull(controller.state.value.tab))
                    }
                    assertEquals(page.url, controller.state.value.tab?.url)
                    assertEquals(page.url, controller.state.value.page.url)
                    assertEquals("Reader readability passed", controller.state.value.page.title)
                    assertTrue("Every exact-resource readability case must complete", result.text.contains("READER_READABILITY_PASS"))
                    assertTrue("A fixture failure cannot count as qualification", !result.text.contains("READER_READABILITY_FAIL"))
                    stage = "COMPLETE"; completed = true
                } catch (error: Throwable) { primary = error; throw error }
                finally {
                    try {
                        withContext(NonCancellable + Dispatchers.Main) {
                            val folder = File(checkNotNull(instrumentation.targetContext.getExternalFilesDir(null)), "instrumentation")
                            check(folder.isDirectory || folder.mkdirs())
                            File(folder, "reader-readability.json").writeText(JSONObject().put("schema", 1)
                                .put("stage", stage).put("titleKind", titleKind).put("latestLoading", latestLoading)
                                .put("sourceCurrent", sourceCurrent).put("completed", completed).toString(2))
                        }
                    } catch (error: Throwable) { if (primary != null) primary!!.addSuppressed(error) else throw error }
                }
            }
        }
    }

    private class ReadabilityFixture(private val html: String) : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val live = AtomicBoolean(true)
        private val executor = Executors.newSingleThreadExecutor()
        val url = "http://127.0.0.1:${server.localPort}/reader-readability"
        init {
            executor.submit {
                while (live.get()) {
                    val socket = try { server.accept() } catch (_: SocketException) { break }
                    try {
                        socket.use { client ->
                            client.soTimeout = 5000
                            val input = client.getInputStream().bufferedReader()
                            input.readLine() ?: return@use
                            while (!input.readLine().isNullOrEmpty()) { /* Drain only the owned fixture request. */ }
                            val body = html.toByteArray(Charsets.UTF_8)
                            client.getOutputStream().apply {
                                write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
                                write(body); flush()
                            }
                        }
                    } catch (_: IOException) { /* A cancelled client cannot retire this fixture's accept loop. */ }
                }
            }
        }
        override fun close() { live.set(false); server.close(); executor.shutdownNow() }
    }
}

package dev.yab.browser

import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import dev.yab.nativefeatures.*
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The translator is deterministic; DOM, document leases and delivery use shipped Gecko code. */
@RunWith(AndroidJUnit4::class)
class TranslationDomTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val fixture = BrowserInstrumentedTest()

    @Test(timeout = 180_000)
    fun dynamicSiteEditsOriginalAndAlwaysRulesUseTheActualIsolatedDocument(): Unit = runBlocking {
        assumeTrue("Requires the runner's disposable emulator", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        TranslationFixture().use { server ->
            fixture.withBrowser { browser, engine ->
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                val runtime = FixtureTranslator()
                val rules = MemoryTranslationRules()
                val port = engine.translationPort()
                val controller = PageTranslationController(port, runtime, rules, pollMillis = 50)
                val observer = scope.launch { controller.observe("en") }
                try {
                    main { fixture.ownSpace(browser, "Translation DOM"); browser.openUrl(server.url) }
                    withTimeout(30_000) { port.current.first { it != null } }
                    withTimeout(10_000) { controller.state.first { it.source == "pt" } }
                    val firstOwner = port.current.value!!.owner
                    main { controller.translate("en") }
                    awaitText(browser, engine, "[en] Texto original da página")
                    val text = read(browser, engine)
                    assertTrue(text.contains("Não traduzir esta marca"))
                    assertFalse(text.contains("[en] Não traduzir esta marca"))
                    assertFalse(text.contains("[en] Código permanece"))
                    click("Read language"); awaitText(browser, engine, "Language=en")
                    val initialCalls = runtime.calls.get()
                    delay(400)
                    assertEquals("Own DOM writes scheduled another inference", initialCalls, runtime.calls.get())
                    fixture.shot("translation-dynamic-before.png")

                    click("Add comment")
                    awaitText(browser, engine, "[en] Mais um comentário dos leitores")
                    assertEquals(initialCalls + 1, runtime.calls.get())

                    // Pause an actual model response, then let the site edit that same node.
                    runtime.holdNext = true
                    click("Rewrite heading")
                    withTimeout(10_000) { runtime.started.await() }
                    click("Edit during translation")
                    awaitText(browser, engine, "Palavras mais recentes do próprio site")
                    main { controller.showOriginal() }
                    runtime.release.complete(Unit)
                    delay(250)
                    val original = read(browser, engine)
                    assertTrue("Show Original overwrote site-authored text", original.contains("Palavras mais recentes do próprio site"))
                    assertTrue("Dynamic nodes did not return to their own text", original.contains("Mais um comentário dos leitores"))
                    assertFalse(original.contains("[en]"))
                    click("Read language"); awaitText(browser, engine, "Language=pt")

                    main { controller.setAlways(true) }
                    awaitText(browser, engine, "[en] Palavras mais recentes do próprio site")
                    assertEquals("pt", rules.source("127.0.0.1", false))
                    main { controller.setAlways(false) }
                    assertTrue("Disabling Always changed the visible translation", read(browser, engine).contains("[en]"))
                    main { controller.setAlways(true); controller.showOriginal() }
                    val callsBeforeOriginal = runtime.calls.get()
                    delay(300)
                    assertFalse(read(browser, engine).contains("[en]"))
                    assertEquals("Show Original did not suppress this document", callsBeforeOriginal, runtime.calls.get())

                    main { engine.reload(browser.state.value.tab!!.id) }
                    withTimeout(30_000) { port.current.first { it != null && it.owner != firstOwner } }
                    awaitText(browser, engine, "[en] Texto original da página")
                    assertTrue("An old native document lease could write into a reloaded page", runCatching {
                        main { port.apply(firstOwner, listOf(TranslationSegment("1", "STALE DOCUMENT WRITE"))) }
                    }.isFailure)
                    assertFalse(read(browser, engine).contains("STALE DOCUMENT WRITE"))
                    assertEquals("pt", rules.source("127.0.0.1", false))
                    fixture.shot("translation-always-after-reload.png")
                    main { controller.showOriginal() }
                    assertFalse(read(browser, engine).contains("[en]"))
                } finally {
                    runtime.release.complete(Unit)
                    observer.cancelAndJoin(); scope.cancel()
                }
            }
        }
    }

    private class FixtureTranslator : TranslationRuntime {
        val calls = AtomicInteger()
        var holdNext = false
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        override suspend fun identify(text: String) = "pt"
        override suspend fun modelsReady(source: String, target: String) = true
        override suspend fun download(source: String, target: String) = error("Fixture model downloads are forbidden")
        override suspend fun translate(source: String, target: String, text: List<String>): List<String> {
            calls.incrementAndGet()
            if (holdNext) { holdNext = false; started.complete(Unit); release.await() }
            return text.map { "[$target] $it" }
        }
    }

    private suspend fun read(browser: BrowserController, engine: GeckoEngine): String = main { engine.readText(browser.state.value.tab!!).text }
    private suspend fun awaitText(browser: BrowserController, engine: GeckoEngine, text: String) {
        val deadline = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < deadline) {
            try { if (read(browser, engine).contains(text)) return }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* A navigation may still be connecting the real bridge. */ }
            delay(60)
        }
        error("The native document did not display $text")
    }
    private suspend fun click(text: String) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val node = OwnedWebControl.find(text)
            if (node != null) {
                var target: AccessibilityNodeInfo? = node
                repeat(5) {
                    val current = target
                    if (current?.isClickable == true && current.isEnabled) {
                        assertTrue(current.performAction(AccessibilityNodeInfo.ACTION_CLICK)); return
                    }
                    target = current?.parent
                }
            }
            delay(60)
        }
        error("No clickable web control named $text")
    }
    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }

    internal class TranslationFixture : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val executor = Executors.newSingleThreadExecutor()
        private val running = AtomicBoolean(true)
        val url = "http://127.0.0.1:${server.localPort}/translate"
        private val html = """<!doctype html><html lang="pt"><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Translation fixture</title></head>
            <body style="font:18px sans-serif;margin:18px"><article><h1 id="heading">Texto original da página</h1><p>Bom dia, esta é uma página local com palavras para traduzir.</p></article>
            <p translate="no">Não traduzir esta marca</p><pre>Código permanece</pre><div contenteditable="true">Entrada permanece</div>
            <div translate="no"><button id="add">Add comment</button><button id="rewrite">Rewrite heading</button><button id="late">Edit during translation</button><button id="language">Read language</button><p id="langstatus">Language=pending</p></div>
            <script>document.getElementById('add').onclick=()=>{const p=document.createElement('p');p.textContent='Mais um comentário dos leitores';document.querySelector('article').append(p);};
            document.getElementById('rewrite').onclick=()=>{document.getElementById('heading').firstChild.nodeValue='Novo título escrito pelo site';};
            document.getElementById('late').onclick=()=>{document.getElementById('heading').firstChild.nodeValue='Palavras mais recentes do próprio site';};
            document.getElementById('language').onclick=()=>{document.getElementById('langstatus').textContent='Language='+document.documentElement.lang;};</script></body></html>""".trimIndent()
        init {
            executor.submit {
                while (running.get()) {
                    try {
                        server.accept().use { socket ->
                            try {
                                socket.soTimeout = 5000
                                val reader = socket.getInputStream().bufferedReader()
                                reader.readLine() ?: return@use
                                while (!reader.readLine().isNullOrEmpty()) { }
                                val bytes = html.toByteArray(Charsets.UTF_8)
                                val output = socket.getOutputStream()
                                output.write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                                output.write(bytes); output.flush()
                            } catch (_: IOException) {
                                // Native navigation/reload may cancel this one response.
                            }
                        }
                    } catch (error: SocketException) { if (running.get()) throw error }
                }
            }
        }
        override fun close() { running.set(false); server.close(); executor.shutdownNow() }
    }
}

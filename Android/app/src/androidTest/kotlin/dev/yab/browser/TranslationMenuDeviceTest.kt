package dev.yab.browser

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.BrowserController
import dev.yab.browser.ui.pageTranslationMenu
import dev.yab.nativefeatures.*
import java.io.Closeable
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Genuine Gecko DOM and production menu; the explicitly deterministic local translator is a fixture. */
class TranslationMenuDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun shot(name: String) {
        compose.waitForIdle(); SystemClock.sleep(450)
        val dir = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { File(dir, "translate-menu-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        File(dir, "translate-menu-$name.json").writeText("""{"kind":"production-menu-owned-gecko","realGecko":true,"localFixturePage":true,"translatorRuntime":"deterministic-fixture","realLanguageModelVerified":false,"modelDownloads":false,"realMac":false}""")
    }
    @Test(timeout = 150_000) fun translateOriginalAndAlwaysKeepTheNativeDocumentAndNeverDownload(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val uiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var translation by mutableStateOf<PageTranslationController?>(null)
        val rules = MemoryTranslationRules()
        val attempts = org.json.JSONArray()
        var lastRead = ""
        var lastReadError: String? = null
        var stage = "SETUP"
        val runtime = object : TranslationRuntime {
            override suspend fun identify(text: String) = "pt"
            override suspend fun modelsReady(source: String, target: String) = true
            override suspend fun download(source: String, target: String) = error("No fixture download authorized")
            override suspend fun translate(source: String, target: String, text: List<String>) = text.map { "[en] $it" }
        }
        try {
            Page().use { page ->
                BrowserInstrumentedTest().withBrowser(translationMenu = {
                    translation?.let { controller ->
                        val lease by controller.menu.collectAsState()
                        remember(lease) { lease?.let { original -> pageTranslationMenu(original,
                            onToggle = { uiScope.launch {
                                val before = controller.captureMenu()
                                val accepted = controller.toggleFromMenu(original)
                                attempts.put(org.json.JSONObject().put("action", "toggle").put("admitted", accepted)
                                    .put("capturedGeneration", original.generation).put("liveGenerationBefore", before?.generation)
                                    .put("phaseAfter", controller.state.value.phase.name).put("errorAfter", controller.state.value.error))
                            } },
                            onAlways = { uiScope.launch {
                                val accepted = controller.alwaysFromMenu(original)
                                attempts.put(org.json.JSONObject().put("action", "always").put("admitted", accepted)
                                    .put("phaseAfter", controller.state.value.phase.name).put("errorAfter", controller.state.value.error))
                            } }) } }
                    }
                }) { browser, engine ->
                    val controller = PageTranslationController(engine.translationPort(), runtime, rules, pollMillis = 50)
                    val observer = uiScope.launch { controller.observe("en") }
                    try {
                        withContext(Dispatchers.Main) {
                            translation = controller
                            BrowserInstrumentedTest().ownSpace(browser, "Translation menu")
                            browser.openUrl(page.url)
                        }
                        compose.waitUntil(30_000) { controller.state.value.source == "pt" }
                        val id = checkNotNull(browser.state.value.tab).id
                        suspend fun content(): String = try {
                            compose.waitForIdle()
                            withContext(Dispatchers.Main) { engine.readText(checkNotNull(browser.state.value.tab)).text }
                                .also { lastRead = it.take(1000); lastReadError = null }
                        } catch (failure: Throwable) {
                            lastReadError = failure.javaClass.simpleName + ": " + failure.message?.take(160)
                            throw failure
                        }
                        suspend fun waitContent(translated: Boolean) { withTimeout(20_000) {
                            while (runCatching { content().contains("[en] Texto original") }.getOrDefault(!translated) != translated) delay(60)
                        } }
                        fun menu() {
                            compose.onNodeWithContentDescription("Page menu").performTouchInput { click() }
                            compose.waitUntil(15_000) { compose.onAllNodesWithText("Page Zoom").fetchSemanticsNodes().isNotEmpty() }
                            compose.waitForIdle(); SystemClock.sleep(450)
                        }
                        assertTrue("The original owned content bridge did not answer", content().contains("Texto original"))
                        stage = "OFFERED"; menu(); compose.onNodeWithText("Translate to English").assertExists()
                        compose.onNodeWithText("This page is in Portuguese").assertExists(); shot("offered")
                        stage = "TOGGLE_INPUT"
                        compose.onNodeWithText("Translate to English").performScrollTo().performTouchInput { click() }
                        stage = "WAIT_TRANSLATED"
                        compose.waitUntil(20_000) { controller.state.value.phase == TranslationPhase.TRANSLATED }; waitContent(true)
                        stage = "TRANSLATED_MENU"; menu(); compose.onNodeWithText("Show Original").assertExists()
                        compose.onNodeWithText("Always Translate Portuguese").performScrollTo().performTouchInput { click() }
                        compose.waitUntil(10_000) { controller.state.value.always }
                        assertEquals("pt", rules.source("127.0.0.1", false)); shot("translated-always")
                        stage = "ORIGINAL_INPUT"
                        compose.onNodeWithText("Show Original").performScrollTo().performTouchInput { click() }
                        compose.waitUntil(20_000) { controller.state.value.phase == TranslationPhase.ORIGINAL }; waitContent(false)
                        menu(); compose.onNodeWithText("Translate to English").assertExists(); shot("original-always")
                        assertEquals(id, browser.state.value.tab?.id)
                        assertTrue(controller.state.value.always); stage = "COMPLETE"
                    } catch (failure: Throwable) {
                        runCatching { shot("diagnostic") }; throw failure
                    } finally {
                        val dir = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
                        File(dir, "translate-menu-receipt.json").writeText(org.json.JSONObject().put("stage", stage)
                            .put("completed", stage == "COMPLETE").put("phase", controller.state.value.phase.name)
                            .put("error", controller.state.value.error).put("callbacks", attempts)
                            .put("lastOwnedFixtureText", lastRead).put("lastContentReadError", lastReadError)
                            .put("runtime", "deterministic-fixture").put("realGecko", true).toString(2))
                        observer.cancelAndJoin(); withContext(Dispatchers.Main) { translation = null }
                    }
                }
            }
        } finally { uiScope.cancel() }
    }
    private class Page : Closeable {
        private val live = AtomicBoolean(true)
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        val url = "http://127.0.0.1:${server.localPort}/article"
        private val worker = Thread {
            while (live.get()) try { server.accept().use { client ->
                client.soTimeout = 3000
                val input = client.getInputStream().bufferedReader(); input.readLine()
                while (!input.readLine().isNullOrEmpty()) { }
                val body = """<!doctype html><html lang="pt"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Translation menu fixture</title><article><h1>Texto original</h1><p>Bom dia. Esta página local tem palavras para traduzir.</p></article></html>""".toByteArray()
                client.getOutputStream().apply { write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray()); write(body); flush() }
            } } catch (_: java.io.IOException) { }
        }.apply { isDaemon = true; start() }
        override fun close() { live.set(false); server.close(); worker.join(3000) }
    }
}

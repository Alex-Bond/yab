package dev.yab.browser

import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.BrowserSessionViewModel
import dev.yab.android.MainActivity
import dev.yab.browser.engine.NativeLinkPreview
import dev.yab.browser.model.BrowserSurface
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Actual Main UI, native long presses and server-observed HttpOnly cookies. */
@RunWith(AndroidJUnit4::class)
class LinkPreviewDeviceTest {
    private lateinit var ui: OwnedBrowserTestUi
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 240_000)
    fun nativePreviewUsesTheSourceCookieJarAndNeverOutlivesItsPrivateDocumentOrWindow(): Unit = runBlocking {
        ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.LINK_PREVIEW)
        ui.run {
            check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
            CanaryServer().use { server ->
                val scenario = ActivityScenario.launch(MainActivity::class.java)
                lateinit var owner: BrowserSessionViewModel
                var initialized = false
                try {
                    scenario.onActivity { owner = ViewModelProvider(it)[BrowserSessionViewModel::class.java]; initialized = true }
                    await("Main browser ready") { !owner.browser.state.value.loading }
                    main { ui.bind(owner.browser, owner.engine) }
                    ui.checkpoint("browser_ready")
                    main {
                        owner.browser.updateSettings(owner.browser.state.value.settings.copy(welcomed = true, autoClearToday = false, lockPrivate = true))
                        BrowserInstrumentedTest().ownSpace(owner.browser, "Preview A ${UUID.randomUUID()}")
                        owner.browser.openUrl(server.url("/set?value=a"))
                    }
                    ready(owner, "Source cookie=a")
                    val sourceTab = owner.browser.state.value.tab!!
                    val sourceSession = main { owner.engine.session(sourceTab, owner.browser.state.value.space!!.websiteProfile) }
                    val beforeHistory = owner.browser.state.value.history
                    val beforeTabs = owner.browser.state.value.spaces.flatMap { it.tabs }.map { it.id }
                    val publicA = preview(owner, "a")
                    assertEquals(beforeHistory, owner.browser.state.value.history)
                    assertEquals(beforeTabs, owner.browser.state.value.spaces.flatMap { it.tabs }.map { it.id })
                    assertEquals(server.url("/set?value=a"), owner.browser.state.value.page.url)
                    assertNull(main { owner.engine.tabId(publicA.session) })
                    assertFalse(main { owner.engine.owns(publicA.session) })
                    assertFalse(main { owner.engine.ownsInteractive(sourceSession) })
                    assertEquals(main { sourceSession.settings.contextId }, main { publicA.session.settings.contextId })
                    assertFalse(publicA.isPrivate)
                    await("preview has denied the real APK native-port connection") { main { publicA.deniedNativeConnections > 0 } }
                    assertFalse(owner.engine.prompts!!.pending.value)
                    BrowserInstrumentedTest().shot("browser-link-preview-public.png")
                    clickPreview("Preview cookie=a")
                    ready(owner, "Preview cookie=a")
                    assertEquals(sourceTab.id, owner.browser.state.value.tab!!.id)
                    assertSame(sourceSession, main { owner.engine.session(owner.browser.state.value.tab!!, owner.browser.state.value.space!!.websiteProfile) })
                    assertFalse(main { publicA.session.isOpen })
                    assertFalse(main { owner.engine.commitLinkPreview(publicA.id) })

                    main {
                        BrowserInstrumentedTest().ownSpace(owner.browser, "Preview B ${UUID.randomUUID()}")
                        owner.browser.openUrl(server.url("/set?value=b"))
                    }
                    ready(owner, "Source cookie=b")
                    val publicB = preview(owner, "b")
                    assertNotEquals(main { sourceSession.settings.contextId }, main { publicB.session.settings.contextId })
                    main { owner.browser.openUrl(server.url("/replacement"), newTab = false) }
                    ready(owner, "Replacement document")
                    assertNull(owner.engine.linkPreview.value)
                    assertFalse(main { publicB.session.isOpen })
                    assertFalse(main { owner.engine.commitLinkPreview(publicB.id) })

                    main { owner.browser.openUrl(server.url("/set?value=b"), newTab = false) }
                    ready(owner, "Source cookie=b")
                    val away = preview(owner, "b")
                    scenario.moveToState(Lifecycle.State.CREATED)
                    assertNull(owner.engine.linkPreview.value)
                    assertFalse(main { away.session.isOpen })
                    scenario.moveToState(Lifecycle.State.RESUMED)
                    await("source visible after real Activity stop") { owner.browser.state.value.surface == BrowserSurface.PAGE }
                    assertFalse(main { owner.engine.commitLinkPreview(away.id) })

                    main { owner.browser.openUrl(server.url("/set?value=p"), privately = true); owner.browser.unlockPrivate(true) }
                    ready(owner, "Source cookie=p")
                    val privateId = owner.browser.state.value.tab!!.id
                    val privatePreview = preview(owner, "p")
                    assertTrue(privatePreview.isPrivate)
                    assertTrue(main { privatePreview.session.settings.usePrivateMode })
                    assertFalse(File(instrumentation.targetContext.filesDir, "browser.json").readText().contains(privateId))
                    main { owner.browser.lockPrivate() }
                    assertTrue(owner.browser.state.value.privateContentBlocked)
                    assertNull(owner.engine.linkPreview.value)
                    assertFalse(main { privatePreview.session.isOpen })
                    main { owner.browser.unlockPrivate(true) }
                    assertFalse(main { owner.engine.commitLinkPreview(privatePreview.id) })
                } finally {
                    main { if (initialized) owner.engine.dismissContextMenu() }
                    scenario.close()
                }
            }
        }
    }

    private suspend fun ready(owner: BrowserSessionViewModel, title: String) {
        await(title) { owner.browser.state.value.page.let { it.title == title && !it.loading } }
    }
    private suspend fun preview(owner: BrowserSessionViewModel, cookie: String): NativeLinkPreview {
        val source = main { owner.browser.state.value.tab!! to owner.browser.state.value.space!!.websiteProfile }
        val nativeSource = main { owner.engine.captureExternalActivityOwner() }
        ui.longPress("Preview authenticated destination", activated = {
            owner.engine.contextMenu.value?.let { it.tab == source.first.id && it.profile == source.second.id && it.isPrivate == source.second.isPrivate } == true
        })
        try {
            await("native same-container preview $cookie") {
                owner.engine.linkPreview.value?.page?.value?.let { !it.loading && !it.failed && it.title == "Preview cookie=$cookie" } == true
            }
        } catch (failure: Throwable) {
            // Preserve fixed, app-owned state before the activity's finally disposes
            // its context menu and native sessions. No URL, cookie or page text.
            runCatching {
                val evidence = main {
                    val state = owner.browser.state.value
                    val menu = owner.engine.contextMenu.value
                    val held = owner.engine.linkPreview.value
                    JSONObject().put("schema", 1).put("sourcePrivate", source.second.isPrivate)
                        .put("sourceSelected", state.tab?.id == source.first.id && state.space?.websiteProfile == source.second)
                        .put("sourceUrlUnchanged", state.tab?.url == source.first.url).put("surfacePage", state.surface == BrowserSurface.PAGE)
                        .put("privateBlocked", state.privateContentBlocked).put("pageLoading", state.page.loading)
                        .put("nativeSourceCurrent", nativeSource?.let(owner.engine::ownsExternalActivity) == true)
                        .put("contextMenuPresent", menu != null)
                        .put("contextMenuMatchesSource", menu?.let { it.tab == source.first.id && it.profile == source.second.id && it.isPrivate == source.second.isPrivate } == true)
                        .put("previewPresent", held != null).put("previewLoading", held?.page?.value?.loading)
                        .put("previewFailed", held?.page?.value?.failed)
                        .put("expectedPreviewTitle", held?.page?.value?.title == "Preview cookie=$cookie")
                        .put("previewSessionOpen", held?.session?.isOpen == true)
                }
                val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation")
                check(folder.isDirectory || folder.mkdirs())
                File(folder, "link-preview-native-failure.json").writeText(evidence.toString(2))
            }
            throw failure
        }
        return requireNotNull(owner.engine.linkPreview.value)
    }
    private suspend fun clickPreview(title: String) = ui.click("Open preview, $title")
    private suspend fun await(label: String, predicate: suspend () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 30_000
        while (!predicate()) { check(SystemClock.elapsedRealtime() < until) { "Timed out waiting for $label" }; delay(60) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }

    private class CanaryServer : Closeable {
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val executor = Executors.newSingleThreadExecutor()
        private val cookieName = "preview_" + UUID.randomUUID().toString().replace("-", "")
        init { executor.submit {
            while (running.get()) {
                val client = try { socket.accept() } catch (error: IOException) { if (running.get()) throw error else break }
                try { client.use { connection ->
                    connection.soTimeout = 3000
                    val input = connection.getInputStream().bufferedReader()
                    val request = input.readLine() ?: return@use
                    val headers = mutableMapOf<String, String>()
                    while (true) {
                        val line = input.readLine()?.takeIf { it.isNotEmpty() } ?: break
                        headers[line.substringBefore(':').lowercase()] = line.substringAfter(':').trim()
                    }
                    val uri = URI(request.split(' ').getOrElse(1) { "/" })
                    val supplied = uri.rawQuery?.substringAfter("value=")?.takeIf { it in setOf("a", "b", "p") }
                    val cookie = headers["cookie"].orEmpty().split(';').map(String::trim).firstOrNull { it.startsWith("$cookieName=") }
                        ?.substringAfter('=')?.takeIf { it in setOf("a", "b", "p") } ?: "empty"
                    val title = when (uri.path) {
                        "/set" -> "Source cookie=${supplied ?: "empty"}"
                        "/preview" -> "Preview cookie=$cookie"
                        else -> "Replacement document"
                    }
                    val html = """<!doctype html><html><meta name='viewport' content='width=device-width,initial-scale=1'>
                        <title>$title</title><main style='padding:36px 20px;font:20px sans-serif'><h1>$title</h1>
                        <a style='display:block;padding:30px 0' href='/preview'>Preview authenticated destination</a>
                        <button onclick="document.title='Unexpected interaction'">Noninteractive preview button</button></main></html>""".toByteArray()
                    val setCookie = if (uri.path == "/set" && supplied != null) "Set-Cookie: $cookieName=$supplied; Path=/; HttpOnly; SameSite=Lax\r\n" else ""
                    connection.getOutputStream().use { output ->
                        output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n" +
                            setCookie + "Content-Length: ${html.size}\r\nConnection: close\r\n\r\n").toByteArray())
                        output.write(html)
                    }
                } } catch (_: IOException) { /* A canceled preview owns only its client connection. */ }
            }
        } }
        fun url(path: String) = "http://127.0.0.1:${socket.localPort}$path"
        override fun close() { running.set(false); socket.close(); executor.shutdownNow() }
    }
}

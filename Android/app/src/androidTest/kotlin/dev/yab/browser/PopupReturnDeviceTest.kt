package dev.yab.browser

import android.graphics.Rect
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserTab
import java.io.Closeable
import java.io.IOException
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject

/** Controlled HTTP callbacks use Gecko's real opener/postMessage/window.close path. No OAuth account. */
class PopupReturnDeviceTest {
    private val fixture = BrowserInstrumentedTest()
    private var fixtureCase = ""
    private var diagnosticBrowser: BrowserController? = null
    private var diagnosticEngine: GeckoEngine? = null
    private val diagnosticSamples = JSONArray()

    @Test(timeout = 180_000)
    fun actualDirectAndInitiallyBlankCallbacksReturnWithTheirOpenerAndCookies(): Unit = runBlocking {
        owned("direct")
        CallbackSite().use { site -> fixture.withBrowser { browser, engine ->
            bind(browser, engine)
            for (blank in listOf(false, true)) {
                val source = openSource(site, browser, engine, "public")
                val native = main { engine.session(source, browser.state.value.space!!.websiteProfile) }
                val popup = openPopup(browser, engine, if (blank) "Open blank callback" else "Open callback")
                click("Complete callback")
                await("native callback closes its own tab and returns") { browser.state.value.tab?.id == source.id && !exists(browser, popup.id) }
                assertTrue(text(browser, engine, "Owned signed in").contains("Session=public"))
                assertSame(native, main { engine.session(browser.state.value.tab!!, browser.state.value.space!!.websiteProfile) })
                assertFalse(main { engine.hasLiveSession(popup.id) })
                assertFalse(browser.state.value.undoAvailable)
            }
        } }
    }

    @Test(timeout = 180_000)
    fun backgroundCallbackAndAlreadyClosedOpenerNeverTakeTheNewerSelection(): Unit = runBlocking {
        owned("background")
        CallbackSite().use { site -> fixture.withBrowser { browser, engine ->
            bind(browser, engine)
            for (closeOpener in listOf(false, true)) {
                val source = openSource(site, browser, engine, "public")
                val popup = openPopup(browser, engine)
                click("Wait for callback")
                await("controlled callback is waiting") { site.waiting.get() }
                main {
                    browser.openUrl(site.url("/unrelated"))
                    if (closeOpener) browser.closeTab(source.id)
                }
                text(browser, engine, "Owned unrelated")
                val newer = browser.state.value.tab!!.id
                site.release()
                await("background popup closes") { !exists(browser, popup.id) }
                assertEquals(newer, browser.state.value.tab!!.id)
                assertTrue(text(browser, engine, "Owned unrelated").contains("Unrelated page"))
                assertEquals(!closeOpener, exists(browser, source.id))
                site.reset()
            }
        } }
    }

    @Test(timeout = 180_000)
    fun privateCallbackSharesOnlyItsPrivateJarAndLockedCompletionDoesNotRevealIt(): Unit = runBlocking {
        owned("private")
        CallbackSite().use { site -> fixture.withBrowser { browser, engine ->
            bind(browser, engine)
            val public = openSource(site, browser, engine, "public")
            val publicSpace = browser.state.value.space!!.id
            val source = openSource(site, browser, engine, "private", privately = true)
            val popup = openPopup(browser, engine)
            assertTrue(browser.state.value.tab!!.isPrivate)
            assertTrue(text(browser, engine, "Owned auth").contains("Session=private"))
            click("Complete callback")
            await("private callback returns to the private opener") { browser.state.value.tab?.id == source.id && !exists(browser, popup.id) }
            assertTrue(text(browser, engine, "Owned signed in").contains("Session=private"))
            assertFalse(browser.publicSnapshot().toString().contains("scope=private"))

            main { browser.selectSpace(publicSpace); browser.selectTab(public.id); browser.openUrl(site.url("/signed-in?scope=public"), newTab = false) }
            assertTrue(text(browser, engine, "Owned signed in").contains("Session=public"))
            openSource(site, browser, engine, "private", privately = true)
            val lockedPopup = openPopup(browser, engine)
            click("Wait for callback")
            await("private callback is waiting") { site.waiting.get() }
            main { browser.lockPrivate() }
            site.release()
            await("locked callback removes only its private window") { !exists(browser, lockedPopup.id) }
            assertTrue(browser.state.value.privateContentBlocked)
            assertFalse(browser.publicSnapshot().toString().contains("scope=private"))
        } }
    }

    @Test(timeout = 240_000)
    fun ordinaryReplacementOldEpochAndChangedProfileCannotCloseTheCurrentTab(): Unit = runBlocking {
        owned("replacement")
        CallbackSite().use { site -> fixture.withBrowser { browser, engine ->
            bind(browser, engine)
            val source = openSource(site, browser, engine, "public")
            main {
                val ordinary = engine.session(source, browser.state.value.space!!.websiteProfile)
                ordinary.contentDelegate!!.onCloseRequest(ordinary)
            }
            assertTrue(exists(browser, source.id))
            val popup = openPopup(browser, engine)
            val retired = main { engine.session(popup, browser.state.value.space!!.websiteProfile) }
            val oldDelegate = main { retired.contentDelegate!! }
            main { engine.close(popup.id); engine.activate(popup, browser.state.value.space!!.websiteProfile) }
            text(browser, engine, "Owned auth")
            val replacement = main { engine.session(popup, browser.state.value.space!!.websiteProfile) }
            assertNotSame(retired, replacement)
            main { oldDelegate.onCloseRequest(retired); replacement.contentDelegate!!.onCloseRequest(replacement) }
            assertTrue(exists(browser, popup.id))
            assertSame(replacement, main { engine.session(popup, browser.state.value.space!!.websiteProfile) })

            main { browser.selectTab(source.id) }
            text(browser, engine, "Owned source")
            val epochPopup = openPopup(browser, engine)
            val original = main { engine.session(epochPopup, browser.state.value.space!!.websiteProfile) }
            main { browser.invalidateLocalOwnership(); original.contentDelegate!!.onCloseRequest(original) }
            assertTrue(exists(browser, epochPopup.id))
            val oldProfileDelegate = main { original.contentDelegate!! }
            main { browser.changeSignIns(browser.state.value.space!!.id, false) }
            text(browser, engine, "Owned auth")
            main { oldProfileDelegate.onCloseRequest(original) }
            assertTrue(exists(browser, epochPopup.id))
            assertNotSame(original, main { engine.session(epochPopup, browser.state.value.space!!.websiteProfile) })
        } }
    }

    private fun owned(kind: String) {
        require(kind in setOf("direct", "background", "private", "replacement")); fixtureCase = kind
        assumeTrue("Requires the runner's disposable emulator", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
    }
    private suspend fun bind(browser: BrowserController, engine: GeckoEngine) = main {
        diagnosticBrowser = browser; diagnosticEngine = engine
        fixture.ownSpace(browser, "Callback fixture")
        engine.createWindow = { opener, url -> browser.createEngineTab(url, openerId = opener)?.let { (tab, profile) -> engine.prepareWindow(tab, profile, select = true) } }
        engine.onCloseWindow = browser::closeEnginePopup
    }
    private suspend fun openSource(site: CallbackSite, browser: BrowserController, engine: GeckoEngine, scope: String, privately: Boolean = false): BrowserTab {
        main {
            browser.openUrl(site.url("/source?scope=$scope"), privately = privately)
            if (browser.state.value.privateContentBlocked) browser.unlockPrivate(true)
        }
        assertTrue(text(browser, engine, "Owned source").contains("Source page"))
        return browser.state.value.tab!!
    }
    private suspend fun openPopup(browser: BrowserController, engine: GeckoEngine, button: String = "Open callback"): BrowserTab {
        val source = browser.state.value.tab!!.id
        click(button)
        assertTrue(text(browser, engine, "Owned auth").contains("HasOpener=yes"))
        val popup = browser.state.value.tab!!
        assertEquals(source, popup.openerId)
        return popup
    }
    private fun exists(browser: BrowserController, id: String) = browser.state.value.spaces.any { space -> space.tabs.any { it.id == id } }
    private suspend fun text(browser: BrowserController, engine: GeckoEngine, title: String): String {
        await("owned $title native load", 45_000) { browser.state.value.page.let { !it.loading && it.title == title && it.progress >= 1f } }
        var result: String? = null
        await("owned $title native text", 20_000) {
            try { result = mainSuspend { engine.readText(browser.state.value.tab!!).text }; !result.isNullOrBlank() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { false }
        }
        return requireNotNull(result)
    }
    private suspend fun click(label: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val expectedPackage = instrumentation.targetContext.packageName
        var projection = JSONObject()
        var clicked = false
        try {
            await("owned button $label", 15_000) {
                val root = instrumentation.uiAutomation.rootInActiveWindow
                val queue = java.util.ArrayDeque<AccessibilityNodeInfo>()
                val candidates = mutableListOf<AccessibilityNodeInfo>()
                var visited = 0; var textMatches = 0; var descriptionMatches = 0
                val owned = root?.packageName?.toString() == expectedPackage
                val rootBounds = Rect()
                if (owned) root?.getBoundsInScreen(rootBounds)
                val matchStates = JSONArray()
                val sourceLabels = setOf("Open callback", "Open blank callback")
                val authLabels = setOf("Complete callback", "Wait for callback")
                var sourceControls = 0; var sourceVisible = 0; var authControls = 0; var authVisible = 0
                if (owned) queue.add(requireNotNull(root))
                while (queue.isNotEmpty() && visited < 1_024) {
                    val node = queue.removeFirst(); visited++
                    val text = node.text?.toString() == label
                    val description = node.contentDescription?.toString() == label
                    if (text) textMatches++
                    if (description) descriptionMatches++
                    if (node.packageName?.toString() == expectedPackage) {
                        // Export only fixed fixture controls, never arbitrary accessibility text.
                        val source = node.text?.toString() in sourceLabels || node.contentDescription?.toString() in sourceLabels
                        val auth = node.text?.toString() in authLabels || node.contentDescription?.toString() in authLabels
                        if (source) { sourceControls++; if (node.isVisibleToUser) sourceVisible++ }
                        if (auth) { authControls++; if (node.isVisibleToUser) authVisible++ }
                        if ((text || description) && matchStates.length() < 4) {
                            val bounds = Rect(); node.getBoundsInScreen(bounds)
                            matchStates.put(JSONObject().put("visible", node.isVisibleToUser).put("enabled", node.isEnabled)
                                .put("clickable", node.isClickable)
                                .put("actionClick", node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK })
                                .put("boundsNonempty", !bounds.isEmpty).put("intersectsRoot", Rect.intersects(rootBounds, bounds))
                                .put("bounds", JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).map { it.coerceIn(-1_000_000, 1_000_000) })))
                        }
                    }
                    if ((text || description) && node.isVisibleToUser && node.isEnabled && node.packageName?.toString() == expectedPackage) {
                        var target: AccessibilityNodeInfo? = node
                        var nearest: AccessibilityNodeInfo? = null
                        repeat(5) {
                            val candidate = target
                            if (nearest == null && candidate != null && candidate.isClickable && candidate.isEnabled && candidate.isVisibleToUser &&
                                candidate.packageName?.toString() == expectedPackage) nearest = candidate
                            target = candidate?.parent
                        }
                        nearest?.let { match -> if (candidates.none { it == match }) candidates.add(match) }
                    }
                    repeat(node.childCount) { node.getChild(it)?.let(queue::add) }
                }
                projection = JSONObject().put("rootOwned", owned).put("visited", visited).put("capped", queue.isNotEmpty())
                    .put("textMatches", textMatches).put("descriptionMatches", descriptionMatches).put("actionableTargets", candidates.size)
                    .put("sourceControls", sourceControls).put("sourceVisible", sourceVisible)
                    .put("authControls", authControls).put("authVisible", authVisible).put("matchStates", matchStates)
                clicked = queue.isEmpty() && candidates.size == 1 && candidates.single().performAction(AccessibilityNodeInfo.ACTION_CLICK)
                clicked
            }
        } finally {
            main {
                val state = diagnosticBrowser?.state?.value
                val control = when (label) {
                    "Open callback" -> "OPEN"; "Open blank callback" -> "OPEN_BLANK"
                    "Complete callback" -> "COMPLETE"; "Wait for callback" -> "WAIT"; else -> "OTHER"
                }
                if (diagnosticSamples.length() < 16) diagnosticSamples.put(JSONObject().put("control", control).put("clicked", clicked)
                    .put("accessibility", projection).put("private", state?.space?.isPrivate == true)
                    .put("privateBlocked", state?.privateContentBlocked == true)
                    .put("pageRead", diagnosticEngine?.textReadDiagnostics(state?.tab?.id)))
                val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
                File(folder, "popup-return-$fixtureCase-diagnostics.json").writeText(JSONObject().put("schema", 1).put("samples", diagnosticSamples).toString(2))
            }
        }
    }
    private suspend fun await(name: String, timeout: Long = 20_000, condition: suspend () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + timeout
        while (!condition()) { check(SystemClock.elapsedRealtime() < end) { "Timed out waiting for $name" }; delay(30) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun <T> mainSuspend(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }

    private class CallbackSite : Closeable {
        private val server = ServerSocket(0, 12, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val clients = Executors.newCachedThreadPool()
        private val latch = java.util.concurrent.atomic.AtomicReference(CountDownLatch(1))
        val waiting = AtomicBoolean(false)
        private val listener = Thread {
            while (running.get()) try { val client = server.accept(); clients.execute { client.use {
                try {
                    it.soTimeout = 5000
                    val reader = it.getInputStream().bufferedReader()
                    val request = reader.readLine().orEmpty().split(' ')
                    var bytes = 0
                    val headers = mutableMapOf<String, String>()
                    while (true) {
                        val row = reader.readLine() ?: break
                        bytes += row.length; check(bytes <= 8192)
                        if (row.isEmpty()) break
                        val colon = row.indexOf(':')
                        if (colon > 0) headers[row.substring(0, colon).lowercase()] = row.substring(colon + 1).trim()
                    }
                    val uri = URI(request.getOrElse(1) { "/" })
                    val scope = if (uri.rawQuery == "scope=private") "private" else "public"
                    val cookie = headers["cookie"].orEmpty().split(';').map(String::trim).firstOrNull { row -> row.startsWith("owned-session=") }?.substringAfter('=') ?: "empty"
                    if (uri.path == "/release") { waiting.set(true); check(latch.get().await(90, TimeUnit.SECONDS)) }
                    val body = when (uri.path) {
                        "/source" -> """<title>Owned source</title><p>Source page</p>
                            <button onclick="openOwned(false)">Open callback</button><button onclick="openOwned(true)">Open blank callback</button>
                            <script>function openOwned(blank){window.ownedPopup=window.open(blank?'about:blank':'/auth?scope=$scope');if(blank&&window.ownedPopup)window.ownedPopup.location='/auth?scope=$scope'}
                            addEventListener('message',e=>{if(e.origin===location.origin&&e.source===window.ownedPopup&&e.data==='owned-approved')location='/signed-in?scope=$scope'})</script>"""
                        "/auth" -> """<title>Owned auth</title><p>Session=$cookie</p><p id=opener></p><button onclick="completeOwned()">Complete callback</button>
                            <button onclick="fetch('/release').then(()=>window.close())">Wait for callback</button>
                            <script>document.getElementById('opener').textContent='HasOpener='+(window.opener?'yes':'no');function completeOwned(){if(window.opener)window.opener.postMessage('owned-approved',location.origin);setTimeout(()=>window.close(),50)}</script>"""
                        "/signed-in" -> "<title>Owned signed in</title><p>Session=$cookie</p>"
                        "/unrelated" -> "<title>Owned unrelated</title><p>Unrelated page</p>"
                        else -> "<title>Owned release</title><p>Released</p>"
                    }
                    val document = ("<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'></head><body>" + body + "</body></html>").toByteArray()
                    val setCookie = if (uri.path == "/source") "Set-Cookie: owned-session=$scope; Path=/; HttpOnly; SameSite=Lax\r\n" else ""
                    it.getOutputStream().apply {
                        write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n" + setCookie + "Content-Length: ${document.size}\r\nConnection: close\r\n\r\n").toByteArray())
                        write(document); flush()
                    }
                } catch (_: IOException) { /* Navigation can cancel this owned response. */ }
            } } } catch (_: IOException) { if (running.get()) throw IllegalStateException("Owned callback server stopped") }
        }.apply { isDaemon = true; name = "owned-callback-site"; start() }
        fun url(path: String) = "http://127.0.0.1:${server.localPort}$path"
        fun release() { latch.get().countDown() }
        fun reset() { latch.set(CountDownLatch(1)); waiting.set(false) }
        override fun close() { running.set(false); release(); server.close(); clients.shutdownNow(); listener.join(3000) }
    }
}

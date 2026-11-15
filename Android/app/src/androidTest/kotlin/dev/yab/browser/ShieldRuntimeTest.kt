package dev.yab.browser

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import dev.yab.shield.*
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoResult

/** Actual native cancellation, frame hierarchy and Private policy, with no Internet lists. */
@RunWith(AndroidJUnit4::class)
class ShieldRuntimeTest {
    private val fixture = BrowserInstrumentedTest()
    private var publicSpace: String? = null
    @Test(timeout = 120_000)
    fun nativePublicSuffixDistinguishesRegistrablePrivateAndWildcardDomains(): Unit = runBlocking {
        assumeTrue("Requires the runner's disposable emulator", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        lateinit var shield: ShieldRuntime
        fixture.withBrowser(configure = { shield = ShieldRuntime(it.runtime) }) { _, _ ->
            try {
                val rules = ShieldFilters.convert(listOf("*${'$'}popup,third-party,domain=example.co.uk|one.github.io|city.kawasaki.jp|127.0.0.1"))
                main { shield.configure(rules, ShieldPolicy()) }
                suspend fun allowed(target: String, page: String) = shield.allowsPopup(ShieldPopupRequest(UUID.randomUUID().toString(), target, page, false))
                assertTrue(allowed("https://a.example.co.uk/", "https://b.example.co.uk/"))
                assertFalse(allowed("https://other.co.uk/", "https://b.example.co.uk/"))
                assertFalse(allowed("https://two.github.io/", "https://one.github.io/"))
                assertTrue(allowed("https://a.city.kawasaki.jp/", "https://b.city.kawasaki.jp/"))
                assertFalse(allowed("http://localhost/", "http://127.0.0.1/"))
                assertTrue(allowed("http://127.0.0.1/elsewhere", "http://127.0.0.1/"))
                assertTrue(allowed("about:blank", "https://b.example.co.uk/"))
            } finally { main { shield.close() } }
        }
    }

    @Test(timeout = 240_000)
    fun nativePopupVetoStopsLoadsBeforeWindowCreationAndRejectsStaleOwner(): Unit = runBlocking {
        assumeTrue("Requires the runner's disposable emulator", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        ShieldFixture().use { server ->
            lateinit var shield: ShieldRuntime
            fixture.withBrowser(configure = { shield = ShieldRuntime(it.runtime) }) { browser, engine ->
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                val decisions = ConcurrentHashMap<String, Boolean>(); val windows = AtomicInteger()
                try {
                    main {
                        engine.setTrackingProtection(false)
                        shield.configure(ShieldFilters.convert(listOf("/popup-ad${'$'}popup")), ShieldPolicy())
                        engine.popupPolicy = { request -> shield.checkPopup(request, scope).also { result -> result.accept({ decisions[request.url] = it == true }, {}) } }
                        engine.createWindow = { opener, url -> browser.createEngineTab(url, openerId = opener)?.let { (tab, profile) ->
                            windows.incrementAndGet(); engine.prepareWindow(tab, profile, select = true)
                        } }
                        fixture.ownSpace(browser, "Popup probe"); publicSpace = browser.state.value.space!!.id
                        browser.openUrl("about:blank")
                    }
                    val group = UUID.randomUUID().toString()
                    main { browser.openUrl(server.popupUrl(group), newTab = false) }
                    awaitDocument(browser, engine, "Popup source $group")
                    val source = browser.state.value.tab!!.id
                    click("Open ad popup")
                    withTimeout(10_000) { while (decisions.keys.none { "/popup-ad" in it }) delay(50) }
                    assertFalse(decisions.entries.first { "/popup-ad" in it.key }.value)
                    assertEquals(0, windows.get()); assertEquals(0, server.count(group, "ad"))

                    click("Open allowed popup")
                    awaitDocument(browser, engine, "Popup result $group")
                    assertEquals(1, windows.get()); assertEquals(1, server.count(group, "good"))
                    main { browser.selectTab(source) }
                    awaitDocument(browser, engine, "Popup source $group")
                    val beforeBlank = windows.get()
                    decisions.clear(); click("Open blank then ad")
                    withTimeout(10_000) { while (decisions.entries.none { "/popup-ad" in it.key && !it.value }) delay(50) }
                    assertEquals(beforeBlank + 1, windows.get()); assertEquals(0, server.count(group, "ad"))
                    val blank = browser.state.value.tab!!.id
                    main { browser.closeTab(blank); browser.selectTab(source) }
                    awaitDocument(browser, engine, "Popup source $group")

                    val privateGroup = UUID.randomUUID().toString()
                    val beforePrivate = windows.get()
                    main {
                        shield.configure(ShieldFilters.convert(listOf("/popup-ad${'$'}popup")), ShieldPolicy(privateSites = mapOf("127.0.0.1" to false)))
                        browser.showPrivate(); browser.openUrl("about:blank", privately = true)
                        if (browser.state.value.privateContentBlocked) browser.unlockPrivate(true)
                        browser.openUrl(server.popupUrl(privateGroup), newTab = false, privately = true)
                    }
                    awaitDocument(browser, engine, "Popup source $privateGroup")
                    click("Open ad popup"); awaitDocument(browser, engine, "Popup result $privateGroup")
                    assertTrue(browser.state.value.tab!!.isPrivate)
                    assertEquals(beforePrivate + 1, windows.get()); assertEquals(1, server.count(privateGroup, "ad"))
                    main {
                        browser.selectTab(source)
                        shield.configure(ShieldFilters.convert(listOf("/popup-ad${'$'}popup")), ShieldPolicy())
                    }
                    awaitDocument(browser, engine, "Popup source $group")

                    // Hold a genuine native navigation response, switch owner, then return Allow.
                    // GeckoResult captures its delivery Handler at construction.
                    // The JUnit coroutine thread has no Looper.
                    val held = main { GeckoResult<Boolean>() }; val requested = AtomicInteger()
                    main { engine.popupPolicy = { requested.incrementAndGet(); held } }
                    click("Open ad popup")
                    withTimeout(10_000) { while (requested.get() == 0) delay(25) }
                    val delivered = CompletableDeferred<Unit>()
                    val beforeStale = windows.get()
                    main {
                        browser.openUrl("about:blank")
                        held.accept({ delivered.complete(Unit) }, { delivered.complete(Unit) })
                        held.complete(true)
                    }
                    withTimeout(5_000) { delivered.await() }
                    assertEquals(beforeStale, windows.get()); assertEquals(0, server.count(group, "ad"))
                    main {
                        engine.popupPolicy = { request -> shield.checkPopup(request, scope) }
                        browser.openUrl(server.normalAdUrl(group), newTab = false, privately = false)
                    }
                    awaitDocument(browser, engine, "Popup result $group")
                    assertEquals("Popup-only rule blocked a direct page navigation", 1, server.count(group, "normal"))
                    assertNull(server.failure)
                } finally { main { shield.close() }; scope.cancel() }
            }
        }
    }
    @Test(timeout = 240_000)
    fun trustedBuiltinCancelsThirdPartyFrameRequestsAndAppliesScopedCosmetics(): Unit = runBlocking {
        assumeTrue("Requires the runner's disposable emulator", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        ShieldFixture().use { server ->
            lateinit var shield: ShieldRuntime
            fixture.withBrowser(configure = { engine -> shield = ShieldRuntime(engine.runtime) }) { browser, engine ->
                try {
                    val rules = ShieldFilters.convert(listOf("""
                        /shield-ads.js${'$'}script,third-party
                        /important.js${'$'}script,important
                        @@/important.js${'$'}script
                        ##.shield-ad
                    """.trimIndent()))
                    main {
                        engine.setTrackingProtection(false); shield.configure(rules, ShieldPolicy(localGlobal = false))
                        fixture.ownSpace(browser, "Shield probe"); publicSpace = browser.state.value.space!!.id
                    }
                    val before = load(server, browser, engine, privately = false, hidden = false)
                    assertTrue(before.second.contains("Advertisement fixture"))
                    assertEquals(1, server.count(before.first, "top")); assertEquals(1, server.count(before.first, "frame")); assertEquals(1, server.count(before.first, "important"))

                    main { shield.configure(rules, ShieldPolicy()) }
                    val blocked = load(server, browser, engine, privately = false, hidden = true)
                    assertFalse("Native content stylesheet did not hide the element", blocked.second.contains("Advertisement fixture"))
                    assertEquals("First-party script was overblocked", 1, server.count(blocked.first, "top"))
                    assertEquals("Third-party frame's script reached the server", 0, server.count(blocked.first, "frame"))
                    assertEquals("Exception overrode an important rule", 0, server.count(blocked.first, "important"))
                    fixture.shot("shield-real-network-and-cosmetics.png")

                    // The iframe is localhost, but its top-level policy belongs to 127.0.0.1.
                    main { shield.configure(rules, ShieldPolicy(publicSites = mapOf("127.0.0.1" to false))) }
                    val paused = load(server, browser, engine, privately = false, hidden = false)
                    assertTrue(paused.second.contains("Advertisement fixture")); assertEquals(1, server.count(paused.first, "frame"))

                    main { shield.configure(rules, ShieldPolicy(privateSites = mapOf("127.0.0.1" to false))) }
                    val privateAllowed = load(server, browser, engine, privately = true, hidden = false)
                    assertTrue(privateAllowed.second.contains("Advertisement fixture")); assertEquals(1, server.count(privateAllowed.first, "frame"))
                    val publicAgain = load(server, browser, engine, privately = false, hidden = true)
                    assertFalse(publicAgain.second.contains("Advertisement fixture")); assertEquals(0, server.count(publicAgain.first, "frame"))

                    // The normal API permits our APK code in Private; it must really cancel there.
                    main { shield.configure(rules, ShieldPolicy()) }
                    val privateBlocked = load(server, browser, engine, privately = true, hidden = true)
                    assertFalse(privateBlocked.second.contains("Advertisement fixture")); assertEquals(0, server.count(privateBlocked.first, "frame"))
                    assertNull(server.failure)
                } finally { main { shield.close() } }
            }
        }
    }
    private suspend fun load(server: ShieldFixture, browser: BrowserController, engine: GeckoEngine, privately: Boolean, hidden: Boolean): Pair<String, String> {
        val group = UUID.randomUUID().toString()
        main {
            if (privately) browser.showPrivate() else browser.selectSpace(publicSpace!!)
            if (browser.state.value.tab == null) browser.openUrl("about:blank", privately = privately)
            if (browser.state.value.privateContentBlocked) browser.unlockPrivate(true)
            // The native blank session exists before this one measured network navigation.
            browser.openUrl(server.url(group), newTab = false, privately = privately)
        }
        val deadline = android.os.SystemClock.elapsedRealtime() + 30_000
        var last = ""
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            val state = browser.state.value
            if (!state.page.loading && state.page.title == "Shield $group") {
                try { last = main { engine.readText(browser.state.value.tab!!).text }; if ("Probe ready" in last && ("Advertisement fixture" !in last) == hidden) return group to last }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { }
            }
            delay(100)
        }
        throw AssertionError("Actual Shield fixture did not finish: $last")
    }
    private suspend fun <T> main(action: suspend () -> T): T = withContext(Dispatchers.Main.immediate) { action() }
    private suspend fun awaitDocument(browser: BrowserController, engine: GeckoEngine, title: String) {
        withTimeout(30_000) {
            while (true) {
                if (browser.state.value.page.let { !it.loading && it.title == title }) {
                    try { if (main { engine.readText(browser.state.value.tab!!).title } == title) return@withTimeout }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { }
                }
                delay(100)
            }
        }
    }
    private suspend fun click(label: String) {
        withTimeout(10_000) {
            while (true) {
                val node = OwnedWebControl.find(label)
                var target = node
                repeat(5) {
                    val current = target
                    if (current?.isClickable == true && current.isEnabled && current.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK)) return@withTimeout
                    target = current?.parent
                }
                delay(50)
            }
        }
    }

    private class ShieldFixture : Closeable {
        private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val executor = Executors.newCachedThreadPool()
        private val counts = ConcurrentHashMap<String, AtomicInteger>()
        @Volatile var failure: String? = null
        private val port get() = server.localPort
        fun url(group: String) = "http://127.0.0.1:$port/top?group=$group"
        fun popupUrl(group: String) = "http://127.0.0.1:$port/popup-source?group=$group"
        fun normalAdUrl(group: String) = "http://127.0.0.1:$port/popup-ad?group=$group&kind=normal"
        fun count(group: String, kind: String) = counts["$group:$kind"]?.get() ?: 0
        init {
            executor.submit {
                while (running.get()) {
                    val socket = try { server.accept() } catch (error: IOException) {
                        if (running.get()) failure = error.message ?: "Fixture accept failed"
                        break
                    }
                    executor.submit {
                        socket.use {
                            try {
                                it.soTimeout = 5000; val reader = it.getInputStream().bufferedReader()
                                val line = reader.readLine() ?: return@use
                                while (!reader.readLine().isNullOrEmpty()) { }
                                val uri = URI(line.split(' ')[1]); val params = uri.rawQuery.orEmpty().split('&').mapNotNull { p -> p.split('=', limit = 2).takeIf { p -> p.size == 2 }?.let { p -> p[0] to p[1] } }.toMap()
                                val group = params["group"].orEmpty(); val kind = params["kind"].orEmpty()
                                val script = uri.path.endsWith(".js")
                                if (script || uri.path in setOf("/popup-ad", "/popup-good")) counts.computeIfAbsent("$group:$kind") { AtomicInteger() }.incrementAndGet()
                                val content = when (uri.path) {
                                    "/top" -> """<!doctype html><html><head><title>Shield $group</title></head><body><p class="shield-ad" style="display:block!important">Advertisement fixture</p>
                                      <script src="/shield-ads.js?group=$group&kind=top"></script><script src="/important.js?group=$group&kind=important"></script>
                                      <iframe src="http://localhost:$port/frame?group=$group"></iframe><p>Probe ready</p></body></html>"""
                                    "/frame" -> """<!doctype html><html><body><p class="shield-ad">Frame advertisement</p><script src="/shield-ads.js?group=$group&kind=frame"></script></body></html>"""
                                    "/popup-source" -> """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Popup source $group</title></head><body>
                                      <button onclick="window.open('/popup-ad?group=$group&amp;kind=ad')">Open ad popup</button>
                                      <button onclick="window.open('/popup-good?group=$group&amp;kind=good')">Open allowed popup</button>
                                      <button onclick="const w=window.open('about:blank');if(w)w.location='/popup-ad?group=$group&amp;kind=ad'">Open blank then ad</button>
                                      <p>Popup source fixture</p></body></html>"""
                                    "/popup-ad", "/popup-good" -> """<!doctype html><html><head><title>Popup result $group</title></head><body>Popup loaded</body></html>"""
                                    else -> "window.shieldFixtureScriptLoaded=true;"
                                }.toByteArray()
                                val type = if (script) "application/javascript" else "text/html; charset=utf-8"
                                it.getOutputStream().apply { write("HTTP/1.1 200 OK\r\nContent-Type: $type\r\nCache-Control: no-store\r\nContent-Length: ${content.size}\r\nConnection: close\r\n\r\n".toByteArray()); write(content); flush() }
                            } catch (_: IOException) { /* A browser navigation may cancel its response. */ }
                        }
                    }
                }
            }
        }
        override fun close() { running.set(false); server.close(); executor.shutdownNow() }
    }
}

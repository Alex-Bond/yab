package dev.yab.browser

import android.graphics.Rect
import android.os.SystemClock
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import java.io.Closeable
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
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoSessionSettings

@RunWith(AndroidJUnit4::class)
class SiteSettingsInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val fixture = BrowserInstrumentedTest()

    @Test(timeout = 120_000)
    fun actualZoomAndDesktopSurviveNavigationWhilePrivateAndOtherHostsStayIndependent(): Unit = runBlocking {
        owned()
        SettingsFixture().use { server -> fixture.withBrowser { browser, engine ->
            main { fixture.ownSpace(browser, "Site settings fixture"); browser.openUrl(server.url("/one")) }
            ready(browser, engine, "/one")
            awaitText(browser, engine, "Agent=mobile")
            val host = "127.0.0.1"
            try {
                val original = main { engine.captureExternalActivityOwner()!! }
                main { assertTrue(engine.setZoom(browser.state.value.tab!!.id, 1.75)); assertTrue(engine.setDesktop(browser.state.value.tab!!.id, true)) }
                await("desktop reload document") { !engine.ownsExternalActivity(original) }
                ready(browser, engine, "/one")
                awaitText(browser, engine, "Agent=desktop")
                click("Read zoom")
                awaitText(browser, engine, "Zoom=1.75;")
                val first = browser.state.value.tab!!.id
                assertEquals(GeckoSessionSettings.USER_AGENT_MODE_DESKTOP, main { engine.session(browser.state.value.tab!!, browser.state.value.space!!.websiteProfile).settings.userAgentMode })
                main { browser.openUrl(server.url("/two"), newTab = false) }
                ready(browser, engine, "/two"); click("Read zoom"); awaitText(browser, engine, "Zoom=1.75;")
                awaitText(browser, engine, "Agent=desktop")
                main { browser.openUrl(server.url("/other", localhost = true), newTab = false) }
                ready(browser, engine, "/other"); click("Read zoom"); awaitText(browser, engine, "Zoom=1;")
                awaitText(browser, engine, "Agent=mobile")
                assertEquals(GeckoSessionSettings.USER_AGENT_MODE_MOBILE, main { engine.session(browser.state.value.tab!!, browser.state.value.space!!.websiteProfile).settings.userAgentMode })
                main { browser.openUrl(server.url("/private"), privately = true); browser.unlockPrivate(true) }
                ready(browser, engine, "/private"); click("Read zoom"); awaitText(browser, engine, "Zoom=1;")
                awaitText(browser, engine, "Agent=mobile")
                assertEquals(1.0, engine.sitePreferences(browser.state.value.tab!!.id).zoom, 0.0)
                assertFalse(engine.sitePreferences(browser.state.value.tab!!.id).desktop)
                main { assertTrue(engine.setZoom(browser.state.value.tab!!.id, 0.5)) }
                click("Read zoom"); awaitText(browser, engine, "Zoom=0.5;")
                assertEquals(1.75, engine.siteSettings.site(host, false).zoom, 0.0)
                main { browser.selectTab(first) }
                ready(browser, engine, "/other")
            } finally {
                main { engine.siteSettings.clear(host, false); engine.siteSettings.clear("localhost", false) }
                engine.siteSettings.flush()
            }
        } }
    }

    @Test(timeout = 90_000)
    fun nativeLongPressHasOneDocumentLeaseAndHiddenPagesCannotOpenNativeUi(): Unit = runBlocking {
        owned()
        SettingsFixture().use { server -> fixture.withBrowser { browser, engine ->
            main { fixture.ownSpace(browser, "Native context fixture"); browser.openUrl(server.url("/context")) }
            ready(browser, engine, "/context")
            val tab = browser.state.value.tab!!
            val session = main { engine.session(tab, browser.state.value.space!!.websiteProfile) }
            assertTrue(main { engine.ownsInteractive(session) })
            longPress("Held destination")
            await("native context request") { engine.contextMenu.value != null }
            val offered = engine.contextMenu.value!!
            assertEquals(server.url("/destination"), offered.link)
            assertEquals(tab.id, offered.tab)
            assertFalse(offered.isPrivate)
            assertEquals(offered, main { engine.takeContextMenu(offered.id) })
            assertNull(main { engine.takeContextMenu(offered.id) })
            longPress("Held destination")
            await("second native context request") { engine.contextMenu.value != null }
            val stale = engine.contextMenu.value!!
            main { engine.setVisibleTabs(emptySet()) }
            assertTrue(main { engine.owns(session) })
            assertFalse(main { engine.ownsInteractive(session) })
            assertNull(main { engine.takeContextMenu(stale.id) })
            assertNull(engine.contextMenu.value)
            main { engine.setVisibleTabs(setOf(tab.id)); browser.openUrl(server.url("/next"), newTab = false) }
            ready(browser, engine, "/next")
            assertNull(main { engine.takeContextMenu(stale.id) })
            await("native insecure observation") { engine.connections.value[tab.id] != null }
            val connection = engine.connections.value.getValue(tab.id)
            assertFalse(connection.secure); assertFalse(connection.exception)
            assertNull(connection.subject); assertNull(connection.sha256)
            assertFalse(browser.state.value.page.secure)
        } }
    }

    private fun owned() = assumeTrue("Requires the runner's disposable emulator", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
    private suspend fun ready(browser: BrowserController, engine: GeckoEngine, path: String) {
        await("fixture page load $path") { browser.state.value.page.title == "Site settings fixture $path" && !browser.state.value.page.loading }
        awaitText(browser, engine, "Read zoom")
    }
    private suspend fun awaitText(browser: BrowserController, engine: GeckoEngine, words: String) {
        val deadline = SystemClock.elapsedRealtime() + 15_000
        while (true) {
            val result = try { mainSuspend { engine.readText(browser.state.value.tab!!).text } } catch (_: Exception) { "" }
            if (result.contains(words)) return
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $words" }
            delay(75)
        }
    }
    private fun node(words: String): AccessibilityNodeInfo? = OwnedWebControl.find(words)
    private suspend fun click(words: String) {
        await("$words control") { node(words) != null }
        var target = node(words)!!
        repeat(6) {
            if (target.isClickable) { assertTrue(target.performAction(AccessibilityNodeInfo.ACTION_CLICK)); return }
            target = target.parent ?: error("No clickable $words control")
        }
        error("No clickable $words control")
    }
    private suspend fun longPress(words: String) {
        await("$words link") { node(words) != null }
        val bounds = Rect(); node(words)!!.getBoundsInScreen(bounds)
        val time = SystemClock.uptimeMillis()
        fun inject(action: Int) {
            val properties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
            val coordinates = arrayOf(MotionEvent.PointerCoords().apply {
                x = bounds.exactCenterX(); y = bounds.exactCenterY(); pressure = 1f; size = 1f
            })
            val event = MotionEvent.obtain(time, SystemClock.uptimeMillis(), action, 1, properties, coordinates,
                0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { assertTrue(instrumentation.uiAutomation.injectInputEvent(event, true)) }
            finally { event.recycle() }
        }
        inject(MotionEvent.ACTION_DOWN)
        delay(ViewConfiguration.getLongPressTimeout().toLong() + 200)
        inject(MotionEvent.ACTION_UP)
    }
    private suspend fun await(label: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 15_000
        while (!predicate()) {
            if (SystemClock.elapsedRealtime() >= deadline) {
                NativeWebControlDiagnostics.capture(label)
                error("Timed out waiting for $label")
            }
            delay(50)
        }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun <T> mainSuspend(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }

    private class SettingsFixture : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val executor = Executors.newSingleThreadExecutor()
        private val nonce = UUID.randomUUID().toString()
        init { executor.submit {
            while (running.get()) {
                val client = try { server.accept() } catch (error: IOException) { if (running.get()) throw error else break }
                try { client.use { socket ->
                    socket.soTimeout = 5000
                    val input = socket.getInputStream().bufferedReader()
                    val request = input.readLine() ?: return@use
                    val path = URI(request.split(' ').getOrElse(1) { "/" }).path.takeIf { it.matches(Regex("/[a-z]+")) } ?: "/invalid"
                    while (!input.readLine().isNullOrEmpty()) { /* Drain request. */ }
                    val body = """<!doctype html><html><meta name='viewport' content='width=device-width,initial-scale=1'><title>Site settings fixture $path</title><main>
                        <h1>Site settings fixture $path</h1><button style='font-size:18px' onclick="document.getElementById('result').textContent='Zoom='+getComputedStyle(document.documentElement).zoom+';'">Read zoom</button>
                        <p id='result'>Zoom=pending</p><p id='agent'></p><a style='display:block;padding:20px;font-size:18px' href='${url("/destination")}'>Held destination</a><p>$nonce</p>
                        <script>document.getElementById('agent').textContent='Agent='+(navigator.userAgent.includes('Mobile')?'mobile':'desktop');</script></main></html>""".trimIndent().toByteArray()
                    socket.getOutputStream().use { output ->
                        output.write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray()); output.write(body)
                    }
                } } catch (_: IOException) { /* A cancelled navigation does not stop the fixture. */ }
            }
        } }
        fun url(path: String, localhost: Boolean = false) = "http://${if (localhost) "localhost" else "127.0.0.1"}:${server.localPort}$path"
        override fun close() { running.set(false); server.close(); executor.shutdownNow() }
    }
}

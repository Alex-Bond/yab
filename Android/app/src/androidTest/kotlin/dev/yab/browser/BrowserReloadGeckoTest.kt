package dev.yab.browser

import android.os.SystemClock
import android.graphics.Rect
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.engine.GeckoEngine
import org.mozilla.geckoview.GeckoSession
import java.io.Closeable
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Real loopback loading and native UI action proof. No virtual clock or motion acceptance. */
class BrowserReloadGeckoTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 180_000)
    fun heldReloadStopsAndAQuickReloadKeepsTheActualPageSessionHistoryAndStorage(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        OwnedLoopbackSiteSettings.reset()
        val receipt = JSONObject().put("passed", false).put("realGecko", true).put("realNativeAction", true)
            .put("controlInput", "OWNED_EXACT_LABEL_NATIVE_TOUCH").put("talkBackActionVerified", false)
            .put("frameParityVerified", false).put("physicalDeviceSmoothnessVerified", false)
        try {
            ReloadServer().use { server ->
                BrowserInstrumentedTest().withBrowser { browser, engine ->
                    main { BrowserInstrumentedTest().ownSpace(browser, "Reload native"); browser.openUrl(server.url("/start")) }
                    ready(browser, "Reload start")
                    main { browser.openUrl(server.url("/article"), newTab = false) }
                    ready(browser, "Real reload 1")
                    val tab = checkNotNull(browser.state.value.tab)
                    val profile = checkNotNull(browser.state.value.space).websiteProfile
                    val session = main { engine.session(tab, profile) }
                    suspend fun clickOwned(label: String) = click(label, browser, engine, tab, profile, session)
                    await("native back history before reload") { main { engine.backItems(tab.id).isNotEmpty() } }
                    val history = main { engine.backItems(tab.id).map { it.url } }
                    assertTrue(browser.state.value.page.canGoBack)
                    assertTrue(main { engine.readText(tab) }.text.contains("Storage kept"))
                    server.holdNext()
                    clickOwned("Reload")
                    await("actual held reload") { server.requests.get() == 2 && browser.state.value.page.loading }
                    delay(650) // Actual window clock; visual timings have separate controlled assertions.
                    clickOwned("Stop loading")
                    await("native stop") { !browser.state.value.page.loading }
                    assertEquals(2, server.requests.get())
                    server.release()
                    val quickStart = clickOwned("Reload")
                    ready(browser, "Real reload 3")
                    val quickMillis = (SystemClock.elapsedRealtimeNanos() - quickStart) / 1_000_000.0
                    receipt.put("quickNativeLoadMillis", quickMillis)
                    assertTrue("The owned response did not complete within the 450 ms quick-load fixture window", quickMillis < 450)
                    assertTrue(main { engine.readText(checkNotNull(browser.state.value.tab)) }.text.contains("Storage kept"))
                    main {
                        assertEquals(tab.id, browser.state.value.tab?.id)
                        assertEquals(tab.url, browser.state.value.tab?.url)
                        assertSame(session, engine.session(checkNotNull(browser.state.value.tab), profile))
                        assertEquals(history, engine.backItems(tab.id).map { it.url })
                    }
                    await("native Gecko origin includes its actual AndroidView inset") {
                        main {
                            val matrix = android.graphics.Matrix()
                            session.getClientToScreenMatrix(matrix)
                            val origin = floatArrayOf(0f, 0f); matrix.mapPoints(origin)
                            // The exact session's registered view is inspected below through
                            // the fixture's real hierarchy, not a synthetic coordinate offset.
                            var correct = false
                            val active = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                                .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).singleOrNull()
                            fun visit(view: android.view.View) {
                                if (view is org.mozilla.geckoview.GeckoView && view.session === session) {
                                    val xy = IntArray(2); view.getLocationOnScreen(xy)
                                    correct = kotlin.math.abs(origin[0] - xy[0]) < 1f && kotlin.math.abs(origin[1] - xy[1]) < 1f
                                }
                                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
                            }
                            active?.window?.decorView?.let(::visit)
                            correct
                        }
                    }
                    NativeWebControlDiagnostics.capture("Before real page action after reload")
                    clickOwned("Page action")
                    await("native page action after stop/reload") {
                        main { engine.readText(checkNotNull(browser.state.value.tab)) }.text.contains("Page action worked")
                    }
                    receipt.put("ownedHoldBarrierTimedOut", server.holdTimedOut.get())
                    assertFalse("The owned reload hold barrier expired", server.holdTimedOut.get())
                    receipt.put("reloadRequests", server.requests.get()).put("sameTabUrlSessionHistory", true)
                        .put("pageStorageKept", true).put("nativePageActionWorked", true).put("passed", true)
                }
            }
        } finally {
            val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/reload-native").apply { check(isDirectory || mkdirs()) }
            File(folder, "held-and-quick.json").writeText(receipt.toString(2))
        }
    }

    private data class ControlBounds(val window: Int, val bounds: Rect)

    private suspend fun click(expected: String, browser: BrowserController, engine: GeckoEngine,
        tab: BrowserTab, profile: WebsiteProfile, session: GeckoSession): Long {
        require(expected in setOf("Reload", "Stop loading", "Page action"))
        val deadline = SystemClock.elapsedRealtime() + 5000
        val (epoch, owner) = main {
            val state = browser.state.value
            check(state.let { it.tab?.id == tab.id && it.tab?.url == tab.url &&
                it.space?.websiteProfile == profile && it.surface == BrowserSurface.PAGE && !it.privateContentBlocked })
            check(engine.ownsInteractive(session))
            state.surfaceEpoch to checkNotNull(engine.captureExternalActivityOwner())
        }
        suspend fun current() = main { browser.state.value.let { it.tab?.id == tab.id && it.tab?.url == tab.url &&
            it.space?.websiteProfile == profile && it.surfaceEpoch == epoch && it.surface == BrowserSurface.PAGE && !it.privateContentBlocked } &&
            engine.ownsInteractive(session) && engine.ownsExternalActivity(owner) }
        suspend fun measure(): ControlBounds? {
            check(current()) { "The original reload page owner changed before native input" }
            val value = exactVisibleControl(expected)
            check(current()) { "The original reload page owner changed during its control lookup" }
            return value
        }
        var measured: ControlBounds? = null
        var unchangedAt = SystemClock.elapsedRealtime()
        while (true) {
            val next = measure()
            val now = SystemClock.elapsedRealtime()
            if (next == null || next != measured) { measured = next; unchangedAt = now }
            else if (now - unchangedAt >= 96) break
            check(SystemClock.elapsedRealtime() < deadline) { "Missing owned native reload control" }
            delay(15)
        }
        val held = checkNotNull(measured)
        check(measure() == held) { "The owned native reload control moved before DOWN" }
        val evidence = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/reload-native").apply { mkdirs() }
        File(evidence, "input-${expected.replace(' ', '-')}.json").writeText(JSONObject()
            .put("label", expected).put("window", held.window).put("surfaceEpoch", epoch)
            .put("bounds", held.bounds.toShortString()).put("x", held.bounds.exactCenterX())
            .put("y", held.bounds.exactCenterY()).put("stableForMillis", 96).toString(2))
        val down = SystemClock.uptimeMillis()
        var pressed = false
        var failure: Throwable? = null
        fun input(action: Int) {
            val properties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
            val coordinates = arrayOf(MotionEvent.PointerCoords().apply {
                x = held.bounds.exactCenterX(); y = held.bounds.exactCenterY(); pressure = 1f; size = 1f
            })
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, properties, coordinates,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { assertTrue("Owned reload native input was refused", instrumentation.uiAutomation.injectInputEvent(event, true)) }
            finally { event.recycle() }
        }
        try {
            check(current()) { "The reload document changed before DOWN" }
            pressed = true; input(MotionEvent.ACTION_DOWN)
            delay(32)
            val ownerAtUp = current()
            val frameAtUp = if (ownerAtUp) measure() else null
            if (!ownerAtUp || frameAtUp != held) {
                File(evidence, "refused-${expected.replace(' ', '-')}.json").writeText(JSONObject()
                    .put("label", expected).put("originalOwnerCurrent", ownerAtUp)
                    .put("originalWindow", held.window).put("currentWindow", frameAtUp?.window)
                    .put("originalBounds", held.bounds.toShortString()).put("currentBounds", frameAtUp?.bounds?.toShortString())
                    .put("nativeAcceptance", false).toString(2))
                error("The reload owner, document, window or bounds changed before UP")
            }
            val actionStart = SystemClock.elapsedRealtimeNanos()
            input(MotionEvent.ACTION_UP); pressed = false
            return actionStart
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (expected == "Page action") NativeWebControlDiagnostics.capture("After original native Page action touch")
            if (pressed) runCatching { input(MotionEvent.ACTION_CANCEL) }.exceptionOrNull()?.let { cancelled ->
                failure?.addSuppressed(cancelled) ?: throw cancelled
            }
        }
    }

    private fun exactVisibleControl(expected: String): ControlBounds? {
        if (android.os.Build.VERSION.SDK_INT >= 34) check(instrumentation.uiAutomation.clearCache())
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return null
        val ownPackage = instrumentation.targetContext.packageName
        val queue = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        val matches = mutableListOf<ControlBounds>()
        try {
            check(root.packageName?.toString() == ownPackage) { "The owned reload window is not current" }
            val window = root.windowId
            val rootBounds = Rect().also(root::getBoundsInScreen)
            var visited = 0
            while (queue.isNotEmpty()) {
                val node = queue.removeFirst()
                try {
                    check(++visited <= 600) { "The owned control inventory exceeded its bound" }
                    if (node.packageName?.toString() == ownPackage && node.windowId == window && node.isVisibleToUser && node.isEnabled &&
                        (node.contentDescription?.toString() == expected || node.text?.toString() == expected)) {
                        val bounds = Rect().also(node::getBoundsInScreen)
                        check(!bounds.isEmpty && rootBounds.contains(bounds)) { "The exact reload label is not inside its owned window" }
                        matches += ControlBounds(window, bounds)
                    }
                    check(node.childCount <= 100) { "The owned control child inventory exceeded its bound" }
                    for (index in 0 until node.childCount) node.getChild(index)?.let(queue::addLast)
                } finally { node.recycle() }
            }
            check(matches.size <= 1) { "Ambiguous owned native reload control" }
            return matches.singleOrNull()
        } finally { queue.forEach { it.recycle() } }
    }

    private suspend fun ready(browser: BrowserController, title: String) = await("owned reload page") {
        browser.state.value.page.let { !it.loading && it.progress >= 1f && it.title == title }
    }
    private suspend fun await(name: String, predicate: suspend () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (!predicate()) {
            if (SystemClock.elapsedRealtime() >= deadline) {
                NativeWebControlDiagnostics.capture(name)
                error("Timed out: $name")
            }
            delay(15)
        }
    }
    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }

    private class ReloadServer : Closeable {
        private val running = AtomicBoolean(true)
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val active = AtomicReference<Socket?>()
        private val hold = AtomicReference<CountDownLatch?>()
        val requests = AtomicInteger()
        val holdTimedOut = AtomicBoolean()
        private val worker = Thread {
            while (running.get()) {
                try {
                    socket.accept().use { client ->
                        active.set(client); client.soTimeout = 3000
                        val input = client.getInputStream().bufferedReader()
                        val request = input.readLine() ?: return@use
                        var total = request.length
                        while (true) {
                            val line = input.readLine() ?: break
                            total += line.length; check(total <= 8192)
                            if (line.isEmpty()) break
                        }
                        val path = request.split(' ').getOrNull(1)
                        val number = if (path == "/article") requests.incrementAndGet() else 0
                        if (path == "/article") hold.get()?.let {
                            // 30s held-ready + 650ms dwell + 5s native control +
                            // 30s Stop callback are the caller's existing bounds.
                            if (!it.await(70, TimeUnit.SECONDS)) {
                                holdTimedOut.set(true)
                                return@use // Close only this fixture socket; never crash the app thread.
                            }
                        }
                        val title = if (path == "/article") "Real reload $number" else "Reload start"
                        val html = """<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><title>$title</title>
                            <main><h1>$title</h1><p id='storage'></p><button onclick="document.getElementById('action').textContent='Page action worked'">Page action</button><p id='action'></p></main>
                            <script>${if (path == "/start") "localStorage.setItem('reload-fixture','kept');" else ""}document.getElementById('storage').textContent=localStorage.getItem('reload-fixture')==='kept'?'Storage kept':'Storage lost';</script>""".trimIndent().toByteArray()
                        val accepted = path == "/start" || path == "/article"
                        val body = if (accepted) html else ByteArray(0)
                        client.getOutputStream().apply {
                            write(("HTTP/1.1 ${if (accepted) "200 OK" else "404 Not Found"}\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n").toByteArray())
                            write(body); flush()
                        }
                    }
                } catch (_: java.io.IOException) { /* Native Stop closes its own connection. */ }
                finally { active.set(null) }
            }
        }.apply { name = "owned-reload-page"; isDaemon = true; start() }
        fun url(path: String) = "http://127.0.0.1:${socket.localPort}$path"
        fun holdNext() { check(hold.compareAndSet(null, CountDownLatch(1))) }
        fun release() { hold.getAndSet(null)?.countDown() }
        override fun close() {
            running.set(false); release()
            runCatching { active.getAndSet(null)?.close() }
            runCatching { socket.close() }
            worker.join(4000)
        }
    }
}

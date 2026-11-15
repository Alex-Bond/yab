package dev.yab.browser

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.*
import dev.yab.browser.model.*
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Real owned native capture/content assertions. No MP4 cadence, presentation or iOS frame claim. */
class HistoryPixelsGeckoTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 160_000)
    fun normalDocumentCachesTheActualPreviousGlyphWithoutFetchingAndRevokesItsRendererLease(): Unit = runBlocking {
        owned()
        OwnedLoopbackSiteSettings.reset()
        val receipt = receipt()
        try { FixtureServer().use { server ->
            BrowserInstrumentedTest().withBrowser(historySwipe = true) { browser, engine ->
                try {
                main { BrowserInstrumentedTest().ownSpace(browser, "History pixels"); browser.openUrl(server.url("one")) }
                ready(browser, "one")
                val id = checkNotNull(browser.state.value.tab).id
                await("first native initial-document frame") { main { engine.currentHistoryPixels(id) != null } }
                main { glyph(checkNotNull(engine.currentHistoryPixels(id)), GREEN) }
                receipt.put("firstActualNativeGlyph", true)
                main { browser.openUrl(server.url("two"), newTab = false) }
                ready(browser, "two")
                await("second native initial-document frame") { main { engine.currentHistoryPixels(id) != null && engine.historyPixelState(id).frames == 2 } }
                main { glyph(checkNotNull(engine.currentHistoryPixels(id)), BLUE) }
                val beforeRequests = server.counts.toMap()
                val lease = main { checkNotNull(browser.captureHistorySwipe(HistorySwipeDirection.BACK)) }
                val pixels = withContext(Dispatchers.Main) {
                    checkNotNull(engine.historySwipePixels(checkNotNull(lease.target)) { browser.historySwipeCurrent(lease) })
                }
                main {
                    val bitmap = checkNotNull(pixels.bitmapIfCurrent())
                    glyph(bitmap, GREEN)
                    assertEquals(server.url("two"), browser.state.value.tab?.url)
                    assertTrue(engine.historyPixelState(id).reservedFrames <= 2)
                    browser.cancelHistorySwipe(lease)
                    assertNull(pixels.bitmapIfCurrent())
                    assertFalse("A revoked renderer bitmap was recycled", bitmap.isRecycled)
                    pixels.close()
                }
                assertEquals("A cached neighbor made a page request", beforeRequests, server.counts.toMap())
                receipt.put("previousActualNativeGlyph", true).put("noPreviewFetch", true).put("cancelRevokedRenderer", true)
                main { engine.invalidateTransientOwnership(); assertNull(engine.currentHistoryPixels(id)) }
                receipt.put("accountRevocationDroppedPixels", true).put("passed", true)
                } finally { main { observe(receipt, engine.historyPixelState(engine.selected.orEmpty())) } }
            }
        } } finally { write("normal-native-pixels.json", receipt) }
    }

    @Test(timeout = 160_000)
    fun actualSameDocumentPushBackAndReplaceCannotRehabilitateTheInitialPageImage(): Unit = runBlocking {
        owned()
        OwnedLoopbackSiteSettings.reset()
        val receipt = receipt()
        val view = AtomicReference<HistorySwipeView?>()
        try { FixtureServer().use { server ->
            BrowserInstrumentedTest().withBrowser(historySwipe = true,
                viewBound = { (it as? HistorySwipeView)?.let(view::set) }) { browser, engine ->
                try {
                main { BrowserInstrumentedTest().ownSpace(browser, "History SPA"); browser.openUrl(server.url("one")) }
                ready(browser, "one")
                val id = checkNotNull(browser.state.value.tab).id
                await("real native initial glyph") { main { engine.currentHistoryPixels(id) != null } }
                val owner = main { checkNotNull(engine.captureExternalActivityOwner()) }
                val requests = server.counts.toMap()
                tap(checkNotNull(view.get()), engine, owner, .7f, .65f) // owned page's push button
                await("trusted native same-document invalidation") { main { engine.historyPixelState(id).spaDisqualified } }
                await("actual push location") { browser.state.value.tab?.url == server.url("one") + "/pushed" }
                main { assertTrue(engine.ownsExternalActivity(owner)); assertNull(engine.currentHistoryPixels(id)) }
                tap(checkNotNull(view.get()), engine, owner, .7f, .75f) // owned page's native history.back
                await("actual A→B→A native location") { browser.state.value.tab?.url == server.url("one") }
                main {
                    assertTrue(engine.ownsExternalActivity(owner))
                    assertTrue(engine.historyPixelState(id).spaDisqualified)
                    assertEquals(0, engine.historyPixelState(id).frames)
                    assertNull(engine.currentHistoryPixels(id))
                }
                tap(checkNotNull(view.get()), engine, owner, .7f, .85f) // owned replaceState
                await("actual replace location") { browser.state.value.tab?.url == server.url("one") + "/replaced" }
                main { assertTrue(engine.ownsExternalActivity(owner)); assertNull(engine.currentHistoryPixels(id)) }
                assertEquals("Same-document history unexpectedly fetched a page", requests, server.counts.toMap())
                receipt.put("pushDroppedImage", true).put("returnToSameKeyStillDisqualified", true)
                    .put("replaceDroppedImage", true).put("sameNativeDocument", true).put("noPreviewFetch", true).put("passed", true)
                } finally { main { observe(receipt, engine.historyPixelState(engine.selected.orEmpty())) } }
            }
        } } finally { write("spa-native-pixels.json", receipt) }
    }

    private fun owned() { check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") }
    private fun receipt() = JSONObject().put("passed", false).put("realGecko", true).put("nativePixelAssertions", true)
        .put("presentationFenceProven", false).put("frameParityVerified", false).put("physicalDeviceSmoothnessVerified", false)
    private fun observe(receipt: JSONObject, state: HistoryPixelState) {
        receipt.put("firstPaintObserved", state.firstPaint).put("pageStopped", state.pageStopped)
            .put("spaDisqualified", state.spaDisqualified).put("retainedFrames", state.frames.coerceIn(0, 2))
            .put("reservedFrames", state.reservedFrames.coerceIn(0, 2)).put("nativeCapturePending", state.nativeBusy)
            .put("captureStage", state.stage.takeIf { it in setOf("IDLE", "NEW_DOCUMENT", "KEY_UNPROVEN", "BUDGET_BUSY",
                "NATIVE_BUSY", "CAPTURING", "KEY_CHANGED", "RETAINED_INITIAL_DOCUMENT", "SAME_DOCUMENT_CHANGE", "ABSENT") } ?: "UNKNOWN")
    }
    private fun write(name: String, value: JSONObject) {
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/history-pixels")
            .apply { check(isDirectory || mkdirs()) }
        File(folder, name).writeText(value.toString(2))
    }
    private suspend fun ready(browser: BrowserController, name: String) = await("owned history page") {
        browser.state.value.page.let { !it.loading && it.progress >= 1f && it.title == "History pixels $name" }
    }
    private suspend fun await(name: String, condition: suspend () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 25_000
        while (!condition()) {
            if (SystemClock.elapsedRealtime() >= end) {
                NativeWebControlDiagnostics.capture(name)
                error("Timed out: $name")
            }
            delay(20)
        }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private fun glyph(bitmap: Bitmap, background: Int) {
        assertTrue(bitmap.width > 100 && bitmap.height > 100)
        fun sample(x: Float, y: Float, expected: Int) {
            val actual = bitmap.getPixel((bitmap.width * x).toInt(), (bitmap.height * y).toInt())
            val matches = abs(Color.red(actual) - Color.red(expected)) <= 3 &&
                abs(Color.green(actual) - Color.green(expected)) <= 3 && abs(Color.blue(actual) - Color.blue(expected)) <= 3
            if (!matches) {
                val directory = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/history-pixels").apply { mkdirs() }
                File(directory, "mismatched-owned-native-glyph.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                write("glyph-mismatch.json", JSONObject().put("width", bitmap.width).put("height", bitmap.height)
                    .put("xFraction", x).put("yFraction", y).put("actualColor", actual).put("expectedColor", expected))
            }
            assertTrue("The actual native glyph/color does not match the owned page at $x,$y: $actual expected $expected", matches)
        }
        sample(.7f, .4f, background)
        sample(.21f, .21f, Color.WHITE); sample(.38f, .21f, Color.WHITE)
        sample(.21f, .38f, Color.WHITE); sample(.38f, .38f, background)
        sample(.34f, .30f, Color.WHITE); sample(.39f, .30f, background)
    }
    private suspend fun tap(view: HistorySwipeView, engine: GeckoEngine, owner: GeckoEngine.ExternalActivityOwner,
        xFraction: Float, yFraction: Float) {
        val bounds = main {
            check(engine.ownsExternalActivity(owner) && view.isAttachedToWindow && view.isShown && view.hasWindowFocus())
            val origin = IntArray(2).also(view::getLocationOnScreen)
            Rect(origin[0], origin[1], origin[0] + view.width, origin[1] + view.height)
        }
        val session = main { view.session }
        val root = withTimeout(5_000) {
            var current = instrumentation.uiAutomation.rootInActiveWindow
            while (current == null) {
                main { check(engine.ownsExternalActivity(owner) && view.isAttachedToWindow && view.isShown && view.hasWindowFocus()) }
                delay(40)
                current = instrumentation.uiAutomation.rootInActiveWindow
            }
            checkNotNull(current)
        }
        val window: Int
        val rootBounds = Rect()
        try {
            check(root.packageName?.toString() == instrumentation.targetContext.packageName)
            window = root.windowId; root.getBoundsInScreen(rootBounds)
            check(!rootBounds.isEmpty && rootBounds.contains(bounds))
        } finally { root.recycle() }
        val point = floatArrayOf(bounds.left + bounds.width() * xFraction, bounds.top + bounds.height() * yFraction)
        NativeWebControlDiagnostics.capture("Before owned history page touch $xFraction,$yFraction")
        write("original-native-touch.json", JSONObject().put("xFraction", xFraction).put("yFraction", yFraction)
            .put("bounds", bounds.toShortString()).put("x", point[0]).put("y", point[1]))
        suspend fun current(): Boolean {
            if (!main {
                val origin = IntArray(2).also(view::getLocationOnScreen)
                engine.ownsExternalActivity(owner) && view.session === session && view.isAttachedToWindow && view.isShown && view.hasWindowFocus() &&
                    bounds == Rect(origin[0], origin[1], origin[0] + view.width, origin[1] + view.height)
            }) return false
            val active = instrumentation.uiAutomation.rootInActiveWindow ?: return false
            return try {
                active.packageName?.toString() == instrumentation.targetContext.packageName && active.windowId == window &&
                    Rect().also(active::getBoundsInScreen) == rootBounds
            } finally { active.recycle() }
        }
        val down = SystemClock.uptimeMillis()
        suspend fun inject(action: Int) {
            check(current()) { "The original native page window or bounds changed before input" }
            val props = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
            val coords = arrayOf(MotionEvent.PointerCoords().apply { x = point[0]; y = point[1]; pressure = 1f; size = 1f })
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, props, coords,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { check(instrumentation.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
        }
        var held = false
        try { inject(MotionEvent.ACTION_DOWN); held = true; delay(40); inject(MotionEvent.ACTION_UP); held = false }
        finally { if (held && current()) inject(MotionEvent.ACTION_CANCEL) }
    }
    private class FixtureServer : Closeable {
        val counts = ConcurrentHashMap<String, Int>()
        private val running = AtomicBoolean(true)
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val thread = Thread {
            while (running.get()) try { socket.accept().use { client ->
                client.soTimeout = 3000
                val input = client.getInputStream().bufferedReader()
                val path = input.readLine()?.split(' ')?.getOrNull(1) ?: return@use
                var bytes = 0
                while (true) { val line = input.readLine() ?: break; bytes += line.length; if (bytes > 8192 || line.isEmpty()) break }
                val name = path.removePrefix("/").takeIf { it in setOf("one", "two") }
                if (name != null) counts.merge(name, 1, Int::plus)
                val background = if (name == "one") "#166a31" else "#164a9a"
                val body = """<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'>
                    <title>History pixels ${name ?: "other"}</title><style>
                    html,body{margin:0;width:100%;height:100%;overflow:hidden;background:$background;touch-action:auto}
                    #glyph{position:fixed;left:20vw;top:20vh;width:20vw;height:20vh;background:white;
                    clip-path:polygon(0 0,100% 0,100% 20%,30% 20%,30% 40%,80% 40%,80% 60%,30% 60%,30% 100%,0 100%)}
                    button{position:fixed;left:55vw;width:30vw;height:6vh}#push{top:62vh}#back{top:72vh}#replace{top:82vh}</style>
                    <div id='glyph'></div><button id='push' onclick="history.pushState({},'',location.pathname+'/pushed')">Push</button>
                    <button id='back' onclick='history.back()'>Return</button>
                    <button id='replace' onclick="history.replaceState({},'','/one/replaced')">Replace</button>""".trimIndent().toByteArray()
                client.getOutputStream().apply {
                    write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    write(body); flush()
                }
            } } catch (_: IOException) { /* Only this exact fixture socket is closed. */ }
        }.apply { isDaemon = true; start() }
        fun url(name: String) = "http://127.0.0.1:${socket.localPort}/$name"
        override fun close() { running.set(false); socket.close(); thread.join(4000) }
    }
    companion object { private val GREEN = Color.rgb(0x16, 0x6a, 0x31); private val BLUE = Color.rgb(0x16, 0x4a, 0x9a) }
}

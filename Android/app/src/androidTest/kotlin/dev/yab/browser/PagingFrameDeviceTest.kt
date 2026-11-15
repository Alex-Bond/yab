package dev.yab.browser

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.*
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserChromeFrame
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.mozilla.geckoview.GeckoView

/** Actual app-owned compositor bytes. No OS capture, PNG export, account or pixel-parity claim. */
class PagingFrameDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 180_000)
    fun thePartlyOffscreenNativeViewportProducesBothOriginalColorHalvesWithoutRecreatingItsView(): Unit = runBlocking {
        requireOwned()
        val plate = AtomicReference<BrowserChromeFrame?>()
        val views = ConcurrentHashMap<String, GeckoView>()
        val receipt = baseReceipt().put("case", "partly-offscreen")
        var captured: PagingFrame? = null
        try {
            PatternServer().use { server ->
                BrowserInstrumentedTest().withBrowser(chromeFrames = plate::set,
                    viewBound = { view -> (view.tag as? String)?.let { views[it] = view } }, paging = true) { browser, engine ->
                    main { BrowserInstrumentedTest().ownSpace(browser, "Paging pixels"); browser.openUrl(server.url) }
                    ready(browser)
                    await { plate.get() != null && views[browser.state.value.tab?.id]?.isAttachedToWindow == true }
                    val tab = checkNotNull(browser.state.value.tab)
                    val lease = main { checkNotNull(browser.capturePageSwipe()) }
                    assertFalse(lease.profile.isPrivate)
                    val view = checkNotNull(views[tab.id])
                    val session = main { checkNotNull(view.session) }
                    val bounds = checkNotNull(plate.get())
                    val start = bounds.boundsPx.center.x; val y = bounds.boundsPx.center.y
                    val end = start - 130 * bounds.density
                    val down = SystemClock.uptimeMillis()
                    var held = true
                    fun input(action: Int, x: Float) {
                        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                        try { assertTrue("Owned native input was refused", instrumentation.uiAutomation.injectInputEvent(event, true)) }
                        finally { event.recycle() }
                    }
                    try {
                        input(MotionEvent.ACTION_DOWN, start)
                        for (step in 1..18) { delay(16); input(MotionEvent.ACTION_MOVE, start + (end - start) * step / 18f) }
                        await { main { IntArray(2).also(view::getLocationOnScreen)[0] < -80 * bounds.density } }
                        val frame = capturePattern(browser, engine, lease, receipt)
                        captured = frame
                        val bitmap = main { checkNotNull(frame.bitmapIfCurrent()) }
                        val originX = main { IntArray(2).also(view::getLocationOnScreen)[0] }
                        assertTrue("The sampled original left quarter was not outside the screen", originX + bitmap.width / 4 < 0)
                        assertTrue(matchesPattern(bitmap))
                        receipt.put("originalColorHalvesVerified", true).put("sourcePartlyOffscreen", true)
                            .put("bitmapWidth", bitmap.width).put("bitmapHeight", bitmap.height)
                            .put("bitmapBytes", bitmap.allocationByteCount).put("captureOutcome", "READY")
                        input(MotionEvent.ACTION_CANCEL, end); held = false
                        await { main { IntArray(2).also(view::getLocationOnScreen)[0] >= -1 } }
                        main {
                            assertEquals(tab.id, browser.state.value.tab?.id)
                            assertSame(view, views[tab.id]); assertSame(session, view.session)
                            browser.invalidateLocalOwnership()
                            assertNull("A revoked capture survived its account/local owner", frame.bitmapIfCurrent())
                            engine.foreground()
                            assertNull("Returning foreground revived old pixels", frame.bitmapIfCurrent())
                        }
                        assertFalse("Published pixels were recycled while a renderer may hold them", bitmap.isRecycled)
                        receipt.put("sameNativeViewAndSession", true).put("revokedOwnerNeverRevived", true).put("passed", true)
                    } finally { if (held) input(MotionEvent.ACTION_CANCEL, end) }
                }
            }
        } finally { captured?.close(); write("partly-offscreen", receipt) }
    }

    @Test(timeout = 180_000)
    fun privatePixelsRemainOnlyInTheOneRamLeaseAndCannotReturnAfterLockAndUnlock(): Unit = runBlocking {
        requireOwned()
        val receipt = baseReceipt().put("case", "private-ram").put("osBiometricVerified", false)
        var captured: PagingFrame? = null
        try {
            PatternServer().use { server ->
                BrowserInstrumentedTest().withBrowser(paging = true) { browser, engine ->
                    main { browser.openUrl(server.url, privately = true); browser.unlockPrivate(true) }
                    ready(browser)
                    val tab = checkNotNull(browser.state.value.tab)
                    val lease = main { checkNotNull(browser.capturePageSwipe()) }
                    assertTrue(lease.profile.isPrivate && tab.isPrivate)
                    val folder = File(instrumentation.targetContext.cacheDir, "public-tab-pictures")
                    fun disk() = folder.listFiles().orEmpty().map { it.name to it.length() }.toSet()
                    val before = disk()
                    val frame = capturePattern(browser, engine, lease, receipt)
                    captured = frame
                    val bitmap = main { checkNotNull(frame.bitmapIfCurrent()) }
                    assertTrue(matchesPattern(bitmap))
                    main {
                        browser.lockPrivate()
                        assertTrue(browser.state.value.privateContentBlocked)
                        assertNull(frame.bitmapIfCurrent())
                        browser.unlockPrivate(true)
                        assertNull("Unlock revived the previous Private capture lease", frame.bitmapIfCurrent())
                    }
                    assertNull(engine.thumbnails.value[tab.id])
                    assertTrue("Private capture changed the public thumbnail disk cache", before == disk())
                    assertFalse(bitmap.isRecycled)
                    receipt.put("captureOutcome", "READY").put("privatePixelsMatchedFixture", true)
                        .put("publicDiskUnchanged", true).put("thumbnailAbsent", true).put("lockRevokedPermanently", true).put("passed", true)
                }
            }
        } finally { captured?.close(); write("private-ram", receipt) }
    }

    private suspend fun capturePattern(browser: BrowserController, engine: GeckoEngine, lease: PageSwipeLease, receipt: JSONObject): PagingFrame {
        val start = SystemClock.elapsedRealtime()
        val deadline = start + 20_000
        var outcome = PagingCaptureOutcome.UNAVAILABLE
        var attempts = 0
        while (SystemClock.elapsedRealtime() < deadline) {
            val result = mainSuspend { engine.capturePagingFrame(lease.front, lease.profile) { browser.pageSwipeCurrent(lease) } }
            outcome = result.outcome
            receipt.put("captureAttempts", ++attempts).put("lastCaptureOutcome", outcome.name)
                .put("captureTotalMs", (SystemClock.elapsedRealtime() - start).coerceIn(0, 25_000))
            val frame = result.frame
            if (frame != null) {
                val matches = main { frame.bitmapIfCurrent()?.let(::matchesPattern) } == true
                receipt.put("lastPatternMatched", matches)
                if (matches) return frame
                frame.close()
            }
            delay(100)
        }
        error("Owned pattern capture did not complete: ${outcome.name}")
    }

    private fun matchesPattern(bitmap: Bitmap): Boolean {
        fun near(pixel: Int, red: Int, green: Int, blue: Int) = kotlin.math.abs((pixel shr 16 and 255) - red) <= 3 &&
            kotlin.math.abs((pixel shr 8 and 255) - green) <= 3 && kotlin.math.abs((pixel and 255) - blue) <= 3
        return bitmap.width > 8 && bitmap.height > 8 &&
            near(bitmap.getPixel(bitmap.width / 4, bitmap.height / 2), 0x13, 0x57, 0xAD) &&
            near(bitmap.getPixel(bitmap.width * 3 / 4, bitmap.height / 2), 0xDF, 0x66, 0x22)
    }
    private fun requireOwned() { check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") }
    private fun baseReceipt() = JSONObject().put("passed", false).put("actualGeckoCompositor", true)
        .put("osCaptureUsed", false).put("privatePngExported", false).put("presentedFrameParityVerified", false)
        .put("physicalDeviceVerified", false).put("productionAccountTransitionVerified", false)
    private fun write(name: String, receipt: JSONObject) {
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/paging-ram").apply { check(isDirectory || mkdirs()) }
        File(folder, "$name.json").writeText(receipt.toString(2))
    }
    private suspend fun ready(browser: BrowserController) = await { browser.state.value.page.let { it.title == "Owned paging pixels" && !it.loading && it.progress >= 1f } }
    private suspend fun await(predicate: suspend () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 25_000
        while (!predicate()) { check(SystemClock.elapsedRealtime() < deadline) { "Owned paging pixel stage timed out" }; delay(40) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun <T> mainSuspend(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }

    private class PatternServer : Closeable {
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val worker = Executors.newSingleThreadExecutor()
        val url get() = "http://127.0.0.1:${socket.localPort}/pixels"
        init { worker.submit {
            while (running.get()) {
                val accepted = try { socket.accept() } catch (error: IOException) { if (running.get()) throw error else break }
                try { accepted.use { client ->
                    client.soTimeout = 5000
                    val reader = client.getInputStream().bufferedReader()
                    if (reader.readLine() == null) return@use
                    while (!reader.readLine().isNullOrEmpty()) { }
                    val body = "<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><title>Owned paging pixels</title><style>html,body{margin:0;width:100%;height:100%;color-scheme:light;background:linear-gradient(to right,#1357ad 0%,#1357ad 50%,#df6622 50%,#df6622 100%)}</style><p style='position:absolute;top:16px'>Owned compositor pattern</p>".toByteArray()
                    client.getOutputStream().use { output ->
                        output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n").toByteArray())
                        output.write(body)
                    }
                } } catch (_: IOException) { }
            }
        } }
        override fun close() { running.set(false); socket.close(); worker.shutdownNow() }
    }
}

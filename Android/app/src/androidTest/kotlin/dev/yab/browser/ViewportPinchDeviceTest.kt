package dev.yab.browser

import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.YabApplication
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.engine.HistorySwipeView
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.model.BrowserTab
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test

/** Real Gecko input and viewport scale only. No rendered-frame or Main Activity claim. */
class ViewportPinchDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 180_000)
    fun nativePinchScalesARestrictiveViewportWithoutClaimingHistory(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val view = AtomicReference<HistorySwipeView?>()
        val claimed = AtomicBoolean(false)
        val samples = JSONArray()
        val receipt = JSONObject().put("passed", false).put("realGecko", false)
            .put("nativeTwoFingerInput", false).put("mainActivityVerified", false)
            .put("frameParityVerified", false).put("brightnessVerified", false)
            .put("lateHistoryClaimPinchResumeVerified", false).put("smoothnessVerified", false)
        var primary: Throwable? = null
        try {
            ViewportSite().use { server ->
                BrowserInstrumentedTest().withBrowser(historySwipe = true, viewBound = { current ->
                    val native = current as? HistorySwipeView
                    view.set(native)
                    native?.historyInputObserver = { if (it.claimed) claimed.set(true) }
                }) { browser, engine ->
                    val fixture = BrowserInstrumentedTest()
                    main { fixture.ownSpace(browser, "Owned viewport pinch"); browser.openUrl(server.url("before")) }
                    ready(browser, engine, "before")
                    val tab = checkNotNull(browser.state.value.tab)
                    val profile = checkNotNull(browser.state.value.space).websiteProfile
                    check(!profile.isPrivate && browser.state.value.space?.isPrivate == false)
                    val originalSession = main { engine.session(tab, profile) }
                    main { browser.openUrl(server.url("restrictive"), newTab = false) }
                    ready(browser, engine, "restrictive")
                    await("real back entry") { main { engine.backItems(tab.id).any { it.url == server.url("before") } } }
                    val originalTab = checkNotNull(browser.state.value.tab)
                    val owner = main { checkNotNull(engine.captureExternalActivityOwner()) }
                    val native = main { checkNotNull(view.get()) }
                    val token = main { checkNotNull(native.windowToken) }
                    val bounds = main {
                        check(native.isAttachedToWindow && native.isShown && native.hasWindowFocus() && native.session === originalSession)
                        val point = IntArray(2).also(native::getLocationOnScreen)
                        Rect(point[0], point[1], point[0] + native.width, point[1] + native.height)
                    }
                    receipt.put("realGecko", true)
                    fun source(): Boolean {
                        val state = browser.state.value
                        val point = IntArray(2).also(native::getLocationOnScreen)
                        return state.tab?.id == originalTab.id && state.tab?.url == originalTab.url &&
                            state.space?.websiteProfile == profile && !state.privateContentBlocked &&
                            state.surface == BrowserSurface.PAGE && !state.page.loading &&
                            view.get() === native && native.windowToken === token &&
                            native.session === originalSession && native.isAttachedToWindow && native.isShown &&
                            native.hasWindowFocus() && engine.ownsExternalActivity(owner) && engine.ownsInteractive(originalSession) &&
                            bounds == Rect(point[0], point[1], point[0] + native.width, point[1] + native.height)
                    }
                    check(bounds.width() >= 240 && bounds.height() >= 240)
                    var window: Int? = null
                    await("original owned input window") {
                        check(main { source() }) { "Original viewport source changed before input" }
                        val root = instrumentation.uiAutomation.rootInActiveWindow
                        try {
                            if (root == null) false else {
                                check(root.packageName?.toString() == context.packageName) { "Foreign viewport input window refused" }
                                check(Rect().also(root::getBoundsInScreen).contains(bounds)) { "Viewport escaped its own input window" }
                                window = root.windowId
                                true
                            }
                        } finally { root?.recycle() }
                    }
                    val originalWindow = checkNotNull(window)
                    suspend fun current(): Boolean {
                        if (!main { source() }) return false
                        val root = instrumentation.uiAutomation.rootInActiveWindow
                        return try {
                            root != null && root.packageName?.toString() == context.packageName &&
                                root.windowId == originalWindow && Rect().also(root::getBoundsInScreen).contains(bounds)
                        } finally { root?.recycle() }
                    }
                    val before = scale(engine, originalTab)
                    check(current()) { "Original viewport source changed while reading its initial scale" }
                    check(before in 0.9..1.1) { "Restrictive viewport did not begin at its original scale" }
                    receipt.put("configuredForceUserScalable", main {
                        (context.applicationContext as YabApplication).runtime.settings.forceUserScalableEnabled
                    }).put("beforeScale", before)
                    await("original page history prearmed before pinch") {
                        check(current()) { "Original viewport source changed while waiting for history prearm" }
                        main { native.historyGestureReady }
                    }
                    receipt.put("historyPrearmedBeforeInput", true)
                    claimed.set(false)
                    pinch(bounds, current = { current() }, samples = samples)
                    receipt.put("nativeTwoFingerInput", true)
                    check(current()) { "Original viewport source changed after pinch" }
                    var after: Double? = null
                    val deadline = SystemClock.elapsedRealtime() + 10_000
                    while (SystemClock.elapsedRealtime() < deadline) {
                        check(current()) { "Original viewport source changed while observing scale" }
                        val value = scale(engine, originalTab)
                        check(current()) { "Original viewport source changed while reading its pinched scale" }
                        after = value
                        if (value > before * 1.5) break
                        delay(75)
                    }
                    receipt.put("afterScale", after ?: JSONObject.NULL).put("historyClaimed", claimed.get())
                    check(checkNotNull(after) > before * 1.5) { "RESTRICTIVE_VIEWPORT_MUST_SCALE_FROM_REAL_NATIVE_PINCH" }
                    check(!claimed.get()) { "Two-finger viewport input claimed browser history" }
                    check(main {
                        browser.state.value.tab?.id == originalTab.id && browser.state.value.tab?.url == originalTab.url &&
                            native.session === originalSession && engine.backItems(originalTab.id).any { it.url == server.url("before") }
                    }) { "Pinch navigated or replaced the original page" }
                    receipt.put("originalPageAndHistoryRetained", true).put("passed", true)
                }
            }
        } catch (error: Throwable) {
            primary = error
            throw error
        } finally {
            receipt.put("inputSamples", samples)
            val writeFailure = runCatching {
                val folder = File(context.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
                File(folder, "viewport-native-pinch.json").writeText(receipt.toString(2))
            }.exceptionOrNull()
            if (writeFailure != null) {
                val original = primary
                if (original != null) original.addSuppressed(writeFailure) else throw writeFailure
            }
        }
    }

    private suspend fun pinch(bounds: Rect, current: suspend () -> Boolean, samples: JSONArray) {
        val y = bounds.exactCenterY()
        val center = bounds.exactCenterX()
        val near = bounds.width() * .10f
        val far = bounds.width() * .32f
        val began = SystemClock.uptimeMillis()
        var active = 0
        var radius = near
        var primary: Throwable? = null
        fun send(action: Int, contacts: Int, phase: String) {
            check(contacts in 1..2 && samples.length() < 24)
            val properties = Array(contacts) { index -> MotionEvent.PointerProperties().apply {
                id = index; toolType = MotionEvent.TOOL_TYPE_FINGER
            } }
            val points = Array(contacts) { index -> MotionEvent.PointerCoords().apply {
                x = center + if (index == 0) -radius else radius
                this.y = y; size = 1f
                pressure = if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL ||
                    action and MotionEvent.ACTION_MASK == MotionEvent.ACTION_POINTER_UP && index == 1) 0f else 1f
            } }
            val event = MotionEvent.obtain(began, SystemClock.uptimeMillis(), action, contacts, properties, points,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            val accepted = try { instrumentation.uiAutomation.injectInputEvent(event, true) } finally { event.recycle() }
            samples.put(JSONObject().put("phase", phase).put("contacts", contacts).put("accepted", accepted)
                .put("elapsedMs", (SystemClock.uptimeMillis() - began).coerceIn(0, 10_000)))
            check(accepted) { "Original owned viewport native input was refused" }
        }
        try {
            check(current()) { "Original viewport target was stale before DOWN" }
            active = 1; send(MotionEvent.ACTION_DOWN, 1, "DOWN")
            delay(16)
            check(current()) { "Original viewport target changed before second contact" }
            active = 2; send(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, "SECOND_DOWN")
            repeat(16) { step ->
                delay(16)
                check(current()) { "Original viewport target changed during pinch" }
                radius = near + (far - near) * (step + 1) / 16f
                send(MotionEvent.ACTION_MOVE, 2, "MOVE")
            }
            check(current()) { "Original viewport target changed before second UP" }
            send(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, "SECOND_UP"); active = 1
            delay(16)
            check(current()) { "Original viewport target changed before UP" }
            send(MotionEvent.ACTION_UP, 1, "UP"); active = 0
        } catch (error: Throwable) {
            primary = error
            throw error
        } finally {
            if (active > 0) {
                val cancelFailure = runCatching {
                    if (current()) send(MotionEvent.ACTION_CANCEL, active, "CANCEL")
                    else samples.put(JSONObject().put("phase", "CANCEL_REFUSED_STALE_SOURCE").put("contacts", active)
                        .put("accepted", false).put("elapsedMs", (SystemClock.uptimeMillis() - began).coerceIn(0, 10_000)))
                }.exceptionOrNull()
                if (cancelFailure != null) {
                    val original = primary
                    if (original != null) original.addSuppressed(cancelFailure) else throw cancelFailure
                }
            }
        }
    }

    private suspend fun ready(browser: BrowserController, engine: GeckoEngine, route: String) {
        await("owned viewport document") { browser.state.value.page.let { !it.loading && it.title == "Owned viewport $route" } }
        await("owned viewport telemetry") { runCatching { scale(browser, engine) in .1..20.0 }.getOrDefault(false) }
    }

    private suspend fun scale(browser: BrowserController, engine: GeckoEngine): Double =
        scale(engine, checkNotNull(browser.state.value.tab))

    private suspend fun scale(engine: GeckoEngine, tab: BrowserTab): Double {
        val text = withContext(Dispatchers.Main) { engine.readText(tab).text }
        val value = Regex("NativeScale=([0-9]+(?:\\.[0-9]+)?)").find(text)?.groupValues?.get(1)?.toDoubleOrNull()
        return checkNotNull(value).also { check(it.isFinite() && it in .1..20.0) }
    }

    private suspend fun await(label: String, predicate: suspend () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 20_000
        while (!predicate()) {
            check(SystemClock.elapsedRealtime() < end) { "Timed out waiting for $label" }
            delay(75)
        }
    }

    private suspend fun <T> main(action: () -> T): T = withContext(Dispatchers.Main) { action() }
}

/** Its visible DOM reports the native viewport. It never sets a scale, CSS zoom, or page transform. */
private class ViewportSite : Closeable {
    private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    private val alive = AtomicBoolean(true)
    private val executor = Executors.newSingleThreadExecutor()
    init {
        executor.execute {
            while (alive.get()) try {
                socket.accept().use { client ->
                    client.soTimeout = 5000
                    val reader = client.getInputStream().bufferedReader()
                    val first = try {
                        val request = reader.readLine().orEmpty()
                        while (!reader.readLine().isNullOrEmpty()) Unit
                        request
                    } catch (_: SocketTimeoutException) {
                        return@use
                    }
                    val route = first.split(' ').getOrNull(1)?.substringBefore('?')?.removePrefix("/")
                        ?.takeIf { it == "before" || it == "restrictive" } ?: "before"
                    val body = """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><title>Owned viewport $route</title>
                        <style>html,body{margin:0;background:white;color:black;font:20px sans-serif}main{padding:48px 16px}#picture{height:320px;background:#9a9a9a}</style></head>
                        <body><main><h1>Owned viewport $route</h1><p id="scale">NativeScale=pending</p><div id="picture">Owned picture</div></main>
                        <script>function report(){document.getElementById('scale').textContent='NativeScale='+window.visualViewport.scale.toFixed(3)};window.visualViewport.addEventListener('resize',report);report()</script></body></html>""".trimIndent().toByteArray()
                    val header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray()
                    val output = client.getOutputStream()
                    try {
                        output.write(header); output.write(body); output.flush()
                    } catch (error: SocketException) {
                        if (error.message != "Broken pipe") throw error
                    }
                }
            } catch (error: IOException) { if (alive.get()) throw error }
        }
    }
    fun url(route: String) = "http://127.0.0.1:${socket.localPort}/$route"
    override fun close() { alive.set(false); socket.close(); executor.shutdownNow() }
}

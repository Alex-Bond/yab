package dev.yab.browser

import android.animation.ValueAnimator
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.provider.Settings
import android.view.Choreographer
import android.view.FrameMetrics
import android.view.Window
import android.view.View
import android.view.ViewGroup
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.ui.BrowserChromeFrame
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import org.mozilla.geckoview.GeckoView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Opt-in real-clock film. No animation scales or device security settings are changed. */
class BrowserMotionFilmTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 180_000)
    fun filmOwnedMotion(): Unit = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        check(args.getString("ownedEmulator") == "true")
        val scenario = requireNotNull(args.getString("motionFilm"))
        val nonce = requireNotNull(args.getString("motionNonce"))
        val motionPixels = args.getString("motionPixels").let { value ->
            check(value == null || value == "true") { "Unknown owned pixel-capture mode" }
            value == "true"
        }
        check(scenario in setOf("chromeFold", "chromeReverse80", "chromeReverse160", "chromeSwipe", "spaces"))
        check(nonce.matches(Regex("[a-f0-9]{32}")))
        check(ValueAnimator.areAnimatorsEnabled()) { "Motion proof requires the existing system animators to be enabled" }
        val context = instrumentation.targetContext
        val scales = JSONObject()
        for (setting in listOf(Settings.Global.ANIMATOR_DURATION_SCALE, Settings.Global.TRANSITION_ANIMATION_SCALE, Settings.Global.WINDOW_ANIMATION_SCALE)) {
            val scale = Settings.Global.getFloat(context.contentResolver, setting, 1f)
            check(scale == 1f) { "Motion proof requires the existing animation scale to be 1: $setting=$scale" }
            scales.put(setting, scale)
        }
        val parent = File(context.getExternalFilesDir(null), "instrumentation")
        check(parent.isDirectory || parent.mkdirs()) { "Cannot create the owned instrumentation parent" }
        val folder = File(parent, "motion-film-$nonce")
        check(folder.mkdir()) { "A motion fixture output must be new" }
        val marks = CopyOnWriteArrayList<JSONObject>()
        val chromeFrames = CopyOnWriteArrayList<BrowserChromeFrame>()
        val chromeCapped = AtomicBoolean(false)
        val touches = CopyOnWriteArrayList<JSONObject>()
        val scrolls = CopyOnWriteArrayList<JSONObject>()
        var succeeded = false
        var meter: Meter? = null
        fun mark(name: String) { marks.add(JSONObject().put("name", name).put("elapsedRealtimeNanos", SystemClock.elapsedRealtimeNanos())
            .put("uptimeNanos", System.nanoTime())) }
        try {
            PageServer(instrumentation.context.assets.open("motion/paper.html").use { it.readBytes() }).use { page ->
                BrowserInstrumentedTest().withBrowser(chromeFrames = { frame ->
                    if (chromeFrames.size < 1200) chromeFrames.add(frame) else chromeCapped.set(true)
                }) { browser, engine ->
                    main {
                        BrowserInstrumentedTest().ownSpace(browser, "Motion fixture")
                        browser.openUrl(page.url)
                    }
                    await("owned page loaded") { !browser.state.value.page.loading && browser.state.value.page.title?.contains("Tern 2.0") == true }
                    // PageStop can precede the APK bridge's native port. Keep
                    // waiting for the actual article instead of treating this
                    // transient startup state as a failed motion or skipping it.
                    await("native article text") {
                        try { main { engine.readText(browser.state.value.tab!!).text.contains("Tern 2.0 launch notes") } }
                        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                        catch (_: IllegalStateException) { false }
                    }
                    val activity = main {
                        ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<EngineTestActivity>().single()
                    }
                    val dimensions = main { JSONObject().put("widthPx", activity.window.decorView.width)
                        .put("heightPx", activity.window.decorView.height).put("density", context.resources.displayMetrics.density)
                        .put("fontScale", context.resources.configuration.fontScale)
                        .put("displayRefreshRateHz", activity.windowManager.defaultDisplay.refreshRate)
                        .put("windowHardwareAccelerated", activity.window.decorView.isHardwareAccelerated) }
                    val originalTab = requireNotNull(browser.state.value.tab)
                    val pageBounds = if (scenario == "chromeSwipe") main { ownedPageBounds(activity) } else null
                    val pageGeometry = if (scenario == "chromeSwipe") {
                        val geometry = main { engine.readText(originalTab, diagnostics = true).geometry }
                        requireNotNull(geometry) { "The owned article did not return finite viewport geometry" }
                        JSONObject().put("clientHeight", geometry.clientHeight).put("scrollHeight", geometry.scrollHeight)
                            .put("innerHeight", geometry.innerHeight).put("dpr", geometry.dpr)
                            .put("visualViewportHeight", geometry.visualViewportHeight ?: JSONObject.NULL)
                    } else null
                    if (scenario == "chromeSwipe") {
                        assertTrue("The swipe fixture did not start at the top of the actual article", browser.state.value.page.scrollY < 1f)
                        assertTrue("The swipe fixture did not start at the top of native logical user scroll", browser.state.value.page.userScrollY < 1f)
                    }
                    val inputSpec = if (pageBounds != null) JSONObject()
                        .put("kind", "UiAutomation-touchscreen-swipe")
                        .put("target", "attached-owned-GeckoView")
                        .put("startXFraction", 0.5).put("startYFraction", 0.8).put("endYFraction", 0.2)
                        .put("requestedDurationMillis", 1200).put("moveSteps", 72)
                        .put("chromeTrigger", "native-user-logical-scroll")
                        .put("pageLeftPx", pageBounds.left).put("pageTopPx", pageBounds.top)
                        .put("pageWidthPx", pageBounds.width()).put("pageHeightPx", pageBounds.height())
                        .put("iosReference", "Phone/UITests/Transitions.swift: chromeFold webView.swipeUp(velocity: .slow)")
                        .put("iosInputTrajectoryMeasured", false)
                        .put("exactInputTrajectoryParityVerified", false)
                    else JSONObject().put("kind", if (scenario == "spaces") "owned-surface-command" else "controlled-native-scroll-state")
                    meter = main { Meter(activity.window) }
                    await("actual capsule layout") { chromeFrames.any { it.boundsPx.height > 0 && it.density > 0 } }
                    File(folder, "ready.json").writeText(JSONObject().put("nonce", nonce).put("scenario", scenario)
                        .put("scales", scales).put("viewport", dimensions).put("clockKind", "real-device-monotonic")
                        .put("nativePage", "GeckoView").put("input", inputSpec)
                        .apply { if (pageGeometry != null) put("domGeometryBeforeInput", pageGeometry) }
                        .put("physicalDeviceSmoothnessVerified", false).toString(2))
                    await("camera handshake", 40_000) { File(folder, "recording.json").takeIf(File::isFile)?.let {
                        runCatching { JSONObject(it.readText()).let { receipt -> receipt.getString("nonce") == nonce && receipt.getString("scenario") == scenario } }.getOrDefault(false)
                    } == true }
                    delay(500)
                    main {
                        // Four dp of blue, like the iPhone FrameMeter mark. The raw movie
                        // locates this drawn frame; host clocks are not a video sync source.
                        val size = (4f * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
                        (activity.window.decorView as ViewGroup).addView(View(activity).apply {
                            setBackgroundColor(android.graphics.Color.BLUE)
                            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                            isClickable = false
                        }, ViewGroup.LayoutParams(size, size))
                        mark("start")
                        if (scenario == "spaces") {
                            browser.show(BrowserSurface.SPACES)
                            mark("spaces-open-command")
                        } else if (scenario != "chromeSwipe") {
                            browser.pageChanged(browser.state.value.tab!!.id, browser.state.value.page.copy(scrollY = 150f, userScrollY = 150f))
                            mark("fold-command")
                        }
                    }
                    if (scenario == "chromeSwipe") {
                        mark("swipe-start")
                        swipePage(requireNotNull(pageBounds), touches) {
                            val state = browser.state.value
                            check(state.tab?.id == originalTab.id && state.tab?.url == originalTab.url &&
                                state.surface == BrowserSurface.PAGE && !state.privateContentBlocked) { "The owned swipe article changed" }
                            scrolls.add(JSONObject().put("uptimeNanos", System.nanoTime()).put("scrollY", state.page.scrollY)
                                .put("userScrollY", state.page.userScrollY))
                        }
                        mark("swipe-end")
                        await("native user logical scroll passed the chrome fold threshold", 5000) { browser.state.value.page.userScrollY >= 50f }
                        scrolls.add(JSONObject().put("uptimeNanos", System.nanoTime()).put("scrollY", browser.state.value.page.scrollY)
                            .put("userScrollY", browser.state.value.page.userScrollY))
                        mark("native-scroll-threshold-observed")
                    } else if (scenario == "spaces") {
                        delay(800)
                        clickOwnedClose()
                        mark("spaces-close-command")
                    } else {
                        val tab = browser.state.value.tab!!.id
                        // Feed the same native page scroll state without an accessibility query
                        // during the transition. Record the exact trigger and any reversal.
                        val reverseAfter = when (scenario) { "chromeReverse80" -> 80L; "chromeReverse160" -> 160L; else -> null }
                        if (reverseAfter != null) {
                            delay(reverseAfter)
                            main { browser.pageChanged(tab, browser.state.value.page.copy(scrollY = 120f, userScrollY = 120f)) }
                            mark("reverse-command")
                        }
                    }
                    delay(1000)
                    if (scenario == "spaces") {
                        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
                    } else {
                        val began = marks.first { it.getString("name") == "start" }.getLong("uptimeNanos")
                        val observed = chromeFrames.filter { it.uptimeNanos >= began && it.density > 0 }
                        assertTrue("The actual layout clock did not observe the chrome transition", observed.isNotEmpty())
                        assertTrue("The real chrome transition drew no intermediate layout", observed.any {
                            val height = it.boundsPx.height / it.density
                            height > 31.2f && height < 47.8f
                        })
                        val capsule = observed.last()
                        val expectedHeight = if (scenario in setOf("chromeFold", "chromeSwipe")) 31f else 48f
                        assertEquals("The actual drawn capsule did not arrive", expectedHeight,
                            capsule.boundsPx.height / capsule.density, 1f)
                        if (scenario == "chromeSwipe") {
                            assertEquals(originalTab.id, browser.state.value.tab?.id)
                            assertEquals(originalTab.url, browser.state.value.tab?.url)
                            assertTrue("The article did not physically scroll", browser.state.value.page.scrollY > 0f)
                            assertTrue("Native user logical scroll did not trigger the chrome threshold", browser.state.value.page.userScrollY >= 50f)
                        }
                    }
                    mark("arrived")
                    if (motionPixels) {
                        // The ordinary final receipt is written after withBrowser tears
                        // down its Activity. Pixel transport must stop while this exact
                        // native fixture still owns the visible page.
                        File(folder, "pixels-ready-to-stop.json").writeText(JSONObject()
                            .put("nonce", nonce).put("scenario", scenario)
                            .put("kind", "owned-motion-pixels-ready-to-stop").put("passed", true).toString(2))
                        await("owned pixel recorder stopped before leaving the fixture", 15_000) {
                            val stopped = File(folder, "pixels-stopped.json")
                            if (!stopped.isFile) false else {
                                check(stopped.length() in 1L..4096L) { "Invalid owned pixel-stop receipt size" }
                                val receipt = JSONObject(stopped.readText())
                                check(receipt.opt("nonce") == nonce && receipt.opt("scenario") == scenario &&
                                    receipt.opt("kind") == "owned-motion-pixels-stopped") { "Foreign pixel-stop receipt" }
                                check(receipt.opt("captureStopped") == true && receipt.opt("captureAccepted") == true) {
                                    "The owned pixel recorder failed or was cancelled"
                                }
                                true
                            }
                        }
                        mark("pixels-recorder-stopped")
                    }
                    succeeded = true
                }
            }
        } finally {
            val frames = main { meter?.finish() } ?: JSONObject()
            val chrome = JSONArray(chromeFrames.map { frame -> JSONObject().put("uptimeNanos", frame.uptimeNanos)
                .put("leftPx", frame.boundsPx.left).put("topPx", frame.boundsPx.top)
                .put("widthPx", frame.boundsPx.width).put("heightPx", frame.boundsPx.height).put("density", frame.density) })
            File(folder, "frames.json").writeText(frames.put("marks", JSONArray(marks)).put("clockKind", "real-device-monotonic")
                .put("chromeLayouts", chrome).put("chromeLayoutsCapped", chromeCapped.get())
                .put("touchEvents", JSONArray(touches)).put("nativePageScrollSamples", JSONArray(scrolls))
                .put("composeTestClockInstalled", false)
                .put("dataKind", "Window.FrameMetrics and Choreographer callbacks")
                .put("presentationFenceMeasured", false).toString(2))
            File(folder, "done.json").writeText(JSONObject().put("nonce", nonce).put("scenario", scenario)
                .put("passed", succeeded).put("allAnimationsMatchIOS", false).put("physicalDeviceSmoothnessVerified", false).toString(2))
        }
    }

    /** Actual attached page bounds in screen pixels, not guessed display coordinates. */
    private fun ownedPageBounds(activity: EngineTestActivity): android.graphics.Rect {
        val pages = mutableListOf<GeckoView>()
        fun visit(view: View) {
            if (view is GeckoView && view.isAttachedToWindow && view.session != null && view.isShown) pages += view
            if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(activity.window.decorView)
        val page = pages.single()
        val origin = IntArray(2).also(page::getLocationOnScreen)
        return android.graphics.Rect(origin[0], origin[1], origin[0] + page.width, origin[1] + page.height).also {
            check(it.width() > 0 && it.height() > 0) { "The owned native article has no viewport" }
        }
    }

    /** Real slow drag over the native page. All injected timestamps and samples remain inspectable. */
    private suspend fun swipePage(bounds: android.graphics.Rect, events: MutableList<JSONObject>, observe: () -> Unit) {
        val x = bounds.exactCenterX()
        val from = bounds.top + bounds.height() * 0.8f
        val to = bounds.top + bounds.height() * 0.2f
        val began = SystemClock.uptimeMillis()
        var released = false
        var y = from
        fun inject(action: Int) {
            val time = SystemClock.uptimeMillis()
            val event = MotionEvent.obtain(began, time, action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            try {
                check(instrumentation.uiAutomation.injectInputEvent(event, true)) { "Owned article touch injection failed" }
                events.add(JSONObject().put("action", action).put("eventUptimeMillis", time)
                    .put("deliveredUptimeNanos", System.nanoTime()).put("xPx", x).put("yPx", y))
            } finally { event.recycle() }
            observe()
        }
        try {
            inject(MotionEvent.ACTION_DOWN)
            for (step in 1..72) {
                check(SystemClock.uptimeMillis() - began <= 3000) { "The owned slow swipe exceeded its input bound" }
                val target = began + 1200L * step / 72
                val remaining = target - SystemClock.uptimeMillis()
                if (remaining > 0) delay(remaining)
                y = from + (to - from) * step / 72f
                inject(MotionEvent.ACTION_MOVE)
            }
            inject(MotionEvent.ACTION_UP)
            released = true
        } finally {
            if (!released) {
                // Release only this fixture's pointer if ownership or input failed.
                val cancel = MotionEvent.obtain(began, SystemClock.uptimeMillis(), MotionEvent.ACTION_CANCEL, x, y, 0)
                    .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                try { instrumentation.uiAutomation.injectInputEvent(cancel, true) } finally { cancel.recycle() }
            }
        }
    }

    /** The only active Close action in the owned app window, without a Compose test rule or clock. */
    private suspend fun clickOwnedClose() {
        await("owned spaces Close action", 10_000) {
            val root = instrumentation.uiAutomation.rootInActiveWindow ?: return@await false
            if (root.packageName?.toString() != instrumentation.targetContext.packageName) return@await false
            val queue = java.util.ArrayDeque<AccessibilityNodeInfo>()
            val actions = linkedSetOf<AccessibilityNodeInfo>()
            queue.add(root)
            var count = 0
            while (queue.isNotEmpty() && count++ < 512) {
                val node = queue.removeFirst()
                if (node.isVisibleToUser && node.isEnabled && node.contentDescription?.toString() == "Close") {
                    var candidate: AccessibilityNodeInfo? = node
                    repeat(5) {
                        val current = candidate
                        if (current?.isClickable == true && current.isEnabled && current.isVisibleToUser) { actions.add(current); candidate = null }
                        else candidate = current?.parent
                    }
                }
                for (index in 0 until node.childCount) node.getChild(index)?.let(queue::add)
            }
            check(queue.isEmpty()) { "Owned Close hierarchy exceeds its bound" }
            check(actions.size <= 1) { "Owned Close action is ambiguous" }
            actions.singleOrNull()?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
        }
    }

    private class Meter(private val window: Window) {
        private val thread = HandlerThread("owned-motion-metrics").apply { start() }
        private val metrics = CopyOnWriteArrayList<JSONObject>()
        private val callbacks = JSONArray()
        private var active = true
        private val frame = object : Choreographer.FrameCallback {
            override fun doFrame(time: Long) {
                if (!active) return
                if (callbacks.length() < 1200) callbacks.put(time)
                Choreographer.getInstance().postFrameCallback(this)
            }
        }
        private val listener = Window.OnFrameMetricsAvailableListener { _, measured, dropped ->
            if (metrics.size < 1200) metrics.add(JSONObject().put("elapsedRealtimeNanos", SystemClock.elapsedRealtimeNanos())
                .put("intendedVsyncNanos", measured.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP))
                .put("vsyncNanos", measured.getMetric(FrameMetrics.VSYNC_TIMESTAMP))
                .put("totalNanos", measured.getMetric(FrameMetrics.TOTAL_DURATION))
                .put("layoutNanos", measured.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION))
                .put("drawNanos", measured.getMetric(FrameMetrics.DRAW_DURATION))
                .put("gpuNanos", measured.getMetric(FrameMetrics.GPU_DURATION)).put("reportsDropped", dropped))
        }
        init {
            window.addOnFrameMetricsAvailableListener(listener, Handler(thread.looper))
            Choreographer.getInstance().postFrameCallback(frame)
        }
        fun finish(): JSONObject {
            active = false
            Choreographer.getInstance().removeFrameCallback(frame)
            window.removeOnFrameMetricsAvailableListener(listener)
            thread.quitSafely()
            return JSONObject().put("windowFrames", JSONArray(metrics)).put("callbackNanos", callbacks)
                .put("samplesCapped", metrics.size >= 1200 || callbacks.length() >= 1200)
        }
    }

    private class PageServer(private val page: ByteArray) : AutoCloseable {
        private val running = AtomicBoolean(true)
        private val socket = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val url = "http://127.0.0.1:${socket.localPort}/motion"
        private val worker = Thread {
            while (running.get()) runCatching { socket.accept().use { client ->
                client.soTimeout = 3000
                val input = client.getInputStream().bufferedReader()
                var bytes = 0
                while (true) {
                    val line = input.readLine() ?: break
                    bytes += line.length
                    check(bytes <= 8192)
                    if (line.isEmpty()) break
                }
                client.getOutputStream().apply {
                    write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${page.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    write(page); flush()
                }
            } }
        }.apply { name = "owned-motion-page"; isDaemon = true; start() }
        override fun close() { running.set(false); socket.close(); worker.join(4000) }
    }

    private suspend fun await(name: String, timeout: Long = 30_000, predicate: suspend () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeout
        while (!predicate()) { check(SystemClock.elapsedRealtime() < until) { "Timed out waiting for $name" }; delay(30) }
    }
    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }
}

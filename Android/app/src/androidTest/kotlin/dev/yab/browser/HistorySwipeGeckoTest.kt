package dev.yab.browser

import android.os.SystemClock
import android.graphics.Rect
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.engine.HistorySwipeView
import dev.yab.browser.model.*
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

/** Actual native input/history authority only. No source/controlled test substitutes for this run. */
class HistorySwipeGeckoTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    @Test(timeout = 200_000)
    fun originalNativePageDoesNotNavigateBeforeUpCancelKeepsHistoryAndOffNeverStealsThePage(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val view = AtomicReference<HistorySwipeView?>()
        val observedEngine = AtomicReference<GeckoEngine?>()
        val observedController = AtomicReference<BrowserController?>()
        val nativeInputs = CopyOnWriteArrayList<JSONObject>()
        val historyCaptures = CopyOnWriteArrayList<JSONObject>()
        val capturesTruncated = AtomicBoolean(false)
        val injections = CopyOnWriteArrayList<JSONObject>()
        val windowReadiness = CopyOnWriteArrayList<JSONObject>()
        val beganAt = SystemClock.elapsedRealtime()
        val receipt = JSONObject().put("passed", false).put("realGecko", true).put("realFinger", true)
            .put("frameParityVerified", false).put("physicalDeviceSmoothnessVerified", false).put("targetImageAvailable", false)
        fun consumerProjection(): JSONObject? = observedController.get()?.state?.value?.let { state ->
            JSONObject().put("loading", state.loading).put("pageLoading", state.page.loading)
                .put("readerEnabled", state.page.readerEnabled).put("privateBlocked", state.privateContentBlocked)
                .put("findPresent", state.find != null).put("pageSurface", state.surface == BrowserSurface.PAGE)
                .put("swipeEnabled", state.settings.swipeAnywhere).put("tabPresent", state.tab != null)
                .put("tabBlank", state.tab?.isBlank == true)
        }
        var originalFailure: Throwable? = null
        try {
            OwnedHistoryServer().use { server ->
                BrowserInstrumentedTest().withBrowser(viewBound = { (it as? HistorySwipeView)?.let { native ->
                    view.set(native)
                    native.historyInputObserver = { input ->
                        if (nativeInputs.size < 480) nativeInputs += JSONObject().put("stage", input.stage.name)
                            .put("scenario", receipt.optString("stage", "setup"))
                            .put("elapsedMs", (SystemClock.elapsedRealtime() - beganAt).coerceIn(0, 200_000))
                            .put("ticketCurrent", input.ticketCurrent).put("sessionCurrent", input.sessionCurrent)
                            .put("attached", input.attached).put("focused", input.focused)
                            .put("claimed", input.claimed).put("nativeCancelled", input.nativeCancelled)
                            .put("claimGate", input.claimGate?.name ?: JSONObject.NULL)
                            .put("pagePhase", input.pagePhase?.name ?: JSONObject.NULL)
                            .put("pageAccepted", input.pageAccepted ?: JSONObject.NULL)
                            .put("pageHeld", input.pageHeld ?: JSONObject.NULL)
                            .put("pageContacts", input.pageContacts ?: JSONObject.NULL)
                            .put("pageTicketMatches", input.pageTicketMatches ?: JSONObject.NULL)
                            .also { if (input.claimGate != null) it.put("consumer", consumerProjection() ?: JSONObject.NULL) }
                    }
                } }, historySwipe = true) { browser, engine ->
                    main {
                        observedController.set(browser); observedEngine.set(engine)
                        engine.historyCaptureObserver = { capture ->
                            if (historyCaptures.size < 128) historyCaptures += JSONObject()
                                .put("scenario", receipt.optString("stage", "setup"))
                                .put("stage", capture.stage.name).put("direction", capture.direction?.name ?: JSONObject.NULL)
                                .put("source", capture.source?.name ?: JSONObject.NULL)
                                .put("elapsedMs", (SystemClock.elapsedRealtime() - beganAt).coerceIn(0, 200_000))
                                .put("entryPresent", capture.entryPresent).put("entryAlive", capture.entryAlive)
                                .put("selected", capture.selected).put("sessionOwned", capture.sessionOwned)
                                .put("interactive", capture.interactive).put("loading", capture.loading)
                                .put("consumer", consumerProjection() ?: JSONObject.NULL)
                                .put("registry", capture.registry?.let { registry -> JSONObject()
                                    .put("entriesCount", registry.entriesCount).put("currentIndex", registry.currentIndex)
                                    .put("backAvailable", registry.backAvailable).put("forwardAvailable", registry.forwardAvailable)
                                    .put("countsClamped", registry.countsClamped) } ?: JSONObject.NULL)
                            else capturesTruncated.set(true)
                        }
                        BrowserInstrumentedTest().ownSpace(browser, "Native history"); browser.openUrl(server.url("one"))
                    }
                    ready(browser, "one")
                    val first = checkNotNull(browser.state.value.tab)
                    val profile = checkNotNull(browser.state.value.space).websiteProfile
                    val originalSession = main { engine.session(first, profile) }
                    main { browser.openUrl(server.url("two"), newTab = false) }
                    ready(browser, "two")
                    await("native history target") { main { engine.backItems(first.id).any { it.url == server.url("one") } } }
                    val current = checkNotNull(browser.state.value.tab)
                    val requests = server.counts.toMap()
                    suspend fun gesture(back: Boolean, cancel: Boolean, requireArmed: Boolean = true) {
                        val beforeRequests = server.counts.toMap()
                        if (requireArmed) await("prearmed original page") { main { view.get()?.historyGestureReady == true } }
                        val native = checkNotNull(view.get())
                        val owner = main { checkNotNull(engine.captureExternalActivityOwner()) }
                        val bounds = main {
                            check(native.isAttachedToWindow && native.isShown && native.hasWindowFocus() && native.session === originalSession)
                            val origin = IntArray(2).also(native::getLocationOnScreen)
                            Rect(origin[0], origin[1], origin[0] + native.width, origin[1] + native.height)
                        }
                        val nativeToken = main { checkNotNull(native.windowToken) }
                        fun observeWindow(row: JSONObject) {
                            if (windowReadiness.size < 64) windowReadiness += row.put("scenario", receipt.optString("stage"))
                        }
                        // Capture native/source/bounds BEFORE waiting. A null accessibility
                        // root can be transient; a changed owner/window is never retargeted.
                        val began = SystemClock.elapsedRealtime()
                        var poll = 0
                        var capturedWindow: Int? = null
                        var capturedRoot: Rect? = null
                        while (capturedWindow == null) {
                            val source = main {
                                val origin = IntArray(2).also(native::getLocationOnScreen)
                                JSONObject().put("ownerCurrent", engine.ownsExternalActivity(owner))
                                    .put("interactive", engine.ownsInteractive(originalSession))
                                    .put("sameSession", native.session === originalSession).put("sameView", view.get() === native)
                                    .put("sameWindowToken", native.windowToken === nativeToken)
                                    .put("attached", native.isAttachedToWindow).put("shown", native.isShown).put("focused", native.hasWindowFocus())
                                    .put("boundsNonempty", !bounds.isEmpty).put("boundsUnchanged", bounds ==
                                        Rect(origin[0], origin[1], origin[0] + native.width, origin[1] + native.height))
                            }
                            val sourceCurrent = listOf("ownerCurrent", "interactive", "sameSession", "sameView", "sameWindowToken",
                                "attached", "shown", "focused", "boundsNonempty", "boundsUnchanged").all(source::getBoolean)
                            source.put("poll", poll.coerceAtMost(999)).put("elapsedMs", (SystemClock.elapsedRealtime() - began).coerceIn(0, 60_000))
                                .put("sourceCurrent", sourceCurrent).put("phase", "ROOT_WAIT")
                            if (!sourceCurrent) { observeWindow(source); error("Original history source changed while waiting for its window") }
                            check(SystemClock.elapsedRealtime() - began < 5000) { "Timed out waiting for original owned history input window" }
                            val root = instrumentation.uiAutomation.rootInActiveWindow
                            source.put("rootPresent", root != null)
                            if (root != null) try {
                                val owned = root.packageName?.toString() == instrumentation.targetContext.packageName
                                source.put("rootOwned", owned)
                                if (!owned) { observeWindow(source); error("Foreign history input window refused") }
                                val rect = Rect().also(root::getBoundsInScreen)
                                source.put("rootBoundsContainNative", !rect.isEmpty && rect.contains(bounds))
                                observeWindow(source)
                                check(!rect.isEmpty && rect.contains(bounds)) { "Original history view is outside its owned window" }
                                check(SystemClock.elapsedRealtime() - began < 5000) { "Original history root arrived after its readiness budget" }
                                capturedWindow = root.windowId; capturedRoot = rect
                            } finally { root.recycle() }
                            else {
                                if (poll < 4 || poll % 50 == 0) observeWindow(source)
                                delay(20); poll++
                            }
                        }
                        val window = checkNotNull(capturedWindow)
                        val rootBounds = checkNotNull(capturedRoot)
                        val points = floatArrayOf(bounds.left + bounds.width() * (if (back) .2f else .8f),
                            bounds.left + bounds.width() * (if (back) .85f else .15f), bounds.top + bounds.height() * .35f)
                        suspend fun windowCurrent(): Boolean {
                            if (!main {
                                val origin = IntArray(2).also(native::getLocationOnScreen)
                                engine.ownsExternalActivity(owner) && engine.ownsInteractive(originalSession) && native.session === originalSession &&
                                    view.get() === native && native.windowToken === nativeToken &&
                                    native.isAttachedToWindow && native.isShown && native.hasWindowFocus() &&
                                    bounds == Rect(origin[0], origin[1], origin[0] + native.width, origin[1] + native.height)
                            }) return false
                            val active = instrumentation.uiAutomation.rootInActiveWindow ?: return false
                            return try { active.packageName?.toString() == instrumentation.targetContext.packageName && active.windowId == window &&
                                Rect().also(active::getBoundsInScreen) == rootBounds } finally { active.recycle() }
                        }
                        val down = SystemClock.uptimeMillis(); var pressed = false; var lastX = points[0]
                        var step = 0
                        suspend fun inject(action: Int, x: Float) {
                            val actionName = when (action) { MotionEvent.ACTION_DOWN -> "DOWN"; MotionEvent.ACTION_MOVE -> "MOVE"
                                MotionEvent.ACTION_UP -> "UP"; MotionEvent.ACTION_CANCEL -> "CANCEL"; else -> "OTHER" }
                            val ownedWindow = windowCurrent()
                            val row = JSONObject().put("scenario", receipt.optString("stage")).put("action", actionName).put("step", step)
                                .put("windowCurrent", ownedWindow).put("delivered", false)
                            if (injections.size < 160) injections += row
                            check(ownedWindow) { "Original history input window or bounds changed before $actionName" }
                            val ownedViewDisplayId = main { native.display?.displayId?.takeIf { it in 0..64 } ?: -1 }
                            val properties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
                            val coordinates = arrayOf(MotionEvent.PointerCoords().apply { this.x = x; y = points[2]; pressure = 1f; size = 1f })
                            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, properties, coordinates,
                                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
                            try {
                                row.put("toolFinger", event.getToolType(0) == MotionEvent.TOOL_TYPE_FINGER)
                                    .put("touchscreenSource", event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN))
                                    .put("ownedViewDisplayId", ownedViewDisplayId)
                                val started = SystemClock.elapsedRealtime()
                                val delivered = instrumentation.uiAutomation.injectInputEvent(event, true)
                                row.put("delivered", delivered).put("waitMs", (SystemClock.elapsedRealtime() - started).coerceIn(0, 60_000))
                                if (!delivered && !receipt.has("firstRefused")) receipt.put("firstRefused", JSONObject(row.toString()))
                                assertTrue("Owned native finger $actionName refused at step $step", delivered)
                            }
                            finally { event.recycle() }
                            lastX = x
                        }
                        var failure: Throwable? = null
                        try {
                            pressed = true; inject(MotionEvent.ACTION_DOWN, points[0])
                            for (index in 1..28) { step = index; delay(16); inject(MotionEvent.ACTION_MOVE, points[0] + (points[1] - points[0]) * index / 28f) }
                            main {
                                assertTrue("History changed before an accepted UP", engine.ownsExternalActivity(owner))
                                assertSame(originalSession, native.session)
                            }
                            assertEquals("The held preview made a page request", beforeRequests, server.counts.toMap())
                            inject(if (cancel) MotionEvent.ACTION_CANCEL else MotionEvent.ACTION_UP, points[1]); pressed = false
                        } catch (error: Throwable) { failure = error; throw error
                        } finally {
                            if (pressed) withContext(NonCancellable) {
                                runCatching {
                                    withTimeout(2000) {
                                        if (windowCurrent()) inject(MotionEvent.ACTION_CANCEL, lastX)
                                        else observeWindow(JSONObject().put("phase", "CANCEL_OWNER_REFUSED"))
                                    }
                                }.exceptionOrNull()?.let { failure?.addSuppressed(it) ?: throw it }
                            }
                        }
                    }
                    receipt.put("stage", "cancel")
                    gesture(back = true, cancel = true)
                    delay(300)
                    assertEquals(current.url, browser.state.value.tab?.url)
                    assertEquals(requests, server.counts.toMap())
                    receipt.put("cancelKeptOriginalDocument", true).put("stage", "back")
                    gesture(back = true, cancel = false)
                    val committedBackUp = nativeInputs.last { it.optString("scenario") == "back" && it.optString("stage") == "UP" }.getLong("elapsedMs")
                    ready(browser, "one")
                    // The displayed page can arrive before Gecko publishes the restored
                    // native history index. Require that real callback rather than an
                    // earlier page's cached prearm/canGoForward before the next gesture.
                    await("native forward history after Back") {
                        historyCaptures.any { row ->
                            val registry = row.optJSONObject("registry")
                            row.optString("scenario") == "back" && row.optLong("elapsedMs", -1) >= committedBackUp &&
                                row.optString("stage") == "HISTORY_UPDATED" &&
                                row.optString("source") in setOf("SESSION_STATE", "HISTORY_LIST") &&
                                row.optBoolean("selected") && row.optBoolean("sessionOwned") && row.optBoolean("interactive") &&
                                !row.optBoolean("loading", true) && registry != null && registry.optInt("entriesCount") == 2 &&
                                registry.optInt("currentIndex", -1) == 0 && registry.optBoolean("forwardAvailable")
                        }
                    }
                    receipt.put("nativeForwardHistoryObserved", true)
                    assertEquals(first.id, browser.state.value.tab?.id)
                    main { assertSame(originalSession, engine.session(checkNotNull(browser.state.value.tab), profile)) }
                    receipt.put("backCommittedSameNativeSession", true).put("stage", "forward")
                    // The first commit may legitimately let Gecko restore/refetch its real history.
                    // Only requests BEFORE each next UP must remain unchanged.
                    server.counts.clear()
                    gesture(back = false, cancel = false)
                    ready(browser, "two")
                    receipt.put("forwardCommittedSameNativeSession", true).put("stage", "off")
                    main { browser.updateSettings(browser.state.value.settings.copy(swipeAnywhere = false)) }
                    await("setting off revokes arm") { main { view.get()?.historyGestureReady == false } }
                    server.counts.clear()
                    gesture(back = true, cancel = false, requireArmed = false)
                    delay(300)
                    assertEquals(current.url, browser.state.value.tab?.url)
                    receipt.put("offKeptNativeDocument", true).put("passed", true).put("stage", "complete")
                }
            }
        } catch (error: Throwable) { originalFailure = error; throw error
        } finally {
            val observerFailure = withContext(NonCancellable) {
                runCatching { withTimeout(2000) { main {
                    view.get()?.historyInputObserver = null
                    observedEngine.getAndSet(null)?.historyCaptureObserver = null
                    observedController.set(null)
                } } }.exceptionOrNull()
            }
            val receiptFailure = runCatching {
                receipt.put("observerCleanupConfirmed", observerFailure == null)
                    .put("nativeInputs", JSONArray(nativeInputs)).put("injections", JSONArray(injections))
                    .put("windowReadiness", JSONArray(windowReadiness))
                    .put("historyCaptures", JSONArray(historyCaptures)).put("historyCapturesTruncated", capturesTruncated.get())
                view.get()?.historyLastApz?.let {
                    receipt.put("apz", JSONObject().put("known", it.known).put("handled", it.handled).put("content", it.contentOwned)
                        .put("ignored", it.ignored).put("scrollsLeft", it.scrollsLeft).put("scrollsRight", it.scrollsRight)
                        .put("horizontalOverscroll", it.horizontalOverscroll))
                }
                val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/history-native")
                    .apply { check(isDirectory || mkdirs()) }
                File(folder, "commit-cancel-off.json").writeText(receipt.toString(2))
            }.exceptionOrNull()
            val secondary = listOfNotNull(observerFailure, receiptFailure)
            originalFailure?.let { original -> secondary.forEach(original::addSuppressed) }
                ?: secondary.firstOrNull()?.let { first -> secondary.drop(1).forEach(first::addSuppressed); throw first }
        }
    }
    private suspend fun ready(browser: BrowserController, name: String) = await("owned history document") {
        browser.state.value.page.let { !it.loading && it.progress >= 1f && it.title == "History $name" }
    }
    private suspend fun await(name: String, block: suspend () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 25_000
        while (!block()) { check(SystemClock.elapsedRealtime() < end) { "Timed out: $name" }; delay(20) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }

    private class OwnedHistoryServer : Closeable {
        val counts = ConcurrentHashMap<String, Int>()
        private val running = AtomicBoolean(true)
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val thread = Thread {
            while (running.get()) {
                try { socket.accept().use { client ->
                    client.soTimeout = 3000
                    val input = client.getInputStream().bufferedReader()
                    val path = input.readLine()?.split(' ')?.getOrNull(1) ?: return@use
                    var bytes = 0
                    while (true) { val line = input.readLine() ?: break; bytes += line.length; if (bytes > 8192 || line.isEmpty()) break }
                    val name = path.removePrefix("/").takeIf { it in setOf("one", "two") }
                    if (name != null) counts.merge(name, 1, Int::plus)
                    val body = """<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'>
                        <title>History ${name ?: "other"}</title><style>body{margin:0;overflow-x:visible;touch-action:auto}main{height:1800px;padding:24px}</style>
                        <main><h1>History ${name ?: "other"}</h1><p>Only this exact native document owns this fixture touch area.</p></main>""".trimIndent().toByteArray()
                    val header = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                    client.getOutputStream().apply { write(header.toByteArray()); write(body); flush() }
                } } catch (_: IOException) { /* Closing only our fixture socket stops the loop. */ }
            }
        }.apply { isDaemon = true; start() }
        fun url(name: String) = "http://127.0.0.1:${socket.localPort}/$name"
        override fun close() { running.set(false); socket.close(); thread.join(4000) }
    }
}

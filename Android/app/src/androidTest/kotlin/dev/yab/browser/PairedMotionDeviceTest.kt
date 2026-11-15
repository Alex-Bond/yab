package dev.yab.browser

import android.animation.ValueAnimator
import android.graphics.Rect as NativeRect
import android.os.SystemClock
import android.provider.Settings
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dev.yab.agent.*
import dev.yab.android.EngineTestActivity
import dev.yab.browser.engine.SitePreferences
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in component consumer for PairedMotionTransitions.swift's nine native-input plans.
 * No Compose test rule/virtual clock, screen capture, provider, network or presentation claim.
 * Synthetic public scene data is intentionally separate from whole-Phone fixture equivalence. */
@RunWith(AndroidJUnit4::class)
class PairedMotionDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val marks = CopyOnWriteArrayList<JSONObject>()
    private val events = CopyOnWriteArrayList<JSONObject>()
    private val alive = AtomicBoolean(true)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val began = SystemClock.elapsedRealtimeNanos()
    private lateinit var activity: EngineTestActivity
    private lateinit var output: File
    private lateinit var receipt: JSONObject
    private var parked: ParkedChats? = null
    private var reduced = false
    private var callbacks = 0
    private var claimedWindow: WindowLease? = null
    private val labelSamples = CopyOnWriteArrayList<JSONObject>()
    private val checkpoints = ArrayList<JSONObject>()
    private var lastLabelProjection = ""
    private var pixelsRequested = false
    private var pixelMarker by mutableStateOf(false)
    private var pixelChannel: PairedPixelChannel? = null
    @Volatile private var pixelSource: (() -> Boolean)? = null

    @Test(timeout = 90_000)
    fun consumeOwnedPairedTransition(): Unit = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        check(args.getString("ownedEmulator") == "true")
        val name = checkNotNull(args.getString("pairedMotion"))
        check(name in NAMES)
        val nonce = checkNotNull(args.getString("pairedNonce"))
        check(nonce.matches(Regex("[a-f0-9]{32}")))
        reduced = when (args.getString("pairedReduced")) { "false" -> false; "true" -> true; else -> error("Explicit paired reduced preference required") }
        pixelsRequested = when (args.getString("pairedPixels")) { null -> false; "true" -> true; else -> error("Unknown paired pixel mode") }
        check(!pixelsRequested || name == "pairEyesClose" && !reduced)
        val initialScales = scales()
        check(ValueAnimator.areAnimatorsEnabled() && initialScales.all { it == 1f }) { "Existing native animations must be enabled at scale one" }
        val parent = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation")
        check(parent.isDirectory || parent.mkdirs())
        val folder = File(parent, "paired-motion-$nonce")
        check(folder.mkdir()) { "Paired fixture output must be new" }
        output = File(folder, "paired-motion.json")
        receipt = JSONObject().put("schema", 1).put("scenario", name).put("nonce", nonce)
            .put("phoneState", when { name.startsWith("pairEyes") -> if (name == "pairEyesOpen") "privacy.2" else "privacy.1"
                name.startsWith("pairParked") -> "now.12"; name == "pairMenuOpen" -> "page.1"; else -> "page.6" })
            .put("clock", "real-Recomposer-and-device-uptime").put("composeTestClockUsed", false)
            .put("composeAutoAdvanceApplicable", false).put("nativeAnimatorsEnabled", true)
            .put("animationScalesBefore", JSONArray(initialScales)).put("appLocalReducedRequested", reduced)
            .put("systemReducedPreferenceMatched", !reduced).put("globalAnimationSettingsChanged", false)
            .put("syntheticPublicScene", true).put("productionComponents", true).put("wholePhoneSceneMatched", false)
            .put("requestedTimingIsObservedDelivery", false).put("rawPixelsArchived", false)
            .put("presentedFrameCadenceVerified", false).put("pairedFrameParityVerified", false)
            .put("physicalDeviceSmoothnessVerified", false).put("completed", false)
            .put("pixelCaptureRequested", pixelsRequested).put("pixelStopAcknowledged", false)
        var scenario: ActivityScenario<EngineTestActivity>? = null
        var completed = false
        var failure: Throwable? = null
        try {
            checkpoint("ACTIVITY_LAUNCH")
            scenario = ActivityScenario.launch(EngineTestActivity::class.java)
            scenario.onActivity { activity = it }
            await("owned activity resumed") { activityCurrent() }
            checkpoint("ACTIVITY_RESUMED")
            main {
                val decor = activity.window.decorView
                check(decor.width == 1206 && decor.height == 2622 && kotlin.math.abs(activity.resources.displayMetrics.density - 3f) < .001f)
                check(activity.resources.configuration.fontScale == 1f)
                receipt.put("viewportPx", JSONArray(listOf(decor.width, decor.height))).put("density", 3)
                    .put("fontScale", 1).put("systemInsetsOrFontMetricsMatched", false)
            }
            mark("START")
            checkpoint("START")
            if (pixelsRequested) preparePixels(nonce)
            when {
                name.startsWith("pairEyes") -> eyes(name)
                name.startsWith("pairParked") -> parked(name)
                else -> menu(name)
            }
            completed = true
        } catch (error: Throwable) {
            failure = error
            receipt.put("failureKind", when (error) {
                is kotlinx.coroutines.CancellationException -> "CANCELLATION"
                is AssertionError -> "ASSERTION"
                is IllegalStateException -> "STATE"
                is java.net.SocketTimeoutException -> "SOCKET_TIMEOUT"
                else -> "OTHER"
            })
            runCatching { checkpoint("FAILED") }
            throw error
        } finally {
          try {
            runCatching { checkpoint("FINALLY") }
            val finalScales = scales()
            val settingsUnchanged = finalScales == initialScales && ValueAnimator.areAnimatorsEnabled()
            val channelClosed = pixelChannel?.finish() ?: true
            receipt.put("completed", completed && settingsUnchanged && channelClosed).put("callbackCount", main { callbacks })
                .put("animationScalesAfter", JSONArray(finalScales)).put("animationSettingsUnchanged", settingsUnchanged)
                .put("pixelChannelClosed", channelClosed)
            try { save(); assertTrue("Native animation settings changed during the owned take", settingsUnchanged)
                assertTrue("Owned pixel channel did not stop", channelClosed) }
            finally {
                alive.set(false)
                try { scenario?.close() } finally { main { parked?.close(); scope.cancel() } }
            }
          } catch (cleanup: Throwable) {
              if (failure != null) failure.addSuppressed(cleanup) else throw cleanup
          }
        }
    }

    private suspend fun eyes(name: String) {
        var shut by mutableStateOf(name == "pairEyesOpen")
        var bounds by mutableStateOf(Rect.Zero)
        checkpoint("EYES_CONTENT")
        main {
            activity.setContent { Scene {
                Box(Modifier.fillMaxSize().padding(end = 20.dp, bottom = 342.dp), contentAlignment = Alignment.BottomEnd) {
                    BrowserEyesButton(shut, true, Color.Black, onToggle = {
                        if (alive.get() && activityCurrent()) { callbacks++; shut = !shut; mark("TARGET_CHANGED") }
                    }, modifier = Modifier.onGloballyPositioned { bounds = it.boundsInWindow() })
                }
            } }
        }
        await("initial Eyes layout") { bounds.width > 0 && bounds.height > 0 }
        checkpoint("EYES_LAYOUT")
        val original = main { bounds }
        checkpoint("EYES_WINDOW_WAIT")
        val window = originalWindow()
        checkpoint("EYES_WINDOW_READY")
        checkpoint("EYES_LABEL_WAIT")
        await("initial Eyes native control") { exactLabel(if (shut) "Turn off private input" else "Search privately", window) != null }
        checkpoint("EYES_LABEL_READY")
        val density = main { activity.resources.displayMetrics.density }
        val x = original.right - 19 * density
        val y = original.center.y
        val reverse = when (name) { "pairEyesReverse80" -> 80L; "pairEyesReverse160" -> 160L; else -> null }
        val plan = mutableListOf(Input(20, MotionEvent.ACTION_DOWN), Input(40, MotionEvent.ACTION_UP))
        if (reverse != null) plan += listOf(Input(20 + reverse, MotionEvent.ACTION_DOWN, reversal = true), Input(40 + reverse, MotionEvent.ACTION_UP))
        pixelSource = { bounds.width > 0 && kotlin.math.abs(bounds.right - original.right) < 1 &&
            kotlin.math.abs(bounds.center.y - original.center.y) < 1 && x >= bounds.left && x < bounds.right && y >= bounds.top && y < bounds.bottom }
        mark("READY"); checkpoint("READY")
        pixelChannel?.let { channel ->
            check(windowCurrent(window, checkNotNull(pixelSource)))
            channel.ready(); checkpoint("START_WAIT"); channel.awaitStarted()
            checkpoint("START_ACK")
            check(windowCurrent(window, checkNotNull(pixelSource)))
            main { pixelMarker = true }
        }
        perform(plan, window, current = {
            val target = exactLabel(if (shut) "Turn off private input" else "Search privately", window)
            bounds.width > 0 && kotlin.math.abs(bounds.right - original.right) < 1 && kotlin.math.abs(bounds.center.y - original.center.y) < 1 &&
                x >= bounds.left && x < bounds.right && y >= bounds.top && y < bounds.bottom &&
                target?.contains(x.toInt(), y.toInt()) == true
        }, point = { x to y })
        delay(550)
        val expected = name == "pairEyesClose"
        main { assertEquals(if (reverse == null) 1 else 2, callbacks); assertEquals(expected, shut) }
        check(exactLabel(if (expected) "Turn off private input" else "Search privately", window) != null)
        mark("SETTLED")
        receipt.put("finalCondition", true).put("finalEyesShut", expected)
        pixelChannel?.let { channel ->
            check(windowCurrent(window, checkNotNull(pixelSource)))
            channel.stopReady(); checkpoint("STOP_WAIT"); channel.awaitStopped()
            receipt.put("pixelStopAcknowledged", true)
            checkpoint("STOP_ACK")
        }
    }

    private suspend fun parked(name: String) {
        val chat = AgentChat("paired-synthetic-chat", title = "Anna and the sprint", messages = listOf(
            AgentMessage("paired-user", MessageRole.USER, "and what did she say about the sprint?", 1)), ephemeral = false)
        val repository = AgentRepository(object : ChatPersistence {
            override suspend fun load() = ChatSnapshot(chats = listOf(chat))
            override suspend fun save(snapshot: ChatSnapshot) = Unit
        }, object : LocalAiAdapter { override suspend fun answer(question: LocalQuestion): String = error("No inference in paired motion") }, NoRemote())
        scope.launch { repository.run() }
        await("synthetic public chat loaded") { repository.state.value.loaded }
        val line = main { check(repository.focusConversation(chat.id)); ParkedChats(repository, scope).also { check(it.park()); parked = it } }
        val owner = checkNotNull(line.state.value)
        val presentation = main { checkNotNull(line.presentation(owner)) }
        var bounds by mutableStateOf(Rect.Zero)
        main {
            activity.setContent { Scene {
                val selected by line.state.collectAsState()
                Box(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 96.dp), contentAlignment = Alignment.BottomCenter) {
                    selected?.let { exact -> line.visible(exact, false)?.let { source ->
                        line.presentation(exact)?.let { motion -> Box(Modifier.onGloballyPositioned { bounds = it.boundsInWindow() }) {
                            ParkedChatLine(source, motion, ownerCurrent = { activityCurrent() && line.visible(exact, false) != null },
                                onRestore = { callbacks += 100; line.restore(exact, false) },
                                onLetGo = { if (line.letGo(exact, false)) { callbacks++; mark("TARGET_CHANGED") } })
                        } }
                    } }
                }
            } }
        }
        await("stationary parked target layout") { bounds.width > 0 && presentation.frame.value.phase == ParkedLinePhase.READY }
        val original = main { bounds }
        val window = originalWindow()
        val samples = when (name) {
            "pairParkedReturn" -> listOf(20L to 0.0, 55L to 10.0, 90L to 20.0, 125L to 30.0, 160L to 40.0, 195L to 50.0, 335L to 50.0)
            "pairParkedHeldReverse" -> listOf(20L to 0.0, 70L to 20.0, 120L to 50.0, 170L to 80.0, 220L to 55.0,
                270L to 30.0, 320L to 50.0, 370L to 70.0, 420L to 50.0, 470L to 35.0, 610L to 35.0)
            else -> listOf(20L to 0.0, 85L to 30.0, 150L to 60.0, 215L to 90.0, 280L to 120.0, 345L to 150.0, 485L to 150.0)
        }
        val plan = samples.mapIndexed { index, (time, distance) -> Input(time,
            if (index == 0) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_MOVE, distance,
            reversal = name == "pairParkedHeldReverse" && index in setOf(4, 6, 8)) } + Input(samples.last().first + 20, MotionEvent.ACTION_UP, samples.last().second)
        val density = main { activity.resources.displayMetrics.density }
        mark("READY"); save()
        perform(plan, window, current = { line.state.value == owner && line.visible(owner, false) != null && bounds == original },
            point = { original.center.x + (it.distance * density).toFloat() to original.center.y })
        delay(550)
        main {
            if (name == "pairParkedLeave") { assertNull(line.state.value); assertEquals(1, callbacks) }
            else {
                assertEquals(owner, line.state.value); assertEquals(0, callbacks)
                val final = presentation.frame.value
                assertEquals(ParkedLinePhase.READY, final.phase); assertEquals(0.0, final.offset, 1.0); assertEquals(1.0, final.opacity, .01)
            }
            assertTrue(repository.state.value.chats.any { it.id == chat.id })
        }
        mark("SETTLED"); receipt.put("finalCondition", true).put("originalChatPreserved", true)
    }

    private suspend fun menu(name: String) {
        val tab = BrowserTab("paired-synthetic-tab", "https://example.invalid/paired", "Paired page", createdAt = 1)
        val space = BrowserSpace("paired-synthetic-space", "Personal", tabs = listOf(tab), currentTabId = tab.id)
        val browser = main { BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)
            override suspend fun save(snapshot: BrowserSnapshot) = Unit
        }, NoPageEngine(), scope) }
        await("synthetic page owner loaded") { !browser.state.value.loading }
        val initial = PageMenuContentSnapshot(tab, EnginePageState(url = tab.url, title = tab.title, progress = 1f), SitePreferences(), null, null, null, null, null)
        val lease = PageMenuLease(null, 1, tab.id, space.id, space.websiteProfile, Any(), browser.state.value.surfaceEpoch, 1, url = tab.url)
        var shown by mutableStateOf(false)
        var session by mutableStateOf<BrowserPageMenuSession?>(null)
        var geometry: BrowserPageMenuGeometry? = null
        var release: PageMenuRelease? = null
        fun current() = activityCurrent() && lease.ownsSource(browser.state.value, tab.url)
        fun open() {
            if (!current() || session != null) return
            val g = checkNotNull(geometry)
            session = makePageMenuSession(lease, g, SpacesRect(0.0, 0.0, 402.0, 874.0), SpacesRect(0.0, 0.0, 402.0, 874.0), initial,
                browser, instrumentation.targetContext, ::current,
                closing = { if (it == lease && current()) { shown = false; callbacks++; mark("TARGET_CHANGED") } },
                released = { expected, reason -> if (expected == lease) { release = reason; session = null } },
                reopened = { if (it == lease && current()) shown = true }, onAsk = null, onTranslate = null, onMac = null, onExtensions = null)
            shown = true; callbacks++; mark("TARGET_CHANGED")
        }
        main {
            activity.setContent { Scene {
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val width = maxWidth.value.toDouble(); val height = maxHeight.value.toDouble()
                    val plate = PageMenuRect(70.0, height - 76.0, width - 140.0, 48.0)
                    SideEffect { geometry = BrowserPageMenuGeometry(width, height, 24.0, plate, 420.0) }
                    Box(Modifier.offset(plate.x.dp, plate.y.dp).size(plate.width.dp, plate.height.dp)
                        .background(Color.LightGray).clickable(enabled = session == null && current(), onClick = ::open)
                        .semantics { contentDescription = "Page menu" }, contentAlignment = Alignment.Center) { Text("Paired page") }
                    session?.let { held -> BrowserPageMenuHost(held.entry, shown, held.geometry) }
                }
            } }
        }
        val window = originalWindow()
        await("initial synthetic menu plate") { geometry != null && exactLabel("Page menu", window) != null }
        if (name == "pairMenuClose") {
            main { open() }
            await("initial open menu settled") { session?.entry?.presentation?.frame?.value?.interactive == true && exactLabel("Site Settings", window) != null }
            callbacks = 0
        }
        val held = main { session }
        val target = if (name == "pairMenuOpen") checkNotNull(exactLabel("Page menu", window)) else checkNotNull(exactLabel("Site Settings", window))
        val point = if (name == "pairMenuOpen") target.exactCenterX() to target.exactCenterY()
            else window.bounds.exactCenterX() to (window.bounds.top + window.bounds.height() * .12f)
        if (name == "pairMenuClose") check(checkNotNull(exactLabel("Close Menu", window)).contains(point.first.toInt(), point.second.toInt()))
        mark("READY"); save()
        perform(listOf(Input(20, MotionEvent.ACTION_DOWN), Input(52, MotionEvent.ACTION_UP)), window,
            current = { current() && if (name == "pairMenuOpen") session == null else session === held && held?.entry?.owned() == true }, point = { point })
        delay(550)
        if (name == "pairMenuOpen") {
            main { assertEquals(1, callbacks); check(session?.entry?.presentation?.frame?.value?.interactive == true) }
            check(exactLabel("Site Settings", window) != null)
        } else {
            main { assertEquals(1, callbacks); assertEquals(PageMenuRelease.LANDED, release); assertNull(session) }
            check(exactLabel("Page menu", window) != null)
        }
        mark("SETTLED"); receipt.put("finalCondition", true).put("nativeGeckoOwnerExercised", false)
    }

    @Composable private fun Scene(content: @Composable () -> Unit) {
        BrowserTheme(BrowserAppearance.LIGHT) {
            CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduceMotion = reduced)) {
                Box(Modifier.fillMaxSize().background(Color.White)) {
                    content()
                    if (pixelMarker) Box(Modifier.offset(8.dp, 32.dp).size(4.dp).background(Color.Blue))
                }
            }
        }
    }

    private suspend fun preparePixels(nonce: String) {
        var bounds by mutableStateOf(Rect.Zero)
        checkpoint("CALIBRATION_CONTENT")
        main {
            activity.setContent {
                Canvas(Modifier.fillMaxSize().onGloballyPositioned { bounds = it.boundsInWindow() }) {
                    drawRect(Color.White)
                    for ((point, color) in listOf(Offset(64f, 128f) to Color.Red, Offset(1141f, 128f) to Color.Green,
                        Offset(64f, 2493f) to Color.Blue, Offset(1141f, 2493f) to Color.Yellow, Offset(603f, 1311f) to Color.Magenta)) {
                        drawRect(color, topLeft = point - Offset(8f, 8f), size = Size(16f, 16f))
                    }
                }
            }
        }
        await("owned calibration canvas") { bounds == Rect(0f, 0f, 1206f, 2622f) }
        checkpoint("CALIBRATION_LAYOUT")
        checkpoint("CALIBRATION_WINDOW_WAIT")
        val owner = originalWindow()
        checkpoint("CALIBRATION_WINDOW_READY")
        pixelSource = { bounds == Rect(0f, 0f, 1206f, 2622f) }
        val channel = PairedPixelChannel(nonce) {
            runBlocking {
                withTimeout(1500) {
                    windowCurrent(owner) { activityCurrent() && pixelSource?.invoke() == true &&
                        scales().all { it == 1f } && ValueAnimator.areAnimatorsEnabled() }
                }
            }
        }
        pixelChannel = channel
        val metadata = JSONObject().put("schema", 1).put("nonce", nonce).put("scenario", "pairEyesClose")
            .put("port", channel.port).put("viewportPx", JSONArray(listOf(1206, 2622)))
        val destination = File(output.parentFile, "pixel-channel.json")
        check(!destination.exists())
        File(output.parentFile, "pixel-channel.pending").apply { check(!exists()); writeText(metadata.toString()); check(renameTo(destination)) }
        checkpoint("CALIBRATION_ACK_WAIT")
        channel.awaitCalibrated()
        checkpoint("CALIBRATION_ACK")
        // No pixel read is admitted during this explicit own-scene transition.
        pixelSource = { activityCurrent() }
    }

    private data class WindowLease(val id: Int, val bounds: NativeRect, val token: android.os.IBinder)
    private data class Input(val at: Long, val action: Int, val distance: Double = 0.0, val reversal: Boolean = false)
    private suspend fun originalWindow(): WindowLease {
        var found: WindowLease? = null
        await("original focused own window") {
            if (!activityCurrent()) false else {
                val root = instrumentation.uiAutomation.rootInActiveWindow
                if (root == null) false else try {
                    check(root.packageName?.toString() == instrumentation.targetContext.packageName) { "Foreign active window" }
                    val rect = NativeRect().also(root::getBoundsInScreen)
                    val origin = IntArray(2).also(activity.window.decorView::getLocationOnScreen)
                    check(rect == NativeRect(0, 0, 1206, 2622) && origin.contentEquals(intArrayOf(0, 0))) { "Owned full-window viewport changed" }
                    found = WindowLease(root.windowId, rect, checkNotNull(activity.window.decorView.windowToken)); true
                } finally { root.recycle() }
            }
        }
        return checkNotNull(found).also { claimedWindow = it }
    }
    private fun activityCurrent() = alive.get() && !activity.isFinishing && !activity.isDestroyed && activity.hasWindowFocus() &&
        activity.window.decorView.isAttachedToWindow && ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).any { it === activity } &&
        (claimedWindow?.let { it.token === activity.window.decorView.windowToken } != false)
    private suspend fun windowCurrent(owner: WindowLease, source: () -> Boolean): Boolean {
        if (!main {
            val origin = IntArray(2).also(activity.window.decorView::getLocationOnScreen)
            activityCurrent() && activity.window.decorView.windowToken === owner.token && origin.contentEquals(intArrayOf(0, 0)) &&
                activity.window.decorView.width == owner.bounds.width() && activity.window.decorView.height == owner.bounds.height() && source()
        }) return false
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return false
        return try { root.packageName?.toString() == instrumentation.targetContext.packageName && root.windowId == owner.id &&
            NativeRect().also(root::getBoundsInScreen) == owner.bounds } finally { root.recycle() }
    }
    private suspend fun perform(plan: List<Input>, window: WindowLease, current: () -> Boolean, point: (Input) -> Pair<Float, Float>) {
        check(plan.size in 2..16 && plan.first().action == MotionEvent.ACTION_DOWN && plan.last().action == MotionEvent.ACTION_UP)
        check(plan.zipWithNext().all { it.first.at < it.second.at } && plan.last().at <= 1000)
        val start = SystemClock.uptimeMillis()
        var down = 0L
        var pressed = false
        var last = point(plan.first())
        var failure: Throwable? = null
        mark("STIMULUS_SUBMITTED")
        try {
            for (step in plan) {
                val wait = start + step.at - SystemClock.uptimeMillis()
                if (wait > 0) delay(wait)
                check(windowCurrent(window, current)) { "Original input owner changed" }
                val (x, y) = point(step)
                check(x.isFinite() && y.isFinite() && window.bounds.contains(x.toInt(), y.toInt()))
                val now = SystemClock.uptimeMillis()
                if (step.action == MotionEvent.ACTION_DOWN) { down = now; pressed = true }
                val properties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
                val coordinates = arrayOf(MotionEvent.PointerCoords().apply { this.x = x; this.y = y; pressure = 1f; size = 1f })
                val event = MotionEvent.obtain(down, now, step.action, 1, properties, coordinates, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
                val delivered = try { instrumentation.uiAutomation.injectInputEvent(event, false) } finally { event.recycle() }
                check(events.size < 20)
                events += JSONObject().put("action", action(step.action)).put("plannedOffsetMs", step.at)
                    .put("submittedOffsetMs", (now - start).coerceIn(0, 90_000)).put("callCompletedOffsetMs", (SystemClock.uptimeMillis() - start).coerceIn(0, 90_000))
                    .put("logicalDistance", step.distance).put("accepted", delivered)
                check(delivered) { "Owned native input refused" }
                if (step.reversal) mark("REVERSAL_SUBMITTED")
                if (step.action == MotionEvent.ACTION_UP) pressed = false
                last = x to y
            }
            mark("STIMULUS_COMPLETED")
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (pressed) withContext(NonCancellable) {
                val cleanup = runCatching {
                    withTimeout(2000) {
                        if (windowCurrent(window, current)) {
                            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_CANCEL, last.first, last.second, 0)
                                .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                            try { check(instrumentation.uiAutomation.injectInputEvent(event, false)) }
                            finally { event.recycle() }
                            mark("CANCEL_SUBMITTED")
                        } else mark("CANCEL_OWNER_REFUSED")
                    }
                }
                cleanup.exceptionOrNull()?.let { error -> failure?.addSuppressed(error) ?: throw error }
            }
        }
    }
    private fun exactLabel(label: String, owner: WindowLease): NativeRect? {
        check(label in setOf("Search privately", "Turn off private input", "Page menu", "Site Settings", "Close Menu"))
        val row = JSONObject().put("label", label)
        val root = instrumentation.uiAutomation.rootInActiveWindow
        if (root == null) {
            recordLabel(row.put("rootPresent", false))
            return null
        }
        var complete = true; var visited = 0
        var nullPackages = 0; var foreignPackages = 0; var wrongWindows = 0
        var exactText = 0; var exactDescription = 0; var knownLabelContained = 0; var actionableMatches = 0
        val states = JSONArray()
        val found = mutableListOf<NativeRect>()
        fun visit(node: AccessibilityNodeInfo) {
            val ownPackage = node.packageName?.toString() == instrumentation.targetContext.packageName
            if (node.packageName == null) nullPackages++ else if (!ownPackage) foreignPackages++
            if (node.windowId != owner.id) wrongWindows++
            val ownedNode = ownPackage && node.windowId == owner.id
            val textMatches = ownedNode && node.text?.toString() == label
            val descriptionMatches = ownedNode && node.contentDescription?.toString() == label
            exactText += if (textMatches) 1 else 0
            exactDescription += if (descriptionMatches) 1 else 0
            knownLabelContained += if (ownedNode && (node.text?.toString()?.contains(label) == true || node.contentDescription?.toString()?.contains(label) == true)) 1 else 0
            if ((textMatches || descriptionMatches) && states.length() < 4) {
                val bounds = NativeRect().also(node::getBoundsInScreen)
                states.put(JSONObject().put("textExact", textMatches).put("descriptionExact", descriptionMatches)
                    .put("visible", node.isVisibleToUser).put("enabled", node.isEnabled).put("clickable", node.isClickable)
                    .put("clickAction", node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK })
                    .put("ownPackage", ownPackage).put("sameWindow", node.windowId == owner.id)
                    .put("insideRoot", !bounds.isEmpty && owner.bounds.contains(bounds))
                    .put("bounds", JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).map { it.coerceIn(-5000, 5000) })))
            }
            if (++visited > 512 || node.childCount > 128 || !ownPackage || node.windowId != owner.id) { complete = false; return }
            // Actual FINGER input targets the exact labelled pixels, not an AX click action.
            // Compose exposes the observed Eyes label as visible/enabled without ACTION_CLICK.
            if (node.isVisibleToUser && node.isEnabled && (textMatches || descriptionMatches)) {
                val bounds = NativeRect().also(node::getBoundsInScreen)
                if (!bounds.isEmpty && owner.bounds.contains(bounds)) {
                    found += bounds
                    if (node.isClickable || node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }) actionableMatches++
                } else complete = false
            }
            for (index in 0 until node.childCount) {
                val child = node.getChild(index)
                if (child == null) complete = false else try { visit(child) } finally { child.recycle() }
            }
        }
        return try {
            val sameWindow = root.windowId == owner.id
            val sameBounds = NativeRect().also(root::getBoundsInScreen) == owner.bounds
            row.put("rootPresent", true).put("rootOwned", root.packageName?.toString() == instrumentation.targetContext.packageName)
                .put("sameWindow", sameWindow).put("sameRootBounds", sameBounds)
            if (!sameWindow || !sameBounds) { complete = false; null } else { visit(root); found.singleOrNull().takeIf { complete } }
        } finally {
            row.put("complete", complete).put("visited", visited.coerceAtMost(513)).put("nullPackageNodes", nullPackages.coerceAtMost(513))
                .put("foreignPackageNodes", foreignPackages.coerceAtMost(513)).put("wrongWindowNodes", wrongWindows.coerceAtMost(513))
                .put("exactTextMatches", exactText.coerceAtMost(513)).put("exactDescriptionMatches", exactDescription.coerceAtMost(513))
                .put("knownLabelContained", knownLabelContained.coerceAtMost(513)).put("actionableMatches", actionableMatches.coerceAtMost(513))
                .put("directVisibleEnabledMatches", found.size.coerceAtMost(513))
                .put("matchingStates", states)
            root.recycle(); recordLabel(row)
        }
    }
    private fun recordLabel(row: JSONObject) {
        val projection = row.toString()
        if (projection == lastLabelProjection) return
        lastLabelProjection = projection
        if (labelSamples.size == 12) labelSamples.removeAt(0)
        labelSamples += row
    }
    private fun mark(phase: String) {
        check(phase in setOf("START", "READY", "STIMULUS_SUBMITTED", "TARGET_CHANGED", "REVERSAL_SUBMITTED", "STIMULUS_COMPLETED", "CANCEL_SUBMITTED", "CANCEL_OWNER_REFUSED", "SETTLED"))
        check(marks.size < 48)
        marks += JSONObject().put("phase", phase).put("elapsedNanos", (SystemClock.elapsedRealtimeNanos() - began).coerceIn(0, 90_000_000_000))
    }
    private fun save() {
        receipt.put("marks", JSONArray(marks.toList())).put("inputEvents", JSONArray(events.toList()))
            .put("labelDiagnostics", JSONArray(labelSamples.toList()))
            .put("fixtureCheckpoints", JSONArray(checkpoints.toList()))
        pixelChannel?.let { receipt.put("pixelChannelDiagnostics", it.diagnostics()) }
        val text = receipt.toString(2)
        check(text.toByteArray(Charsets.UTF_8).size <= 32_768)
        val temporary = File(output.parentFile, "paired-motion.pending")
        temporary.writeText(text)
        check(temporary.renameTo(output))
    }
    private fun checkpoint(phase: String) {
        check(phase in CHECKPOINTS && checkpoints.size < 40)
        checkpoints += JSONObject().put("phase", phase).put("elapsedNanos", (SystemClock.elapsedRealtimeNanos() - began).coerceIn(0, 90_000_000_000))
            .put("markCount", marks.size).put("inputCount", events.size).put("labelSampleCount", labelSamples.size)
        receipt.put("fixturePhase", phase)
        save()
    }
    private fun scales() = listOf(Settings.Global.ANIMATOR_DURATION_SCALE, Settings.Global.TRANSITION_ANIMATION_SCALE,
        Settings.Global.WINDOW_ANIMATION_SCALE).map { Settings.Global.getFloat(instrumentation.targetContext.contentResolver, it, 1f) }
    private suspend fun await(name: String, condition: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 15_000
        while (!main(condition)) { check(SystemClock.elapsedRealtime() < end) { "Timed out: $name" }; delay(8) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    private fun action(value: Int) = when (value) { MotionEvent.ACTION_DOWN -> "DOWN"; MotionEvent.ACTION_MOVE -> "MOVE"; MotionEvent.ACTION_UP -> "UP"; else -> error("Unknown paired input") }
    private class NoRemote : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection())
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("No remote provider in paired motion")
        override suspend fun stop(owner: RemoteOwner) = error("No remote provider in paired motion")
        override suspend fun delete(owner: RemoteOwner) = error("No remote provider in paired motion")
        override suspend fun answerApproval(answer: ApprovalAnswer) = error("No approvals in paired motion")
    }
    private class NoPageEngine : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) = Unit
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) = error("No navigation in component consumer")
        override fun goBack(tabId: String) = Unit
        override fun goForward(tabId: String) = Unit
        override fun reload(tabId: String) = Unit
        override fun stop(tabId: String) = Unit
        override fun close(tabId: String) = Unit
        override suspend fun clearWebsiteData(profileIds: Set<String>) = Unit
    }
    companion object {
        private val CHECKPOINTS = setOf("ACTIVITY_LAUNCH", "ACTIVITY_RESUMED", "START", "FAILED", "FINALLY",
            "CALIBRATION_CONTENT", "CALIBRATION_LAYOUT", "CALIBRATION_WINDOW_WAIT", "CALIBRATION_WINDOW_READY",
            "CALIBRATION_ACK_WAIT", "CALIBRATION_ACK", "EYES_CONTENT", "EYES_LAYOUT", "EYES_WINDOW_WAIT",
            "EYES_WINDOW_READY", "EYES_LABEL_WAIT", "EYES_LABEL_READY", "READY", "START_WAIT", "START_ACK", "STOP_WAIT", "STOP_ACK")
        private val NAMES = setOf("pairEyesClose", "pairEyesOpen", "pairEyesReverse80", "pairEyesReverse160", "pairParkedReturn",
            "pairParkedHeldReverse", "pairParkedLeave", "pairMenuOpen", "pairMenuClose")
    }
}

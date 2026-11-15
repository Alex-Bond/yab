package dev.yab.browser

import android.animation.ValueAnimator
import android.app.UiAutomation
import android.graphics.Rect
import android.os.SystemClock
import android.provider.Settings
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Four independent takes: no Compose rule, simulated IME, test clock, animator override or
 * forced public/private state during the stimulus. Input goes through the real Field Eyes. */
class PairedFieldSceneDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private data class Layout(val window: Int, val root: Rect, val eyes: Rect, val pill: Rect, val close: Rect, val pages: Rect)
    private val measurements = JSONArray()
    private val events = JSONArray()
    private val milestones = JSONArray()
    private val readiness = JSONArray()
    private val inputGuards = JSONArray()
    private val sourceReadiness = JSONArray()
    private var lastSourceProjection: String? = null
    private var previousSourceSnapshot: JSONObject? = null
    private var firstSourceLoss: JSONObject? = null
    private var lastReadiness: String? = null
    private val began = SystemClock.elapsedRealtimeNanos()
    private var originalWindow: Pair<Int, Rect>? = null
    private var automation: UiAutomation? = null
    private var automationConnectRequested = false
    private var automationConnected = false

    @Test(timeout = 150_000) fun eyesCloseFullField(): Unit = runBlocking { take("pairEyesClose") }
    @Test(timeout = 150_000) fun eyesOpenFullField(): Unit = runBlocking { take("pairEyesOpen") }
    @Test(timeout = 150_000) fun eyesReverse80FullField(): Unit = runBlocking { take("pairEyesReverse80") }
    @Test(timeout = 150_000) fun eyesReverse160FullField(): Unit = runBlocking { take("pairEyesReverse160") }

    private suspend fun take(name: String) {
        val args = InstrumentationRegistry.getArguments()
        check(args.getString("ownedEmulator") == "true")
        val film = when (args.getString("pairedFieldFilm")) { null -> false; "true" -> true; else -> error("Unknown full Field mode") }
        val nonce = if (film) checkNotNull(args.getString("pairedFieldNonce")) else UUID.randomUUID().toString().replace("-", "")
        check(nonce.matches(Regex("[a-f0-9]{32}")))
        check(name in setOf("pairEyesClose", "pairEyesOpen", "pairEyesReverse80", "pairEyesReverse160"))
        val folder = File(checkNotNull(instrumentation.targetContext.getExternalFilesDir(null)), "instrumentation/paired-field-$nonce")
        check(folder.parentFile?.let { it.isDirectory || it.mkdirs() } == true && folder.mkdir())
        val beforeScales = scales(); check(beforeScales.all { it == 1f } && ValueAnimator.areAnimatorsEnabled())
        val scene = PairedFieldScene.create(nonce)
        var completed = false; var sourceAccepted = false; var stopAcknowledged = false; var readyPublished = false
        var failure: Throwable? = null
        val receipt = JSONObject().put("schema", 1).put("scenario", name).put("nonce", nonce)
            .put("productionBrowserScreen", true).put("productionController", true).put("realGecko", true)
            .put("realOsIme", true).put("composeTestClockUsed", false).put("animatorOverrideUsed", false)
            .put("phoneWorldPublicProjectionSha256", PairedFieldScene.MIRA_ASSET_SHA)
            .put("phoneWorldSha256", PairedFieldScene.PHONE_WORLD_SHA).put("phonePageSha256", PairedFieldScene.FIGMA_SHA)
            .put("selectedNavigationOriginRewritten", true).put("isolatedFixtureProfiles", true)
            .put("inlineChatsSceneMatched", false).put("systemKeyboardMatched", false)
            .put("wholePhoneSceneMatched", false).put("pairedFrameParityVerified", false)
            .put("wholeSceneTimingCoverageVerified", false).put("markerIsPresentationFence", false)
            .put("markerSetElapsedNanos", JSONObject.NULL)
            .put("nativeFrameCadenceVerified", false).put("physicalDeviceSmoothnessVerified", false)
            .put("requestedTimingIsObservedDelivery", false).put("captureRequested", film)
            .put("inputElapsedNanosMeaning", "injection-returned-upper-bound-not-UI-callback-or-presentation")
            .put("betweenEventsGeometrySource", "original-ViewRootForTest-public-semantics-read-only")
            .put("liveGeometryIsPresentationFence", false)
        try {
            mark("SETUP")
            // Acquire the SAME public instrumentation API before an Activity/root is
            // created. Its default accessibility connection permits native window IDs;
            // readiness must not wait on that ID before requesting the connection.
            // Do not put the framework's bounded synchronous connection on Main.
            check(android.os.Looper.myLooper() !== android.os.Looper.getMainLooper())
            automationConnectRequested = true
            mark("AUTOMATION_CONNECT")
            automation = checkNotNull(instrumentation.uiAutomation)
            automationConnected = true
            mark("AUTOMATION_CONNECTED")
            scene.start(name == "pairEyesOpen")
            await("actual own Field and stable real IME", 30_000) { ready(scene) }
            val first = checkNotNull(project(scene))
            originalWindow = first.window to Rect(first.root)
            val source = main { checkNotNull(scene.controller.captureFieldInput()) }
            check(main { scene.current() && scene.controller.fieldInputCurrent(source) })
            observe(scene, "READY")
            sourceAccepted = true
            if (film) {
                val ready = header(nonce, name).put("kind", "owned-field-ready").put("passed", true)
                    .put("geometry", measurements.getJSONObject(measurements.length() - 1))
                environment(scene, ready)
                publish(folder, "ready.json", ready)
                readyPublished = true // The parent may start its recorder before ACK reaches this coroutine.
                waitReceipt(folder, "recording.json", nonce, name, "owned-field-recording", 40_000, scene)
                main { scene.marker = true; receipt.put("markerSetElapsedNanos", elapsed()) }
            }
            mark("STIMULUS_START")
            val reverse = when (name) { "pairEyesReverse80" -> 80L; "pairEyesReverse160" -> 160L; else -> null }
            val initial = name == "pairEyesOpen"
            val x = first.eyes.right - 19f * main { scene.activity.resources.displayMetrics.density }
            val y = first.eyes.exactCenterY()
            val start = SystemClock.uptimeMillis()
            tap(scene, first, x, y, initial, start, 20, 40)
            await("first actual Eyes target") { main { scene.controller.state.value.fieldIsPrivate == !initial } }
            if (reverse == null) observe(scene, "FIRST_TARGET")
            else {
                // Never do a whole UiAutomation AX Binder traversal between the two presses.
                // The immediate target assertion above and every event's live guard remain.
                mark("FIRST_TARGET")
                tap(scene, first, x, y, true, start, 20 + reverse, 40 + reverse)
                await("actual reversed Eyes target") { main { !scene.controller.state.value.fieldIsPrivate } }
                observe(scene, "REVERSED_TARGET")
                val delivered = (0 until events.length()).map { events.getJSONObject(it) }.filter { it.getString("event") == "UP" }
                check(delivered.size == 2)
                val gap = delivered[1].getLong("eventUptimeMillis") - delivered[0].getLong("eventUptimeMillis")
                receipt.put("actualTargetUpGapMillis", gap).put("requestedTargetUpGapMillis", reverse)
                    .put("reversalDeliveryWithin24Millis", kotlin.math.abs(gap - reverse) <= 24)
                assertTrue("Actual delivered reversal missed its bounded requested window", kotlin.math.abs(gap - reverse) <= 24)
                assertTrue("The reversal was not delivered during the original 200 ms lid flight", gap in 1..199)
            }
            delay(550)
            val expected = name == "pairEyesClose"
            main {
                assertTrue(scene.current())
                assertEquals(expected, scene.controller.state.value.fieldIsPrivate)
                assertTrue(scene.controller.state.value.privateLocked)
                assertTrue(scene.controller.state.value.fieldText.isEmpty())
            }
            check(checkNotNull(project(scene)).let { it.eyes.contains(x.toInt(), y.toInt()) })
            observe(scene, "SETTLED")
            mark("SETTLED")
            if (film) {
                publish(folder, "ready-to-stop.json", header(nonce, name).put("kind", "owned-field-ready-to-stop").put("passed", true))
                waitReceipt(folder, "recorder-stopped.json", nonce, name, "owned-field-recorder-stopped", 15_000, scene)
                stopAcknowledged = true; mark("RECORDER_STOPPED")
            }
            completed = true
        } catch (error: Throwable) {
            failure = error
            receipt.put("failureKind", when (error) {
                is CancellationException -> "CANCELLED"; is AssertionError -> "ASSERTION"; is IllegalStateException -> "STATE"; else -> "OTHER"
            })
            throw error
        } finally {
            withContext(NonCancellable) {
                // Even a failed take requests cessation before destroying the original Activity.
                // Reading this exact stop ACK grants no capture, input or fresh source authority.
                val stopFailure = if (film && readyPublished && !stopAcknowledged) runCatching {
                    if (!File(folder, "ready-to-stop.json").exists()) publish(folder, "ready-to-stop.json",
                        header(nonce, name).put("kind", "owned-field-ready-to-stop").put("passed", false))
                    await("owned failed-take recorder stop", 15_000) {
                        val path = File(folder, "recorder-stopped.json")
                        if (!path.isFile) false else {
                            check(path.length() in 1..4096)
                            val value = JSONObject(path.readText())
                            check(value.optInt("schema") == 1 && value.optString("nonce") == nonce &&
                                value.optString("scenario") == name && value.optString("kind") == "owned-field-recorder-stopped" && value.optBoolean("passed"))
                            stopAcknowledged = true; true
                        }
                    }
                }.exceptionOrNull() else null
                val sourceDiagnostic = runCatching {
                    publish(folder, "source-readiness.json", header(nonce, name)
                        .put("kind", "owned-field-source-readiness").put("snapshots", sourceReadiness)
                        .put("firstSourceLoss", firstSourceLoss ?: JSONObject.NULL)
                        .put("diagnosticOnly", true).put("acceptancePredicatesChanged", false))
                }
                val cleanup = runCatching {
                    val afterScales = scales()
                    val unchanged = afterScales == beforeScales && ValueAnimator.areAnimatorsEnabled()
                    receipt.put("completed", completed && unchanged).put("passed", completed && unchanged && (!film || stopAcknowledged))
                        .put("sourceAccepted", sourceAccepted)
                        .put("recorderStopAcknowledged", stopAcknowledged).put("scalesBefore", JSONArray(beforeScales))
                        .put("scalesAfter", JSONArray(afterScales)).put("globalAnimationSettingsUnchanged", unchanged)
                        .put("measurements", measurements).put("inputEvents", events).put("milestones", milestones)
                        .put("readiness", readiness).put("inputGuards", inputGuards)
                        .put("automationConnectRequested", automationConnectRequested)
                        .put("automationConnectedBeforeScene", automationConnected)
                        .put("sourceReadinessPublished", sourceDiagnostic.isSuccess)
                    if (sourceAccepted) environment(scene, receipt)
                    publish(folder, "paired-field.json", receipt)
                    check(unchanged)
                }
                val close = runCatching { scene.close() }
                for (error in listOfNotNull(stopFailure, sourceDiagnostic.exceptionOrNull(), cleanup.exceptionOrNull(), close.exceptionOrNull())) {
                    if (failure != null) failure.addSuppressed(error) else { failure = error }
                }
                if (!completed && failure == null) error("Incomplete owned Field take")
                if (completed) failure?.let { throw it }
            }
        }
    }

    private var readyBounds: Map<String, Rect>? = null
    private var readySince = 0L
    private suspend fun ready(scene: PairedFieldScene): Boolean {
        val probe = main { scene.geometry().also { recordSourceReadiness(scene, it) } }
        val resumed = main { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).any { it === scene.activity } }
        val ime = main { ViewCompat.getRootWindowInsets(scene.activity.window.decorView)?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0 }
        val density = main { scene.activity.resources.displayMetrics.density }
        val keyboardMatch = ime > 0 && probe.keyboard?.let { kotlin.math.abs(it * density - ime) <= .001f } == true
        val settled = resumed && probe.settled && keyboardMatch
        recordReadiness(probe, resumed, ime, keyboardMatch, false)
        if (!settled) { readyBounds = null; return false }
        if (probe.bounds != readyBounds) { readyBounds = probe.bounds.mapValues { Rect(it.value) }; readySince = SystemClock.uptimeMillis() }
        if (SystemClock.uptimeMillis() - readySince < 96) return false
        val ax = project(scene) ?: return false
        val matches = liveMatches(probe, ax)
        recordReadiness(probe, resumed, ime, keyboardMatch, matches)
        return matches
    }

    /** Separate capped observer artifact; never adds these fields to the 24-row main receipt. */
    private fun recordSourceReadiness(scene: PairedFieldScene, probe: PairedFieldScene.GeometryProbe) {
        val value = JSONObject().put("sourceCurrent", probe.source)
        scene.sourceComponents().forEach { (key, accepted) -> value.put(key, accepted) }
        value.put("semanticsVisited", probe.traversal.visited).put("semanticsForeignRoots", probe.traversal.foreignRoots)
            .put("semanticsUnplaced", probe.traversal.unplaced).put("fixedTagsFound", probe.traversal.fixedTagsFound)
            .put("semanticsCapped", probe.traversal.capped)
        val projection = value.toString()
        value.put("elapsedNanos", elapsed())
        val previous = previousSourceSnapshot
        if (firstSourceLoss == null && previous?.optBoolean("sourceCurrent") == true && !probe.source) {
            // Reserved independently of the six most recent tree/component changes.
            firstSourceLoss = JSONObject().put("before", JSONObject(previous.toString()))
                .put("after", JSONObject(value.toString()))
        }
        previousSourceSnapshot = JSONObject(value.toString())
        if (projection != lastSourceProjection) {
            if (sourceReadiness.length() == 6) sourceReadiness.remove(0)
            sourceReadiness.put(value); lastSourceProjection = projection
        }
    }
    private fun liveMatches(probe: PairedFieldScene.GeometryProbe, layout: Layout) = probe.window == layout.window &&
        probe.rootBounds == layout.root && probe.bounds["browser.field.eyes"] == layout.eyes &&
        probe.bounds["browser.field.pill"] == layout.pill && probe.bounds["browser.field.close"] == layout.close &&
        probe.bounds["browser.field.pages"] == layout.pages
    private fun recordReadiness(probe: PairedFieldScene.GeometryProbe, resumed: Boolean, ime: Int, keyboardMatch: Boolean, axMatch: Boolean) {
        val value = JSONObject().put("sourceCurrent", probe.source).put("originalRootOwned", probe.rootOwned)
            .put("activityResumed", resumed).put("rootResumed", probe.lifecycleResumed).put("pendingLayout", probe.pendingLayout)
            .put("completeFixedTags", probe.complete).put("fieldProgress", probe.progress ?: JSONObject.NULL)
            .put("fieldClosing", probe.closing ?: JSONObject.NULL).put("fieldKeyboardDp", probe.keyboard ?: JSONObject.NULL)
            .put("actualImeBottomPx", ime.coerceIn(0, 2622)).put("actualKeyboardMatches", keyboardMatch)
            .put("focusedNodes", probe.focusedNodes).put("editableNodes", probe.editableNodes).put("nativeAxMatches", axMatch)
            .put("automationConnectRequested", automationConnectRequested).put("automationConnectedBeforeScene", automationConnected)
            .put("composeRootPresent", probe.preflight.composeRootPresent).put("viewAttached", probe.preflight.viewAttached)
            .put("originalWindowToken", probe.preflight.originalWindowToken).put("originalDecorRoot", probe.preflight.originalDecorRoot)
            .put("viewWindowFocused", probe.preflight.viewWindowFocused).put("nativeNodePresent", probe.preflight.nativeNodePresent)
            .put("nativePackageMatches", probe.preflight.nativePackageMatches).put("nativeWindowIdKnown", probe.preflight.nativeWindowIdKnown)
            .put("nativeRootBoundsNonempty", probe.preflight.nativeRootBoundsNonempty)
        val projection = value.toString()
        if (projection != lastReadiness) {
            if (readiness.length() == 24) readiness.remove(0)
            readiness.put(value.put("elapsedNanos", elapsed())); lastReadiness = projection
        }
    }

    /** Exact named production semantics only. No arbitrary labels, app content or system tree is saved. */
    private suspend fun project(scene: PairedFieldScene): Layout? {
        if (!main { scene.current() }) return null
        val root = checkNotNull(automation).rootInActiveWindow ?: return null
        val own = instrumentation.targetContext.packageName
        try {
            check(root.packageName?.toString() == own)
            val bounds = Rect().also(root::getBoundsInScreen)
            val window = root.windowId
            originalWindow?.let { check(it.first == window && it.second == bounds) }
            var count = 0; var complete = true
            val found = mutableMapOf<String, MutableList<Rect>>()
            val tags = setOf("browser.field.eyes", "browser.field.pill", "browser.field.close", "browser.field.pages")
            fun visit(node: AccessibilityNodeInfo, enabled: Boolean) {
                if (count >= 512) { complete = false; return }; count++
                if (node.packageName?.toString() != own || node.windowId != window) { complete = false; return }
                val active = enabled && node.isEnabled
                val id = node.viewIdResourceName
                if (id in tags && node.isVisibleToUser) {
                    val rect = Rect().also(node::getBoundsInScreen)
                    if (!rect.isEmpty && bounds.contains(rect) && (id != "browser.field.eyes" || active))
                        found.getOrPut(checkNotNull(id)) { mutableListOf() }.add(rect)
                }
                if (node.childCount > 128) complete = false
                for (i in 0 until node.childCount.coerceAtMost(128)) {
                    val child = node.getChild(i)
                    if (child == null) complete = false else try { visit(child, active) } finally { child.recycle() }
                }
            }
            visit(root, true)
            if (!complete || tags.any { found[it]?.size != 1 }) return null
            return Layout(window, bounds, found.getValue("browser.field.eyes").single(), found.getValue("browser.field.pill").single(),
                found.getValue("browser.field.close").single(), found.getValue("browser.field.pages").single())
        } finally { root.recycle() }
    }

    private suspend fun observe(scene: PairedFieldScene, phase: String) {
        check(phase in setOf("READY", "FIRST_TARGET", "REVERSED_TARGET", "SETTLED") && measurements.length() < 8)
        val layout = checkNotNull(project(scene))
        val liveMatchesNative = main { liveMatches(scene.geometry(), layout) }
        if (phase in setOf("READY", "SETTLED")) check(liveMatchesNative)
        val ime = main { checkNotNull(ViewCompat.getRootWindowInsets(scene.activity.window.decorView)).getInsets(WindowInsetsCompat.Type.ime()).bottom }
        val density = main { scene.activity.resources.displayMetrics.density }
        main {
            val decor = scene.activity.window.decorView
            check(decor.width == 1206 && decor.height == 2622 && kotlin.math.abs(density - 3f) < .001f && scene.activity.resources.configuration.fontScale == 1f)
        }
        measurements.put(JSONObject().put("phase", phase).put("elapsedNanos", elapsed()).put("ownerCurrent", main { scene.current() })
            .put("viewportPx", JSONArray(listOf(1206, 2622))).put("density", density).put("fontScale", 1)
            .put("actualImeBottomPx", ime).put("livePlacedBoundsMatchNativeAx", liveMatchesNative).put("eyesBoundsPx", rect(layout.eyes)).put("pillBoundsPx", rect(layout.pill))
            .put("closeBoundsPx", rect(layout.close)).put("pagesBoundsPx", rect(layout.pages)).put("rootBoundsPx", rect(layout.root))
            .put("iosHistoricalEyesBeforePoints", JSONArray(listOf(295, 516, 40, 36)))
            .put("iosHistoricalOriginMatches", layout.eyes.left == 885 && layout.eyes.top == 1548 && layout.eyes.width() == 120 && layout.eyes.height() == 108))
    }

    private suspend fun tap(scene: PairedFieldScene, initial: Layout, x: Float, y: Float, privateBefore: Boolean,
        start: Long, downOffset: Long, upOffset: Long) {
        val input = main { checkNotNull(scene.controller.captureFieldInput()).also { check(scene.controller.state.value.fieldIsPrivate == privateBefore) } }
        suspend fun current(kind: String) = main {
            check(kind in setOf("DOWN", "UP", "CANCEL") && inputGuards.length() < 12)
            val live = scene.geometry()
            val source = scene.current() && scene.controller.fieldInputCurrent(input)
            val window = live.window == initial.window && live.rootBounds == initial.root
            val point = live.bounds["browser.field.eyes"]?.contains(x.toInt(), y.toInt()) == true
            val pill = live.bounds["browser.field.pill"] == initial.pill
            val accepted = source && live.source && live.rootOwned && live.lifecycleResumed && live.complete && window && point && pill
            // A pending future measure is normal during the word's width animation. This reads
            // the currently placed touch rectangles; it never forces or guesses that future layout.
            inputGuards.put(JSONObject().put("event", kind).put("elapsedNanos", elapsed()).put("sourceCurrent", source)
                .put("originalRootOwned", live.rootOwned).put("rootResumed", live.lifecycleResumed)
                .put("pendingFutureLayout", live.pendingLayout).put("completeFixedTags", live.complete)
                .put("originalWindowMatches", window).put("pointStillInside", point).put("originalPillMatches", pill).put("accepted", accepted))
            accepted
        }
        var down = 0L; var pressed = false; var failure: Throwable? = null
        fun send(action: Int, planned: Long): Boolean {
            val now = SystemClock.uptimeMillis()
            if (action == MotionEvent.ACTION_DOWN) down = now
            val properties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
            val coordinates = arrayOf(MotionEvent.PointerCoords().apply { this.x = x; this.y = y; pressure = 1f; size = 1f })
            val event = MotionEvent.obtain(down, now, action, 1, properties, coordinates, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            val accepted = try { checkNotNull(automation).injectInputEvent(event, true) } finally { event.recycle() }
            check(events.length() < 12)
            events.put(JSONObject().put("event", when (action) { MotionEvent.ACTION_DOWN -> "DOWN"; MotionEvent.ACTION_UP -> "UP"; else -> "CANCEL" })
                .put("plannedOffsetMillis", planned).put("actualOffsetMillis", now - start).put("eventUptimeMillis", now)
                .put("elapsedNanos", elapsed())
                .put("injectionAccepted", accepted).put("x", x).put("y", y))
            return accepted
        }
        try {
            delay((start + downOffset - SystemClock.uptimeMillis()).coerceAtLeast(0))
            check(current("DOWN")); check(send(MotionEvent.ACTION_DOWN, downOffset)); pressed = true
            delay((start + upOffset - SystemClock.uptimeMillis()).coerceAtLeast(0))
            check(current("UP")); check(send(MotionEvent.ACTION_UP, upOffset)); pressed = false
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (pressed) withContext(NonCancellable) {
                runCatching { withTimeout(2000) { check(current("CANCEL")); check(send(MotionEvent.ACTION_CANCEL, -1)) } }
                    .exceptionOrNull()?.let { cleanup -> failure?.addSuppressed(cleanup) ?: throw cleanup }
            }
        }
    }

    private fun header(nonce: String, scenario: String) = JSONObject().put("schema", 1).put("nonce", nonce).put("scenario", scenario)
    private suspend fun environment(scene: PairedFieldScene, output: JSONObject) = main {
        val decor = scene.activity.window.decorView
        val refresh = checkNotNull(scene.activity.display).refreshRate
        check(refresh.isFinite() && refresh in 24f..240f)
        output.put("width", decor.width).put("height", decor.height)
            .put("density", scene.activity.resources.displayMetrics.density).put("fontScale", scene.activity.resources.configuration.fontScale)
            .put("refreshHz", refresh).put("refreshHzIsPresentedCadence", false)
            .put("actualIme", (ViewCompat.getRootWindowInsets(decor)?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0) > 0)
            .put("sourceOwnerCurrent", scene.current()).put("nativeAnimatorsEnabled", ValueAnimator.areAnimatorsEnabled())
            .put("animationScalesOne", scales().all { it == 1f }).put("markerRectPx", JSONArray(listOf(24, 96, 12, 12)))
            .put("markerVisible", scene.marker).put("wholePhoneSceneMatched", false)
    }
    private fun publish(folder: File, name: String, value: JSONObject) {
        check(name in setOf("ready.json", "ready-to-stop.json", "paired-field.json", "source-readiness.json"))
        val maximum = if (name == "source-readiness.json") 16_384 else 32_768
        val bytes = value.toString(2).toByteArray(); check(bytes.size in 1..maximum)
        val destination = File(folder, name); check(!destination.exists())
        val temporary = File(folder, "$name.pending"); check(!temporary.exists()); temporary.writeBytes(bytes)
        check(temporary.renameTo(destination))
    }
    private suspend fun waitReceipt(folder: File, file: String, nonce: String, scenario: String, kind: String, timeout: Long, scene: PairedFieldScene) {
        await("owned recorder handshake", timeout) {
            check(main { scene.current() }); check(project(scene) != null)
            val path = File(folder, file)
            if (!path.isFile) false else {
                check(path.length() in 1..4096)
                val value = JSONObject(path.readText())
                check(value.optInt("schema") == 1 && value.optString("nonce") == nonce && value.optString("scenario") == scenario && value.optString("kind") == kind)
                check(value.optBoolean("passed")); true
            }
        }
    }
    private fun mark(phase: String) {
        check(phase in setOf("SETUP", "AUTOMATION_CONNECT", "AUTOMATION_CONNECTED", "STIMULUS_START", "FIRST_TARGET", "SETTLED", "RECORDER_STOPPED") && milestones.length() < 8)
        milestones.put(JSONObject().put("phase", phase).put("elapsedNanos", elapsed()))
    }
    private fun elapsed() = (SystemClock.elapsedRealtimeNanos() - began).coerceIn(0, 150_000_000_000)
    private fun rect(value: Rect) = JSONArray(listOf(value.left, value.top, value.right, value.bottom))
    private fun scales() = listOf(Settings.Global.ANIMATOR_DURATION_SCALE, Settings.Global.TRANSITION_ANIMATION_SCALE,
        Settings.Global.WINDOW_ANIMATION_SCALE).map { Settings.Global.getFloat(instrumentation.targetContext.contentResolver, it, 1f) }
    private suspend fun await(reason: String, timeout: Long = 15_000, current: suspend () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeout
        while (!current()) { check(SystemClock.elapsedRealtime() < until) { "Timed out: $reason" }; delay(8) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
}

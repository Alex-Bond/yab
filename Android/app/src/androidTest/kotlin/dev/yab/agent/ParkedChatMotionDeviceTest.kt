package dev.yab.agent

import android.graphics.Rect as AndroidRect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
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
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real native input and Recomposer draw callbacks. Synthetic local draft, no provider or AI answer. */
@RunWith(AndroidJUnit4::class)
class ParkedChatMotionDeviceTest {
    private class Memory : ChatPersistence {
        override suspend fun load() = ChatSnapshot()
        override suspend fun save(snapshot: ChatSnapshot) = Unit
    }
    private class Remote : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection(account = "parked-motion-fixture"))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("This fixture cannot send")
        override suspend fun stop(owner: RemoteOwner) = Unit
        override suspend fun delete(owner: RemoteOwner) = error("This fixture cannot delete a remote conversation")
        override suspend fun answerApproval(answer: ApprovalAnswer) = error("This fixture cannot answer an approval")
    }
    private data class Draw(val pose: ParkedLineFrame, val bounds: Rect, val nanos: Long, val ownerCurrent: Boolean, val chatPresent: Boolean)
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val events = CopyOnWriteArrayList<JSONObject>()
    private val plans = CopyOnWriteArrayList<JSONObject>()
    private val readiness = CopyOnWriteArrayList<String>()

    @Test(timeout = 90_000)
    fun actualShortDragReturnsAndSubThresholdFastFlickLeavesBeforeDeletingTheExactDraft(): Unit = runBlocking {
        fixture("gesture") { _, repository, line, frames, activity ->
            val original = line.state.value!!
            val originalMotion = main { line.presentation(original)!! }
            gesture(line, frames, activity, original, listOf(10.0, 20.0, 30.0, 40.0, 50.0), 35, 140, MotionEvent.ACTION_UP)
            await("actual return draw") { frames.any { it.pose.phase == ParkedLinePhase.RETURNING && it.pose.offset > 0 } }
            await("return reaches its original place") { originalMotion.frame.value.phase == ParkedLinePhase.READY }
            assertEquals(original, line.state.value)
            val began = System.nanoTime()
            // Native owner/root checks take real time. A requested 2 ms pause is not an
            // observed 2 ms touch interval. Stay below the 110 pt distance gate, but use
            // enough physical travel for an actual native velocity-only release.
            gesture(line, frames, activity, original, listOf(30.0, 60.0, 90.0), 2, 0, MotionEvent.ACTION_UP)
            await("native short flick enters its real flight") { frames.any { it.nanos >= began && it.pose.phase == ParkedLinePhase.LEAVING } }
            val flight = frames.first { it.nanos >= began && it.pose.phase == ParkedLinePhase.LEAVING }
            // The policy gates on speed magnitude; its departure direction comes
            // from the original translation. Native least-squares velocity can
            // reverse sign across an irregularly delivered final sample.
            assertTrue("A sub-threshold flick must use the actual velocity gate", kotlin.math.abs(flight.pose.velocity) > 650)
            assertEquals(90.0, events.last().getDouble("logicalX"), 0.0)
            assertTrue(events.last().getDouble("logicalX") < 110)
            assertTrue("The departing frame must retain its exact source", flight.ownerCurrent && flight.chatPresent)
            await("exact original draft deleted only after flight") { line.state.value == null && repository.state.value.chats.none { it.id == original.chat } }
            assertTrue(frames.any { it.nanos >= began && it.pose.phase == ParkedLinePhase.LEAVING && it.pose.offset > 90 && it.pose.opacity in 0.0..1.0 })
        }
    }

    @Test(timeout = 90_000)
    fun cancelledLongDragAndReparkOrReconnectCannotCompleteAnOldGeneration(): Unit = runBlocking {
        fixture("owner") { remote, repository, line, frames, activity ->
            val first = line.state.value!!
            val firstMotion = main { line.presentation(first)!! }
            gesture(line, frames, activity, first, listOf(45.0, 90.0, 135.0, 180.0), 25, 0, MotionEvent.ACTION_CANCEL)
            await("cancelled long drag actually followed its pointer") { frames.any { it.pose.phase == ParkedLinePhase.DRAGGING && it.pose.offset >= 135 } }
            await("cancelled long drag returns") { firstMotion.frame.value.phase == ParkedLinePhase.READY }
            assertTrue(frames.none { it.pose.phase == ParkedLinePhase.LEAVING })
            assertEquals(first, line.state.value); assertTrue(repository.state.value.chats.any { it.id == first.chat })
            val old = main { line.presentation(first)!! }
            main { old.leave(1.0, System.nanoTime(), false) }
            await("first actual flight draw") { frames.any { it.pose.phase == ParkedLinePhase.LEAVING } }
            main { assertTrue(line.park()) }
            val replacement = line.state.value!!
            assertEquals(first.chat, replacement.chat); assertNotEquals(first.generation, replacement.generation)
            delay(250)
            assertFalse(main { old.claimCompletion() }); assertFalse(main { line.letGo(first, false) })
            assertEquals(replacement, line.state.value); assertTrue(repository.state.value.chats.any { it.id == replacement.chat })
            val next = main { line.presentation(replacement)!! }
            main { next.leave(1.0, System.nanoTime(), false); remote.connection.value = remote.connection.value.copy(epoch = 1) }
            await("same-account reconnect retires the presentation") { line.state.value == null }
            delay(250)
            assertFalse(main { next.claimCompletion() }); assertFalse(main { line.letGo(replacement, false) })
            assertTrue(repository.state.value.chats.any { it.id == replacement.chat })
        }
    }

    private suspend fun fixture(kind: String,
        body: suspend (Remote, AgentRepository, ParkedChats, CopyOnWriteArrayList<Draw>, EngineTestActivity) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        require(kind in setOf("gesture", "owner"))
        val remote = Remote()
        val local = object : LocalAiAdapter { override suspend fun answer(question: LocalQuestion): String = error("No inference in a motion fixture") }
        val repository = AgentRepository(Memory(), local, remote)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val frames = CopyOnWriteArrayList<Draw>()
        val began = System.nanoTime()
        var scenario: ActivityScenario<EngineTestActivity>? = null
        lateinit var line: ParkedChats
        lateinit var host: EngineTestActivity
        var completed = false
        var lineCreated = false
        try {
            scenario = ActivityScenario.launch(EngineTestActivity::class.java)
            scope.launch { repository.run() }
            await("fixture repository ready") { repository.state.value.loaded && repository.state.value.connection.account == remote.connection.value.account }
            main {
                repository.newChat(ephemeral = true)
                line = ParkedChats(repository, scope); lineCreated = true; assertTrue(line.park())
            }
            checkNotNull(scenario).onActivity { activity ->
                host = activity
                activity.setContent {
                    val owner by line.state.collectAsState()
                    BrowserTheme(BrowserAppearance.SYSTEM) {
                        CompositionLocalProvider(LocalParkedLineAnimationsEnabled provides true,
                            LocalParkedLineDrawObserver provides { pose, bounds, nanos ->
                                if (frames.size < 400) {
                                    val current = line.state.value
                                    frames.add(Draw(pose, bounds, nanos,
                                        current != null && line.visible(current, false) != null,
                                        current?.let { source -> repository.state.value.chats.any { it.id == source.chat } } == true))
                                }
                            }) {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                owner?.let { expected -> line.visible(expected, false)?.let { chat ->
                                    line.presentation(expected)?.let { motion ->
                                        Box(Modifier.width(300.dp)) {
                                            ParkedChatLine(chat, motion, ownerCurrent = { line.visible(expected, false) != null },
                                                onRestore = { line.restore(expected, false) }, onLetGo = { line.letGo(expected, false) })
                                        }
                                    }
                                } }
                            }
                        }
                    }
                }
            }
            await("owned parked line actually drawn") { frames.any { it.bounds.width > 0 && it.pose.phase == ParkedLinePhase.READY } }
            body(remote, repository, line, frames, host)
            completed = true
        } finally {
            try {
                val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
                val rows = JSONArray()
                frames.take(400).forEach { row -> rows.put(JSONObject().put("phase", row.pose.phase.name)
                    .put("offset", row.pose.offset.coerceIn(-1000.0, 1000.0)).put("opacity", row.pose.opacity)
                    .put("ownerCurrent", row.ownerCurrent).put("chatPresent", row.chatPresent)
                    .put("velocity", row.pose.velocity.coerceIn(-20_000.0, 20_000.0))
                    .put("elapsedMs", ((row.nanos - began) / 1_000_000).coerceIn(0, 120_000))) }
                File(folder, "parked-chat-motion-$kind.json").writeText(JSONObject().put("schema", 1).put("case", kind)
                    .put("completed", completed).put("appLocalAnimationFixture", true).put("providerAcceptance", false).put("presentedFrameOrIosParityVerified", false)
                    .put("nativeTouchDeliveryTimesObserved", false).put("inputClock", "MotionEvent actual uptimeMillis")
                    .put("frames", rows).put("inputPlans", JSONArray(plans.take(4)))
                    .put("inputEvents", JSONArray(events.take(32))).put("readiness", JSONArray(readiness)).toString(2))
            } finally { try { scenario?.close() } finally { main { if (lineCreated) line.close(); scope.cancel() } } }
        }
    }

    private suspend fun gesture(line: ParkedChats, frames: CopyOnWriteArrayList<Draw>, activity: EngineTestActivity,
        owner: ParkedChat, distances: List<Double>, intervalMs: Long, holdMs: Long, terminal: Int) {
        require(distances.size <= 8 && terminal in setOf(MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL))
        require(plans.size < 4 && distances.isNotEmpty() && distances.all { it.isFinite() && it in -500.0..500.0 })
        val gestureIndex = plans.size
        plans.add(JSONObject().put("gesture", gestureIndex).put("logicalMoves", JSONArray(distances))
            .put("requestedIntervalMs", intervalMs).put("requestedHoldMs", holdMs).put("terminal", terminal))
        val snapshot = frames.last { it.bounds.width > 0 }
        val density = main { activity.resources.displayMetrics.density }
        val screenOrigin = main { IntArray(2).also(activity.window.decorView::getLocationOnScreen) }
        val bounds = AndroidRect(snapshot.bounds.left.toInt() + screenOrigin[0], snapshot.bounds.top.toInt() + screenOrigin[1],
            snapshot.bounds.right.toInt() + screenOrigin[0], snapshot.bounds.bottom.toInt() + screenOrigin[1])
        // A Recomposer draw is not a UiAutomation-root readiness acknowledgment. Wait only for
        // this exact source before DOWN; never reacquire another window or retry a started gesture.
        val readinessDeadline = SystemClock.elapsedRealtime() + 15_000
        var window: Int? = null
        fun observed(phase: String) { if (readiness.lastOrNull() != phase && readiness.size < 32) readiness.add(phase) }
        while (window == null) {
            check(main { line.state.value == owner && line.visible(owner, false) != null }) { "Original parked owner changed before DOWN" }
            check(frames.lastOrNull { it.bounds.width > 0 }?.bounds == snapshot.bounds) { "Original parked bounds changed before DOWN" }
            val focused = main { activity.hasWindowFocus() }
            val root = instrumentation.uiAutomation.rootInActiveWindow
            if (root == null) observed("ROOT_NULL") else try {
                check(root.packageName?.toString() == instrumentation.targetContext.packageName) { "Foreign active root before DOWN" }
                check(AndroidRect().also(root::getBoundsInScreen).contains(bounds)) { "Original parked bounds left the owned root" }
                if (focused) { window = root.windowId; observed("OWNED_READY") } else observed("OWNED_NOT_FOCUSED")
            } finally { root.recycle() }
            if (window == null) {
                check(SystemClock.elapsedRealtime() < readinessDeadline) { "Original parked root readiness timed out before DOWN" }
                delay(8)
            }
        }
        val originalWindow = checkNotNull(window)
        fun originalNativeWindow(): Boolean {
            val node = activity.window.decorView.createAccessibilityNodeInfo() ?: return false
            return try { node.windowId == originalWindow } finally { node.recycle() }
        }
        main {
            check(originalNativeWindow())
            check(activity.window.decorView.isAttachedToWindow)
        }
        val touchX = bounds.left + bounds.width() * .2f
        val touchY = bounds.exactCenterY()
        val down = SystemClock.uptimeMillis()
        var pressed = false
        var lastLogical = 0.0
        suspend fun windowCurrent(): Boolean {
            // The actual decor exposes the same native accessibility window ID
            // verified against the owned root before DOWN. Query it on every
            // sample, without a cross-process tree traversal delaying the flick.
            // Never retarget a replacement Activity/window or alter event times.
            return main {
                val decor = activity.window.decorView
                line.state.value == owner && line.visible(owner, false) != null && activity.hasWindowFocus() &&
                    decor.isAttachedToWindow && originalNativeWindow() &&
                    frames.lastOrNull { it.bounds.width > 0 }?.bounds == snapshot.bounds &&
                    IntArray(2).also(decor::getLocationOnScreen).contentEquals(screenOrigin)
            }
        }
        suspend fun send(action: Int, logical: Double, requestedDelayMs: Long = 0) {
            check(windowCurrent()) { "Original parked owner, target or input window changed" }
            val now = SystemClock.uptimeMillis()
            val properties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
            val coordinates = arrayOf(MotionEvent.PointerCoords().apply { this.x = touchX + (logical * density).toFloat(); this.y = touchY; pressure = 1f; size = 1f })
            val event = MotionEvent.obtain(down, now, action, 1, properties, coordinates,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { check(instrumentation.uiAutomation.injectInputEvent(event, false)) }
            finally { event.recycle() }
            lastLogical = logical
            if (events.size < 32) events.add(JSONObject().put("action", action).put("logicalX", logical)
                .put("gesture", gestureIndex).put("requestedDelayMs", requestedDelayMs)
                .put("toolFinger", true).put("touchscreenSource", true)
                .put("eventDeltaMs", (now - down).coerceIn(0, 10_000))
                .put("injectionReturnedDeltaMs", (SystemClock.uptimeMillis() - down).coerceIn(0, 10_000)))
        }
        var failure: Throwable? = null
        try {
            send(MotionEvent.ACTION_DOWN, 0.0); pressed = true
            for (distance in distances) { delay(intervalMs); send(MotionEvent.ACTION_MOVE, distance, intervalMs) }
            if (holdMs > 0) { delay(holdMs); send(MotionEvent.ACTION_MOVE, distances.last(), holdMs) }
            send(terminal, distances.last()); pressed = false
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (pressed) withContext(NonCancellable) {
                val cancelled = runCatching { if (windowCurrent()) send(MotionEvent.ACTION_CANCEL, lastLogical) }
                cancelled.exceptionOrNull()?.let { error -> failure?.addSuppressed(error) ?: throw error }
            }
        }
    }
    private suspend fun await(name: String, predicate: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 15_000
        while (!predicate()) { check(SystemClock.elapsedRealtime() < until) { "Timed out waiting for $name" }; delay(8) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
}

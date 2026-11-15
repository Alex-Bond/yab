package dev.yab.sync

import android.app.UiAutomation
import android.content.Intent
import android.graphics.Rect
import android.os.IBinder
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.agent.*
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Controlled UI consumer only. No provider, sync envelope, authentication or controller answer. */
@RunWith(AndroidJUnit4::class)
class ProviderApprovalUiDeviceTest {
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("synthetic-account",
            listOf(RemoteMac("synthetic-mac", "Synthetic Mac", true, emptySet())), epoch = 7))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        val answers = CopyOnWriteArrayList<ApprovalAnswer>()
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) {
            check(!answer.approved && answer.proof == null && answer.expectedEpoch == connection.value.epoch)
            answers.add(answer)
        }
    }

    private data class Guard(val activity: Boolean, val attached: Boolean, val account: Boolean,
        val epoch: Boolean, val mac: Boolean, val facts: Boolean, val display: Boolean,
        val ready: Boolean, val interactive: Boolean, val idle: Boolean) {
        val current get() = activity && attached && account && epoch && mac && facts && display && ready && interactive && idle
        fun json() = JSONObject().put("activity", activity).put("attached", attached).put("account", account)
            .put("epoch", epoch).put("mac", mac).put("facts", facts).put("display", display)
            .put("ready", ready).put("interactive", interactive).put("idle", idle).put("current", current)
    }

    private data class Target(val window: Int, val root: Rect, val label: Rect)
    private data class Projection(val rootPresent: Boolean, val rootOwned: Boolean, val complete: Boolean,
        val visited: Int, val headerDescription: Int, val headerText: Int, val headerVisible: Int,
        val headerEnabled: Int, val headerClickable: Int, val headerAction: Int,
        val footerText: Int, val footerVisible: Int, val target: Target?) {
        fun json() = JSONObject().put("rootPresent", rootPresent).put("rootOwned", rootOwned).put("complete", complete)
            .put("visited", visited).put("headerDescription", headerDescription).put("headerText", headerText)
            .put("headerVisible", headerVisible).put("headerEnabled", headerEnabled).put("headerClickable", headerClickable)
            .put("headerAction", headerAction).put("footerText", footerText).put("footerVisible", footerVisible)
            .put("uniquePointerTarget", target != null)
            .put("legacySameNodePredicate", complete && headerDescription == 1 && headerVisible == 1 &&
                headerEnabled == 1 && headerClickable == 1).also { value -> target?.let {
                value.put("rootBounds", rect(it.root)).put("labelBounds", rect(it.label))
            } }
    }

    private class Receipt {
        val samples = JSONArray()
        val events = JSONArray()
        var passed = false
        var staleRefused = false
        var phase = "START"
        var cancelled = false
        var cancelRefused = false
        var answers = 0
        var draws = 0
        var readyDraws = 0
        private var last: String? = null
        fun sample(stage: String, guard: Guard, projection: Projection) {
            val row = JSONObject().put("stage", stage).put("guards", guard.json()).put("ax", projection.json())
            val key = row.toString()
            if (key != last && samples.length() < 16) { samples.put(row); last = key }
        }
        fun json() = JSONObject().put("schema", 1).put("controlledUiOnly", true).put("realProviderAcceptance", false)
            .put("composeTestClock", false).put("passed", passed).put("phase", phase).put("staleRefused", staleRefused)
            .put("answers", answers).put("cancelled", cancelled).put("cancelRefused", cancelRefused)
            .put("draws", draws).put("readyDraws", readyDraws).put("pointerAttempted", events.length() > 0)
            .put("samples", samples).put("events", events)
    }

    @Test(timeout = 120_000)
    fun actualHeaderPointerDeclinesOnlyTheFreshDisplayedEpoch(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val port = Port()
        val controller = ApprovalController(port)
        val request = ApprovalRequest("synthetic-question", "synthetic-account", "synthetic-mac", 1,
            System.currentTimeMillis() + 300_000, "Claude", "Delete synthetic draft?", "Controlled public UI fixture",
            ApprovalKind.LINES, lines = listOf("Delete only this synthetic draft."),
            requestDigest = "synthetic-current-facts", permit = "synthetic-permit")
        val requestFacts = request.fingerprint()
        val receipt = Receipt()
        val drawCount = AtomicInteger()
        val readyDraws = AtomicInteger()
        val scenario = ActivityScenario.launch<EngineTestActivity>(Intent(context, EngineTestActivity::class.java))
        var originalActivity: EngineTestActivity? = null
        var token: IBinder? = null
        try {
            scenario.onActivity { original ->
                originalActivity = original
                original.setContent {
                    CompositionLocalProvider(LocalApprovalMotionObserver provides { frame ->
                        drawCount.updateAndGet { (it + 1).coerceAtMost(4096) }
                        if (frame.phase == ApprovalTravel.READY) readyDraws.updateAndGet { (it + 1).coerceAtMost(4096) }
                    }) { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, null) } }
                }
            }
            main { controller.replaceValidated(listOf(request)) }
            receipt.phase = "WAIT_READY"
            await("actual real-clock approval rest") { main {
                controller.trayPresentation.frame.value.phase == ApprovalTravel.READY && readyDraws.get() > 0
            } }
            // Match the existing provider fixture's connection order. This is not an early AX bootstrap fix.
            val automation = instrumentation.uiAutomation
            val activity = checkNotNull(originalActivity)
            main { token = activity.window.decorView.windowToken; checkNotNull(token) }
            suspend fun captured(epoch: Long): Pair<ApprovalDisplayLease, suspend () -> Guard> {
                val lease = main { checkNotNull(controller.captureDisplayed(request)) }
                val guard: suspend () -> Guard = { main {
                    val connection = port.connection.value
                    val state = controller.state.value
                    val frame = controller.trayPresentation.frame.value
                    Guard(!activity.isFinishing && !activity.isDestroyed && activity.lifecycle.currentState == Lifecycle.State.RESUMED,
                        activity.window.decorView.isAttachedToWindow && activity.window.decorView.windowToken == token,
                        connection.account == request.account, connection.epoch == epoch,
                        connection.macs.any { it.id == request.mac },
                        state.requests.any { it.fingerprint() == requestFacts },
                        controller.isDisplayedCurrent(lease) && frame.content?.let {
                            it.key.epoch == epoch && it.key.generation == lease.generation &&
                                it.request.fingerprint() == requestFacts && it.action?.let(controller::isDisplayedCurrent) == true
                        } == true,
                        frame.phase == ApprovalTravel.READY, frame.interactive, state.busy == null && state.error == null)
                } }
                return lease to guard
            }
            val (_, oldGuard) = captured(7)
            receipt.phase = "ORIGINAL_AX"
            stableTarget(automation, context.packageName, oldGuard, receipt, "ORIGINAL")
            main {
                port.connection.value = port.connection.value.copy(epoch = 8)
                controller.replaceValidated(listOf(request))
            }
            receipt.phase = "STALE_RECONNECT"
            receipt.staleRefused = !press(automation, context.packageName, oldGuard, receipt, "STALE")
            assertTrue("The original same-facts owner must refuse before any pointer", receipt.staleRefused)
            assertEquals(0, receipt.events.length())
            assertTrue(port.answers.isEmpty())
            await("fresh epoch actual tray rest") { main {
                val frame = controller.trayPresentation.frame.value
                frame.phase == ApprovalTravel.READY && frame.content?.key?.epoch == 8L &&
                    frame.content?.action?.let(controller::isDisplayedCurrent) == true && controller.captureDisplayed(request) != null
            } }
            val (_, freshGuard) = captured(8)
            receipt.phase = "FRESH_POINTER"
            assertTrue("Only an actual owned pointer may invoke Decline", press(automation, context.packageName, freshGuard, receipt, "FRESH"))
            receipt.phase = "WAIT_NO"
            await("actual UI dispatched one synthetic No") { port.answers.size == 1 }
            val answer = port.answers.single()
            assertFalse(answer.approved); assertNull(answer.proof)
            assertEquals(requestFacts, answer.request.fingerprint()); assertEquals(8L, checkNotNull(answer.expectedEpoch))
            assertTrue("Real frame callbacks must have run", drawCount.get() > 0)
            receipt.passed = true
            receipt.phase = "COMPLETED"
        } finally {
            withContext(NonCancellable) {
                receipt.answers = port.answers.size.coerceAtMost(10)
                receipt.draws = drawCount.get()
                receipt.readyDraws = readyDraws.get()
                try {
                    val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
                    check(folder.isDirectory || folder.mkdirs())
                    val bytes = receipt.json().toString().toByteArray(Charsets.UTF_8)
                    check(bytes.size <= 32 * 1024)
                    File(folder, "provider-approval-ui.json").writeBytes(bytes)
                } finally {
                    main { originalActivity?.setContent {} }
                    scenario.close()
                }
            }
        }
    }

    private suspend fun stableTarget(automation: UiAutomation, ownPackage: String, guard: suspend () -> Guard,
        receipt: Receipt, stage: String): Target {
        var prior: Target? = null
        val deadline = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val current = guard()
            val projection = project(automation, ownPackage)
            receipt.sample(stage, current, projection)
            check(current.current) { "Original approval source refused" }
            check(!projection.rootPresent || projection.rootOwned) { "Foreign active root refused" }
            val target = projection.target
            if (target != null && target == prior) return target
            prior = target
            delay(32)
        }
        error("Timed out waiting for stable unique owned approval header")
    }

    private suspend fun press(automation: UiAutomation, ownPackage: String, guard: suspend () -> Guard,
        receipt: Receipt, stage: String): Boolean {
        val initial = guard()
        val projected = project(automation, ownPackage)
        receipt.sample(stage, initial, projected)
        if (!initial.current) return false
        val target = stableTarget(automation, ownPackage, guard, receipt, stage)
        val x = target.label.exactCenterX(); val y = target.label.exactCenterY()
        var pressed = false
        var failure: Throwable? = null
        val downTime = SystemClock.uptimeMillis()
        suspend fun same(): Boolean {
            val current = guard()
            val next = project(automation, ownPackage)
            receipt.sample(stage, current, next)
            return current.current && next.target == target
        }
        fun event(action: Int): Boolean {
            check(receipt.events.length() < 4)
            val time = SystemClock.uptimeMillis()
            val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
            val coordinates = MotionEvent.PointerCoords().apply { this.x = x; this.y = y; pressure = 1f; size = 1f }
            val value = MotionEvent.obtain(downTime, time, action, 1, arrayOf(properties), arrayOf(coordinates),
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            var accepted = false
            try { accepted = automation.injectInputEvent(value, true); return accepted }
            finally {
                value.recycle()
                receipt.events.put(JSONObject().put("action", when (action) {
                    MotionEvent.ACTION_DOWN -> "DOWN"; MotionEvent.ACTION_UP -> "UP"; else -> "CANCEL"
                }).put("accepted", accepted).put("eventUptimeMillis", time))
            }
        }
        try {
            check(same()) { "Original approval changed before DOWN" }
            pressed = true
            check(event(MotionEvent.ACTION_DOWN)) { "Owned DOWN was not accepted" }
            delay(32)
            check(same()) { "Original approval changed before UP" }
            check(event(MotionEvent.ACTION_UP)) { "Owned UP was not accepted" }
            pressed = false
            return true
        } catch (caught: Throwable) { failure = caught; throw caught }
        finally {
            if (pressed) withContext(NonCancellable) {
                try {
                    val source = guard()
                    val now = project(automation, ownPackage)
                    if (source.current && now.rootOwned && now.complete && now.target?.let {
                        it.window == target.window && it.root == target.root
                    } == true) receipt.cancelled = event(MotionEvent.ACTION_CANCEL)
                    else receipt.cancelRefused = true
                } catch (cleanup: Throwable) {
                    val originalFailure = failure
                    if (originalFailure != null) originalFailure.addSuppressed(cleanup) else throw cleanup
                }
            }
        }
    }

    private fun project(automation: UiAutomation, ownPackage: String): Projection {
        val root = automation.rootInActiveWindow ?: return Projection(false, false, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, null)
        val queue = ArrayDeque<Pair<AccessibilityNodeInfo, Int>>()
        queue.add(root to 0)
        val rootBounds = Rect()
        var window = -1
        var owned = false
        var complete = false
        var visited = 0; var descriptions = 0; var texts = 0; var visible = 0; var enabled = 0
        var clickable = 0; var actions = 0; var footers = 0; var footerVisible = 0
        var candidate: Rect? = null
        try {
            root.getBoundsInScreen(rootBounds)
            window = root.windowId
            owned = root.packageName?.toString() == ownPackage && window >= 0 && !rootBounds.isEmpty
            complete = owned
            while (queue.isNotEmpty()) {
                val (node, depth) = queue.removeFirst()
                try {
                    if (++visited > 512) { complete = false; break }
                    if (node.packageName?.toString() != ownPackage || node.windowId != window) { complete = false; continue }
                    val header = node.contentDescription?.toString() == "Decline approval"
                    if (node.text?.toString() == "Decline approval") texts++
                    if (header) {
                        descriptions++
                        if (node.isVisibleToUser) visible++
                        if (node.isEnabled) enabled++
                        if (node.isClickable) clickable++
                        if (node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }) actions++
                        val bounds = Rect().also(node::getBoundsInScreen)
                        if (node.isVisibleToUser && node.isEnabled && !bounds.isEmpty && rootBounds.contains(bounds)) candidate = bounds
                    }
                    if (node.text?.toString() == "Decline") { footers++; if (node.isVisibleToUser) footerVisible++ }
                    val count = node.childCount
                    if (count !in 0..128 || depth >= 64 && count > 0) { complete = false; continue }
                    repeat(count) { index ->
                        if (queue.size + visited >= 512) complete = false
                        else {
                            val child = node.getChild(index)
                            if (child == null) complete = false else queue.add(child to depth + 1)
                        }
                    }
                } finally { node.recycle() }
            }
        } finally { while (queue.isNotEmpty()) queue.removeFirst().first.recycle() }
        return Projection(true, owned, complete, visited.coerceAtMost(513), descriptions, texts, visible, enabled,
            clickable, actions, footers, footerVisible,
            candidate?.takeIf { complete && descriptions == 1 && visible == 1 && enabled == 1 }?.let { Target(window, rootBounds, it) })
    }

    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    private suspend fun await(label: String, predicate: suspend () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < deadline) { if (predicate()) return; delay(32) }
        throw AssertionError("Timed out waiting for $label")
    }
    private companion object {
        fun rect(value: Rect) = JSONArray(listOf(value.left, value.top, value.right, value.bottom).map { it.coerceIn(-1_000_000, 1_000_000) })
    }
}

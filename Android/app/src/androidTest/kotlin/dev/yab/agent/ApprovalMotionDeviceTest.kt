package dev.yab.agent

import android.content.Intent
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserAccessibilityPreferences
import dev.yab.browser.ui.BrowserTheme
import dev.yab.browser.ui.LocalBrowserAccessibility
import dev.yab.core.sync.Clock
import dev.yab.core.sync.Record
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancelAndJoin
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real Activity/Recomposer frames, never ComposeTestRule's animation clock or a provider result. */
@RunWith(AndroidJUnit4::class)
class ApprovalMotionDeviceTest {
    private val inputEvents = CopyOnWriteArrayList<JSONObject>()
    private class Port(private val answerRelease: CompletableDeferred<Unit>? = null, private val allowApproval: Boolean = false) : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("fixture-account", listOf(RemoteMac("fixture-mac", "Fixture Mac", true, emptySet()),
            RemoteMac("fixture-mac-next", "Next Fixture Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override val approvalResults = MutableStateFlow(emptyList<ApprovalResult>())
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        @Volatile var declines = 0
        @Volatile var approvals = 0
        override suspend fun answerApproval(answer: ApprovalAnswer) {
            val release = checkNotNull(answerRelease) { "Motion fixture must not send an answer" }
            check(answer.approved == allowApproval && (answer.proof != null) == allowApproval)
            if (answer.approved) approvals++ else declines++
            release.await()
        }
    }
    @Test(timeout = 90_000) fun actualTrayFramesRetainExitAndRejectAReconnectedOwner(): Unit = runBlocking {
        fixture(false) { controller, port, frames, first ->
            await("first actual enter and rest") { frames.any { it.phase == ApprovalTravel.ENTERING && it.rise > .1 && it.boundsPx.height > 0 } &&
                controller.trayPresentation.frame.value.phase == ApprovalTravel.READY }
            val next = first.copy(id = "fixture-question-next", title = "Next synthetic question")
            val began = System.nanoTime()
            main { controller.replaceValidated(listOf(next)) }
            await("old request exits before next enters") {
                frames.any { it.uptimeNanos >= began && it.phase == ApprovalTravel.LEAVING && it.rise > .1 } &&
                    controller.trayPresentation.frame.value.content?.request == next && controller.trayPresentation.frame.value.phase == ApprovalTravel.READY
            }
            val old = main { checkNotNull(controller.captureDisplayed(next)) }
            main {
                port.connection.value = port.connection.value.copy(epoch = 1)
                controller.replaceValidated(emptyList())
            }
            await("retired epoch removed") { controller.trayPresentation.frame.value.content == null }
            assertFalse(controller.isDisplayedCurrent(old))
            assertFalse(controller.trayPresentation.frame.value.running)
        }
    }
    @Test(timeout = 90_000) fun reducedTrayUsesActualCrossfadeFramesWithoutTranslation(): Unit = runBlocking {
        fixture(true) { controller, _, frames, first ->
            await("actual reduced enter frames") {
                frames.any { it.opacity > .05 && it.opacity < .95 } && controller.trayPresentation.frame.value.phase == ApprovalTravel.READY
            }
            assertTrue(frames.all { it.rise == 0.0 && it.fold == 0.0 })
            val began = System.nanoTime()
            main { controller.later(first.id) }
            await("actual reduced exit and release") { frames.any { it.uptimeNanos >= began && it.phase == ApprovalTravel.LEAVING && it.opacity in 0.05..0.95 } &&
                controller.trayPresentation.frame.value.content == null }
            val departing = frames.filter { it.uptimeNanos >= began && it.phase == ApprovalTravel.LEAVING }
            assertTrue(departing.isNotEmpty())
            assertTrue(departing.all { it.rise == 0.0 && it.fold == 0.0 })
            assertTrue(departing.maxOf { it.boundsPx.top } - departing.minOf { it.boundsPx.top } < 1f)
        }
    }
    @Test(timeout = 90_000) fun actualHeaderPullRegrabAndShortFlickKeepTheirAcceptedExitVelocity(): Unit = runBlocking {
        val release = CompletableDeferred<Unit>()
        fixture(false, release, artifact = "gesture") { controller, port, frames, _ ->
            await("actual tray rest") { controller.trayPresentation.frame.value.phase == ApprovalTravel.READY && frames.any { it.boundsPx.height > 0 } }
            val density = frames.last().density
            suspend fun point(): Pair<Float, Float> = main { frames.last().boundsPx.let { (it.left + it.width * .35f) to (it.top + 30 * density) } }
            val (x, y) = point()
            val down = SystemClock.uptimeMillis()
            touch(MotionEvent.ACTION_DOWN, down, x, y)
            for (i in 1..5) { delay(50); touch(MotionEvent.ACTION_MOVE, down, x, y + i * 6 * density) }
            delay(180); touch(MotionEvent.ACTION_MOVE, down, x, y + 30 * density)
            touch(MotionEvent.ACTION_UP, down, x, y + 30 * density)
            await("short pull actually springs back") { controller.trayPresentation.frame.value.drag in 1.0..25.0 }
            assertEquals(0, port.declines)
            val beforeRegrab = controller.trayPresentation.frame.value.drag
            val (rx, ry) = point()
            val ownRoot = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow)
            try { check(ownRoot.packageName?.toString() == InstrumentationRegistry.getInstrumentation().targetContext.packageName) }
            finally { ownRoot.recycle() }
            val captured = main { checkNotNull(controller.captureDisplayed(checkNotNull(controller.trayPresentation.frame.value.content).request)) }
            assertTrue(controller.isDisplayedCurrent(captured))
            val redown = SystemClock.uptimeMillis()
            touch(MotionEvent.ACTION_DOWN, redown, rx, ry, synchronous = false)
            // Regrab starts at a live offset, rather than resetting to the resting tray.
            assertTrue(beforeRegrab > 0)
            // Waiting for every dispatched MOVE can turn an 8ms caller delay into a slow
            // gesture on a loaded emulator. Queue real event uptimes, never invented ones.
            // The preceding full run emitted only 36dp in 77ms, below the real
            // velocity gate. Keep real event uptimes and use four moves over 48dp;
            // the unchanged assertion below still requires a velocity-only exit.
            for (index in 1..4) { delay(2); touch(MotionEvent.ACTION_MOVE, redown, rx, ry + index * 12 * density, synchronous = false) }
            touch(MotionEvent.ACTION_UP, redown, rx, ry + 48 * density, synchronous = false)
            await("native fast flick submits only No") { port.declines == 1 }
            val held = controller.trayPresentation.frame.value
            assertTrue(held.awaitingDecline); assertTrue(held.drag > 0)
            assertTrue("Short flick must not rely on a height threshold", held.drag < (held.height + 60) / 3)
            delay(120)
            assertEquals("No premature spring-back while transport is pending", held.drag, controller.trayPresentation.frame.value.drag, .01)
            release.complete(Unit)
            await("accepted decline leaves the retained tray") { controller.trayPresentation.frame.value.content == null }
            assertEquals(1, port.declines)
            assertTrue(frames.any { it.phase == ApprovalTravel.LEAVING && it.rise > 0 })
        }
    }
    @Test(timeout = 90_000) fun actualOwnedReceiptFoldsToACapsuleBeforeTheNextMacQuestionArrives(): Unit = runBlocking {
        val release = CompletableDeferred<Unit>()
        fixture(false, release, allowApproval = true, artifact = "receipt", requestTransform = { request ->
            request.copy(kind = ApprovalKind.PAYMENT, payment = ApprovalPayment("fixture.test", "Synthetic item", "$42"),
                requestDigest = "synthetic-owned-facts", sourceIssuedAt = 1.0)
        }) { controller, port, frames, request ->
            await("actual question rest") { controller.trayPresentation.frame.value.phase == ApprovalTravel.READY && frames.any { it.boundsPx.height > 0 } }
            val next = request.copy(id = "fixture-next-owner-question", mac = "fixture-mac-next", kind = ApprovalKind.LINES,
                title = "Next Mac synthetic question", payment = null, requestDigest = "synthetic-next-facts", sourceIssuedAt = 2.0)
            assertEquals("Fixture must queue the next question after the displayed one", request,
                ApprovalContent.order(listOf(next, request)).first())
            main { controller.replaceValidated(listOf(request, next)) }
            val captured = main { checkNotNull(controller.captureDisplayed(request)) }
            val answer = launch(Dispatchers.Main.immediate) {
                controller.answer(request.id, true, object : ApprovalAuthentication {
                    override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(System.currentTimeMillis())
                }, displayed = captured)
            }
            try {
                await("controlled approval awaiting transport ack") { port.approvals == 1 }
                assertTrue(controller.state.value.receipts.isEmpty())
                assertTrue(frames.none { it.receipt || it.result != null })
                release.complete(Unit); answer.join()
                await("actual accepted receipt drawn") { frames.any { it.receipt && it.result == null && it.surface == ApprovalDrawSurface.TRAY } }
                val body = buildJsonObject { put("id", request.id); put("phase", "paid"); put("at", 1234.5) }
                val record = Record("assistantresult", request.id).updated(buildJsonObject { put("body", body.toString()) }, Clock(request.mac))
                val result = checkNotNull(ApprovalResultCodec.read(record, request))
                main { port.approvalResults.value = listOf(result) }
                await("owned paid result drawn before fold") { frames.any { it.phase == ApprovalTravel.READY && it.result == ApprovalResultPhase.paid } }
                await("actual receipt fold") { frames.any { it.phase == ApprovalTravel.FOLDING && it.fold in 0.05..0.95 && it.result == ApprovalResultPhase.paid } }
                await("actual no-Island capsule") { frames.any { it.surface == ApprovalDrawSurface.CAPSULE && it.phase == ApprovalTravel.ISLAND && it.boundsPx.height > 0 } }
                val capsule = frames.last { it.surface == ApprovalDrawSurface.CAPSULE && it.phase == ApprovalTravel.ISLAND }
                assertEquals(37.0, (capsule.boundsPx.height / capsule.density).toDouble(), .6)
                assertTrue(capsule.opacity > .95)
                assertEquals(request, controller.trayPresentation.frame.value.content?.request)
                await("next owner only after capsule exit") { controller.trayPresentation.frame.value.content?.request == next &&
                    controller.trayPresentation.frame.value.phase == ApprovalTravel.READY && frames.any {
                        it.uptimeNanos > capsule.uptimeNanos && it.surface == ApprovalDrawSurface.TRAY && !it.receipt && it.phase == ApprovalTravel.ENTERING } }
                assertNotNull(main { controller.captureDisplayed(next) })
                assertEquals(1, port.approvals); assertEquals(0, port.declines)
            } finally { release.complete(Unit); answer.cancelAndJoin() }
        }
    }
    private suspend fun fixture(reduced: Boolean, answerRelease: CompletableDeferred<Unit>? = null,
        allowApproval: Boolean = false, artifact: String = if (reduced) "reduced" else "tray",
        requestTransform: (ApprovalRequest) -> ApprovalRequest = { it },
        body: suspend (ApprovalController, Port, CopyOnWriteArrayList<ApprovalDrawFrame>, ApprovalRequest) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        require(artifact in setOf("tray", "reduced", "gesture", "receipt"))
        val port = Port(answerRelease, allowApproval); val controller = ApprovalController(port)
        val request = requestTransform(ApprovalRequest("fixture-question", "fixture-account", "fixture-mac", 1,
            System.currentTimeMillis() + 300_000, "Claude", "Synthetic approval question", "Public motion fixture", lines = listOf("Read these exact synthetic facts.")))
        val frames = CopyOnWriteArrayList<ApprovalDrawFrame>()
        val capped = AtomicBoolean()
        val scenario = ActivityScenario.launch<EngineTestActivity>(Intent(context, EngineTestActivity::class.java))
        var passed = false
        try {
            scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduceMotion = reduced),
                    LocalApprovalMotionObserver provides { frame -> if (frames.size < 1200) frames.add(frame) else capped.set(true) }) {
                    BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, null) }
                }
            } }
            main { controller.replaceValidated(listOf(request)) }
            body(controller, port, frames, request)
            check(!capped.get()) { "The bounded real-draw receipt was truncated" }
            passed = true
        } finally {
          try {
            val folder = File(context.getExternalFilesDir(null), "instrumentation")
            check(folder.isDirectory || folder.mkdirs())
            val sampled = JSONArray()
            frames.forEach { value -> sampled.put(JSONObject().put("uptimeNanos", value.uptimeNanos).put("phase", value.phase.name)
                .put("leftPx", value.boundsPx.left).put("topPx", value.boundsPx.top).put("widthPx", value.boundsPx.width).put("heightPx", value.boundsPx.height)
                .put("density", value.density).put("rise", value.rise).put("fold", value.fold).put("opacity", value.opacity).put("receipt", value.receipt)
                .put("surface", value.surface.name).put("result", value.result?.name ?: "none")) }
            File(folder, "approval-$artifact-motion.json").writeText(
                JSONObject().put("passed", passed).put("clock", "real-device-draw").put("reducedMotion", reduced)
                    .put("providerAcceptance", false).put("iosFrameComparisonVerified", false).put("framesTruncated", capped.get())
                    .put("inputEvents", JSONArray(inputEvents.toList())).put("frames", sampled).toString())
          } finally { scenario.close() }
        }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    private fun touch(action: Int, down: Long, x: Float, y: Float, synchronous: Boolean = true) {
        require(action in setOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP) && inputEvents.size < 32)
        require(x.isFinite() && y.isFinite() && x in 0f..20_000f && y in 0f..20_000f)
        val eventTime = SystemClock.uptimeMillis()
        val event = MotionEvent.obtain(down, eventTime, action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
        try {
            assertTrue("Owned approval touchscreen injection failed", InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(event, synchronous))
            inputEvents.add(JSONObject().put("action", when (action) { MotionEvent.ACTION_DOWN -> "down"; MotionEvent.ACTION_MOVE -> "move"; else -> "up" })
                .put("eventTime", eventTime).put("callerUptimeBefore", eventTime).put("callerUptimeAfter", SystemClock.uptimeMillis())
                .put("xPx", x).put("yPx", y).put("waitedForDelivery", synchronous))
        }
        finally { event.recycle() }
    }
    private suspend fun await(name: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + 25_000_000_000L
        while (!condition() && System.nanoTime() < deadline) delay(16)
        assertTrue("Timed out waiting for $name", condition())
    }
}

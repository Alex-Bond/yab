package dev.yab.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.app.UiAutomation
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.agent.*
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import dev.yab.core.sync.RecordKey
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.Closeable
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject

/** AndroidSyncBridge projects the raw Mac "asker: title" into separate fields. */
internal fun matchesProviderFixtureApproval(request: ApprovalRequest, account: String, mac: String): Boolean =
    request.account == account && request.mac == mac && request.title == "Delete synthetic draft?" &&
        request.permit != null && request.kind == ApprovalKind.LINES

/** Standalone paid-provider acceptance, explicitly excluded from the normal device batch.
 * The host driver supplies a real local Worker and an owned production Mac consumer.
 * No mock peer or model is created here. Missing required arguments are a failure. */
@RunWith(AndroidJUnit4::class)
class MacProviderDeviceTest {
    private class OwnedContext(base: Context) : ContextWrapper(base), Closeable {
        private val id = UUID.randomUUID().toString().replace("-", "")
        private val root = File(base.cacheDir, "provider-proof-$id").apply { check(mkdirs()) }
        override fun getApplicationContext(): Context = this
        override fun getPackageName(): String = baseContext.packageName + ".providerproof" + id
        override fun getNoBackupFilesDir(): File = File(root, "no-backup").apply { mkdirs() }
        override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
        override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        override fun close() { SyncIdentityStore(this).forget(); root.deleteRecursively() }
    }

    @Test(timeout = 900_000)
    fun genuineMacProviderAnswersAndResumesAfterAndroidReconnect() = runProof("chat")

    @Test(timeout = 900_000)
    fun genuineMacProviderRequestsAndroidDeclineAndResumesAfterReconnect() = runProof("approval-decline")

    private fun runProof(scenario: String) {
        runBlocking {
            val args = InstrumentationRegistry.getArguments()
            check(args.getString("requireMacProviderProof") == "true") { "Run only through mac-provider-proof.py" }
            check(args.getString("macProofScenario", "chat") == scenario) { "The owned driver did not select this exact proof scenario" }
            fun loopback(name: String): HttpUrl {
                val value = checkNotNull(args.getString(name)) { "Missing $name" }.toHttpUrl()
                require(value.scheme == "http" && value.host == "127.0.0.1" && value.port > 0 && value.username.isEmpty() && value.password.isEmpty())
                return value
            }
            val backend = loopback("syncBackendUrl")
            val control = loopback("macProofControl")
            val nonce = checkNotNull(args.getString("macProofNonce"))
            require(nonce.matches(Regex("[a-f0-9]{32}")))
            val http = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).followRedirects(false).build()
            suspend fun host(path: String, body: JsonObject? = null): JsonObject = withContext(Dispatchers.IO) {
                val request = Request.Builder().url(control.newBuilder().addPathSegment(path).build())
                    .header("Authorization", "Bearer $nonce")
                if (body != null) request.post(body.toString().toRequestBody("application/json".toMediaType()))
                http.newCall(request.build()).execute().use { response ->
                    check(response.isSuccessful) { "Owned Mac control refused $path (${response.code})" }
                    Json.parseToJsonElement(checkNotNull(response.body).string()).jsonObject
                }
            }
            try {
            val config = host("config")
            check(config["scenario"]?.jsonPrimitive?.contentOrNull.orEmpty().ifEmpty { "chat" } == scenario)
            val mac = config.getValue("mac").jsonPrimitive.content
            val account = config.getValue("account").jsonPrimitive.content
            val provider = when (config.getValue("provider").jsonPrimitive.content) {
                "claude" -> AgentProvider.CLAUDE; "codex" -> AgentProvider.CODEX; else -> error("Provider is not pinned")
            }
            val target = InstrumentationRegistry.getInstrumentation().targetContext
            OwnedContext(target).use { context ->
                var bridge = AndroidSyncBridge(context, backend.toString(), allowInsecureForTests = true)
                try {
                    bridge.join()
                    await("Android pairing challenge") { bridge.ui.value.code != null }
                    val code = checkNotNull(bridge.ui.value.code); val check = checkNotNull(bridge.ui.value.check)
                    val paired = host("pair", buildJsonObject { put("code", code); put("check", check) })
                    assertTrue("Production Mac Pairing.answer must approve the exact challenge", paired["paired"]?.jsonPrimitive?.boolean == true)
                    await("real Mac roster and capability") {
                        bridge.ui.value.phase == "live" && bridge.connection.value.account == account &&
                            bridge.connection.value.macs.any { it.id == mac && it.awake && provider in it.providers }
                    }
                    val android = checkNotNull(bridge.ownDevice)
                    val saved = checkNotNull(SyncIdentityStore(context).load())
                    assertEquals(account, saved.seal.account); assertEquals(android, saved.device)
                    val cap = bridge.accountRecords.value.records.first { it.key == RecordKey("commandcap", mac) }
                    for (field in listOf("device", "platform", "androidSync", "chatAgent")) assertEquals(mac, cap.stamps[field]?.device)
                    assertEquals("macos", cap["platform"]?.jsonPrimitive?.content)
                    assertEquals(1, cap["androidSync"]?.jsonPrimitive?.int)

                    val chatId = UUID.randomUUID().toString()
                    val token = "ANDROID_" + UUID.randomUUID().toString().replace("-", "")
                    val firstSend = UUID.randomUUID().toString()
                    val words = if (scenario == "approval-decline") {
                        val fixture = config.getValue("approvalFixtureUrl").jsonPrimitive.content.toHttpUrl()
                        require(fixture.scheme == "http" && fixture.host == "127.0.0.1" && fixture.port > 1024 &&
                            fixture.username.isEmpty() && fixture.password.isEmpty() && fixture.query == null &&
                            fixture.encodedPath.matches(Regex("/approval-fixture/[a-f0-9]{32}")))
                        "Remember this validation token for this conversation: $token. Open only $fixture in a new browser tab. " +
                            "Use the normal browser click tool to attempt the Delete synthetic draft button exactly once. " +
                            "Wait for the actual Yab approval, which I will decline on Android. Never bypass or retry that declined action. " +
                            "Once the tool confirms the decline, reply with exactly READY $token. Do not inspect files, use other sites, send messages, or change anything else."
                    } else "Remember this validation token for this conversation: $token. Reply with exactly READY $token. Do not use tools, inspect files, browse, or change anything."
                    val transport = SyncProtocolTransport(bridge)
                    val receipt = transport.send(AgentSendCommand(firstSend, chatId, account, mac, provider, null,
                        LocalQuestion(words, null, emptyList()), emptyList(), ModelSelection(), bridge.connection.value.epoch))
                    assertEquals(firstSend, receipt.send?.id)
                    if (scenario == "approval-decline") declineRealProviderApproval(bridge, firstSend, account, mac, android, ::host)
                    val first = answer(bridge, account, mac, provider, chatId, "READY $token")
                    assertSealedOwner(bridge, first.owner, firstSend, android, "READY $token")
                    host("observe", buildJsonObject { put("stage", "first"); put("send", firstSend); put("chat", first.owner.chat) })

                    // Close/reload the actual adapter, Keystore identity and durable journal.
                    bridge.awaitClosedForTests()
                    bridge = AndroidSyncBridge(context, backend.toString(), allowInsecureForTests = true)
                    bridge.start()
                    await("same account/device after adapter reconnect") {
                        bridge.ui.value.phase == "live" && bridge.ownDevice == android && bridge.connection.value.account == account &&
                            bridge.connection.value.macs.any { it.id == mac && provider in it.providers }
                    }
                    assertEquals(saved.device, SyncIdentityStore(context).load()?.device)
                    val reloaded = answer(bridge, account, mac, provider, chatId, "READY $token")
                    assertEquals(first.owner, reloaded.owner)

                    val followSend = UUID.randomUUID().toString()
                    // The token is deliberately absent: the genuine provider must resume its
                    // own conversation. questionText does not retransmit history on this path.
                    val followWords = "What validation token did I ask you to remember? Reply with exactly FOLLOWUP followed by a space and that token. Do not use tools or change anything."
                    val follow = SyncProtocolTransport(bridge).send(AgentSendCommand(followSend, chatId, account, mac, provider, first.owner,
                        LocalQuestion(followWords, null, emptyList()), emptyList(), ModelSelection(), bridge.connection.value.epoch))
                    assertEquals(followSend, follow.send?.id)
                    val resumed = answer(bridge, account, mac, provider, chatId, "FOLLOWUP $token")
                    assertEquals(first.owner, resumed.owner)
                    assertSealedOwner(bridge, resumed.owner, followSend, android, "FOLLOWUP $token")
                    host("observe", buildJsonObject { put("stage", "followup"); put("send", followSend); put("chat", resumed.owner.chat) })
                    host("complete", buildJsonObject { put("account", account); put("mac", mac); put("android", android); put("chat", resumed.owner.chat) })
                } finally {
                    withContext(NonCancellable) { bridge.awaitClosedForTests() }
                }
            }
            } finally {
                http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll()
            }
        }
    }

    /** Actual sealed provider question, real production UI No, and actual Mac-consumed decision.
     * No synthetic permit, fake biometric, provider response or remote answer is created here. */
    private suspend fun declineRealProviderApproval(bridge: AndroidSyncBridge, send: String, account: String,
        mac: String, android: String, host: suspend (String, JsonObject?) -> JsonObject) = coroutineScope {
        var found: ApprovalRequest? = null
        await("the actual provider's sealed safe-fixture permit", 300_000) {
            found = bridge.approvals.value.singleOrNull { matchesProviderFixtureApproval(it, account, mac) }
            found != null
        }
        val request = checkNotNull(found)
        val snapshot = bridge.accountRecords.value
        check(snapshot.account == account && snapshot.epoch == bridge.connection.value.epoch)
        val original = snapshot.records.first { it.key == RecordKey("assistantapproval", request.id) }
        assertEquals(mac, original.stamps["body"]?.device)
        val body = original["body"]?.jsonPrimitive?.content ?: error("Missing actual sealed request body")
        val command = snapshot.records.first { it.key == RecordKey("send", send) }
        assertEquals("taken", command["state"]?.jsonPrimitive?.content)
        assertEquals(mac, command.stamps["state"]?.device)
        val chat = checkNotNull(command["chat"]?.jsonPrimitive?.content)
        val claim = buildJsonObject {
            put("id", request.id); put("chat", chat); put("android", android)
            put("requestBodySHA256", sha256(body)); put("requestDigest", checkNotNull(request.requestDigest))
        }
        assertTrue(host("approval-issued", claim)["issued"]?.jsonPrimitive?.boolean == true)
        val controller = ApprovalController(bridge)
        val collector = launch(Dispatchers.Main.immediate) { bridge.approvals.collect { controller.replaceValidated(it) } }
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val scene = ActivityScenario.launch<EngineTestActivity>(Intent(target, EngineTestActivity::class.java))
        val actionReceipt = DeclineActionReceipt()
        var activity: EngineTestActivity? = null
        var failure: Throwable? = null
        try {
            scene.onActivity { originalActivity ->
                activity = originalActivity
                originalActivity.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, null) } }
            }
            actionReceipt.phase = "WAIT_READY"
            await("actual provider approval tray ready") { controller.trayPresentation.frame.value.phase == ApprovalTravel.READY &&
                controller.state.value.requests.any { it.fingerprint() == request.fingerprint() } }
            val originalActivity = checkNotNull(activity)
            val captured = withContext(Dispatchers.Main.immediate) {
                checkNotNull(controller.captureDisplayed(request))
            }
            val originalToken = withContext(Dispatchers.Main.immediate) {
                checkNotNull(originalActivity.window.decorView.windowToken)
            }
            val expectedIdentity = SyncIdentityLease(account, android, snapshot.epoch)
            val facts = request.fingerprint()
            suspend fun source(): DeclineGuard = withContext(Dispatchers.Main.immediate) {
                val connection = bridge.connection.value
                val records = bridge.accountRecords.value
                val currentRequest = bridge.approvals.value.singleOrNull { matchesProviderFixtureApproval(it, account, mac) }
                val currentBody = records.records.firstOrNull { it.key == original.key }
                val currentSend = records.records.firstOrNull { it.key == command.key }
                val state = controller.state.value
                val frame = controller.trayPresentation.frame.value
                DeclineGuard(
                    activity = !originalActivity.isFinishing && !originalActivity.isDestroyed &&
                        originalActivity.lifecycle.currentState == Lifecycle.State.RESUMED,
                    attached = originalActivity.window.decorView.isAttachedToWindow && originalActivity.window.decorView.windowToken == originalToken,
                    identity = bridge.identityLease() == expectedIdentity && bridge.ownDevice == android,
                    account = connection.account == account && records.account == account && records.device == android && !records.removed,
                    epoch = connection.epoch == snapshot.epoch && records.epoch == snapshot.epoch,
                    mac = connection.macs.any { it.id == mac },
                    permit = currentRequest != null && currentRequest.fingerprint() == facts && currentRequest.permit == request.permit &&
                        currentRequest.requestDigest == request.requestDigest && currentRequest.kind == ApprovalKind.LINES,
                    sealedBody = currentBody?.stamps?.get("body")?.device == mac && currentBody?.get("body")?.jsonPrimitive?.content == body,
                    takenCommand = currentSend?.stamps?.get("state")?.device == mac && currentSend?.get("state")?.jsonPrimitive?.content == "taken" &&
                        currentSend?.get("chat")?.jsonPrimitive?.content == chat,
                    facts = state.requests.any { it.fingerprint() == facts } && request.expiresAt > System.currentTimeMillis(),
                    display = controller.isDisplayedCurrent(captured),
                    drawnOwner = frame.content?.let { it.key.epoch == snapshot.epoch && it.key.generation == captured.generation &&
                        it.request.fingerprint() == facts && it.action?.let(controller::isDisplayedCurrent) == true } == true,
                    ready = frame.phase == ApprovalTravel.READY, interactive = frame.interactive,
                    idle = state.busy == null && state.error == null,
                )
            }
            actionReceipt.phase = "WAIT_OWNED_HEADER"
            pressDecline(InstrumentationRegistry.getInstrumentation().uiAutomation, target.packageName, ::source, actionReceipt)
            actionReceipt.phase = "WAIT_ANDROID_NO"
            await("actual Android No written by the real bridge") {
                check(controller.state.value.error == null) { "The production Android approval action was refused" }
                bridge.accountRecords.value.records.firstOrNull { it.key == RecordKey("assistantanswer", request.id) }?.let { record ->
                    val answer = record["body"]?.jsonPrimitive?.content?.let { Json.parseToJsonElement(it) }?.jsonObject
                    record.stamps["body"]?.device == android && answer?.get("yes")?.jsonPrimitive?.booleanOrNull == false &&
                        answer?.get("requestDigest")?.jsonPrimitive?.content == request.requestDigest
                } == true
            }
            actionReceipt.androidNoObserved = true
            actionReceipt.phase = "WAIT_MAC_NO"
            withTimeout(60_000) {
                while (host("approval-declined", claim)["declined"]?.jsonPrimitive?.boolean != true) delay(100)
            }
            actionReceipt.macNoObserved = true
            actionReceipt.phase = "COMPLETED"
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            withContext(NonCancellable) {
                var cleanupFailure: Throwable? = null
                fun remember(error: Throwable) {
                    val previous = cleanupFailure
                    if (previous == null) cleanupFailure = error else previous.addSuppressed(error)
                }
                try {
                    val json = actionReceipt.json().toString()
                    check(json.toByteArray(Charsets.UTF_8).size <= 32 * 1024)
                    val folder = File(checkNotNull(target.getExternalFilesDir(null)), "instrumentation")
                    check(folder.isDirectory || folder.mkdirs())
                    File(folder, "provider-approval-action.json").writeText(json)
                    // Existing runner preserves this public status line; code2 has no JUnit case fields.
                    InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply { putString("providerApprovalAction", json) })
                } catch (error: Throwable) { remember(error) }
                try { collector.cancelAndJoin() } catch (error: Throwable) { remember(error) }
                try { withContext(Dispatchers.Main.immediate) { activity?.setContent {} }; scene.close() }
                catch (error: Throwable) { remember(error) }
                cleanupFailure?.let { error -> val originalFailure = failure
                    if (originalFailure != null) originalFailure.addSuppressed(error) else throw error
                }
            }
        }
    }

    private data class DeclineGuard(val activity: Boolean, val attached: Boolean, val identity: Boolean,
        val account: Boolean, val epoch: Boolean, val mac: Boolean, val permit: Boolean, val sealedBody: Boolean,
        val takenCommand: Boolean, val facts: Boolean, val display: Boolean, val drawnOwner: Boolean,
        val ready: Boolean, val interactive: Boolean, val idle: Boolean) {
        val sourceCurrent get() = activity && attached && identity && account && epoch && mac && permit && sealedBody && takenCommand && facts && display
        val current get() = sourceCurrent && drawnOwner && ready && interactive && idle
        fun json() = JSONObject().put("activity", activity).put("attached", attached).put("identity", identity)
            .put("account", account).put("epoch", epoch).put("mac", mac).put("permit", permit)
            .put("sealedBody", sealedBody).put("takenCommand", takenCommand).put("facts", facts).put("display", display)
            .put("drawnOwner", drawnOwner).put("ready", ready).put("interactive", interactive).put("idle", idle)
            .put("sourceCurrent", sourceCurrent).put("current", current)
    }
    private data class DeclineTarget(val window: Int, val root: Rect, val label: Rect)
    private data class DeclineProjection(val rootPresent: Boolean, val rootOwned: Boolean, val complete: Boolean,
        val visited: Int, val descriptions: Int, val visible: Int, val enabled: Int, val clickable: Int,
        val actionClick: Int, val target: DeclineTarget?) {
        fun json() = JSONObject().put("rootPresent", rootPresent).put("rootOwned", rootOwned).put("complete", complete)
            .put("visited", visited).put("headerDescription", descriptions).put("headerVisible", visible)
            .put("headerEnabled", enabled).put("headerClickable", clickable).put("headerActionClick", actionClick)
            .put("uniquePointerTarget", target != null).also { value -> target?.let {
                fun rect(bounds: Rect) = JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).map { n -> n.coerceIn(-1_000_000, 1_000_000) })
                value.put("rootBounds", rect(it.root)).put("labelBounds", rect(it.label))
            } }
    }
    private class DeclineActionReceipt {
        var phase = "START"
        var androidNoObserved = false
        var macNoObserved = false
        var cancelled = false
        var cancelRefused = false
        val samples = JSONArray()
        val events = JSONArray()
        private var last: String? = null
        fun sample(guard: DeclineGuard, projection: DeclineProjection) {
            val value = JSONObject().put("phase", phase).put("guards", guard.json()).put("ax", projection.json())
            val key = value.toString()
            if (last != key && samples.length() < 16) { samples.put(value); last = key }
        }
        fun json() = JSONObject().put("schema", 1).put("kind", "provider-approval-action")
            .put("phase", phase).put("androidNoObserved", androidNoObserved).put("macNoObserved", macNoObserved)
            .put("pointerAttempted", events.length() > 0).put("cancelled", cancelled).put("cancelRefused", cancelRefused)
            .put("directControllerAnswer", false).put("accessibilityActionInvoked", false).put("samples", samples).put("events", events)
    }

    /** One real gesture, only after stable native label geometry and the original sealed source. */
    private suspend fun pressDecline(automation: UiAutomation, own: String, source: suspend () -> DeclineGuard,
        receipt: DeclineActionReceipt) {
        var prior: DeclineTarget? = null
        var target: DeclineTarget? = null
        val deadline = SystemClock.elapsedRealtime() + 60_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val guard = source()
            val projection = declineProjection(automation, own)
            val after = source()
            receipt.sample(guard, projection)
            receipt.sample(after, projection)
            check(guard.sourceCurrent && after.sourceCurrent) { "The original sealed provider approval owner was revoked" }
            check(!projection.rootPresent || projection.rootOwned) { "A foreign active approval window was refused" }
            val next = projection.target.takeIf { guard.current && after.current }
            if (next != null && next == prior) { target = next; break }
            prior = next
            delay(32)
        }
        val original = checkNotNull(target) { "Timed out waiting for the actual unique owned native Decline approval control" }
        val x = original.label.exactCenterX(); val y = original.label.exactCenterY()
        var pressed = false
        var failure: Throwable? = null
        var down = 0L
        suspend fun same(): Boolean {
            val guard = source(); val projection = declineProjection(automation, own)
            val after = source()
            receipt.sample(guard, projection)
            receipt.sample(after, projection)
            return guard.current && after.current && projection.target == original
        }
        fun event(action: Int): Boolean {
            check(receipt.events.length() < 4)
            val time = SystemClock.uptimeMillis()
            if (action == MotionEvent.ACTION_DOWN) down = time
            val property = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
            val point = MotionEvent.PointerCoords().apply { this.x = x; this.y = y; pressure = 1f; size = 1f }
            val value = MotionEvent.obtain(down, time, action, 1, arrayOf(property), arrayOf(point), 0, 0, 1f, 1f,
                0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
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
            receipt.phase = "POINTER_DOWN"
            check(same()) { "Original provider approval changed before DOWN" }
            pressed = true
            check(event(MotionEvent.ACTION_DOWN)) { "Owned provider approval DOWN was refused" }
            delay(32)
            receipt.phase = "POINTER_UP"
            check(same()) { "Original provider approval changed before UP" }
            check(event(MotionEvent.ACTION_UP)) { "Owned provider approval UP was refused" }
            pressed = false
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (pressed) withContext(NonCancellable) {
                try {
                    val guard = source(); val projection = declineProjection(automation, own)
                    val after = source()
                    receipt.sample(guard, projection)
                    receipt.sample(after, projection)
                    if (guard.current && after.current && projection.rootOwned && projection.complete && projection.target?.let {
                        it.window == original.window && it.root == original.root
                    } == true) receipt.cancelled = event(MotionEvent.ACTION_CANCEL)
                    else receipt.cancelRefused = true
                } catch (error: Throwable) { val originalFailure = failure
                    if (originalFailure != null) originalFailure.addSuppressed(error) else throw error
                }
            }
        }
    }

    private fun declineProjection(automation: UiAutomation, own: String): DeclineProjection {
        val root = automation.rootInActiveWindow ?: return DeclineProjection(false, false, false, 0, 0, 0, 0, 0, 0, null)
        val queue = java.util.ArrayDeque<Pair<AccessibilityNodeInfo, Int>>().apply { add(root to 0) }
        val rootBounds = Rect()
        var window = -1; var owned = false; var complete = false
        var visited = 0; var descriptions = 0; var visible = 0; var enabled = 0; var clickable = 0; var actionClick = 0
        var found: Rect? = null
        try {
            root.getBoundsInScreen(rootBounds); window = root.windowId
            owned = root.packageName?.toString() == own && window >= 0 && !rootBounds.isEmpty
            complete = owned
            while (queue.isNotEmpty()) {
                val (node, depth) = queue.removeFirst()
                try {
                    if (++visited > 512) { complete = false; break }
                    if (node.packageName?.toString() != own || node.windowId != window) { complete = false; continue }
                    if (node.contentDescription?.toString() == "Decline approval") {
                        descriptions++
                        if (node.isVisibleToUser) visible++
                        if (node.isEnabled) enabled++
                        if (node.isClickable) clickable++
                        if (node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }) actionClick++
                        val bounds = Rect().also(node::getBoundsInScreen)
                        if (node.isVisibleToUser && node.isEnabled && !bounds.isEmpty && rootBounds.contains(bounds)) found = bounds
                    }
                    val count = node.childCount
                    if (count !in 0..128 || depth >= 64 && count > 0) { complete = false; continue }
                    repeat(count) { index ->
                        if (queue.size + visited >= 512) complete = false
                        else node.getChild(index)?.let { queue.add(it to depth + 1) } ?: run { complete = false }
                    }
                } finally { node.recycle() }
            }
        } finally { while (queue.isNotEmpty()) queue.removeFirst().first.recycle() }
        return DeclineProjection(true, owned, complete, visited.coerceAtMost(513), descriptions, visible, enabled, clickable, actionClick,
            found?.takeIf { complete && descriptions == 1 && visible == 1 && enabled == 1 }?.let { DeclineTarget(window, rootBounds, it) })
    }

    private fun sha256(text: String) = java.security.MessageDigest.getInstance("SHA-256")
        .digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }

    private suspend fun answer(bridge: AndroidSyncBridge, account: String, mac: String, provider: AgentProvider, clientChat: String, expected: String): RemoteConversation {
        var found: RemoteConversation? = null
        await("a genuine sealed $provider answer", 300_000) {
            val current = bridge.conversations.value.firstOrNull { it.clientChat == clientChat }
            check(bridge.ui.value.phase != "removed") { "The owned Android device was revoked" }
            check(current?.remoteState != "failed") { "The real Mac provider could not finish this turn" }
            if (current != null && !current.working && current.messages.lastOrNull { it.role == MessageRole.ASSISTANT }?.text?.trim() == expected) found = current
            found != null
        }
        return checkNotNull(found).also {
            assertEquals(account, it.owner.account); assertEquals(mac, it.owner.mac); assertEquals(provider, it.owner.provider)
            assertTrue(it.messages.last { message -> message.role == MessageRole.ASSISTANT }.origin == AnswerOrigin.MAC)
        }
    }

    private fun assertSealedOwner(bridge: AndroidSyncBridge, owner: RemoteOwner, send: String, android: String, expected: String) {
        val snapshot = bridge.accountRecords.value
        assertEquals(owner.account, snapshot.account)
        val record = snapshot.records.first { it.key == RecordKey("send", send) }
        assertEquals(android, record.stamps["clientDevice"]?.device)
        assertEquals(owner.mac, record.stamps["state"]?.device)
        assertEquals("taken", record["state"]?.jsonPrimitive?.content)
        assertEquals(owner.chat, record["chat"]?.jsonPrimitive?.content)
        val head = snapshot.records.first { it.key == RecordKey("chat", owner.chat) }
        assertEquals(owner.mac, head["device"]?.jsonPrimitive?.content); assertEquals(owner.mac, head.stamps["device"]?.device)
        val reply = snapshot.records.first { it.key.collection == "chatitem" && it["chat"]?.jsonPrimitive?.content == owner.chat && it["text"]?.jsonPrimitive?.content?.trim() == expected }
        assertEquals(owner.mac, reply.stamps["text"]?.device)
    }

    private suspend fun await(label: String, timeout: Long = 60_000, condition: () -> Boolean) {
        try { withTimeout(timeout) { while (!condition()) delay(50) } }
        catch (error: TimeoutCancellationException) { throw AssertionError("Timed out waiting for $label", error) }
    }
}

package dev.yab.browser.download

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.MainThread
import dev.yab.android.BuildConfig
import dev.yab.android.PageDownloadOwner
import java.io.FilterInputStream
import java.io.InputStream
import java.util.IdentityHashMap
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.mozilla.gecko.util.GeckoBundle
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.WebExtension
import org.mozilla.geckoview.WebResponse

/** Actual pre-stream authority only. It never pretends that file bytes or progress have arrived. */
data class OwnedImagePreparation(val token: String, val owner: PageDownloadOwner)

/**
 * Only APK code may arm this path after consuming a native held-image action.
 * Requests run in one sandboxed child of that exact page. Neither Java fetch nor copied cookies are used.
 * All public methods are called on the main thread; the supplied scope belongs to the retained browser owner.
 */
@MainThread
class OwnedImageDownloadRuntime(private val runtime: GeckoRuntime, private val scope: CoroutineScope) {
    private class Registration(val document: () -> String?, val url: () -> String?, val interactive: () -> Boolean) {
        var content: Document? = null
    }
    private class Document(val port: WebExtension.Port, val bridge: String, val id: String, val nativeDocument: String)
    private class Transfer(val session: GeckoSession, val registration: Registration, val content: Document,
        val attempt: OwnedDownloadAttempt, val owner: PageDownloadOwner, val ownerCurrent: () -> Boolean,
        val deliver: (WebResponse, PageDownloadOwner) -> Unit, val failure: (String) -> Unit) {
        var watch: Job? = null
        var input: InputStream? = null
    }
    private class Check(val transfer: Transfer, val port: WebExtension.Port, val answer: CompletableDeferred<Boolean>)
    private val sessions = IdentityHashMap<GeckoSession, Registration>()
    private val checks = mutableMapOf<String, Check>()
    private val main = Handler(Looper.getMainLooper())
    private var extension: WebExtension? = null
    private var active: Transfer? = null
    private val mutablePreparation = MutableStateFlow<OwnedImagePreparation?>(null)
    val preparation = mutablePreparation.asStateFlow()
    private var closed = false
    private val debugEvents = ArrayDeque<String>()
    private var debugFailure = "NONE"
    private var debugLastPhase = "NONE"
    private var debugResponseSeen = false
    private fun debugEvent(value: String) {
        if (!BuildConfig.DEBUG) return
        if (debugEvents.size == 16) debugEvents.removeFirst()
        debugEvents.addLast(value)
    }
    /** Owned fixture diagnostics contain fixed protocol coordinates and booleans only. */
    fun debugStatus(session: GeckoSession?): JSONObject {
        check(BuildConfig.DEBUG)
        val registration = session?.let(sessions::get)
        val transfer = active
        return JSONObject().put("events", org.json.JSONArray(debugEvents.toList()))
            .put("failure", debugFailure).put("lastPhase", debugLastPhase).put("responseSeen", debugResponseSeen)
            .put("runtimeReady", ready).put("sessionRegistered", registration != null)
            .put("contentConnected", registration?.content != null)
            .put("documentMatches", registration?.let { it.content != null && it.document() != null && it.document() == it.content?.nativeDocument } == true)
            .put("interactive", registration?.let { runCatching(it.interactive).getOrDefault(false) } == true)
            .put("active", transfer != null).put("sameSession", transfer != null && transfer.session === session)
            .put("sourceCurrent", transfer?.let { runCatching { current(it) }.getOrDefault(false) } == true)
            .put("phase", transfer?.attempt?.phase?.name ?: "NONE")
    }
    val ready: Boolean get() = extension != null && !closed
    val hasActiveAttempt: Boolean get() = active != null
    fun canSaveImage(session: GeckoSession): Boolean = ready && active == null && sessions[session]?.let {
        it.content != null && it.interactive() && it.document() == it.content?.nativeDocument
    } == true

    private val backgroundDelegate = object : WebExtension.MessageDelegate {
        override fun onMessage(nativeApp: String, message: Any, sender: WebExtension.MessageSender): GeckoResult<Any> {
            if (nativeApp != NATIVE || !own(sender) || sender.session != null || sender.environmentType != WebExtension.MessageSender.ENV_TYPE_EXTENSION)
                return denied()
            val value = message as? JSONObject ?: return denied()
            val transfer = active?.takeIf { value.string("token") == it.attempt.token } ?: return denied()
            if (value.int("v") != 1L) return denied()
            if (value.string("kind") == "failed") { debugEvent("BACKGROUND_FAILED"); debugFailure(value.string("reason")); fail(transfer, "This image couldn't be saved from this page. Open the image and try there."); return denied() }
            val kind = value.string("kind")
            if (kind !in setOf("bind", "claim", "stamp")) return denied()
            if (!current(transfer)) { debugEvent("NATIVE_SOURCE_REFUSED"); return denied() }
            debugEvent(when (kind) { "bind" -> "BIND_RECEIVED"; "claim" -> "CLAIM_RECEIVED"; else -> "STAMP_RECEIVED" })
            val result = GeckoResult<Any>()
            val completed = AtomicBoolean()
            // Native callback replies bypass Port.postMessage's JSONObject conversion.
            // Gecko's JNI event dispatcher accepts GeckoBundle for structured replies.
            fun complete(answer: JSONObject) {
                if (completed.compareAndSet(false, true)) result.complete(GeckoBundle.fromJSONObject(answer))
            }
            val job = scope.launch(Dispatchers.Main.immediate) {
                try {
                    val checked = checkDocument(transfer)
                    if (!checked || !current(transfer)) { debugEvent("DOCUMENT_CHECK_REFUSED"); complete(no()); return@launch }
                    val source = source(transfer.owner)
                    val now = SystemClock.elapsedRealtime()
                    val ok = when (kind) {
                        "bind" -> value.frame()?.let { it.bridge == transfer.content.bridge && it.document == transfer.content.id &&
                            transfer.attempt.bind(it, now, source) } == true
                        "claim" -> bindingMatches(transfer, value) && value.optJSONObject("request")?.request()?.let {
                            transfer.attempt.claim(it, now, source) } == true
                        "stamp" -> bindingMatches(transfer, value) && transfer.attempt.stamp(value.string("id").orEmpty(), value.string("url").orEmpty(),
                            value.int("status")?.toInt() ?: -1, value.string("mime").orEmpty(), now, source)
                        else -> false
                    }
                    if (!ok) { debugEvent("NATIVE_BINDING_REFUSED"); fail(transfer, "This image request changed. Open the image and save it from there."); complete(no()) }
                    else { debugEvent(transfer.attempt.phase.name); complete(JSONObject().put("ok", true).apply { if (kind == "stamp") put("stamp", transfer.attempt.stamp) }) }
                } catch (cancelled: CancellationException) { complete(no()); throw cancelled }
                catch (_: Exception) { fail(transfer, "The image request timed out. Try again from this page."); complete(no()) }
            }
            job.invokeOnCompletion { complete(no()) }
            return result
        }
        override fun onConnect(port: WebExtension.Port) { post(port, JSONObject().put("command", "retire")) }
    }

    init {
        runtime.webExtensionController.ensureBuiltIn("resource://android/assets/web_extensions/image_download/", ID).accept(install@{ candidate ->
            val own = candidate?.takeIf { it.isBuiltIn && it.id == ID } ?: return@install
            if (closed) return@install
            runtime.webExtensionController.setAllowedInPrivateBrowsing(own, true).accept(privateReady@{ candidate ->
                val allowed = candidate?.takeIf { it.isBuiltIn && it.id == ID } ?: return@privateReady
                if (closed) return@privateReady
                extension = allowed; allowed.setMessageDelegate(backgroundDelegate, NATIVE)
                sessions.forEach { (session, registration) -> installSession(session, registration, allowed) }
            }, { /* Missing capability leaves Save image unavailable; no permissive fallback. */ })
        }, { /* Built-in installation failure never changes external-extension policy. */ })
    }

    /** Register every original GeckoSession, including its real private/container settings. */
    fun attach(session: GeckoSession, document: () -> String?, url: () -> String?, interactive: () -> Boolean) {
        if (closed) return
        detach(session)
        val registration = Registration(document, url, interactive); sessions[session] = registration
        extension?.let { installSession(session, registration, it) }
    }

    private fun installSession(session: GeckoSession, registration: Registration, owned: WebExtension) {
        session.webExtensionController.setMessageDelegate(owned, object : WebExtension.MessageDelegate {
            override fun onMessage(nativeApp: String, message: Any, sender: WebExtension.MessageSender): GeckoResult<Any> = denied()
            override fun onConnect(port: WebExtension.Port) {
                val sender = port.sender
                if (closed || sessions[session] !== registration || port.name != NATIVE || !own(sender) || sender.session !== session ||
                    sender.environmentType != WebExtension.MessageSender.ENV_TYPE_CONTENT_SCRIPT || !sender.isTopLevel ||
                    OwnedDownloadAttempt.resourceUrl(sender.url.orEmpty()) != OwnedDownloadAttempt.resourceUrl(registration.url().orEmpty())) {
                    post(port, JSONObject().put("command", "retire")); return
                }
                port.setDelegate(object : WebExtension.PortDelegate {
                    override fun onPortMessage(message: Any, sourcePort: WebExtension.Port) {
                        val value = message as? JSONObject ?: return
                        if (sourcePort !== port || closed || sessions[session] !== registration || value.int("v") != 1L) return
                        if (value.string("kind") == "hello") {
                            if (registration.content?.port === port) return
                            val bridge = value.string("bridge")?.takeIf { OwnedDownloadAttempt.TOKEN.matches(it) } ?: return
                            val id = value.string("document")?.takeIf { OwnedDownloadAttempt.TOKEN.matches(it) } ?: return
                            val native = registration.document() ?: return
                            active?.takeIf { it.session === session }?.let { fail(it, null) }
                            val old = registration.content; registration.content = Document(port, bridge, id, native)
                            retireDocument(old); return
                        }
                        val document = registration.content?.takeIf { it.port === port && it.bridge == value.string("bridge") && it.id == value.string("document") } ?: return
                        val transfer = active?.takeIf { it.content === document && it.attempt.token == value.string("token") } ?: return
                        when (value.string("kind")) {
                            "prepared" -> {
                                debugEvent("PREPARED_RECEIVED")
                                val frame = value.int("frame") ?: return
                                if (!current(transfer) || !transfer.attempt.prepare(document.bridge, frame, SystemClock.elapsedRealtime(), source(transfer.owner))) {
                                    fail(transfer, "This page changed before the image could be saved."); return
                                }
                                post(document.port, JSONObject().put("command", "bind").put("token", transfer.attempt.token))
                                debugEvent("BIND_SENT")
                            }
                            "checked" -> {
                                val check = value.string("check")?.let(checks::remove) ?: return
                                if (check.transfer === transfer && check.port === sourcePort) check.answer.complete(value.boolean("valid") == true && current(transfer))
                                else check.answer.complete(false)
                            }
                            "failed" -> { debugEvent("CONTENT_FAILED"); debugFailure(value.string("reason")); fail(transfer, "This image couldn't be saved from this page. Open the image and try there.") }
                        }
                    }
                    override fun onDisconnect(source: WebExtension.Port) {
                        if (registration.content?.port !== source) return
                        active?.takeIf { it.session === session }?.let { fail(it, null) }
                        registration.content = null
                    }
                })
            }
        }, NATIVE)
    }

    /** Must be called only after consuming the matching native PageContextMenu and capturing its owner. */
    fun saveImage(session: GeckoSession, image: String, owner: PageDownloadOwner, ownerCurrent: () -> Boolean,
        deliver: (WebResponse, PageDownloadOwner) -> Unit, failure: (String) -> Unit): Boolean {
        if (closed || active != null || extension == null || OwnedDownloadAttempt.resourceUrl(image) == null) return false
        val registration = sessions[session] ?: return false
        val content = registration.content ?: return false
        if (!registration.interactive() || !ownerCurrent() || registration.document() != owner.document || content.nativeDocument != owner.document ||
            session.settings.usePrivateMode != owner.privateOrigin || session.settings.contextId != owner.profile) return false
        val attempt = OwnedDownloadAttempt(UUID.randomUUID().toString(), UUID.randomUUID().toString(), source(owner), image,
            SystemClock.elapsedRealtime() + 30_000)
        val transfer = Transfer(session, registration, content, attempt, owner, ownerCurrent, deliver, failure)
        if (BuildConfig.DEBUG) { debugEvents.clear(); debugFailure = "NONE"; debugLastPhase = "NONE"; debugResponseSeen = false }
        active = transfer
        debugEvent("ARMED")
        mutablePreparation.value = OwnedImagePreparation(attempt.token, owner)
        post(content.port, JSONObject().put("command", "prepare").put("token", attempt.token).put("target", attempt.target)
            .put("bridge", content.bridge).put("document", content.id))
        debugEvent("PREPARE_SENT")
        transfer.watch = scope.launch(Dispatchers.Main.immediate) {
            while (active === transfer) {
                if (!sameSource(transfer)) { fail(transfer, null); return@launch }
                if (!transfer.attempt.current(SystemClock.elapsedRealtime(), source(transfer.owner))) {
                    fail(transfer, "The image request timed out. Try again from this page."); return@launch
                }
                delay(100)
            }
        }
        return true
    }

    /** Call before the ordinary onExternalResponse handler. True means this module owns/closed the response. */
    fun intercept(session: GeckoSession, response: WebResponse): Boolean {
        val stamps = response.headers.entries.filter { it.key.equals(OwnedDownloadAttempt.RESPONSE_STAMP, true) }.map { it.value }
        val transfer = active?.takeIf { it.session === session }
        if (transfer != null) { if (BuildConfig.DEBUG) debugResponseSeen = true; debugEvent("NATIVE_RESPONSE") }
        if (stamps.isEmpty() && (transfer == null || transfer.attempt.phase == OwnedDownloadAttempt.Phase.DELIVERED)) return false
        if (transfer == null || stamps.size != 1 || stamps.single() != transfer.attempt.stamp || response.body == null ||
            !current(transfer) || response.statusCode != 200 || !OwnedDownloadAttempt.isImageMime(response.headers.entries
                .firstOrNull { it.key.equals("content-type", true) }?.value.orEmpty())) {
            closeInput(response.body); transfer?.let { fail(it, "This image request could not be verified. Open the image and try there.") }; return true
        }
        // Gecko suspends this ORIGINAL channel until the body is read. Revalidate the exact document before handing it off.
        val handedOff = AtomicBoolean()
        val job = scope.launch(Dispatchers.Main.immediate) {
            try {
                if (!checkDocument(transfer) || !current(transfer) || !transfer.attempt.deliver(stamps.single(), response.uri, response.redirected,
                        SystemClock.elapsedRealtime(), source(transfer.owner))) return@launch
                response.setReadTimeoutMillis(60_000)
                val raw = requireNotNull(response.body)
                val input = object : FilterInputStream(raw) {
                    private val ended = AtomicBoolean()
                    override fun close() {
                        if (!ended.compareAndSet(false, true)) return
                        try { super.close() } finally { main.post { finish(transfer) } }
                    }
                }
                transfer.input = input
                mutablePreparation.value = null
                val builder = WebResponse.Builder(response.uri).statusCode(response.statusCode).redirected(response.redirected).isSecure(response.isSecure).body(input)
                response.headers.forEach { (key, value) -> if (!key.equals(OwnedDownloadAttempt.RESPONSE_STAMP, true)) builder.header(key, value) }
                response.certificate?.let { builder.certificate(it) }
                post(transfer.content.port, JSONObject().put("command", "delivered").put("token", transfer.attempt.token))
                transfer.deliver(builder.build(), transfer.owner)
                handedOff.set(true)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { fail(transfer, "This image couldn't be saved from this page. Open the image and try there.") }
            finally { if (!handedOff.get()) { closeInput(response.body); fail(transfer, null) } }
        }
        job.invokeOnCompletion { if (!handedOff.get()) { closeInput(response.body); main.post { fail(transfer, null) } } }
        return true
    }

    private fun retireDocument(document: Document?) {
        // The old registration is already revoked. Its trusted content script owns
        // the only disconnect, even if a pagehide close is already in Gecko's queue.
        document?.let { post(it.port, JSONObject().put("command", "retire")) }
    }

    /** Navigation, account/epoch changes, Private lock, source hiding and engine disposal revoke pending authority. */
    fun invalidate(session: GeckoSession) {
        active?.takeIf { it.session === session }?.let { fail(it, null) }
        sessions[session]?.let { registration -> val old = registration.content; registration.content = null; retireDocument(old) }
    }
    fun cancel(token: String? = null) { active?.takeIf { token == null || it.attempt.token == token }?.let { fail(it, null) } }
    fun preparationCurrent(value: OwnedImagePreparation): Boolean = active?.let {
        it.attempt.token == value.token && it.owner === value.owner && it.attempt.phase != OwnedDownloadAttempt.Phase.DELIVERED && current(it)
    } == true
    fun revalidate() { active?.takeUnless(::current)?.let { fail(it, null) } }
    fun detach(session: GeckoSession) {
        invalidate(session); sessions.remove(session)
        extension?.let { session.webExtensionController.setMessageDelegate(it, null, NATIVE) }
    }
    fun close() {
        if (closed) return
        closed = true; active?.let { fail(it, null) }
        sessions.keys.toList().forEach(::detach)
        extension?.setMessageDelegate(null, NATIVE); extension = null
    }

    private fun sameSource(transfer: Transfer): Boolean = !closed && active === transfer && sessions[transfer.session] === transfer.registration &&
        transfer.session.settings.contextId == transfer.owner.profile && transfer.session.settings.usePrivateMode == transfer.owner.privateOrigin &&
        transfer.registration.content === transfer.content && transfer.registration.document() == transfer.owner.document &&
        transfer.content.nativeDocument == transfer.owner.document && runCatching(transfer.ownerCurrent).getOrDefault(false) &&
        (transfer.attempt.phase == OwnedDownloadAttempt.Phase.DELIVERED || transfer.registration.interactive())
    private fun current(transfer: Transfer): Boolean = sameSource(transfer) && transfer.attempt.current(SystemClock.elapsedRealtime(), source(transfer.owner))

    private suspend fun checkDocument(transfer: Transfer): Boolean = withTimeout(900) {
        if (!current(transfer)) return@withTimeout false
        val id = UUID.randomUUID().toString(); val answer = CompletableDeferred<Boolean>()
        checks[id] = Check(transfer, transfer.content.port, answer)
        debugEvent("DOCUMENT_CHECK_SENT")
        try {
            post(transfer.content.port, JSONObject().put("command", "check").put("token", transfer.attempt.token).put("check", id))
            answer.await() && current(transfer)
        } finally { checks.remove(id) }
    }
    private fun bindingMatches(transfer: Transfer, value: JSONObject): Boolean = value.frame() == transfer.attempt.frame
    private fun finish(transfer: Transfer) {
        if (active !== transfer) return
        if (BuildConfig.DEBUG) debugLastPhase = transfer.attempt.phase.name
        debugEvent("FINISHED")
        active = null; transfer.watch?.cancel(); transfer.attempt.close(); transfer.input = null
        mutablePreparation.value = null
        checks.entries.filter { it.value.transfer === transfer }.map { it.key }.forEach { checks.remove(it)?.answer?.complete(false) }
        post(transfer.content.port, JSONObject().put("command", "finish").put("token", transfer.attempt.token))
    }
    private fun fail(transfer: Transfer, message: String?) {
        if (active !== transfer) return
        val show = message != null && sameSource(transfer)
        val input = transfer.input; finish(transfer); closeInput(input)
        if (show) transfer.failure(requireNotNull(message))
    }
    private fun debugFailure(reason: String?) {
        if (!BuildConfig.DEBUG) return
        debugFailure = when (reason) {
            "source_changed" -> "SOURCE_CHANGED"; "frame_unavailable" -> "FRAME_UNAVAILABLE"
            "bridge_closed" -> "BRIDGE_CLOSED"; "request_timeout" -> "REQUEST_TIMEOUT"
            "request_refused" -> "REQUEST_REFUSED"; "prepare_failed" -> "PREPARE_FAILED"
            "prepare_source_before" -> "PREPARE_SOURCE_BEFORE"; "prepare_child" -> "PREPARE_CHILD"
            "prepare_source_after_child" -> "PREPARE_SOURCE_AFTER_CHILD"; "prepare_bind" -> "PREPARE_BIND"
            "prepare_bind_reply" -> "PREPARE_BIND_REPLY"; "prepare_source_after_bind" -> "PREPARE_SOURCE_AFTER_BIND"
            "prepare_duplicate" -> "PREPARE_DUPLICATE"
            "request_live" -> "REQUEST_LIVE"; "request_duplicate" -> "REQUEST_DUPLICATE"
            "request_method" -> "REQUEST_METHOD"; "request_type" -> "REQUEST_TYPE"
            "request_url" -> "REQUEST_URL"; "request_frame" -> "REQUEST_FRAME"
            "request_parent_frame" -> "REQUEST_PARENT_FRAME"; "request_parent_document" -> "REQUEST_PARENT_DOCUMENT"
            "request_cookie_store" -> "REQUEST_COOKIE_STORE"; "request_privacy" -> "REQUEST_PRIVACY"
            "request_source_before" -> "REQUEST_SOURCE_BEFORE"; "request_native_claim" -> "REQUEST_NATIVE_CLAIM"
            "request_native_reply" -> "REQUEST_NATIVE_REPLY"; "request_live_after" -> "REQUEST_LIVE_AFTER"
            "request_source_after" -> "REQUEST_SOURCE_AFTER"
            "native_refused" -> "NATIVE_REFUSED"; "frame_changed" -> "FRAME_CHANGED"
            "unsupported_response" -> "UNSUPPORTED_RESPONSE"; "redirect_unsupported" -> "REDIRECT_UNSUPPORTED"
            "request_failed" -> "REQUEST_FAILED"; "cancelled" -> "CANCELLED"
            else -> "OTHER"
        }
    }
    private fun closeInput(input: InputStream?) { if (input != null) scope.launch(NonCancellable + Dispatchers.IO) { runCatching { input.close() } } }
    private fun own(sender: WebExtension.MessageSender): Boolean = sender.webExtension.isBuiltIn && sender.webExtension.id == ID
    private fun post(port: WebExtension.Port, value: JSONObject) { runCatching { port.postMessage(value.put("v", 1)) } }
    private fun denied(): GeckoResult<Any> = GeckoResult.fromValue(GeckoBundle.fromJSONObject(no()))
    private fun no() = JSONObject().put("ok", false)
    private fun source(owner: PageDownloadOwner) = OwnedDownloadSource(owner.tab, owner.profile, owner.document, owner.privateOrigin, owner.account, owner.accountEpoch)
    private fun JSONObject.string(key: String): String? = opt(key) as? String
    private fun JSONObject.boolean(key: String): Boolean? = opt(key) as? Boolean
    private fun JSONObject.int(key: String): Long? {
        val number = opt(key) as? Number ?: return null
        val value = number.toDouble()
        return number.toLong().takeIf { value.isFinite() && value == it.toDouble() && kotlin.math.abs(value) <= 9_007_199_254_740_991.0 }
    }
    private fun JSONObject.frame(): OwnedDownloadFrame? {
        return OwnedDownloadFrame(string("bridge") ?: return null, string("document") ?: return null,
            int("tab") ?: return null, int("frame") ?: return null, string("cookieStore") ?: return null, boolean("privately") ?: return null)
    }
    private fun JSONObject.request(): OwnedDownloadRequest? {
        return OwnedDownloadRequest(string("id") ?: return null, string("url") ?: return null,
            string("method") ?: return null, string("type") ?: return null, int("tab") ?: return null, int("frame") ?: return null,
            int("parentFrame") ?: return null, string("parentDocument") ?: return null, string("cookieStore") ?: return null, boolean("privately") ?: return null)
    }
    companion object { const val ID = "yab-owned-image@browser.local"; private const val NATIVE = "yab_owned_image" }
}

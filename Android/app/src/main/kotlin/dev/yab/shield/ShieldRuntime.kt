package dev.yab.shield

import android.content.Context
import android.net.ConnectivityManager
import java.io.Closeable
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.WebExtension

data class ShieldStatus(val ready: Boolean = false, val rules: Int = 0, val skipped: Int = 0, val left: Int = 0,
    val unsupportedPopupRules: Int = 0, val refreshing: Boolean = false, val sources: List<ShieldListState> = emptyList(), val error: String? = null)

/** Only APK-owned background code receives these native policy messages. */
class ShieldRuntime(private val runtime: GeckoRuntime) : Closeable {
    private val json = Json { encodeDefaults = true }
    private val connected = MutableStateFlow<WebExtension.Port?>(null)
    // Keep each actual port replacement observable, even if both ports are connected.
    internal val connectionChanges: Flow<Boolean> = connected.map { it != null }
    private var extension: WebExtension? = null
    private var closed = false
    private var applied: ShieldRules? = null
    private val mutex = Mutex()
    private val pending = mutableMapOf<String, CompletableDeferred<Unit>>()
    private data class PopupWait(val owner: String, val result: CompletableDeferred<Boolean>)
    private val popups = mutableMapOf<String, PopupWait>()
    private var popupSupported = false
    private val failure = MutableStateFlow<String?>(null)
    val errors = failure.asStateFlow()
    private val delegate = object : WebExtension.MessageDelegate {
        override fun onConnect(port: WebExtension.Port) {
            val sender = port.sender
            if (closed || sender.session != null || sender.environmentType != WebExtension.MessageSender.ENV_TYPE_EXTENSION ||
                !sender.webExtension.isBuiltIn || sender.webExtension.id != ID) {
                runCatching { port.postMessage(JSONObject().put("command", "retire").put("revision", "refused")) }; return
            }
            connected.value?.takeIf { it !== port }?.let { old ->
                runCatching { old.postMessage(JSONObject().put("command", "retire").put("revision", "retire")) }
            }
            applied = null; popupSupported = false; connected.value = port
            port.setDelegate(object : WebExtension.PortDelegate {
                override fun onPortMessage(message: Any, source: WebExtension.Port) {
                    if (connected.value !== source) return
                    val value = message as? JSONObject ?: return
                    if (value.optString("kind") == "capability-error") {
                        failure.value = value.optString("error", "Shield document integration failed"); return
                    }
                    if (value.optString("kind") == "popup") {
                        val waiting = popups.remove(value.optString("request")) ?: return
                        waiting.result.complete(value.optString("owner") == waiting.owner && value.optBoolean("evaluated") && value.optBoolean("allowed"))
                        return
                    }
                    val request = pending.remove(value.optString("revision")) ?: return
                    if (value.optString("kind") == "configured" && value.optBoolean("popupSupported")) { popupSupported = true; request.complete(Unit) }
                    else request.completeExceptionally(IllegalStateException(value.optString("error", "Shield configuration failed")))
                }
                override fun onDisconnect(source: WebExtension.Port) {
                    if (connected.value !== source) return
                    connected.value = null; applied = null; popupSupported = false
                    pending.values.forEach { it.completeExceptionally(IllegalStateException("Shield background disconnected")) }; pending.clear()
                    popups.values.forEach { it.result.complete(false) }; popups.clear()
                }
            })
        }
    }
    /** The same owned matcher evaluates popup loads before Gecko creates a window. */
    suspend fun allowsPopup(request: ShieldPopupRequest): Boolean = withTimeout(2_000) {
        mutex.withLock { withContext(Dispatchers.Main.immediate) {
            if (closed || !popupSupported || applied == null) return@withContext false
            val port = connected.value ?: return@withContext false
            val id = UUID.randomUUID().toString(); val done = CompletableDeferred<Boolean>()
            popups[id] = PopupWait(request.owner, done)
            try {
                port.postMessage(JSONObject().put("command", "popup").put("revision", id).put("request", id).put("owner", request.owner)
                    .put("url", request.url).put("page", request.page).put("privately", request.privately))
                done.await() && connected.value === port && !closed
            } finally { popups.remove(id) }
        } }
    }
    fun checkPopup(request: ShieldPopupRequest, scope: CoroutineScope): GeckoResult<Boolean> {
        val answer = GeckoResult<Boolean>()
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try { answer.complete(allowsPopup(request)) }
            catch (_: CancellationException) { answer.complete(false) }
            catch (_: Exception) { answer.complete(false) }
        }
        return answer
    }
    init {
        check(owners[runtime]?.closed != false) { "One Shield owner is allowed per Gecko runtime" }
        owners[runtime] = this
        runtime.webExtensionController.ensureBuiltIn("resource://android/assets/web_extensions/shield/", ID).accept(install@{ candidate ->
            val own = candidate ?: run { failure.value = "Shield could not start"; return@install }
            check(own.isBuiltIn && own.id == ID)
            runtime.webExtensionController.setAllowedInPrivateBrowsing(own, true).accept(allowPrivate@{ candidate ->
                val ready = candidate ?: run { failure.value = "Private Shield could not start"; return@allowPrivate }
                if (!closed) { extension = ready; ready.setMessageDelegate(delegate, NATIVE) }
            }, { error -> failure.value = error?.message ?: "Private Shield could not start" })
        }, { error -> failure.value = error?.message ?: "Shield could not start" })
    }
    suspend fun configure(rules: ShieldRules, policy: ShieldPolicy) = mutex.withLock {
        withContext(Dispatchers.Main.immediate) {
            check(!closed) { "Shield is closed" }
            val port = withTimeout(20_000) { connected.filterNotNull().first() }
            val revision = UUID.randomUUID().toString(); val done = CompletableDeferred<Unit>(); pending[revision] = done
            fun send(message: JSONObject) { check(connected.value === port && !closed) { "Shield background changed" }; port.postMessage(message.put("revision", revision)) }
            try {
                if (applied !== rules) {
                    val buckets = linkedMapOf("blocks" to rules.blocks, "exceptions" to rules.exceptions, "important" to rules.important,
                        "generic" to rules.generic, "unhide" to rules.unhide)
                    send(JSONObject().put("command", "begin").put("count", buckets.values.sumOf { it.size }))
                    for ((bucket, values) in buckets) for (chunk in values.chunked(400)) {
                        currentCoroutineContext().ensureActive()
                        send(JSONObject().put("command", "chunk").put("bucket", bucket).put("rules", JSONArray(json.encodeToString(chunk))))
                        yield()
                    }
                    send(JSONObject().put("command", "commit").put("policy", JSONObject(json.encodeToString(policy))))
                } else send(JSONObject().put("command", "policy").put("policy", JSONObject(json.encodeToString(policy))))
                withTimeout(30_000) { done.await() }; applied = rules; failure.value = null
            } finally { pending.remove(revision) }
        }
    }
    override fun close() {
        if (closed) return
        closed = true
        val port = connected.value
        connected.value = null; applied = null
        // Let the trusted extension close its end once. A local disconnect racing
        // Gecko's queued remote disconnect shuts down the native dispatcher twice.
        port?.let { runCatching { it.postMessage(JSONObject().put("command", "shutdown").put("revision", "close")) } }
        pending.values.forEach { it.cancel() }; pending.clear()
        popups.values.forEach { it.result.complete(false) }; popups.clear()
        if (owners[runtime] === this) { extension?.setMessageDelegate(null, NATIVE); owners.remove(runtime) }
        extension = null
    }
    companion object {
        const val ID = "yab-shield@browser.local"; private const val NATIVE = "yab.shield"
        private val owners = java.util.WeakHashMap<GeckoRuntime, ShieldRuntime>()
    }
}

/** Retained with the browser, so Private site choices never enter a disk snapshot. */
class ShieldController(context: Context, runtime: GeckoRuntime, private val scope: CoroutineScope,
    val policies: ShieldPolicyStore = ShieldPolicyStore(File(context.filesDir, "shield-policy.json")),
    private val automaticDownloads: Boolean = true) : Closeable {
    private val app = context.applicationContext
    private val native = ShieldRuntime(runtime)
    private val cache = ShieldListCache(File(app.filesDir, "Shield/lists"))
    private val mutable = MutableStateFlow(ShieldStatus())
    val state = mutable.asStateFlow()
    private val rules = MutableStateFlow<ShieldRules?>(null)
    private var textsDigest: String? = null
    private var buildError: String? = null
    private val refreshMutex = Mutex()
    private var closed = false
    private var visible = false
    private var automaticRefresh: Job? = null
    private val job = scope.launch {
        launch { rebuild() }
        launch {
            combine(rules.filterNotNull(), policies.state, native.connectionChanges) { converted, policy, connected ->
                Triple(converted, policy, connected)
            }.collectLatest { (converted, policy, connected) ->
                if (!connected) {
                    mutable.value = mutable.value.copy(ready = false)
                    return@collectLatest
                }
                val error = shieldApplyFailure { native.configure(converted, policy) }
                mutable.value = if (error == null) mutable.value.copy(ready = true, unsupportedPopupRules = 0, error = buildError)
                    else mutable.value.copy(ready = false, error = error.message ?: "Shield could not be applied")
            }
        }
        launch { native.errors.filterNotNull().collect { mutable.value = mutable.value.copy(ready = false, error = it) } }
    }
    fun foreground() {
        if (closed || visible || !automaticDownloads) return
        visible = true
        automaticRefresh = scope.launch { delay(30_000); refresh() }
    }
    fun background() { visible = false; automaticRefresh?.cancel(); automaticRefresh = null }
    fun checkPopup(request: ShieldPopupRequest): GeckoResult<Boolean> = native.checkPopup(request, scope)
    /** Await the native policy before a caller reloads the page for a site choice. */
    suspend fun setSite(host: String?, privately: Boolean, enabled: Boolean): Boolean {
        policies.setSite(host, privately, enabled)
        val expected = policies.state.value
        val converted = withTimeout(20_000) { rules.filterNotNull().first() }
        native.configure(converted, expected)
        return !closed && policies.state.value == expected
    }
    suspend fun refresh(explicit: Boolean = false) = refreshMutex.withLock {
        if (closed || !explicit && !policies.state.value.global) return@withLock
        mutable.value = mutable.value.copy(refreshing = true)
        try {
            val metered = (app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)?.isActiveNetworkMetered != false
            val results = mutableListOf<ShieldListState>()
            for (source in ShieldLists.sources) {
                currentCoroutineContext().ensureActive(); if (closed) return@withLock
                results += cache.refresh(source, explicit, metered)
            }
            rebuild(); mutable.value = mutable.value.copy(sources = results)
        } finally { mutable.value = mutable.value.copy(refreshing = false) }
    }
    private data class Build(val digest: String, val selected: ShieldSelection.Selected, val skipped: Int, val warning: String? = null)
    private suspend fun rebuild() {
        val converted = try { withContext(Dispatchers.Default) {
            val base = app.assets.open("web_extensions/shield/base.txt").bufferedReader().use { it.readText() }
            val texts = listOf(base) + ShieldLists.sources.mapNotNull(cache::read)
            val digest = ShieldLists.digest(texts)
            if (digest == textsDigest) return@withContext null
            try {
                val all = ShieldFilters.convert(texts)
                Build(digest, ShieldSelection.select(all), all.skipped)
            } catch (error: Exception) {
                if (rules.value != null) throw error
                val fallback = ShieldFilters.convert(listOf(base))
                Build(digest, ShieldSelection.select(fallback), fallback.skipped, "Cached lists could not be converted. The built-in rules remain active.")
            }
        } } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            buildError = error.message ?: "Shield conversion failed; keeping existing rules"
            mutable.value = mutable.value.copy(error = buildError); null
        } ?: return
        if (closed) return
        textsDigest = converted.digest; buildError = converted.warning; val selection = converted.selected
        mutable.value = mutable.value.copy(rules = selection.rules.count, skipped = converted.skipped, left = selection.left, error = buildError,
            unsupportedPopupRules = (selection.rules.blocks + selection.rules.important + selection.rules.exceptions).count { "popup" in it.types },
            sources = ShieldLists.sources.map { cache.state(it) })
        rules.value = selection.rules
    }
    override fun close() { closed = true; background(); job.cancel(); native.close() }
}

/** The iPhone's 50k list / shared 447k selection budget, without repeated tail rules. */
object ShieldSelection {
    data class Selected(val rules: ShieldRules, val left: Int)
    fun select(rules: ShieldRules, perList: Int = 50_000, cap: Int = 447_000): Selected {
        val most = maxOf(1, cap / perList); val limit = perList / 4
        check(rules.exceptions.size <= limit) { "Too many filter exceptions; keep the last working rules" }
        val important = rules.important.take(limit - rules.exceptions.size)
        val whole = rules.exceptions.count { it.types.isEmpty() }
        val unhide = rules.unhide.take(maxOf(0, limit - whole))
        val room = perList - rules.exceptions.size - important.size
        val needed = if (rules.blocks.isEmpty() && important.isEmpty()) 0 else maxOf(1, (rules.blocks.size + room - 1) / room)
        val blocks = rules.blocks.take(most * room)
        val generic = rules.generic.take((most - minOf(needed, most)) * (perList - whole - unhide.size))
        val selected = rules.copy(blocks = blocks, important = important, generic = generic, unhide = unhide)
        return Selected(selected, rules.count - selected.count)
    }
}

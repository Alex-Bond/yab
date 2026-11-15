package dev.yab.core.sync

import dev.yab.core.crypto.Seal
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.Closeable
import java.io.IOException
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

data class Device(val id: String, val name: String, val model: String, val platform: String = "android", val formFactor: String = "phone") {
    init { require(id.matches(Regex("[A-Za-z0-9_-]{1,64}"))); require(name.length <= 200 && model.length <= 200) }
    fun toJson(): JsonObject = buildJsonObject { put("id", id); put("name", name); put("model", model); put("platform", platform); put("formFactor", formFactor); put("androidSync", 1) }
}
data class ListedDevice(val id: String, val name: String, val model: String, val lastSeen: Long?, val revoked: Boolean,
                        val platform: String?, val formFactor: String?)

sealed class SyncState {
    data object Off : SyncState()
    data object Connecting : SyncState()
    data object Live : SyncState()
    data class Waiting(val reason: String) : SyncState()
    data class Refused(val reason: String) : SyncState()
}

/** All state transitions and callbacks run on one owned serial executor, never a UI thread. */
class SyncClient(
    baseUrl: String, val journal: Journal, val seal: Seal, val device: Device,
    initialToken: String? = null, http: OkHttpClient = OkHttpClient(),
    private val saveToken: (String?) -> Unit = {},
    private val allowInsecureForTests: Boolean = false,
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { runnable -> Thread(runnable, "yab-sync").apply { isDaemon = true } },
) : Closeable {
    private val base = baseUrl.toHttpUrl()
    private val http = http.newBuilder().followRedirects(false).followSslRedirects(false).pingInterval(30, TimeUnit.SECONDS).build()
    @Volatile var state: SyncState = SyncState.Off; private set
    @Volatile var token: String? = initialToken; private set
    var onState: (SyncState) -> Unit = {}
    var onRecords: (List<Record>) -> Unit = {}
    var onOutbox: (Int) -> Unit = {}
    var onPresence: (String, Record) -> Unit = { _, _ -> }
    var presence: () -> Record? = { null }
    var onFailure: (Throwable) -> Unit = {}
    private var running = false; @Volatile private var disposed = false; private var generation = 0L; private var retry = 0
    private var registrationVerified = false
    @Volatile private var queueThread: Thread? = null
    private var socket: WebSocket? = null; private var registration: Call? = null; private var reconnect: ScheduledFuture<*>? = null
    private var presenceTimer: ScheduledFuture<*>? = null; private var caughtUp = false; private var nextPush = 0L
    private val inFlight = linkedMapOf<String, VersionedRecord>(); private val stuck = mutableSetOf<String>(); private val full = mutableSetOf<String>()
    private val alerts = mutableMapOf<String, Pair<String, Boolean>>(); private var freed = false
    init {
        require(journal.device == device.id) { "Journal identity mismatch" }
        require(base.isHttps || allowInsecureForTests && base.host in setOf("localhost", "127.0.0.1", "::1", "10.0.2.2")) { "Sync requires HTTPS" }
        require(base.username.isEmpty() && base.password.isEmpty() && base.query == null && base.fragment == null)
    }
    private fun dispatch(action: () -> Unit) {
        if (disposed) return
        executor.execute { queueThread = Thread.currentThread(); if (!disposed) try { action() } catch (error: Exception) { onFailure(error); if (running) waitForConnection("Sync could not save or read its data") } }
    }
    private fun setState(value: SyncState) { if (state != value) { state = value; onState(value) } }
    private fun endpoint(vararg segments: String): HttpUrl = base.newBuilder().apply { segments.forEach(::addPathSegment) }.build()
    fun start() = dispatch {
        if (!running && state !is SyncState.Refused) { running = true; retry = 0; dial() }
    }
    fun stop() = dispatch { stopNow() }
    private fun stopNow() {
        running = false; registrationVerified = false; generation++; registration?.cancel(); registration = null; reconnect?.cancel(false)
        presenceTimer?.cancel(false); socket?.close(1000, "Stopped"); socket = null; inFlight.clear(); setState(SyncState.Off)
    }
    fun kick() = dispatch { push() }
    fun kickAlert(key: RecordKey, withdraw: Boolean = false) = dispatch { alerts[seal.name(key)] = key.id to withdraw; push() }
    fun sayPresence() = dispatch { sendPresence() }
    private fun dial() {
        if (!running || state is SyncState.Refused) return
        reconnect?.cancel(false); setState(SyncState.Connecting); val current = ++generation
        if (token != null && registrationVerified) { connect(current); return }
        val body = buildJsonObject { put("secret", seal.secret); put("device", device.toJson()) }
        registration = http.newCall(jsonRequest(endpoint("v1", "accounts", seal.account, "devices"), "POST", body))
        registration!!.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = dispatch { if (current == generation && running) waitForConnection("No connection") }
            override fun onResponse(call: Call, response: Response) {
                response.use {
                    val status = it.code
                    val body = runCatching { readObject(it) }.getOrNull()
                    dispatch {
                        if (current != generation || !running) return@dispatch
                        registration = null
                        when (status) {
                            200 -> {
                                val received = body?.get("token")?.jsonPrimitive?.contentOrNull
                                if (received.isNullOrBlank()) { waitForConnection("Invalid sync response"); return@dispatch }
                                saveToken(received); token = received; registrationVerified = true; connect(current)
                            }
                            403 -> refuse(if (body?.get("error")?.jsonPrimitive?.contentOrNull == "revoked") "This device was removed from Sync" else "This key is not the account key")
                            409 -> waitForConnection(if (body?.get("error")?.jsonPrimitive?.contentOrNull == "android-sync-upgrade-required") ANDROID_UPGRADE else "Sync server unavailable ($status)")
                            else -> waitForConnection("Sync server unavailable ($status)")
                        }
                    }
                }
            }
        })
    }
    private fun connect(current: Long) {
        caughtUp = false; inFlight.clear(); full.clear(); freed = false
        val request = Request.Builder().url(endpoint("v1", "accounts", seal.account, "socket"))
            .header("Authorization", "Bearer ${token ?: return}").header("X-Yab-Android-Sync", "1").build()
        socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = dispatch {
                if (current != generation || !running) { webSocket.close(1000, "Old connection"); return@dispatch }
                // A peer can close immediately after upgrading. A false enqueue
                // here must leave the queued close/failure callback to classify
                // its actual code (revoked/upgrade), rather than advancing the
                // generation with a generic send error and discarding that code.
                webSocket.send(buildJsonObject { put("t", "hello"); put("cursor", journal.cursor); put("v", 1) }.toString())
            }
            override fun onMessage(webSocket: WebSocket, text: String) = dispatch {
                if (current == generation && running) {
                    require(text.toByteArray(Charsets.UTF_8).size <= 16 * 1024 * 1024) { "Sync message too large" }
                    heard(wireJson.parseToJsonElement(text).jsonObject)
                }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = dispatch { if (current == generation && running) lost(code) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = dispatch { if (current == generation && running) lost(response?.code) }
        })
    }
    private fun refuse(reason: String) { running = false; generation++; socket?.cancel(); socket = null; presenceTimer?.cancel(false); setState(SyncState.Refused(reason)) }
    private fun lost(code: Int?) {
        if (code == 4003) { refuse("This device was removed from Sync"); return }
        if (code == 4004 || code == 409) { registrationVerified = false; waitForConnection(ANDROID_UPGRADE); return }
        if (code == 4001 || code == 401) { saveToken(null); token = null; registrationVerified = false }
        waitForConnection("No connection")
    }
    private fun waitForConnection(reason: String) {
        generation++; socket?.cancel(); socket = null; inFlight.clear(); presenceTimer?.cancel(false)
        if (!running || state is SyncState.Refused) return
        setState(SyncState.Waiting(reason)); reconnect?.cancel(false)
        val delay = minOf(60, 1L shl minOf(retry++, 6))
        reconnect = executor.schedule({ if (running && !disposed) dial() }, delay, TimeUnit.SECONDS)
    }
    private fun openItem(item: JsonObject): VersionedRecord {
        val name = item.getValue("name").jsonPrimitive.content
        val blob = Base64.getDecoder().decode(item.getValue("blob").jsonPrimitive.content)
        val version = item.getValue("version").jsonPrimitive.long
        require(version >= 0)
        return VersionedRecord(seal.open(blob, name), version)
    }
    private fun heard(message: JsonObject) {
        when (message.getValue("t").jsonPrimitive.content) {
            "changes" -> {
                // An unreadable record prevents cursor advancement, so data is not silently lost.
                val incoming = message.getValue("items").jsonArray.map { openItem(it.jsonObject) }
                val cursor = message.getValue("cursor").jsonPrimitive.long
                val changed = journal.receive(incoming, cursor); if (changed.isNotEmpty()) onRecords(changed)
                if (message["more"]?.jsonPrimitive?.booleanOrNull != true && !caughtUp) {
                    caughtUp = true; retry = 0; setState(SyncState.Live); push(); sendPresence()
                    presenceTimer?.cancel(false); presenceTimer = executor.scheduleAtFixedRate({ dispatch { sendPresence() } }, 55, 55, TimeUnit.SECONDS)
                }
            }
            "pushed" -> {
                val sent = mutableListOf<VersionedRecord>(); var top = journal.cursor
                for (element in (message["accepted"] as? JsonArray).orEmpty()) {
                    val item = element.jsonObject; val name = item.getValue("name").jsonPrimitive.content
                    val flight = inFlight.remove(name) ?: continue
                    sent += VersionedRecord(flight.record, item.getValue("version").jsonPrimitive.long)
                    if (journal.record(flight.record.key) == flight.record) alerts.remove(name)
                    top = maxOf(top, item["seq"]?.jsonPrimitive?.longOrNull ?: 0)
                }
                journal.sent(sent, top)
                val conflicts = mutableListOf<VersionedRecord>()
                for (element in (message["conflicts"] as? JsonArray).orEmpty()) {
                    val item = element.jsonObject; val flight = inFlight.remove(item.getValue("name").jsonPrimitive.content) ?: continue
                    if (item["blob"] == null || item["blob"] == JsonNull) journal.rebase(flight.record.key, item["version"]?.jsonPrimitive?.longOrNull ?: 0)
                    else conflicts += openItem(item)
                }
                if (conflicts.isNotEmpty()) { val changed = journal.receive(conflicts); if (changed.isNotEmpty()) onRecords(changed) }
                if (sent.isNotEmpty() && full.isNotEmpty()) freed = true
                for (element in (message["rejected"] as? JsonArray).orEmpty()) {
                    val item = element.jsonObject; val name = item.getValue("name").jsonPrimitive.content
                    if (item["code"]?.jsonPrimitive?.content == "full") full.add(name) else stuck.add(name)
                    inFlight.remove(name)
                }
                if (inFlight.isEmpty()) push()
                onOutbox(journal.pending(Int.MAX_VALUE).size)
            }
            "presence" -> {
                val sender = message.getValue("device").jsonPrimitive.content
                val record = seal.open(Base64.getDecoder().decode(message.getValue("blob").jsonPrimitive.content), seal.name(RecordKey("presence", sender)))
                onPresence(sender, record)
            }
            "error" -> if (message["code"]?.jsonPrimitive?.content == "full") setState(SyncState.Waiting("Sync is full"))
        }
    }
    private fun push() {
        if (!caughtUp || socket == null || inFlight.isNotEmpty() || state != SyncState.Live && state != SyncState.Waiting("Sync is full")) return
        val pending = journal.pending(200 + stuck.size + full.size).filter { seal.name(it.record.key).let { name -> name !in stuck && name !in full } && dependenciesReady(it.record) }.take(200)
        if (pending.isEmpty()) {
            if (full.isNotEmpty() && freed) { full.clear(); freed = false; push() }
            else if (full.isEmpty()) setState(SyncState.Live)
            return
        }
        val changes = mutableListOf<JsonElement>(); var bytes = 0; var alert: String? = null
        for (flight in pending) {
            val name = seal.name(flight.record.key); val blob = Base64.getEncoder().encodeToString(seal.seal(flight.record))
            if (changes.isNotEmpty() && bytes + blob.length > PUSH_BYTES || alert != null && name in alerts) break
            if (name in alerts) alert = name
            bytes += blob.length; inFlight[name] = flight
            changes += buildJsonObject { put("name", name); put("base", flight.version); put("blob", blob) }
        }
        send(buildJsonObject {
            put("t", "push"); put("id", "p${++nextPush}"); put("changes", JsonArray(changes))
            alert?.let { name -> put("alert", name); alerts[name]?.let { (id, withdraw) ->
                if (runCatching { java.util.UUID.fromString(id) }.isSuccess) { put("alertID", id); if (withdraw) put("withdraw", true) }
            } }
        })
    }
    private fun dependenciesReady(record: Record): Boolean {
        fun ready(key: RecordKey): Boolean = journal.record(key)?.alive() == true && !journal.isPending(key)
        if (record.collection == "send") for (file in (record["files"] as? JsonArray).orEmpty())
            for (part in (file.jsonObject["parts"] as? JsonArray).orEmpty()) if (!ready(RecordKey("sendpart", part.jsonPrimitive.content))) return false
        if (record.collection == "assistantanswer") {
            val body = (record["body"] as? JsonPrimitive)?.contentOrNull?.let { runCatching { wireJson.parseToJsonElement(it).jsonObject }.getOrNull() } ?: return true
            for (id in (body["added"] as? JsonArray).orEmpty()) {
                val value = id.jsonPrimitive.content
                if (!ready(RecordKey("card", value)) && !ready(RecordKey("address", value))) return false
            }
        }
        return true
    }
    private fun sendPresence() {
        if (state != SyncState.Live) return
        val record = presence() ?: return
        require(record.key == RecordKey("presence", device.id)) { "Presence identity mismatch" }
        send(buildJsonObject { put("t", "presence"); put("blob", Base64.getEncoder().encodeToString(seal.seal(record))) })
    }
    private fun send(message: JsonObject) { if (socket?.send(message.toString()) != true) throw IOException("Sync socket closed") }

    /** Callback returns on the sync queue; unsuccessful requests never invent a local success. */
    fun devices(done: (Result<List<ListedDevice>>) -> Unit) = accountCall("GET", listOf("devices")) { result ->
        done(result.map { response ->
            require(response.first == 200)
            response.second!!.getValue("devices").jsonArray.map { value -> val d = value.jsonObject; ListedDevice(
                d.getValue("id").jsonPrimitive.content, d["name"]?.jsonPrimitive?.content ?: "", d["model"]?.jsonPrimitive?.content ?: "",
                d["lastSeen"]?.jsonPrimitive?.longOrNull, d["revoked"]?.jsonPrimitive?.booleanOrNull ?: false,
                d["platform"]?.jsonPrimitive?.contentOrNull, d["formFactor"]?.jsonPrimitive?.contentOrNull)
            }
        })
    }
    fun removeDevice(id: String, done: (Result<Boolean>) -> Unit) = accountCall("DELETE", listOf("devices", id)) { done(it.map { response -> response.first in listOf(200, 204) }) }
    fun deleteAccount(done: (Result<Boolean>) -> Unit) = accountCall("DELETE", emptyList()) { done(it.map { response -> response.first in listOf(200, 204) }) }
    fun registerPush(body: JsonObject, done: (Result<Boolean>) -> Unit) = accountCall("PUT", listOf("devices", device.id, "push"), body) { done(it.map { response -> response.first == 204 }) }
    fun unregisterPush(done: (Result<Boolean>) -> Unit) = accountCall("DELETE", listOf("devices", device.id, "push")) { done(it.map { response -> response.first in listOf(200, 204) }) }
    private fun accountCall(method: String, path: List<String>, body: JsonObject? = null, done: (Result<Pair<Int, JsonObject?>>) -> Unit) = dispatch {
        val saved = token ?: return@dispatch done(Result.failure(IllegalStateException("Sync is not registered")))
        val request = jsonRequest(endpoint(*listOf("v1", "accounts", seal.account).plus(path).toTypedArray()), method, body).newBuilder().header("Authorization", "Bearer $saved").build()
        http.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = dispatch { done(Result.failure(e)) }
            override fun onResponse(call: Call, response: Response) { response.use { val result = runCatching { it.code to (if (it.code == 204) null else readObject(it)) }; dispatch { done(result) } } }
        })
    }
    override fun close() {
        if (disposed) return
        if (Thread.currentThread() === queueThread) { stopNow(); disposed = true; executor.shutdown(); return }
        executor.submit { stopNow(); disposed = true }.get(5, TimeUnit.SECONDS)
        executor.shutdown()
    }
    companion object {
        const val PUSH_BYTES = 768 * 1024
        const val ANDROID_UPGRADE = "Update Yab on every device before syncing with Android"
        internal fun jsonRequest(url: HttpUrl, method: String, body: JsonObject?): Request = Request.Builder().url(url).method(method,
            body?.toString()?.toRequestBody("application/json".toMediaType()) ?: if (method in listOf("POST", "PUT")) byteArrayOf().toRequestBody() else null).build()
        internal fun readObject(response: Response): JsonObject {
            val source = response.body?.source() ?: throw IOException("Missing sync response")
            if (source.request(1024L * 1024 + 1)) throw IOException("Sync response too large")
            return wireJson.parseToJsonElement(source.readUtf8()).jsonObject
        }
    }
}

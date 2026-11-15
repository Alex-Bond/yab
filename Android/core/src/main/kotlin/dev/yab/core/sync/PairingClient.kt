package dev.yab.core.sync

import dev.yab.core.crypto.Joining
import dev.yab.core.crypto.Seal
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.Closeable
import java.io.IOException
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class PairingFailure(val kind: Kind) : IOException("Pairing ${kind.name.lowercase()}") {
    enum class Kind { EXPIRED, CANCELLED, CODE_TAKEN, SERVER, UNREADABLE, CHANGED }
}

/** Short-lived key exchange. The caller must save the returned key durably before registering. */
class PairingClient(baseUrl: String, http: OkHttpClient = OkHttpClient(), allowInsecureForTests: Boolean = false) {
    private val base = baseUrl.toHttpUrl()
    private val http = http.newBuilder().followRedirects(false).followSslRedirects(false).build()
    init { require(base.isHttps || allowInsecureForTests && base.host in setOf("localhost", "127.0.0.1", "::1", "10.0.2.2")); require(base.username.isEmpty() && base.password.isEmpty() && base.query == null && base.fragment == null) }
    private fun endpoint(box: String? = null): HttpUrl = base.newBuilder().addPathSegment("v1").addPathSegment("pair").apply { box?.let(::addPathSegment) }.build()

    fun join(joining: Joining = Joining(), timeoutSeconds: Long = 600, pollMillis: Long = 2000,
             done: (Result<Seal>) -> Unit): Session {
        require(timeoutSeconds in 1..600 && pollMillis >= 10)
        return Session(joining, timeoutSeconds, pollMillis, done).also { it.start() }
    }

    inner class Session internal constructor(val joining: Joining, timeout: Long, private val pollMillis: Long,
                                             private val done: (Result<Seal>) -> Unit) : Closeable {
        private val queue = Executors.newSingleThreadScheduledExecutor { Thread(it, "yab-pairing").apply { isDaemon = true } }
        private val ended = AtomicBoolean(false)
        private val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeout)
        @Volatile private var call: Call? = null
        val code get() = joining.code
        val check get() = joining.check
        internal fun start() {
            request(SyncClient.jsonRequest(endpoint(), "POST", buildJsonObject { put("code", joining.box); put("pub", joining.posted) })) { status, _ ->
                when (status) { 200, 204 -> poll(); 409 -> finish(Result.failure(PairingFailure(PairingFailure.Kind.CODE_TAKEN))); else -> finish(Result.failure(PairingFailure(PairingFailure.Kind.SERVER))) }
            }
        }
        private fun poll() {
            if (ended.get()) return
            if (System.nanoTime() >= deadline) { finish(Result.failure(PairingFailure(PairingFailure.Kind.EXPIRED))); return }
            queue.schedule({
                if (ended.get()) return@schedule
                request(Request.Builder().url(endpoint(joining.box)).build()) { status, body ->
                    if (System.nanoTime() >= deadline) { finish(Result.failure(PairingFailure(PairingFailure.Kind.EXPIRED))); return@request }
                    if (status == 404) { finish(Result.failure(PairingFailure(PairingFailure.Kind.EXPIRED))); return@request }
                    val envelope = body?.get("envelope")?.jsonPrimitive?.contentOrNull
                    if (status == 200 && envelope != null) {
                        val result = runCatching { joining.open(Base64.getDecoder().decode(envelope)) }
                        finish(result.fold({ Result.success(it) }, { Result.failure(PairingFailure(PairingFailure.Kind.UNREADABLE)) }))
                    } else poll()
                }
            }, pollMillis, TimeUnit.MILLISECONDS)
        }
        private fun request(request: Request, received: (Int?, JsonObject?) -> Unit) {
            if (ended.get()) return
            call = http.newCall(request).also { call -> call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) { deliver { received(null, null) } }
                override fun onResponse(call: Call, response: Response) { response.use { val status = it.code; val body = runCatching { SyncClient.readObject(it) }.getOrNull(); deliver { received(status, body) } } }
            }) }
        }
        private fun deliver(action: () -> Unit) { if (!ended.get()) runCatching { queue.execute { if (!ended.get()) action() } } }
        private fun finish(result: Result<Seal>) { if (ended.compareAndSet(false, true)) { call?.cancel(); queue.shutdownNow(); done(result) } }
        override fun close() { finish(Result.failure(PairingFailure(PairingFailure.Kind.CANCELLED))) }
    }

    data class Challenge internal constructor(val code: String, val publicKey: ByteArray, val check: String)
    fun lookUp(code: String, done: (Result<Challenge>) -> Unit) {
        val clean = Joining.code(code) ?: return done(Result.failure(PairingFailure(PairingFailure.Kind.CHANGED)))
        http.newCall(Request.Builder().url(endpoint(Joining.box(clean))).build()).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) { done(Result.failure(e)) }
            override fun onResponse(call: Call, response: Response) { response.use {
                done(runCatching {
                    if (it.code != 200) throw PairingFailure(PairingFailure.Kind.SERVER)
                    val body = SyncClient.readObject(it)
                    val key = Joining.verified(body["pub"]?.jsonPrimitive?.contentOrNull, clean) ?: throw PairingFailure(PairingFailure.Kind.UNREADABLE)
                    Challenge(clean, key, Joining.check(clean, key))
                })
            } }
        })
    }
    /** Call only after the person confirms the displayed digits of this exact challenge. */
    fun answer(challenge: Challenge, seal: Seal, done: (Result<Boolean>) -> Unit) {
        lookUp(challenge.code) { current ->
            val checked = current.getOrElse { done(Result.failure(it)); return@lookUp }
            if (!java.security.MessageDigest.isEqual(checked.publicKey, challenge.publicKey)) { done(Result.failure(PairingFailure(PairingFailure.Kind.CHANGED))); return@lookUp }
            val body = buildJsonObject { put("envelope", Base64.getEncoder().encodeToString(Joining.seal(seal, checked.publicKey, checked.code))) }
            http.newCall(SyncClient.jsonRequest(endpoint(Joining.box(challenge.code)), "PUT", body)).enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) { done(Result.failure(e)) }
                override fun onResponse(call: Call, response: Response) { response.use { done(Result.success(it.code in listOf(200, 204))) } }
            })
        }
    }
}

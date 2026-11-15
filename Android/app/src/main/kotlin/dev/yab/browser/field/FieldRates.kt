package dev.yab.browser.field

import android.content.Context
import java.time.Duration
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Request

interface FieldRateSource {
    val state: StateFlow<FieldRatesSnapshot>
    fun warm()
}

/** Same three-hour cache and bounded failure backoff as current iPhone Rates. */
class FieldRatesController(
    private val scope: CoroutineScope,
    private val now: () -> Instant = Instant::now,
    initial: FieldRatesSnapshot = FieldRatesSnapshot(),
    private val persist: (FieldRatesSnapshot) -> Unit = {},
    private val fetch: suspend () -> Map<String, Double>?,
) : FieldRateSource {
    private val mutable = MutableStateFlow(initial)
    override val state: StateFlow<FieldRatesSnapshot> = mutable
    private var asking = false
    private var failures = 0

    override fun warm() {
        val at = now(); val current = mutable.value
        if (asking || current.fetchedAt?.let { Duration.between(it, at) <= Duration.ofHours(3) } == true || current.retryAt?.let { at < it } == true) return
        asking = true
        scope.launch {
            try {
                val received = try { fetch() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
                val rates = received?.filter { (code, value) -> code.matches(Regex("[A-Z]{3,5}")) && value > 0 && value.isFinite() }
                if (rates.isNullOrEmpty()) {
                    failures++
                    val seconds = minOf(60L * (1L shl (failures - 1).coerceAtMost(4)), 900L)
                    mutable.value = mutable.value.copy(failed = mutable.value.perDollar.isEmpty(), retryAt = at.plusSeconds(seconds))
                } else {
                    failures = 0
                    val updated = FieldRatesSnapshot(rates, now(), failed = false)
                    mutable.value = updated
                    runCatching { persist(updated) }
                }
            } finally { asking = false }
        }
    }

    companion object {
        /** Coinbase's response contains rates only. No field text is an input. */
        fun parse(text: String): Map<String, Double>? = runCatching {
            if (text.length > 512 * 1024) return null
            val rates = Json.parseToJsonElement(text).jsonObject["data"]?.jsonObject?.get("rates")?.jsonObject ?: return null
            if (rates.size > 2048) return null
            rates.mapNotNull { (key, value) ->
                value.jsonPrimitive.content.toDoubleOrNull()?.takeIf { it > 0 && it.isFinite() && key.matches(Regex("[A-Z]{3,5}")) }?.let { key to it }
            }.toMap().takeIf { it.isNotEmpty() }
        }.getOrNull()
    }
}

/** Process-wide public rates. The immutable URL is independent of anything being typed. */
object AndroidFieldRates {
    @Volatile private var shared: FieldRateSource? = null
    private const val ENDPOINT = "https://api.coinbase.com/v2/exchange-rates?currency=USD"

    fun get(context: Context): FieldRateSource = shared ?: synchronized(this) {
        shared ?: make(context.applicationContext).also { shared = it }
    }

    private fun make(context: Context): FieldRateSource {
        val cache = context.getSharedPreferences("field-calculator-rates", Context.MODE_PRIVATE)
        val initial = runCatching {
            val payload = cache.getString("response", null) ?: return@runCatching FieldRatesSnapshot()
            val timestamp = cache.getLong("fetchedAt", 0)
            val rates = FieldRatesController.parse(payload) ?: return@runCatching FieldRatesSnapshot()
            FieldRatesSnapshot(rates, Instant.ofEpochMilli(timestamp).takeIf { timestamp > 0 })
        }.getOrDefault(FieldRatesSnapshot())
        val client = OkHttpClient.Builder().callTimeout(10, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).build()
        return FieldRatesController(CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate), initial = initial,
            persist = { snapshot ->
                val payload = buildJsonObject { put("data", buildJsonObject { put("rates", buildJsonObject {
                    snapshot.perDollar.forEach { (key, value) -> put(key, value.toString()) }
                }) }) }.toString()
                cache.edit().putString("response", payload).putLong("fetchedAt", snapshot.fetchedAt?.toEpochMilli() ?: 0).apply()
            }, fetch = {
                withContext(Dispatchers.IO) {
                    client.newCall(Request.Builder().url(ENDPOINT).header("Accept", "application/json").build()).execute().use { response ->
                        if (response.code != 200) return@withContext null
                        val body = response.body ?: return@withContext null
                        if (body.contentLength() > 512 * 1024) return@withContext null
                        val output = java.io.ByteArrayOutputStream()
                        body.byteStream().use { input ->
                            val buffer = ByteArray(8192)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                if (output.size() + count > 512 * 1024) return@withContext null
                                output.write(buffer, 0, count)
                            }
                        }
                        FieldRatesController.parse(output.toString(Charsets.UTF_8.name()))
                    }
                }
            })
    }
}

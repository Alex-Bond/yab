package dev.yab.shield

import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request

data class ShieldSource(val name: String, val url: String, val least: Int)
data class ShieldListState(val name: String, val cached: Boolean, val refreshedAt: Long?, val error: String? = null)

/** Same source order, byte limits, freshness and fallback text as ShieldLists.swift. */
object ShieldLists {
    const val WEEK = 7L * 24 * 3600 * 1000
    const val MOST = 16 * 1024 * 1024
    val sources = listOf(
        ShieldSource("easylist", "https://easylist.to/easylist/easylist.txt", 100_000),
        ShieldSource("easyprivacy", "https://easylist.to/easylist/easyprivacy.txt", 100_000),
        ShieldSource("ublock-filters", "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt", 20_000),
        ShieldSource("ublock-badware", "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt", 10_000),
        ShieldSource("ublock-privacy", "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt", 10_000),
        ShieldSource("ublock-unbreak", "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt", 10_000),
        ShieldSource("ublock-quick-fixes", "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt", 1_000),
        ShieldSource("peter-lowe", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext", 10_000))
    fun digest(texts: List<String>): String = MessageDigest.getInstance("SHA-256").run {
        update(ShieldFilters.SCHEMA.toString().toByteArray()); texts.forEach { update(0); update(it.toByteArray()) }
        digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}

class ShieldListCache(private val directory: File,
    http: OkHttpClient = OkHttpClient()) {
    private val client = http.newBuilder().cookieJar(CookieJar.NO_COOKIES).cache(null)
        .followRedirects(false).followSslRedirects(false).callTimeout(60, TimeUnit.SECONDS).build()
    fun read(source: ShieldSource): String? = runCatching {
        val file = File(directory, source.name + ".txt")
        if (!file.isFile || file.length() !in source.least.toLong()..ShieldLists.MOST.toLong()) return null
        val bytes = file.readBytes()
        decode(bytes).takeIf { 10.toByte() in bytes.take(4096) }
    }.getOrNull()
    fun state(source: ShieldSource, error: String? = null): ShieldListState {
        val file = File(directory, source.name + ".txt")
        return ShieldListState(source.name, read(source) != null, file.lastModified().takeIf { file.isFile && it > 0 }, error)
    }
    suspend fun refresh(source: ShieldSource, explicit: Boolean = false, metered: Boolean = false): ShieldListState = withContext(Dispatchers.IO) {
        val old = state(source)
        if (!explicit && (metered || old.cached && System.currentTimeMillis() - (old.refreshedAt ?: 0) < ShieldLists.WEEK)) return@withContext old
        try {
            var url = source.url; var bytes: ByteArray? = null
            for (redirect in 0..8) {
                check(url.startsWith("https://")) { "Filter lists require HTTPS" }
                client.newCall(Request.Builder().url(url).header("Cache-Control", "no-cache, no-store").build()).execute().use { response ->
                    if (response.code in setOf(301, 302, 303, 307, 308)) {
                        val location = response.header("Location") ?: error("Filter redirect has no destination")
                        val next = response.request.url.resolve(location) ?: error("Invalid filter redirect")
                        check(next.isHttps && redirect < 8) { "Filter redirect must remain bounded HTTPS" }; url = next.toString()
                    } else {
                        check(response.code == 200) { "Filter server returned HTTP ${response.code}" }
                        val body = response.body ?: error("Filter server returned no content")
                        check(body.contentLength() <= ShieldLists.MOST) { "Filter list is too large" }
                        body.byteStream().use { input ->
                            val output = java.io.ByteArrayOutputStream(); val block = ByteArray(16 * 1024)
                            while (true) { val n = input.read(block); if (n < 0) break; check(output.size() + n <= ShieldLists.MOST) { "Filter list is too large" }; output.write(block, 0, n) }
                            bytes = output.toByteArray()
                        }
                    }
                }
                if (bytes != null) break
            }
            val content = bytes ?: error("Filter redirect limit reached")
            check(content.size >= source.least && 10.toByte() in content.take(4096)) { "Filter response is too short or malformed" }
            decode(content)
            directory.mkdirs(); val file = File(directory, source.name + ".txt"); val pending = File(directory, source.name + ".pending")
            try { pending.outputStream().use { it.write(content); it.fd.sync() }; check(pending.renameTo(file)) { "Filter cache could not be saved" } }
            finally { pending.delete() }
            state(source)
        } catch (error: Exception) { state(source, error.message ?: "Filter list could not be refreshed") }
    }
    private fun decode(bytes: ByteArray): String = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
}

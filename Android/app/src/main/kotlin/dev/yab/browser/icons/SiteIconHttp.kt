package dev.yab.browser.icons

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** An ephemeral icon request never borrows the browser's cookie, auth or cache clients. */
internal class SiteIconHttp {
    private val client = OkHttpClient.Builder().cookieJar(CookieJar.NO_COOKIES)
        .authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE).cache(null)
        .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
        .callTimeout(8, TimeUnit.SECONDS).connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS).build()

    /** A site's own page, for the icons it names. Its head is enough: a long page is cut, not refused. */
    suspend fun home(origin: SiteIconOrigin): String? = fetch(origin.address, origin, page = true)?.toString(Charsets.UTF_8)

    suspend fun fetch(address: String, origin: SiteIconOrigin, page: Boolean = false): ByteArray? = withTimeoutOrNull(8_000) {
        var next = address
        repeat(6) {
            if (!origin.reaches(next)) return@withTimeoutOrNull null
            val reply = request(next, page) ?: return@withTimeoutOrNull null
            when (reply) {
                is Reply.Picture -> return@withTimeoutOrNull reply.bytes
                is Reply.Redirect -> {
                    // Resolve relative redirects against the request itself, but never
                    // follow another scheme/host/port or an address with credentials.
                    val raw = runCatching { URI(reply.location) }.getOrNull() ?: return@withTimeoutOrNull null
                    if (raw.rawUserInfo != null) return@withTimeoutOrNull null
                    val redirected = next.toHttpUrlOrNull()?.resolve(reply.location)?.toString()
                        ?: return@withTimeoutOrNull null
                    if (!origin.reaches(redirected)) return@withTimeoutOrNull null
                    next = redirected
                }
            }
        }
        null
    }

    private sealed interface Reply {
        data class Picture(val bytes: ByteArray) : Reply
        data class Redirect(val location: String) : Reply
    }
    private suspend fun request(address: String, page: Boolean): Reply? = suspendCancellableCoroutine { continuation ->
        val request = Request.Builder().url(address).header("Accept", if (page) "text/html" else "image/*")
            // Sites refuse a library's name; this says what asks, and carries nothing of the person.
            .header("User-Agent", "Mozilla/5.0 (Android) Yab").build()
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) { continuation.resume(null) }
            override fun onResponse(call: Call, response: Response) {
                val result = try {
                    response.use {
                        if (it.code in setOf(301, 302, 303, 307, 308)) it.header("Location")?.takeIf { value -> value.length <= 4096 }?.let { location -> Reply.Redirect(location) }
                        else if (it.code !in 200..299 || it.body == null || !page && it.body!!.contentLength() > 1_048_576) null
                        else {
                            val output = ByteArrayOutputStream()
                            val source = it.body!!.byteStream()
                            val buffer = ByteArray(8192)
                            while (true) {
                                if (call.isCanceled()) throw IOException("Icon request cancelled")
                                val read = source.read(buffer)
                                if (read < 0) break
                                if (output.size() + read > 1_048_576) {
                                    if (page) break
                                    throw IOException("Icon response is too large")
                                }
                                output.write(buffer, 0, read)
                            }
                            Reply.Picture(output.toByteArray())
                        }
                    }
                } catch (_: IOException) { null }
                continuation.resume(result)
            }
        })
    }
}

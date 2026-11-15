package dev.yab.update

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

enum class UpdateDownloadResult { VERIFIED, TRY_AGAIN, REFUSED }

/**
 * Fetches an offered APK into private storage. Bytes stay in [part] across interruptions and go on
 * from there when the server honors Range. Only a matching SHA-256 becomes [apk]; anything else is deleted.
 */
class UpdateDownloader(client: OkHttpClient, private val endpoint: UpdateEndpoint, private val maxBytes: Long = UpdatePolicy.MAX_APK_BYTES,
    private val spare: Long = 64L * 1024 * 1024) {
    private val client = client.newBuilder().followRedirects(false).followSslRedirects(false).build()

    fun fetch(offer: UpdateOffer, part: File, apk: File, stopped: () -> Boolean = { false }): UpdateDownloadResult {
        if (apk.isFile && sha256(apk) == offer.sha256) return UpdateDownloadResult.VERIFIED
        apk.delete()
        return try {
            when (receive(offer, part, stopped)) {
                UpdateDownloadResult.VERIFIED -> if (sha256(part) == offer.sha256 && part.renameTo(apk)) UpdateDownloadResult.VERIFIED
                    else { part.delete(); UpdateDownloadResult.REFUSED }
                UpdateDownloadResult.REFUSED -> { part.delete(); UpdateDownloadResult.REFUSED }
                UpdateDownloadResult.TRY_AGAIN -> UpdateDownloadResult.TRY_AGAIN
            }
        } catch (_: IOException) { UpdateDownloadResult.TRY_AGAIN }
    }

    private fun receive(offer: UpdateOffer, part: File, stopped: () -> Boolean): UpdateDownloadResult {
        val resume = part.length()
        val response = open(offer, resume) ?: return UpdateDownloadResult.REFUSED
        response.use {
            val code = response.code
            if (code == 416) { part.delete(); return UpdateDownloadResult.TRY_AGAIN }
            if (code in 500..599 || code == 408 || code == 429) return UpdateDownloadResult.TRY_AGAIN
            if (code != 200 && code != 206) return UpdateDownloadResult.REFUSED
            val body = response.body ?: return UpdateDownloadResult.TRY_AGAIN
            val range = if (code == 206) response.header("Content-Range") else null
            val continues = resume > 0 && code == 206 && range?.startsWith("bytes $resume-") == true
            val start = if (continues) resume else 0L
            val whole = body.contentLength().takeIf { it >= 0 }?.plus(start)
            if (whole != null && whole > maxBytes) return UpdateDownloadResult.REFUSED
            part.parentFile?.mkdirs()
            RandomAccessFile(part, "rw").use { file ->
                file.setLength(start); file.seek(start)
                val buffer = ByteArray(64 * 1024)
                var total = start
                body.byteStream().use { source ->
                    while (true) {
                        if (stopped()) return UpdateDownloadResult.TRY_AGAIN
                        val count = source.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > maxBytes) return UpdateDownloadResult.REFUSED
                        if ((part.parentFile?.usableSpace ?: 0) < count + spare) return UpdateDownloadResult.TRY_AGAIN
                        file.write(buffer, 0, count)
                    }
                }
                file.fd.sync()
                if (whole != null && total != whole) return UpdateDownloadResult.TRY_AGAIN
            }
            return UpdateDownloadResult.VERIFIED
        }
    }

    /** Follows redirects by hand so every hop answers to the endpoint: never to plain http or a stranger. */
    private fun open(offer: UpdateOffer, resume: Long): Response? {
        var url: HttpUrl = offer.url.toHttpUrlOrNull()?.takeIf(endpoint::allowsDownload) ?: return null
        repeat(5) {
            val request = Request.Builder().url(url).header("Accept-Encoding", "identity")
                .apply { if (resume > 0) header("Range", "bytes=$resume-") }.build()
            val response = client.newCall(request).execute()
            if (!response.isRedirect) return response
            val next = response.header("Location")?.let(url::resolve)
            response.close()
            url = next?.takeIf(endpoint::allowsRedirect) ?: return null
        }
        return null
    }

    companion object {
        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
            }
            return hex(digest.digest())
        }
        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    }
}

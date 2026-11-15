package dev.yab.update

import java.io.File
import java.io.InputStream
import java.net.ServerSocket
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class UpdateDownloaderTest {
    private val bytes = ByteArray(300_000) { (it % 251).toByte() }
    private val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private val folder = Files.createTempDirectory("update").toFile()
    private val part = File(folder, "yab.part")
    private val apk = File(folder, "yab.apk")
    private val socket = ServerSocket(0)
    private val requests = CopyOnWriteArrayList<String>()
    private var answer: (String, Long?) -> ByteArray = ::whole
    private val port = socket.localPort
    private val endpoint = UpdateEndpoint("http://127.0.0.1:$port/latest.json", "127.0.0.1", port, cleartext = true)

    init {
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                client.use {
                    val input = client.getInputStream()
                    val head = generateSequence { line(input) }.takeWhile { it.isNotEmpty() }.toList()
                    val path = head.first().split(" ")[1]
                    val range = head.firstOrNull { it.startsWith("Range:", true) }?.substringAfter("bytes=")?.substringBefore("-")?.toLong()
                    requests.add(path + (range?.let { " from $it" } ?: ""))
                    runCatching { client.getOutputStream().write(answer(path, range)) }
                }
            }
        }
    }

    private fun line(input: InputStream): String {
        val text = StringBuilder()
        while (true) { val c = input.read(); if (c < 0 || c == '\n'.code) break; if (c != '\r'.code) text.append(c.toChar()) }
        return text.toString()
    }

    private fun response(status: String, body: ByteArray, vararg headers: String) =
        ("HTTP/1.1 $status\r\n" + headers.joinToString("") { "$it\r\n" } + "Content-Length: ${body.size}\r\nConnection: close\r\n\r\n").toByteArray() + body
    private fun whole(path: String, range: Long?) = response("200 OK", bytes)
    private fun ranged(path: String, range: Long?) = if (range == null) whole(path, null)
        else response("206 Partial Content", bytes.copyOfRange(range.toInt(), bytes.size), "Content-Range: bytes $range-${bytes.size - 1}/${bytes.size}")

    private fun offer(sha: String = hash, path: String = "/n.apk") = UpdateOffer(3, "3", "http://127.0.0.1:$port$path", sha, 29)
    private fun fetch(offer: UpdateOffer = offer(), target: UpdateEndpoint = endpoint) =
        UpdateDownloader(OkHttpClient(), target, spare = 0).fetch(offer, part, apk)

    @After fun close() { socket.close(); folder.deleteRecursively() }

    @Test fun verifiedBytesBecomeTheApk() {
        assertEquals(UpdateDownloadResult.VERIFIED, fetch())
        assertArrayEquals(bytes, apk.readBytes())
        assertFalse(part.exists())
    }

    @Test fun aWrongHashIsRefusedAndNothingStays() {
        assertEquals(UpdateDownloadResult.REFUSED, fetch(offer("0".repeat(64))))
        assertFalse(part.exists()); assertFalse(apk.exists())
    }

    @Test fun anInterruptedDownloadGoesOnFromItsBytes() {
        answer = ::ranged
        part.writeBytes(bytes.copyOf(120_000))
        assertEquals(UpdateDownloadResult.VERIFIED, fetch())
        assertEquals(listOf("/n.apk from 120000"), requests.toList())
        assertArrayEquals(bytes, apk.readBytes())
    }

    @Test fun aServerWithoutRangeStartsOver() {
        part.writeBytes(ByteArray(120_000) { 7 })
        assertEquals(UpdateDownloadResult.VERIFIED, fetch())
        assertArrayEquals(bytes, apk.readBytes())
    }

    @Test fun aRangeThatDoesNotMatchStartsOver() {
        answer = { _, _ -> response("206 Partial Content", bytes, "Content-Range: bytes 0-${bytes.size - 1}/${bytes.size}") }
        part.writeBytes(ByteArray(120_000) { 7 })
        assertEquals(UpdateDownloadResult.VERIFIED, fetch())
    }

    @Test fun aCutResponseKeepsItsBytesForLater() {
        answer = { _, _ -> ("HTTP/1.1 200 OK\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n").toByteArray() + bytes.copyOf(50_000) }
        assertEquals(UpdateDownloadResult.TRY_AGAIN, fetch())
        assertTrue(part.length() > 0); assertFalse(apk.exists())
    }

    @Test fun serverTroubleWaitsAndAGoneFileIsRefused() {
        answer = { _, _ -> response("503 Busy", ByteArray(0)) }
        assertEquals(UpdateDownloadResult.TRY_AGAIN, fetch())
        answer = { _, _ -> response("404 Not Found", ByteArray(0)) }
        assertEquals(UpdateDownloadResult.REFUSED, fetch())
    }

    @Test fun aRedirectInsideTheHostIsFollowed() {
        answer = { path, _ -> if (path == "/n.apk") response("307 Temporary Redirect", ByteArray(0), "Location: /blob.apk") else whole(path, null) }
        assertEquals(UpdateDownloadResult.VERIFIED, fetch())
        assertEquals(listOf("/n.apk", "/blob.apk"), requests.toList())
    }

    @Test fun aRedirectToAStrangerIsNotFollowed() {
        answer = { _, _ -> response("307 Temporary Redirect", ByteArray(0), "Location: http://127.0.0.2:$port/evil.apk") }
        assertEquals(UpdateDownloadResult.REFUSED, fetch())
        assertEquals(1, requests.size)
    }

    @Test fun aSecureEndpointWillNotUsePlainHttp() {
        val secure = UpdateEndpoint("https://127.0.0.1:$port/latest.json", "127.0.0.1", port)
        assertEquals(UpdateDownloadResult.REFUSED, fetch(target = secure))
        assertTrue(requests.isEmpty())
    }

    @Test fun moreBytesThanAllowedAreRefused() {
        val small = UpdateDownloader(OkHttpClient(), endpoint, maxBytes = 1000, spare = 0)
        assertEquals(UpdateDownloadResult.REFUSED, small.fetch(offer(), part, apk))
        assertFalse(part.exists())
    }

    @Test fun anAlreadyVerifiedFileNeedsNoNetwork() {
        apk.writeBytes(bytes)
        assertEquals(UpdateDownloadResult.VERIFIED, fetch())
        assertTrue(requests.isEmpty())
    }
}

package dev.yab.browser.icons

import java.io.Closeable
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class SiteIconHttpTest {
    private data class Reply(val code: Int = 200, val headers: Map<String, String> = emptyMap(), val body: ByteArray = byteArrayOf(1, 2, 3))
    private data class Request(val path: String, val headers: Map<String, String>)
    private class Loopback(private val reply: (String) -> Reply) : Closeable {
        val requests = LinkedBlockingQueue<Request>()
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        val origin get() = "http://127.0.0.1:${socket.localPort}"
        private val worker = thread(isDaemon = true, name = "icon-http-fixture") {
            while (!socket.isClosed) {
                val connection = runCatching { socket.accept() }.getOrNull() ?: break
                connection.use { connection ->
                    connection.soTimeout = 5_000
                    val input = connection.getInputStream().bufferedReader(Charsets.US_ASCII)
                    val line = input.readLine() ?: return@use
                    val path = line.split(' ').getOrNull(1).orEmpty()
                    val headers = mutableMapOf<String, String>()
                    while (true) {
                        val header = input.readLine() ?: break
                        if (header.isEmpty()) break
                        val colon = header.indexOf(':')
                        if (colon > 0) headers[header.take(colon).lowercase()] = header.substring(colon + 1).trim()
                    }
                    requests.add(Request(path, headers))
                    val value = reply(path)
                    runCatching {
                        val output = connection.getOutputStream()
                        val fields = (if (value.headers["Transfer-Encoding"] == "chunked") mapOf("Connection" to "close")
                            else mapOf("Content-Length" to value.body.size.toString(), "Connection" to "close")) + value.headers
                        output.write(("HTTP/1.1 ${value.code} Fixture\r\n" + fields.entries.joinToString("") { "${it.key}: ${it.value}\r\n" } + "\r\n").toByteArray(Charsets.US_ASCII))
                        if (value.headers["Transfer-Encoding"] == "chunked") {
                            output.write("${value.body.size.toString(16)}\r\n".toByteArray(Charsets.US_ASCII))
                            output.write(value.body); output.write("\r\n0\r\n\r\n".toByteArray(Charsets.US_ASCII))
                        } else output.write(value.body)
                        output.flush()
                    }
                }
            }
        }
        override fun close() { socket.close(); worker.join(5_000); check(!worker.isAlive) }
    }

    @Test fun sameOriginRedirectsWorkWithoutReceivingCookiesOrAuthentication(): Unit = runBlocking {
        Loopback { path -> if (path == "/start") Reply(302, mapOf("Location" to "/icon", "Set-Cookie" to "fixture=private; Path=/")) else Reply() }.use { server ->
            val bytes = SiteIconHttp().fetch("${server.origin}/start", SiteIconOrigin.from(server.origin)!!)
            assertArrayEquals(byteArrayOf(1, 2, 3), bytes)
            assertEquals(listOf("/start", "/icon"), server.requests.map { it.path })
            server.requests.forEach { request ->
                assertFalse(request.headers.containsKey("cookie")); assertFalse(request.headers.containsKey("authorization"))
                assertFalse(request.headers.containsKey("proxy-authorization"))
            }
        }
    }

    @Test fun anotherPortIsNeverRequestedAndDeclaredOversizeBodiesAreRejected(): Unit = runBlocking {
        Loopback { Reply() }.use { external ->
            Loopback { Reply(302, mapOf("Location" to "${external.origin}/secret")) }.use { source ->
                assertNull(SiteIconHttp().fetch("${source.origin}/start", SiteIconOrigin.from(source.origin)!!))
                assertEquals(1, source.requests.size); assertTrue(external.requests.isEmpty())
            }
        }
        Loopback { Reply(headers = mapOf("Content-Length" to "1048577"), body = byteArrayOf()) }.use { server ->
            assertNull(SiteIconHttp().fetch("${server.origin}/icon", SiteIconOrigin.from(server.origin)!!))
        }
        Loopback { Reply(headers = mapOf("Transfer-Encoding" to "chunked"), body = ByteArray(1_048_577)) }.use { server ->
            assertNull(SiteIconHttp().fetch("${server.origin}/icon", SiteIconOrigin.from(server.origin)!!))
        }
        val destination = AtomicReference<String>()
        Loopback { Reply(302, mapOf("Location" to destination.get())) }.use { server ->
            destination.set(server.origin.replace("://", "://@") + "/icon")
            assertNull(SiteIconHttp().fetch("${server.origin}/start", SiteIconOrigin.from(server.origin)!!))
            assertEquals("An empty credential authority was normalized into an allowed redirect", 1, server.requests.size)
        }
    }
}

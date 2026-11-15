/* Any copyright is dedicated to the Public Domain.
 * http://creativecommons.org/publicdomain/zero/1.0/ */
package org.mozilla.geckoview.test

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import java.io.Closeable
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** Actual engine qualification, not a fixture that substitutes a clear response. */
@RunWith(AndroidJUnit4::class)
class ScopedSiteDataTest : BaseSessionTest() {
    private data class FixtureSession(val session: GeckoSession, val context: String, val privateMode: Boolean, val host: String, val marker: String)

    private fun sessions(server: FixtureServer): List<FixtureSession> {
        val first = UUID.randomUUID().toString()
        return listOf(Triple(first, false, "127.0.0.1"), Triple(UUID.randomUUID().toString(), false, "127.0.0.1"),
            Triple(first, true, "127.0.0.1"), Triple(first, false, "localhost")).mapIndexed { index, (context, privateMode, host) ->
            val session = sessionRule.createOpenSession(GeckoSessionSettings.Builder().contextId(context).usePrivateMode(privateMode).build())
            val fixture = FixtureSession(session, context, privateMode, host, "marker$index")
            session.loadUri(server.url(host, "/seed/${fixture.marker}")); session.waitForPageStop()
            session.evaluateJS("localStorage.setItem('scopedClear', '${fixture.marker}')")
            assertEquals(fixture.marker, session.evaluateJS("localStorage.getItem('scopedClear')"))
            fixture
        }
    }

    private fun verify(server: FixtureServer, fixture: FixtureSession, removed: Boolean) {
        fixture.session.loadUri(server.url(fixture.host, "/read")); fixture.session.waitForPageStop()
        assertEquals(if (removed) "" else "scopedClear=${fixture.marker}", fixture.session.evaluateJS("document.body.textContent"))
        assertEquals(if (removed) "absent" else fixture.marker, fixture.session.evaluateJS("localStorage.getItem('scopedClear') || 'absent'"))
    }

    @Test
    fun publicHostClearKeepsAnotherPublicProfilePrivateAndNeighborHost() {
        FixtureServer().use { server ->
            val fixtures = sessions(server)
            try {
                sessionRule.waitForResult(sessionRule.runtime.storageController.clearScopedSiteData("127.0.0.1", fixtures[0].context, false, 3))
                fixtures.forEachIndexed { index, fixture -> verify(server, fixture, index == 0) }
            } finally { fixtures.forEach { it.session.close() } }
        }
    }

    @Test
    fun privateHostClearKeepsBothPublicProfilesAndNeighborHost() {
        FixtureServer().use { server ->
            val fixtures = sessions(server)
            try {
                sessionRule.waitForResult(sessionRule.runtime.storageController.clearScopedSiteData("127.0.0.1", fixtures[2].context, true, 3))
                fixtures.forEachIndexed { index, fixture -> verify(server, fixture, index == 2) }
            } finally { fixtures.forEach { it.session.close() } }
        }
    }

    @Test
    fun incompleteFullTypeCoverageRefusesBeforeDeletingAnyCookieOrStorage() {
        FixtureServer().use { server ->
            val fixtures = sessions(server)
            try {
                assertThrows(Exception::class.java) {
                    sessionRule.waitForResult(sessionRule.runtime.storageController.clearScopedSiteData("127.0.0.1", fixtures[0].context, false, 255))
                }
                fixtures.forEach { verify(server, it, false) }
            } finally { fixtures.forEach { it.session.close() } }
        }
    }

    @Test
    fun nativeHttpCacheDoomKeepsOtherProfilesPrivateAndNeighborCache() {
        FixtureServer().use { server ->
            val fixtures = sessions(server)
            try {
                fun read(fixture: FixtureSession): Any? = fixture.session.evaluateJS("""
                    (() => { const request = new XMLHttpRequest(); request.open('GET', '/asset', false); request.send(); return request.responseText; })()
                """.trimIndent())
                fixtures.forEach { assertEquals("version1", read(it)) }
                server.version = 2
                sessionRule.waitForResult(sessionRule.runtime.storageController.clearScopedSiteData("127.0.0.1", fixtures[0].context, false, 4))
                fixtures.forEachIndexed { index, fixture -> assertEquals(if (index == 0) "version2" else "version1", read(fixture)) }
            } finally { fixtures.forEach { it.session.close() } }
        }
    }

    /** Loopback HTTP only; HttpOnly cookies are observed by the server, not faked by JS. */
    private class FixtureServer : Closeable {
        private val running = AtomicBoolean(true)
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        @Volatile var version = 1
        fun url(host: String, path: String) = "http://$host:${socket.localPort}$path"
        private val worker = Thread {
            while (running.get()) {
                try { socket.accept().use { client ->
                    client.soTimeout = 5000
                    val reader = client.getInputStream().bufferedReader()
                    val request = reader.readLine() ?: return@use
                    val path = request.split(' ').getOrNull(1).orEmpty()
                    val headers = mutableMapOf<String, String>()
                    var bytes = request.length
                    while (true) {
                        val line = reader.readLine() ?: break
                        bytes += line.length; check(bytes < 16384)
                        if (line.isEmpty()) break
                        headers[line.substringBefore(':').lowercase()] = line.substringAfter(':', "").trim()
                    }
                    val marker = path.removePrefix("/seed/").takeIf { path.startsWith("/seed/") && it.matches(Regex("marker[0-9]+")) }
                    val cookie = if (marker != null) "Set-Cookie: scopedClear=$marker; HttpOnly; SameSite=Lax; Path=/\r\n" else ""
                    val asset = path == "/asset"
                    val body = if (asset) "version$version" else "<!doctype html><body>${headers["cookie"].orEmpty()}</body>"
                    val data = body.toByteArray()
                    val cache = if (asset) "public, max-age=86400" else "no-store"
                    client.getOutputStream().apply {
                        write(("HTTP/1.1 200 OK\r\nContent-Type: ${if (asset) "text/plain" else "text/html"}; charset=utf-8\r\n" +
                            "Content-Length: ${data.size}\r\nCache-Control: $cache\r\n$cookie" + "Connection: close\r\n\r\n").toByteArray())
                        write(data); flush()
                    }
                } } catch (error: Exception) { if (running.get()) throw error }
            }
        }.apply { name = "owned-scoped-site-fixture"; isDaemon = true; start() }
        override fun close() { running.set(false); socket.close(); worker.join(6000); check(!worker.isAlive) }
    }
}

package dev.yab.core

import dev.yab.core.crypto.Seal
import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class SyncClientTest {
    private open class ClosingWebSocketListener : WebSocketListener() {
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
    }
    private fun eventually(latch: CountDownLatch) { assertTrue("Timed out waiting for actual sync protocol", latch.await(10, TimeUnit.SECONDS)) }
    @Test fun realHttpRegistrationSocketCatchupAndOutboxAreEncrypted() {
        MockWebServer().use { server ->
            server.start(); val seal = Seal.make(); val journal = MemoryJournal("android")
            journal.change(RecordKey("bookmark", "local"), buildJsonObject { put("title", "private title"); put("url", "https://private.test") })
            val remote = Record("bookmark", "remote").updated(buildJsonObject { put("title", "From Mac") }, Clock("mac", now = { 500 }))
            val received = CountDownLatch(1); val sent = CountDownLatch(1); val saved = AtomicReference<String>(); val error = AtomicReference<Throwable>()
            server.enqueue(MockResponse().setBody("{\"token\":\"device-token\"}"))
            server.enqueue(MockResponse().withWebSocketUpgrade(object : ClosingWebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    try {
                        val message = Json.parseToJsonElement(text).jsonObject
                        when (message.getValue("t").jsonPrimitive.content) {
                            "hello" -> {
                                assertEquals(0L, message.getValue("cursor").jsonPrimitive.long)
                                webSocket.send(buildJsonObject { put("t", "changes"); put("cursor", 1); put("items", buildJsonArray { add(buildJsonObject {
                                    put("name", seal.name(remote.key)); put("blob", Base64.getEncoder().encodeToString(seal.seal(remote))); put("version", 1); put("seq", 1)
                                }) }) }.toString())
                            }
                            "push" -> {
                                assertFalse(text.contains("private title")); assertFalse(text.contains("private.test"))
                                val item = message.getValue("changes").jsonArray.single().jsonObject
                                val name = item.getValue("name").jsonPrimitive.content
                                assertEquals("local", seal.open(Base64.getDecoder().decode(item.getValue("blob").jsonPrimitive.content), name).id)
                                webSocket.send(buildJsonObject { put("t", "pushed"); put("id", message.getValue("id")); put("accepted", buildJsonArray {
                                    add(buildJsonObject { put("name", name); put("version", 1); put("seq", 2) })
                                }); put("conflicts", JsonArray(emptyList())) }.toString())
                                sent.countDown()
                            }
                        }
                    } catch (e: Throwable) { error.set(e); sent.countDown() }
                }
            }))
            SyncClient(server.url("/").toString(), journal, seal, Device("android", "Android", "Android test"), saveToken = saved::set, allowInsecureForTests = true).use { client ->
                client.onFailure = { error.set(it); received.countDown(); sent.countDown() }
                client.onRecords = { if (it.contains(remote)) received.countDown() }
                val flushed = CountDownLatch(1)
                client.onOutbox = { if (it == 0) flushed.countDown() }
                client.start(); eventually(received); eventually(sent); eventually(flushed)
                error.get()?.let { throw AssertionError("Sync failed", it) }
                assertEquals("device-token", saved.get()); assertTrue(journal.pending().isEmpty()); assertEquals(2L, journal.cursor)
                assertEquals(remote, journal.record(remote.key))
                val registration = server.takeRequest(5, TimeUnit.SECONDS)!!
                assertEquals("/v1/accounts/${seal.account}/devices", registration.path)
                val body = Json.parseToJsonElement(registration.body.readUtf8()).jsonObject
                assertEquals("android", body.getValue("device").jsonObject.getValue("platform").jsonPrimitive.content)
                assertFalse(body.toString().contains(seal.recovery))
                assertEquals("Bearer device-token", server.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
            }
        }
    }
    @Test fun unreadableChangesNeverAdvanceDurableCursor() {
        MockWebServer().use { server ->
            server.start(); val journal = MemoryJournal("android"); val bad = Record("tab", "one")
            val rejected = CountDownLatch(1)
            server.enqueue(MockResponse().setBody("{\"token\":\"new-token\"}"))
            server.enqueue(MockResponse().withWebSocketUpgrade(object : ClosingWebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    webSocket.send(buildJsonObject { put("t", "changes"); put("cursor", 42); put("items", buildJsonArray { add(buildJsonObject {
                        put("name", "wrong-name"); put("blob", Base64.getEncoder().encodeToString(Seal.make().seal(bad))); put("version", 1)
                    }) }) }.toString())
                }
            }))
            SyncClient(server.url("/").toString(), journal, Seal.make(), Device("android", "Phone", "Android"), initialToken = "saved", allowInsecureForTests = true).use { client ->
                client.onFailure = { rejected.countDown() }; client.start(); eventually(rejected)
                assertEquals(0L, journal.cursor); assertTrue(journal.all().isEmpty())
            }
        }
    }
    @Test fun registrationCannotConnectBeforeTokenDurablySaved() {
        MockWebServer().use { server ->
            server.start(); server.enqueue(MockResponse().setBody("{\"token\":\"new-token\"}"))
            val failed = CountDownLatch(1)
            SyncClient(server.url("/").toString(), MemoryJournal("android"), Seal.make(), Device("android", "Phone", "Android"),
                saveToken = { throw java.io.IOException("Disk unavailable") }, allowInsecureForTests = true).use { client ->
                client.onFailure = { failed.countDown() }; client.start(); eventually(failed)
                assertNull(client.token); assertEquals(1, server.requestCount)
            }
        }
    }
    @Test fun wireConflictMergesBothWritersAndRebasesBeforeResending() {
        MockWebServer().use { server ->
            server.start(); val seal = Seal.make(); val journal = MemoryJournal("android", now = { 100 })
            val key = RecordKey("bookmark", "conflict")
            journal.change(key, buildJsonObject { put("title", "Local title") })
            val remote = Record("bookmark", "conflict").updated(buildJsonObject { put("url", "https://mac.test") }, Clock("mac", now = { 200 }))
            val complete = CountDownLatch(1); val error = AtomicReference<Throwable>(); var pushes = 0
            server.enqueue(MockResponse().setBody("{\"token\":\"saved\"}"))
            server.enqueue(MockResponse().withWebSocketUpgrade(object : ClosingWebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    try {
                        val message = Json.parseToJsonElement(text).jsonObject
                        when (message.getValue("t").jsonPrimitive.content) {
                            "hello" -> webSocket.send("{\"t\":\"changes\",\"cursor\":0,\"items\":[]}")
                            "push" -> {
                                val item = message.getValue("changes").jsonArray.single().jsonObject
                                if (pushes++ == 0) {
                                    assertEquals(0L, item.getValue("base").jsonPrimitive.long)
                                    webSocket.send(buildJsonObject { put("t", "pushed"); put("accepted", JsonArray(emptyList())); put("conflicts", buildJsonArray {
                                        add(buildJsonObject { put("name", seal.name(key)); put("version", 1); put("blob", Base64.getEncoder().encodeToString(seal.seal(remote))) })
                                    }) }.toString())
                                } else {
                                    assertEquals(1L, item.getValue("base").jsonPrimitive.long)
                                    val merged = seal.open(Base64.getDecoder().decode(item.getValue("blob").jsonPrimitive.content), seal.name(key))
                                    assertEquals(JsonPrimitive("Local title"), merged["title"]); assertEquals(JsonPrimitive("https://mac.test"), merged["url"])
                                    webSocket.send(buildJsonObject { put("t", "pushed"); put("conflicts", JsonArray(emptyList())); put("accepted", buildJsonArray {
                                        add(buildJsonObject { put("name", seal.name(key)); put("version", 2); put("seq", 2) })
                                    }) }.toString())
                                }
                            }
                        }
                    } catch (failure: Throwable) { error.set(failure); complete.countDown() }
                }
            }))
            SyncClient(server.url("/").toString(), journal, seal, Device("android", "Phone", "Android"), allowInsecureForTests = true).use { client ->
                client.onOutbox = { if (it == 0) complete.countDown() }; client.onFailure = { error.set(it); complete.countDown() }
                client.start(); eventually(complete); error.get()?.let { throw AssertionError("Conflict failed", it) }
                assertEquals(2, pushes); assertEquals(2L, journal.cursor); assertTrue(journal.pending().isEmpty())
            }
        }
    }
    @Test fun revokedSavedDeviceBecomesTerminalRefusedBeforeAnySocket() {
        MockWebServer().use { server ->
            server.start(); server.enqueue(MockResponse().setResponseCode(403).setBody("{\"error\":\"revoked\"}"))
            val refused = CountDownLatch(1)
            SyncClient(server.url("/").toString(), MemoryJournal("android"), Seal.make(), Device("android", "Phone", "Android"),
                initialToken = "old-device-token", allowInsecureForTests = true).use { client ->
                client.onState = { if (it is SyncState.Refused) refused.countDown() }; client.start(); eventually(refused)
                assertTrue(client.state is SyncState.Refused); assertEquals(1, server.requestCount)
            }
        }
    }
    @Test fun incompatibleRosterExplainsUpgradeWithoutDiscardingSavedToken() {
        MockWebServer().use { server ->
            server.start(); server.enqueue(MockResponse().setResponseCode(409).setBody("{\"error\":\"android-sync-upgrade-required\"}"))
            val waiting = CountDownLatch(1)
            SyncClient(server.url("/").toString(), MemoryJournal("android"), Seal.make(), Device("android", "Phone", "Android"),
                initialToken = "saved", allowInsecureForTests = true).use { client ->
                client.onState = { if (it == SyncState.Waiting(SyncClient.ANDROID_UPGRADE)) waiting.countDown() }
                client.start(); eventually(waiting)
                assertEquals(SyncState.Waiting(SyncClient.ANDROID_UPGRADE), client.state)
                assertEquals("saved", client.token); assertEquals(1, server.requestCount)
            }
        }
    }
    @Test fun incompatibleSocketExplainsUpgradeAndKeepsDurableOutbox() {
        MockWebServer().use { server ->
            server.start(); val journal = MemoryJournal("android")
            val closeAcknowledged = CountDownLatch(1)
            val executor = Executors.newSingleThreadScheduledExecutor { Thread(it, "upgrade-test").apply { isDaemon = true } }
            journal.change(RecordKey("bookmark", "offline"), buildJsonObject { put("url", "https://kept.test") })
            server.enqueue(MockResponse().setBody("{\"token\":\"saved\"}"))
            server.enqueue(MockResponse().withWebSocketUpgrade(object : ClosingWebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { webSocket.close(4004, "android-sync-upgrade-required") }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    super.onClosing(webSocket, code, reason); closeAcknowledged.countDown()
                }
            }))
            val waiting = CountDownLatch(1)
            SyncClient(server.url("/").toString(), journal, Seal.make(), Device("android", "Phone", "Android"),
                saveToken = {
                    // Queue before connect's callbacks. The network completes
                    // its close handshake before queued onOpen tries hello.
                    executor.execute { closeAcknowledged.await(5, TimeUnit.SECONDS) }
                }, allowInsecureForTests = true, executor = executor).use { client ->
                client.onState = { if (it == SyncState.Waiting(SyncClient.ANDROID_UPGRADE)) waiting.countDown() }
                client.start(); eventually(waiting)
                assertEquals("The test must exercise close-before-queued-onOpen", 0L, closeAcknowledged.count)
                assertEquals(SyncState.Waiting(SyncClient.ANDROID_UPGRADE), client.state)
                assertEquals("saved", client.token); assertEquals(1, journal.pending().size)
                server.takeRequest(5, TimeUnit.SECONDS)
                assertEquals("1", server.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("X-Yab-Android-Sync"))
            }
        }
    }
}

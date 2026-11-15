package dev.yab.android

import android.graphics.Rect
import android.net.Uri
import android.provider.MediaStore
import android.os.SystemClock
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.BrowserInstrumentedTest
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.*
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.URI
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Actual held-image input -> APK bridge -> native Gecko stream -> existing SAF controller. No injected response. */
@RunWith(AndroidJUnit4::class)
class OwnedImageDownloadDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 180_000)
    fun actualOriginalPublicAndPrivateImageStreamsSaveExactMediaStoreBytesWithoutAnotherGet(): Unit = runBlocking {
        withBrowser("pictures") { _, owner, fixture ->
            val created = mutableListOf<Uri>()
            try {
                for ((tag, privately) in listOf("picturesa" to false, "picturesp" to true)) {
                    val source = open(owner, fixture, tag, "plain", privately)
                    val before = fixture.imageRequests(tag)
                    holdAndSave(owner)
                    await("original image ready for explicit Pictures export", 35_000) { owner.downloads.state.value.phase == PageDownloadPhase.READY }
                    await("real Pictures action") { node("Save to Pictures") != null }
                    click("Save to Pictures")
                    await("actual MediaStore original image saved", 15_000) { owner.downloads.state.value.phase == PageDownloadPhase.SAVED && owner.downloads.state.value.pictureUri != null }
                    val uri = Uri.parse(requireNotNull(owner.downloads.state.value.pictureUri)); created += uri
                    val actual = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)!!.use { it.readBytes() } }
                    assertEquals(digest(fixture.payload(tag)), digest(actual))
                    context.contentResolver.query(uri, arrayOf(MediaStore.Images.Media.IS_PENDING, MediaStore.Images.Media.MIME_TYPE,
                        MediaStore.Images.Media.RELATIVE_PATH, MediaStore.Images.Media.OWNER_PACKAGE_NAME), null, null, null)!!.use { cursor ->
                        assertTrue(cursor.moveToFirst()); assertEquals(0, cursor.getInt(0)); assertEquals("image/png", cursor.getString(1))
                        assertEquals("Pictures/Yab/", cursor.getString(2)); assertEquals(context.packageName, cursor.getString(3))
                    }
                    assertEquals("Export performed another GET", before + 1, fixture.imageRequests(tag))
                    assertSourceUnchanged(owner, source)
                    assertFalse(File(context.cacheDir, "shared/download-${owner.downloads.state.value.id}").exists())
                    if (privately) assertFalse(File(context.filesDir, "browser.json").readText().contains(source.tab))
                }
            } finally {
                // Only exact rows created by this fresh owned-emulator fixture, never a library sweep.
                created.forEach { uri -> context.contentResolver.delete(uri, null, null) }
            }
        }
    }

    @Test(timeout = 360_000)
    fun realHeldImagePreservesBytesTwoContainersPrivateCachedAndCrossOriginPage(): Unit = runBlocking {
        withBrowser("containers") { _, owner, fixture ->
            val profiles = mutableSetOf<String>()
            for ((tag, mode, privately) in listOf(Triple("a", "plain", false), Triple("b", "plain", false),
                    Triple("p", "plain", true), Triple("c", "cached", false), Triple("d", "cross", false))) {
                val source = open(owner, fixture, tag, mode, privately)
                profiles += source.profile
                val before = fixture.imageRequests(tag)
                holdAndSave(owner)
                await("real native image response $tag", 35_000) { owner.downloads.state.value.phase == PageDownloadPhase.READY }
                val transfer = owner.downloads.state.value
                assertEquals(source.tab, transfer.owner?.tab)
                assertEquals(source.profile, transfer.owner?.profile)
                assertEquals(privately, transfer.owner?.privateOrigin)
                assertEquals("image/png", transfer.mime)
                assertTrue(main { owner.engine.externalActivityAlive(source.native) })
                assertSourceUnchanged(owner, source)
                val export = main { requireNotNull(owner.downloads.beginExport(transfer.id!!, PageDownloadExportKind.SAVE)) }
                assertEquals(digest(fixture.payload(tag)), withContext(Dispatchers.IO) { digest(export.file.readBytes()) })
                val after = fixture.imageRequests(tag)
                if (mode == "cached") assertEquals("Cached browser channel unexpectedly refetched", before, after)
                else assertEquals("The owned request was replayed or never used the page channel", before + 1, after)
                assertTrue(fixture.records.filter { it.tag == tag }.all { it.method == "GET" && it.strictCookie && it.laxCookie })
                // Existing SAF/FileProvider export uses these same bytes; neither export nor cancellation may refetch.
                main { owner.downloads.exportCancelled(export.token); owner.downloads.cancel(transfer.id) }
                await("image reader closed") { !owner.imageDownloads.hasActiveAttempt && owner.downloads.state.value.phase == PageDownloadPhase.CANCELLED }
                assertEquals(after, fixture.imageRequests(tag))
                assertFalse(export.file.exists())
                if (privately) {
                    assertFalse(File(context.filesDir, "browser.json").readText().contains(source.tab))
                    main { owner.browser.lockPrivate(); owner.browser.unlockPrivate(true) }
                }
            }
            assertEquals("The two public sign-in containers and Private must be distinct", 5, profiles.size)
        }
    }

    @Test(timeout = 180_000)
    fun redirectsFramePolicyAndMissingHeadersFailClosedWithoutReplacingSourceOrRefetching(): Unit = runBlocking {
        withBrowser("refusals") { _, owner, fixture ->
            for ((tag, mode) in listOf("r" to "redirect", "f" to "csp", "t" to "headers", "u" to "cancel")) {
                val source = open(owner, fixture, tag, mode, false)
                val before = fixture.imageRequests(tag)
                holdAndSave(owner)
                if (mode == "cancel") {
                    await("pending request with a real Cancel action") { fixture.imageRequests(tag) == before + 1 && node("Cancel") != null }
                    click("Cancel")
                }
                await("owned request refused or expired", if (mode == "redirect") 10_000 else 35_000) { !owner.imageDownloads.hasActiveAttempt }
                assertEquals("Owned image refusal $mode", PageDownloadPhase.CANCELLED, owner.downloads.state.value.phase)
                assertSourceUnchanged(owner, source)
                if (mode == "csp") assertEquals("frame-src policy was bypassed", before, fixture.imageRequests(tag))
                else assertEquals("A rejected owned request was replayed", before + 1, fixture.imageRequests(tag))
                if (mode in setOf("headers", "cancel")) await("timed-out or cancelled original client actually closed") { fixture.cancelled(tag) }
                assertEquals("A redirect was followed despite initial-scope refusal", 0, fixture.redirects.get())
                fixture.release(tag)
            }
        }
    }

    @Test(timeout = 300_000)
    fun navigationPrivateLockAndActualAccountEpochRevokeBeforeHeadersAndDuringOriginalStream(): Unit = runBlocking {
        withBrowser("revocation") { _, owner, fixture ->
            var index = 0
            for (stage in listOf("headers", "body")) for (reason in listOf("navigation", "private", "epoch")) {
                val tag = "lease${index++}"
                val source = open(owner, fixture, tag, stage, reason == "private")
                val before = fixture.imageRequests(tag)
                val previousDownload = owner.downloads.state.value.id
                holdAndSave(owner)
                if (stage == "body") await("real original body began") { owner.downloads.state.value.let { it.phase == PageDownloadPhase.TRANSFERRING && it.received > 0 } }
                else await("actual GET held before response headers") { fixture.imageRequests(tag) == before + 1 && owner.imageDownloads.hasActiveAttempt }
                val downloadId = owner.downloads.state.value.id.takeIf { stage == "body" }
                when (reason) {
                    "navigation" -> { main { owner.browser.openUrl(fixture.url("/replacement"), newTab = false) }; await("replacement") { owner.browser.state.value.page.title == "Replacement" } }
                    "private" -> main { owner.browser.lockPrivate() }
                    "epoch" -> {
                        val sync = (context.applicationContext as YabApplication).sync
                        // This disposable app has no account. Exercise its REAL identity epoch reset without a production request.
                        check(sync.accountRecords.value.account == null && sync.accountRecords.value.device == null) { "Refusing to alter a signed-in account" }
                        val beforeEpoch = sync.accountEpoch
                        main { sync.disconnect() }
                        await("actual unpaired identity epoch reset") { sync.accountEpoch != beforeEpoch }
                    }
                }
                await("owned request revoked") { !owner.imageDownloads.hasActiveAttempt && owner.downloads.state.value.phase == PageDownloadPhase.CANCELLED }
                await("only the original child-channel client actually closed") { fixture.cancelled(tag) }
                fixture.release(tag)
                assertEquals("A revoked source started a second GET", before + 1, fixture.imageRequests(tag))
                if (stage == "body") {
                    assertNotEquals(previousDownload, downloadId)
                    await("only the captured output was removed") { !File(context.cacheDir, "shared/download-$downloadId").exists() }
                } else assertEquals("A revoked header-only request created a file", previousDownload, owner.downloads.state.value.id)
                assertFalse(main { owner.saveHeldImage("stale-native-menu") })
                if (reason == "private") main { owner.browser.unlockPrivate(true) }
            }
        }
    }

    private data class Source(val tab: String, val profile: String, val url: String, val title: String?, val history: List<BrowserVisit>,
        val back: List<BrowserBackItem>, val native: GeckoEngine.ExternalActivityOwner)
    private suspend fun open(owner: BrowserSessionViewModel, fixture: ImageFixture, tag: String, mode: String, privately: Boolean): Source {
        main {
            if (!privately) BrowserInstrumentedTest().ownSpace(owner.browser, "Image $tag ${UUID.randomUUID()}")
            owner.browser.openUrl(fixture.url("/source?tag=$tag&mode=$mode"), privately = privately)
            if (privately) owner.browser.unlockPrivate(true) // State fixture, not a biometric-success claim.
        }
        await("actual image document $tag") { owner.browser.state.value.page.let { !it.loading && it.title == "Owned image $tag" } }
        val tab = owner.browser.state.value.tab!!
        val profile = owner.browser.state.value.space!!.websiteProfile
        val session = main { owner.engine.session(tab, profile) }
        await("APK download content/native bridge") { main { owner.imageDownloads.canSaveImage(session) } }
        await("real image accessible") { node("Held original image") != null }
        val native = main { requireNotNull(owner.engine.captureExternalActivityOwner()) }
        return Source(tab.id, profile.id, tab.url, owner.browser.state.value.page.title, owner.browser.state.value.history,
            main { owner.engine.backItems(tab.id) }, native)
    }
    private suspend fun assertSourceUnchanged(owner: BrowserSessionViewModel, source: Source) {
        assertEquals(source.tab, owner.browser.state.value.tab?.id)
        assertEquals(source.url, owner.browser.state.value.tab?.url)
        assertEquals(source.url, owner.browser.state.value.page.url)
        assertEquals(source.title, owner.browser.state.value.page.title)
        assertEquals(source.history, owner.browser.state.value.history)
        assertEquals(source.back, main { owner.engine.backItems(source.tab) })
        assertTrue("A download navigation replaced the original native document", main { owner.engine.externalActivityAlive(source.native) })
    }
    private suspend fun holdAndSave(owner: BrowserSessionViewModel) {
        val bounds = Rect(); requireNotNull(node("Held original image")).getBoundsInScreen(bounds)
        val began = SystemClock.uptimeMillis()
        MotionEvent.obtain(began, began, MotionEvent.ACTION_DOWN, bounds.exactCenterX(), bounds.exactCenterY(), 0).also {
            assertTrue(instrumentation.uiAutomation.injectInputEvent(it, true)); it.recycle()
        }
        delay(ViewConfiguration.getLongPressTimeout().toLong() + 200)
        MotionEvent.obtain(began, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, bounds.exactCenterX(), bounds.exactCenterY(), 0).also {
            assertTrue(instrumentation.uiAutomation.injectInputEvent(it, true)); it.recycle()
        }
        await("native held-image action") { owner.engine.contextMenu.value?.image != null && node("Save Image") != null }
        click("Save Image")
    }
    private suspend fun withBrowser(case: String, block: suspend (ActivityScenario<MainActivity>, BrowserSessionViewModel, ImageFixture) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(case in setOf("pictures", "containers", "refusals", "revocation"))
        ImageFixture().use { fixture ->
            val scenario = ActivityScenario.launch(MainActivity::class.java)
            lateinit var owner: BrowserSessionViewModel
            var initialized = false
            var restore: BrowserSnapshot? = null
            val diagnosticRows = JSONArray()
            suspend fun diagnostic(point: String) {
                if (!initialized) return
                // Do not create or activate a native session merely to inspect its state.
                val row = main {
                    val browser = owner.browser.state.value
                    val transfer = owner.downloads.state.value
                    val native = owner.engine.captureExternalActivityOwner()
                    JSONObject().put("point", point).put("image", owner.imageDownloads.debugStatus(native?.session))
                        .put("browser", JSONObject().put("loaded", !browser.loading).put("pageLoading", browser.page.loading)
                            .put("surface", browser.surface.name).put("private", browser.space?.isPrivate == true)
                            .put("privateBlocked", browser.privateContentBlocked).put("nativeOwnerAvailable", native != null))
                        .put("transfer", JSONObject().put("phase", transfer.phase.name).put("received", transfer.received.coerceAtMost(1_000_000_000L))
                            .put("ownerMatchesTab", transfer.owner != null && transfer.owner?.tab == browser.tab?.id)
                            .put("ownerMatchesProfile", transfer.owner != null && transfer.owner?.profile == browser.space?.websiteProfile?.id)
                            .put("errorPresent", transfer.error != null))
                        .put("requests", JSONObject().put("count", fixture.records.size.coerceAtMost(10_000))
                            .put("get", fixture.records.count { it.method == "GET" }.coerceAtMost(10_000))
                            .put("strictCookie", fixture.records.count { it.strictCookie }.coerceAtMost(10_000))
                            .put("laxCookie", fixture.records.count { it.laxCookie }.coerceAtMost(10_000)))
                }
                if (diagnosticRows.length() < 2) diagnosticRows.put(row)
                val output = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
                File(output, "owned-image-$case-diagnostics.json").writeText(JSONObject().put("schema", 1).put("samples", diagnosticRows).toString(2))
            }
            var bodyFailure: Throwable? = null
            try {
                scenario.onActivity { owner = ViewModelProvider(it)[BrowserSessionViewModel::class.java]; initialized = true }
                await("Main browser loaded") { !owner.browser.state.value.loading }
                restore = owner.browser.publicSnapshot()
                main { owner.browser.updateSettings(owner.browser.state.value.settings.copy(welcomed = true, autoClearToday = false, lockPrivate = true)) }
                block(scenario, owner, fixture)
            } catch (failure: Throwable) {
                bodyFailure = failure
                withContext(NonCancellable) { runCatching { diagnostic("failure") } }
                throw failure
            } finally {
                try {
                    if (initialized) withContext(NonCancellable) {
                        runCatching { diagnostic("before_cleanup") }
                        main {
                            owner.imageDownloads.cancel(); owner.downloads.cancel()
                            owner.browser.state.value.spaces.filter(BrowserSpace::isPrivate).flatMap { it.tabs }.forEach { owner.browser.closeTab(it.id) }
                            restore?.let { owner.browser.applySyncedSnapshot(it); owner.browser.selectSpace(it.selectedSpaceId) }
                        }
                        fixture.releaseAll()
                        await("owned image cleanup") { !owner.imageDownloads.hasActiveAttempt && owner.downloads.state.value.phase in setOf(PageDownloadPhase.CANCELLED, PageDownloadPhase.SAVED, PageDownloadPhase.SHARED) }
                        restore?.let { snapshot -> await("public image fixture restored") { FileBrowserRepository(File(context.filesDir, "browser.json")).load() == snapshot } }
                    }
                } catch (cleanup: Throwable) {
                    bodyFailure?.addSuppressed(cleanup) ?: throw cleanup
                } finally {
                    fixture.releaseAll(); scenario.close()
                }
            }
        }
    }
    private fun node(text: String): AccessibilityNodeInfo? {
        fun find(value: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
            if (value == null) return null
            if (value.text?.toString() == text || value.contentDescription?.toString() == text) return value
            for (i in 0 until value.childCount) find(value.getChild(i))?.let { return it }
            return null
        }
        return find(instrumentation.uiAutomation.rootInActiveWindow)
    }
    private fun click(text: String) {
        var value = requireNotNull(node(text))
        repeat(8) { if (value.isClickable && value.isEnabled) { assertTrue(value.performAction(AccessibilityNodeInfo.ACTION_CLICK)); return }; value = value.parent ?: error("Missing native control") }
        error("Native control was not clickable")
    }
    private suspend fun await(label: String, timeout: Long = 30_000, predicate: suspend () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeout
        while (!predicate()) { check(SystemClock.elapsedRealtime() < until) { "Timed out waiting for $label" }; delay(50) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }

    private class ImageFixture : Closeable {
        data class Request(val tag: String, val method: String, val strictCookie: Boolean, val laxCookie: Boolean)
        private val primary = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        private val secondary = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val workers = Executors.newFixedThreadPool(10)
        private val gates = ConcurrentHashMap<String, CountDownLatch>()
        private val counts = ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicInteger>()
        private val cancelledClients = ConcurrentHashMap.newKeySet<String>()
        private val cookie = "yabimage" + UUID.randomUUID().toString().replace("-", "")
        val records = ConcurrentLinkedQueue<Request>()
        val redirects = java.util.concurrent.atomic.AtomicInteger()
        init { for (server in listOf(primary, secondary)) workers.submit {
            while (running.get()) {
                val client = try { server.accept() } catch (error: IOException) { if (running.get()) throw error else break }
                workers.submit { try { client.use { socket ->
                    socket.soTimeout = 3000
                    val input = socket.getInputStream().bufferedReader()
                    val first = input.readLine() ?: return@use
                    val method = first.substringBefore(' ')
                    val uri = URI(first.split(' ').getOrElse(1) { "/" })
                    val query = uri.rawQuery.orEmpty().split('&').mapNotNull { it.split('=', limit = 2).takeIf { pair -> pair.size == 2 }?.let { pair -> pair[0] to pair[1] } }.toMap()
                    val tag = query["tag"]?.takeIf { it.matches(Regex("[a-z0-9]{1,16}")) } ?: "invalid"
                    val mode = query["mode"].orEmpty()
                    val headers = mutableMapOf<String, String>()
                    while (true) {
                        val header = input.readLine()?.takeIf { it.isNotEmpty() } ?: break
                        headers[header.substringBefore(':').lowercase()] = header.substringAfter(':').trim()
                    }
                    val output = socket.getOutputStream()
                    if (uri.path == "/source") {
                        val image = if (mode == "cross") "http://127.0.0.1:${secondary.localPort}/image.png?tag=$tag&mode=$mode" else "/image.png?tag=$tag&mode=$mode"
                        val html = """<!doctype html><html><meta name='viewport' content='width=device-width,initial-scale=1'><title>Owned image $tag</title>
                            <body style='margin:0;padding:18px;font:18px sans-serif'><p>Original image source</p>
                            <img alt='Held original image' src='$image' style='display:block;width:220px;height:180px;object-fit:fill'>
                            <a href='/replacement'>Replacement</a></body></html>""".toByteArray()
                        val policy = if (mode == "csp") "Content-Security-Policy: default-src 'self'; img-src *; style-src 'unsafe-inline'; frame-src 'none'\r\n" else ""
                        output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${html.size}\r\nCache-Control: no-store\r\n" +
                            "Set-Cookie: ${cookie}s=$tag; Path=/; HttpOnly; SameSite=Strict\r\nSet-Cookie: ${cookie}l=$tag; Path=/; HttpOnly; SameSite=Lax\r\n" + policy + "Connection: close\r\n\r\n").toByteArray()); output.write(html)
                    } else if (uri.path == "/image.png") {
                        val supplied = headers["cookie"].orEmpty().split(';').map(String::trim)
                        val strict = "${cookie}s=$tag" in supplied; val lax = "${cookie}l=$tag" in supplied
                        records += Request(tag, method, strict, lax)
                        val ordinal = counts.computeIfAbsent(tag) { java.util.concurrent.atomic.AtomicInteger() }.incrementAndGet()
                        if (ordinal > 1 && mode in setOf("headers", "body", "cancel")) {
                            socket.soTimeout = 500
                            workers.submit {
                                val until = SystemClock.elapsedRealtime() + 40_000
                                while (running.get() && SystemClock.elapsedRealtime() < until && gates[tag]?.count != 0L) {
                                    try {
                                        if (socket.getInputStream().read() < 0) { cancelledClients += tag; break }
                                    } catch (_: SocketTimeoutException) { /* Bounded polling of only this owned fixture socket. */ }
                                    catch (_: IOException) { break }
                                }
                            }
                        }
                        if (ordinal > 1 && mode in setOf("headers", "cancel")) check(gates.computeIfAbsent(tag) { CountDownLatch(1) }.await(90, TimeUnit.SECONDS))
                        if (ordinal > 1 && mode == "redirect") {
                            output.write("HTTP/1.1 302 Found\r\nLocation: /redirected.png\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                        } else {
                            val data = if (strict && lax && method == "GET") payload(tag) else "Missing original HttpOnly container cookies".toByteArray()
                            val status = if (strict && lax && method == "GET") "200 OK" else "403 Forbidden"
                            val cache = if (mode == "cached") "private,max-age=3600" else "no-store"
                            output.write(("HTTP/1.1 $status\r\nContent-Type: image/png\r\nX-Frame-Options: DENY\r\nContent-Length: ${data.size}\r\n" +
                                "Cache-Control: $cache\r\nVary: Cookie\r\nConnection: close\r\n\r\n").toByteArray())
                            if (ordinal > 1 && mode == "body") {
                                output.write(data, 0, minOf(1024, data.size)); output.flush()
                                check(gates.computeIfAbsent(tag) { CountDownLatch(1) }.await(90, TimeUnit.SECONDS))
                                output.write(data, minOf(1024, data.size), (data.size - 1024).coerceAtLeast(0))
                            } else output.write(data)
                        }
                    } else {
                        if (uri.path == "/redirected.png") redirects.incrementAndGet()
                        val html = "<html><title>Replacement</title><p>Replacement</p></html>".toByteArray()
                        output.write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: ${html.size}\r\nConnection: close\r\n\r\n".toByteArray()); output.write(html)
                    }
                    output.flush()
                } } catch (_: IOException) { /* Closing the source cancels only its owned client socket. */ }
                catch (_: InterruptedException) { Thread.currentThread().interrupt() } }
            }
        } }
        fun url(path: String) = "http://127.0.0.1:${primary.localPort}$path"
        fun payload(tag: String): ByteArray = Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=") +
            ("original-$tag-".repeat(3000)).toByteArray()
        fun imageRequests(tag: String) = records.count { it.tag == tag }
        fun cancelled(tag: String) = tag in cancelledClients
        fun release(tag: String) { gates.computeIfAbsent(tag) { CountDownLatch(1) }.countDown() }
        fun releaseAll() { gates.values.forEach(CountDownLatch::countDown) }
        override fun close() { running.set(false); releaseAll(); primary.close(); secondary.close(); workers.shutdownNow() }
    }
}

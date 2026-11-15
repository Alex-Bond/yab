package dev.yab.browser

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ActivityScenario
import androidx.lifecycle.ViewModelProvider
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.assertIsDisplayed
import dev.yab.android.MainActivity
import dev.yab.android.BrowserSessionViewModel
import dev.yab.browser.engine.*
import dev.yab.browser.model.*
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentLinkedQueue
import java.net.InetAddress
import java.net.ServerSocket
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule

/** Actual Gecko history, compositor pixels, and owned app storage, rather than synthetic pages. */
class TabRestoreDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val fixture = BrowserInstrumentedTest()

    @Test(timeout = 240_000)
    fun undoReturnsFrontNativeBackScrollAndPrivateCookieJarWithoutPrivateFiles(): Unit = runBlocking {
        BrowserInstrumentedTest.FixtureServer().use { server ->
            fixture.withBrowser { browser, engine ->
                main { fixture.ownSpace(browser, "Undo native fixture"); browser.openUrl(server.url("/safe/undo-first")) }
                ready(browser, "undo-first")
                swipeUp()
                await("first page scroll") { browser.state.value.page.scrollY > 200 }
                val firstScroll = browser.state.value.page.scrollY
                main { browser.openUrl(server.url("/safe/undo-second"), newTab = false) }
                ready(browser, "undo-second")
                val id = browser.state.value.tab!!.id
                swipeUp()
                await("second page scroll") { browser.state.value.page.scrollY > 200 }
                val secondScroll = browser.state.value.page.scrollY
                main { browser.closeTab(id); browser.undoClose() }
                await("Undo front restored") { browser.state.value.tab?.id == id }
                ready(browser, "undo-second")
                assertTrue("Undo lost native Back", browser.state.value.page.canGoBack)
                await("Undo current scroll") { abs(browser.state.value.page.scrollY - secondScroll) < 180 }
                main { assertTrue(browser.back()) }
                ready(browser, "undo-first")
                await("Undo previous scroll") { abs(browser.state.value.page.scrollY - firstScroll) < 180 }

                HttpOnlyJarFixture().use { jar ->
                main { browser.openUrl(jar.url("/read"), privately = true); browser.unlockPrivate(true) }
                pageText(browser, engine, "HttpOnly=empty")
                main { browser.openUrl(jar.url("/write"), newTab = false) }
                pageText(browser, engine, "Cookie was issued")
                main { browser.openUrl(jar.url("/read"), newTab = false) }
                pageText(browser, engine, "HttpOnly=private-undo-only")
                val privateId = browser.state.value.tab!!.id
                // This native Undo case stays inside one live Private session. The
                // separate final-card fixture requires a fresh jar even after Undo.
                main {
                    browser.openUrl("about:blank", privately = true)
                    browser.selectTab(privateId)
                }
                assertEquals(2, browser.state.value.space!!.tabs.size)
                main { browser.openUrl(server.url("/safe/private-undo"), newTab = false) }
                ready(browser, "private-undo")
                main { browser.closeTab(privateId); browser.undoClose() }
                await("Private Undo front restored") { browser.state.value.tab?.id == privateId }
                ready(browser, "private-undo")
                assertTrue(browser.state.value.page.canGoBack)
                // Server read, no Set-Cookie on this route, and HttpOnly is unavailable to JS.
                main { browser.openUrl(jar.url("/read"), newTab = false) }
                pageText(browser, engine, "HttpOnly=private-undo-only")
                assertEquals("The fixture reissued a cookie after Undo", 1, jar.issued.get())
                val name = UUID.nameUUIDFromBytes(privateId.toByteArray()).toString()
                assertFalse(File(context.filesDir, "navigation/$name.json").exists())
                assertFalse(File(context.cacheDir, "public-tab-pictures/$name.thumb").exists())
                assertNull(engine.thumbnails.value[privateId])
                assertFalse(browser.publicSnapshot().toString().contains("private-undo-only"))
                }
            }
        }
    }

    @Test(timeout = 180_000)
    fun realCompositorPictureSurvivesDecodedStoreRecreationAndCloseDataClearPurgeDisk(): Unit = runBlocking {
        BrowserInstrumentedTest.FixtureServer().use { server ->
            fixture.withBrowser { browser, engine ->
                main { fixture.ownSpace(browser, "Public picture fixture"); browser.openUrl(server.url("/safe/disk-one")) }
                ready(browser, "disk-one")
                val first = browser.state.value.tab!!
                val profile = browser.state.value.space!!.websiteProfile
                val owner = ThumbnailOwner(first.id, profile.id, first.url)
                await("real first compositor snapshot") { engine.thumbnails.value[first.id] != null }
                val disk = PublicThumbnailDiskCache(File(context.cacheDir, "public-tab-pictures"))
                awaitDisk("first public JPEG") { disk.get(owner) != null }
                val worker = Executors.newSingleThreadExecutor()
                val handler = Handler(Looper.getMainLooper())
                val restored = TabThumbnails(maximum = 1, disk = disk, io = { worker.execute(it) }, main = { handler.post(it) })
                try {
                    main { restored.reconcile(listOf(owner)) }
                    await("new decoded store reads actual disk image") { restored.state.value[first.id] != null }
                    val copy = restored.state.value.getValue(first.id)
                    assertEquals(first.url, copy.url); assertEquals(profile.id, copy.profileId)
                    assertTrue(copy.bitmap.width > 0 && copy.bitmap.height > 0)
                    assertNotSame(engine.thumbnails.value[first.id]!!.bitmap, copy.bitmap)
                    val raceFolder = File(context.cacheDir, "picture-owner-proof-${UUID.randomUUID()}")
                    val raceDisk = PublicThumbnailDiskCache(raceFolder)
                    val original = withContext(Dispatchers.IO) { disk.get(owner)!! }
                    withContext(Dispatchers.IO) { raceDisk.put(original.capture, original.jpeg) }
                    val callbacks = ConcurrentLinkedQueue<() -> Unit>()
                    val stale = TabThumbnails(disk = raceDisk, io = { worker.execute(it) }, main = { callbacks.add(it) })
                    try {
                        main { stale.reconcile(listOf(owner)) }
                        await("old owned image decoded before identity transition") { callbacks.isNotEmpty() }
                        main {
                            val oldDecode = callbacks.remove()
                            stale.invalidateOwnership(); stale.reconcile(listOf(owner))
                            oldDecode()
                            assertNull("A pre-transition decode republished after exact identifier reuse", stale.state.value[first.id])
                        }
                    } finally {
                        main { stale.close() }
                        // A FIFO barrier keeps cleanup behind this store's queued purge/read.
                        withContext(Dispatchers.IO) { worker.submit { raceFolder.listFiles()?.forEach { it.delete() }; raceFolder.delete() }.get(10, java.util.concurrent.TimeUnit.SECONDS) }
                    }
                    main { browser.openUrl(server.url("/safe/disk-two")) }
                    ready(browser, "disk-two")
                    val second = browser.state.value.tab!!
                    val other = ThumbnailOwner(second.id, profile.id, second.url)
                    await("real second compositor snapshot") { engine.thumbnails.value[second.id] != null }
                    awaitDisk("second public JPEG") { disk.get(other) != null }
                    main { restored.reconcile(listOf(owner, other)); restored.request(other) }
                    await("later visible card replaces decoded working set") { restored.state.value[second.id] != null && restored.state.value[first.id] == null }
                    main { restored.request(owner) }
                    await("evicted card reloads lazily from disk") { restored.state.value[first.id] != null }
                    main { browser.closeTab(first.id) }
                    awaitDisk("close purges first JPEG") { disk.get(owner) == null }
                    mainSuspend { engine.clearWebsiteData(setOf(profile.id)) }
                    awaitDisk("scoped data clear purges second JPEG") { disk.get(other) == null }
                    assertNull(engine.thumbnails.value[second.id])
                } finally {
                    main { restored.close() }
                    worker.shutdown()
                }
            }
        }
    }

    @Test(timeout = 360_000)
    fun shippedGalleryLoadsActualOlderPictureBeyondEighteenDecodedEntries(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") { "Requires the disposable runner device" }
        BrowserInstrumentedTest.FixtureServer().use { server ->
            val scenario = ActivityScenario.launch(MainActivity::class.java)
            lateinit var owner: BrowserSessionViewModel
            var restore: BrowserSnapshot? = null
            try {
                scenario.onActivity { owner = ViewModelProvider(it)[BrowserSessionViewModel::class.java] }
                val browser = owner.browser
                val engine = owner.engine
                await("Main profile") { !browser.state.value.loading }
                restore = browser.publicSnapshot()
                main {
                    browser.updateSettings(browser.state.value.settings.copy(welcomed = true, autoClearToday = false))
                    fixture.ownSpace(browser, "Gallery cache ${UUID.randomUUID()}")
                }
                val pictures = mutableListOf<BrowserTab>()
                val disk = PublicThumbnailDiskCache(File(context.cacheDir, "public-tab-pictures"))
                repeat(20) { index ->
                    main { browser.openUrl(server.url("/safe/gallery-$index")) }
                    ready(browser, "gallery-$index")
                    val tab = browser.state.value.tab!!
                    val profile = browser.state.value.space!!.websiteProfile
                    try {
                        await("real compositor picture $index") { engine.thumbnails.value[tab.id] != null }
                    } catch (failure: Throwable) {
                        val status = main { engine.thumbnailStatus(tab.id) }
                        File(context.getExternalFilesDir(null), "instrumentation/gallery-capture-status.txt").apply {
                            parentFile?.mkdirs()
                            writeText("fixtureIndex=$index,$status")
                        }
                        throw failure
                    }
                    awaitDisk("durable compositor picture $index") { disk.get(ThumbnailOwner(tab.id, profile.id, tab.url)) != null }
                    pictures += tab
                }
                val old = pictures.first()
                main {
                    browser.show(BrowserSurface.GALLERY)
                    engine.setVisibleTabs(emptySet())
                    engine.onTrimMemory(android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW)
                }
                await("old native source evicted", 60_000) { !engine.hasLiveSession(old.id) }
                val index = browser.state.value.galleryTabs.indexOfFirst { it.id == old.id }
                assertTrue("Fixture did not reach beyond the decoded cache bound", index >= 18)
                compose.onNodeWithTag("browser.gallery.cards").performScrollToIndex(index)
                compose.waitUntil(20_000) { engine.thumbnails.value[old.id] != null }
                compose.onNodeWithContentDescription("${old.title} page preview", useUnmergedTree = true).assertIsDisplayed()
                assertFalse(engine.thumbnails.value.getValue(old.id).bitmap.isRecycled)
                assertFalse("Loading a picture navigated the old tab", engine.hasLiveSession(old.id))
                fixture.shot("gallery-later-public-disk-picture.png")
            } finally {
                if (restore != null) {
                    main { owner.browser.applySyncedSnapshot(restore!!) }
                    await("gallery public fixture cleanup") { FileBrowserRepository(File(context.filesDir, "browser.json")).load() == restore }
                }
                scenario.close()
            }
        }
    }

    private suspend fun ready(browser: BrowserController, page: String) = await("$page native document", 45_000) {
        browser.state.value.page.let { it.title == "Safe page $page" && !it.loading && it.progress >= 1 && it.safeToClear }
    }
    private suspend fun pageText(browser: BrowserController, engine: GeckoEngine, text: String) {
        val until = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < until) {
            val value = runCatching { mainSuspend { engine.readText(browser.state.value.tab!!).text } }.getOrNull()
            if (value?.contains(text) == true) return
            delay(100)
        }
        error("Owned fixture body was not returned")
    }
    private fun swipeUp() {
        val screen = context.resources.displayMetrics
        val down = SystemClock.uptimeMillis()
        for (step in 0..10) {
            val action = when (step) { 0 -> MotionEvent.ACTION_DOWN; 10 -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_MOVE }
            val event = MotionEvent.obtain(down, down + step * 25, action, screen.widthPixels / 2f,
                screen.heightPixels * (.7f - .42f * step / 10), 0)
            event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            assertTrue(instrumentation.uiAutomation.injectInputEvent(event, true)); event.recycle()
        }
    }
    private suspend fun awaitDisk(name: String, predicate: () -> Boolean) = await(name) { withContext(Dispatchers.IO) { predicate() } }
    private suspend fun await(name: String, timeout: Long = 20_000, predicate: suspend () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeout
        while (true) {
            // This functional fixture owns a Compose test clock. Let the real
            // state flow mount/update its native GeckoView before asking for
            // compositor pixels; a wall-clock delay alone cannot do that.
            compose.waitForIdle()
            if (predicate()) return
            check(SystemClock.elapsedRealtime() < until) { "Timed out waiting for $name" }
            delay(50)
        }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun <T> mainSuspend(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }

    private class HttpOnlyJarFixture : AutoCloseable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val worker = Executors.newSingleThreadExecutor()
        val issued = AtomicInteger()
        init { worker.execute {
            while (running.get()) {
                val socket = try { server.accept() } catch (_: IOException) { break }
                try { socket.use { connection ->
                    connection.soTimeout = 5_000
                    val input = connection.getInputStream().bufferedReader()
                    val request = input.readLine().orEmpty()
                    var cookie = ""
                    while (true) {
                        val header = input.readLine() ?: break
                        if (header.isEmpty()) break
                        if (header.startsWith("Cookie:", ignoreCase = true)) cookie = header.substringAfter(':').trim()
                    }
                    val write = request.split(' ').getOrNull(1) == "/write"
                    val issueCookie = write && issued.compareAndSet(0, 1)
                    val hasCookie = cookie.split(';').any { it.trim() == "httpOnlyFixture=private-undo-only" }
                    val text = if (write) "Cookie was issued" else "HttpOnly=" + if (hasCookie) "private-undo-only" else "empty"
                    val body = "<!doctype html><html lang='en'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Owned HttpOnly fixture</title><main>$text</main></html>".toByteArray()
                    val setCookie = if (issueCookie) "Set-Cookie: httpOnlyFixture=private-undo-only; HttpOnly; Path=/; SameSite=Lax\r\n" else ""
                    connection.getOutputStream().use { output ->
                        output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n" + setCookie + "Content-Length: ${body.size}\r\nConnection: close\r\n\r\n").toByteArray())
                        output.write(body)
                    }
                } } catch (_: IOException) { /* A canceled navigation owns no fixture failure. */ }
            }
        } }
        fun url(path: String) = "http://127.0.0.1:${server.localPort}$path"
        override fun close() { running.set(false); server.close(); worker.shutdownNow() }
    }
}

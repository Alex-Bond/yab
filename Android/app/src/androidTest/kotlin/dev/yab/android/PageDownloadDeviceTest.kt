package dev.yab.android

import android.app.Notification
import android.app.NotificationManager
import android.os.SystemClock
import android.view.WindowManager
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.BrowserInstrumentedTest
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.*
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** The shipped MainActivity consumes a real cookie-authenticated Gecko response, never a test stream. */
@RunWith(AndroidJUnit4::class)
class PageDownloadDeviceTest {
    private lateinit var ui: OwnedBrowserTestUi
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun originalCookieResponseSurvivesRecreationAndBackgroundThenClosesWithItsSource(): Unit = runBlocking {
        withMain(OwnedBrowserTestUi.Case.DOWNLOAD_PUBLIC) { scenario, owner, fixture ->
            openSource(owner, fixture)
            val tab = owner.browser.state.value.tab!!
            val profile = owner.browser.state.value.space!!.websiteProfile
            val native = main { owner.engine.session(tab, profile) }
            val controller = owner.downloads
            click("Download proof file")
            await("original native response progress") { controller.state.value.let { it.phase == PageDownloadPhase.TRANSFERRING && it.received > 0 } }
            val transfer = controller.state.value
            val source = requireNotNull(transfer.owner)
            val lease = source.native as GeckoEngine.ExternalActivityOwner
            assertEquals(tab.id, source.tab)
            assertEquals(profile.id, source.profile)
            assertFalse(source.privateOrigin)
            assertEquals("Yab original 😀.bin", transfer.name)
            assertTrue(main { owner.engine.externalActivityAlive(lease) })
            assertCookie(fixture, "one")
            await("actual transfer foreground service") { downloadNotification() != null }
            BrowserInstrumentedTest().shot("download-transferring.png")

            scenario.recreate()
            scenario.onActivity { activity ->
                val retained = ViewModelProvider(activity)[BrowserSessionViewModel::class.java]
                assertSame(owner, retained)
                assertSame(controller, retained.downloads)
                assertSame(native, retained.engine.session(tab, profile))
            }
            assertEquals(transfer.id, controller.state.value.id)
            assertEquals(PageDownloadPhase.TRANSFERRING, controller.state.value.phase)
            scenario.moveToState(Lifecycle.State.CREATED)
            assertTrue("Backgrounding the same public page revoked its source", main { owner.engine.externalActivityAlive(lease) })
            fixture.finish("one")
            await("original response finished while backgrounded") { controller.state.value.phase == PageDownloadPhase.READY }
            scenario.moveToState(Lifecycle.State.RESUMED)
            await("retained ready dialog") { ui.hasLabel("Download Ready") }
            assertEquals(fixture.payload.size.toLong(), controller.state.value.received)
            assertCookie(fixture, "one")
            val export = main { requireNotNull(controller.beginExport(transfer.id!!, PageDownloadExportKind.SAVE)) }
            val actual = withContext(Dispatchers.IO) { export.file.readBytes() }
            assertEquals(digest(fixture.payload), digest(actual))
            // Exercise the real provider and bytes without claiming a recipient has read a share.
            val uri = FileProvider.getUriForFile(context, context.packageName + ".files", export.file)
            assertEquals(digest(fixture.payload), withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)!!.use { digest(it.readBytes()) } })
            main { controller.exportCancelled(export.token) }
            await("ready actions returned") { ui.hasLabel("Download Ready") }
            BrowserInstrumentedTest().shot("download-ready-after-recreate.png")
            click("Cancel")
            await("ready file cancelled") { controller.state.value.phase == PageDownloadPhase.CANCELLED && !export.file.exists() }
            assertEquals("A save/share check must not refetch the URL", 1, fixture.requests.count { it.first == "one" })

            await("source is interactive again") { main { owner.engine.ownsInteractive(native) } }
            click("Download second file")
            await("second original response") { controller.state.value.let { it.phase == PageDownloadPhase.TRANSFERRING && it.received > 0 && it.id != transfer.id } }
            val second = controller.state.value.id!!
            assertCookie(fixture, "two")
            main { owner.browser.closeTab(tab.id) }
            await("closing the source cancels and cleans up") {
                controller.state.value.phase == PageDownloadPhase.CANCELLED && !File(context.cacheDir, "shared/download-$second").exists()
            }
            fixture.finish("two")
            assertEquals(1, fixture.requests.count { it.first == "two" })
        }
    }

    @Test(timeout = 180_000)
    fun privateDownloadStaysHiddenWhileAwayThenManualLockRevokesItsReadyFile(): Unit = runBlocking {
        withMain(OwnedBrowserTestUi.Case.DOWNLOAD_PRIVATE) { scenario, owner, fixture ->
            openSource(owner, fixture, privateOrigin = true)
            scenario.onActivity { assertTrue(it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) }
            val tab = owner.browser.state.value.tab!!
            click("Download proof file")
            await("Private original native response") { owner.downloads.state.value.let { it.phase == PageDownloadPhase.TRANSFERRING && it.received > 0 } }
            val transfer = owner.downloads.state.value
            val source = requireNotNull(transfer.owner)
            assertTrue(source.privateOrigin)
            assertCookie(fixture, "one")
            await("Private foreground notification") { downloadNotification() != null }
            val notification = requireNotNull(downloadNotification())
            assertEquals("Yab download", notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
            assertEquals(Notification.VISIBILITY_SECRET, notification.visibility)
            val words = notification.extras.toString()
            assertFalse(words.contains(transfer.name))
            assertFalse(words.contains(fixture.nonce))
            assertFalse(words.contains(fixture.url("/source")))
            scenario.moveToState(Lifecycle.State.CREATED)
            assertTrue(owner.browser.state.value.privateContentBlocked)
            fixture.finish("one")
            await("Private original response finishes while away and locked") { owner.downloads.state.value.phase == PageDownloadPhase.READY }
            val ownedFile = File(context.cacheDir, "shared/download-${transfer.id}/${transfer.name}")
            assertTrue(ownedFile.isFile)
            assertEquals(digest(fixture.payload), withContext(Dispatchers.IO) { digest(ownedFile.readBytes()) })
            scenario.moveToState(Lifecycle.State.RESUMED)
            // RESUMED/locked state can precede the first owned window draw. The
            // absence assertions below require the real visible cover's tree.
            await("Private cover after returning") { ui.hasLabel("Private is Locked") && ui.hasLabel("Unlock") && owner.browser.state.value.privateContentBlocked }
            assertTrue(owner.browser.state.value.privateContentBlocked)
            ui.requireLabelAbsent("Download Ready")
            ui.requireLabelAbsent(transfer.name)
            // This is an explicit state fixture, not evidence of biometric authentication.
            main { owner.browser.unlockPrivate(true) }
            await("ready file appears only after explicit fixture unlock") { ui.hasLabel("Download Ready") && ui.hasLabel(transfer.name) }
            main { owner.browser.lockPrivate() }
            await("manual Private lock cancels the ready file") {
                owner.downloads.state.value.phase == PageDownloadPhase.CANCELLED &&
                    !File(context.cacheDir, "shared/download-${transfer.id}").exists()
            }
            assertFalse(main { owner.engine.externalActivityAlive(source.native as GeckoEngine.ExternalActivityOwner) })
            assertFalse(File(context.filesDir, "browser.json").readText().contains(fixture.nonce))
            assertFalse(File(context.filesDir, "navigation/${UUID.nameUUIDFromBytes(tab.id.toByteArray())}.json").exists())
            assertEquals(1, fixture.requests.count { it.first == "one" })
            fixture.finish("one")
        }
    }

    private suspend fun withMain(case: OwnedBrowserTestUi.Case, block: suspend (ActivityScenario<MainActivity>, BrowserSessionViewModel, DownloadFixture) -> Unit) {
        ui = OwnedBrowserTestUi(case)
        ui.run {
            check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") { "Requires the runner's disposable owned emulator" }
            DownloadFixture().use { fixture ->
                val scenario = ActivityScenario.launch(MainActivity::class.java)
                lateinit var owner: BrowserSessionViewModel
                var restore: BrowserSnapshot? = null
                var bodyFailure: Throwable? = null
                try {
                    scenario.onActivity { owner = ViewModelProvider(it)[BrowserSessionViewModel::class.java] }
                    await("Main browser profile", 30_000) { !owner.browser.state.value.loading }
                    main { ui.bind(owner.browser, owner.engine) { owner.downloads.state.value.let { it.id to it.owner } } }
                    ui.checkpoint("browser_ready")
                    restore = owner.browser.publicSnapshot()
                    main {
                        owner.browser.updateSettings(owner.browser.state.value.settings.copy(welcomed = true, autoClearToday = false, lockPrivate = true))
                        BrowserInstrumentedTest().ownSpace(owner.browser, "Native download ${UUID.randomUUID()}")
                    }
                    block(scenario, owner, fixture)
                } catch (failure: Throwable) { bodyFailure = failure; throw failure }
                finally {
                  try {
                    if (restore != null) {
                        main {
                            owner.downloads.cancel()
                            owner.browser.state.value.spaces.filter(BrowserSpace::isPrivate).flatMap { it.tabs }.forEach { owner.browser.closeTab(it.id) }
                            owner.browser.applySyncedSnapshot(restore!!)
                            owner.browser.selectSpace(restore!!.selectedSpaceId)
                        }
                        fixture.finish("one"); fixture.finish("two")
                        await("download cleanup") { owner.downloads.state.value.phase in setOf(PageDownloadPhase.CANCELLED, PageDownloadPhase.SAVED, PageDownloadPhase.SHARED) }
                        await("restored public snapshot") { FileBrowserRepository(File(context.filesDir, "browser.json")).load() == restore }
                    }
                  } catch (cleanup: Throwable) {
                      bodyFailure?.addSuppressed(cleanup) ?: throw cleanup
                  } finally { scenario.close() }
                }
            }
        }
    }

    private suspend fun openSource(owner: BrowserSessionViewModel, fixture: DownloadFixture, privateOrigin: Boolean = false) {
        main {
            owner.browser.openUrl(fixture.url("/source"), privately = privateOrigin)
            if (privateOrigin) owner.browser.unlockPrivate(true)
        }
        await("cookie-authenticated source page", 30_000) {
            owner.browser.state.value.page.let { !it.loading && it.title == "Original download ${fixture.nonce}" }
        }
        await("native source link") { ui.hasLabel("Download proof file") }
    }

    private fun assertCookie(fixture: DownloadFixture, name: String) {
        val requests = fixture.requests.filter { it.first == name }
        assertEquals("The original response was refetched", 1, requests.size)
        assertTrue("Gecko did not send its HttpOnly container cookie", requests.single().second.split(';').any { it.trim() == "yabdl=${fixture.nonce}" })
    }
    private fun downloadNotification(): Notification? = context.getSystemService(NotificationManager::class.java).activeNotifications
        .firstOrNull { it.notification.channelId == "yab-page-downloads" }?.notification
    private suspend fun click(text: String) = ui.click(text)
    private suspend fun await(label: String, timeout: Long = 20_000, condition: suspend () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (!condition()) { check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $label" }; delay(50) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }

    private class DownloadFixture : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val active = AtomicBoolean(true)
        private val workers = Executors.newFixedThreadPool(4)
        private val gates = ConcurrentHashMap<String, CountDownLatch>()
        val nonce = UUID.randomUUID().toString()
        val requests = ConcurrentLinkedQueue<Pair<String, String>>()
        val payload = ByteArray(512 * 1024 + 79) { (it * 31 % 251).toByte() }
        init {
            workers.submit {
                while (active.get()) {
                    val client = try { server.accept() } catch (error: IOException) { if (active.get()) throw error else break }
                    workers.submit {
                        try { client.use { socket ->
                            socket.soTimeout = 5_000
                            val input = socket.getInputStream().bufferedReader()
                            val line = input.readLine() ?: return@use
                            val address = URI(line.split(' ').getOrElse(1) { "/" })
                            val headers = mutableMapOf<String, String>()
                            while (true) {
                                val header = input.readLine()?.takeIf { it.isNotEmpty() } ?: break
                                val separator = header.indexOf(':')
                                if (separator > 0) headers[header.substring(0, separator).lowercase(java.util.Locale.ROOT)] = header.substring(separator + 1).trim()
                            }
                            val output = socket.getOutputStream()
                            if (address.path == "/file") {
                                val name = address.rawQuery?.substringAfter("id=")?.takeIf { it in setOf("one", "two") } ?: "invalid"
                                requests.add(name to headers["cookie"].orEmpty())
                                val valid = headers["cookie"].orEmpty().split(';').any { it.trim() == "yabdl=$nonce" }
                                val data = if (valid) payload else "The native cookie is missing".toByteArray()
                                output.write(("HTTP/1.1 ${if (valid) "200 OK" else "403 Forbidden"}\r\nContent-Type: application/octet-stream\r\n" +
                                    "Content-Disposition: attachment; filename=proof.bin; filename*=UTF-8''Yab%20original%20%F0%9F%98%80.bin\r\n" +
                                    "Content-Length: ${data.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray())
                                val first = minOf(data.size, 64 * 1024)
                                output.write(data, 0, first); output.flush()
                                check(gates.computeIfAbsent(name) { CountDownLatch(1) }.await(90, TimeUnit.SECONDS)) { "Native download proof did not release its response" }
                                output.write(data, first, data.size - first); output.flush()
                            } else {
                                val html = """<!doctype html><html><meta name='viewport' content='width=device-width,initial-scale=1'><title>Original download $nonce</title>
                                    <main><h1>Native download source</h1><p>Only this Gecko container has the HttpOnly download cookie.</p>
                                    <a style='display:block;font-size:20px;padding:20px' href='/file?id=one' download>Download proof file</a>
                                    <a style='display:block;font-size:20px;padding:20px' href='/file?id=two' download>Download second file</a></main></html>""".trimIndent().toByteArray()
                                output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${html.size}\r\n" +
                                    "Set-Cookie: yabdl=$nonce; Path=/; HttpOnly; SameSite=Lax\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray())
                                output.write(html); output.flush()
                            }
                        } } catch (_: IOException) { /* The original reader may cancel; a broken pipe never kills instrumentation. */ }
                        catch (_: InterruptedException) { Thread.currentThread().interrupt() }
                    }
                }
            }
        }
        fun url(path: String) = "http://127.0.0.1:${server.localPort}$path"
        fun finish(id: String) { gates.computeIfAbsent(id) { CountDownLatch(1) }.countDown() }
        override fun close() { active.set(false); finish("one"); finish("two"); server.close(); workers.shutdownNow() }
    }
}

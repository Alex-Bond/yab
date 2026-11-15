package dev.yab.browser

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.BrowserSessionViewModel
import dev.yab.android.MainActivity
import dev.yab.browser.media.*
import dev.yab.browser.model.*
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.PI
import kotlin.math.sin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Actual page playback, platform transport, background service and OS PiP. No player fake. */
@RunWith(AndroidJUnit4::class)
class MediaPlaybackTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val mediaEvents = org.json.JSONArray()
    private class Ended : androidx.lifecycle.ViewModel() {
        @Volatile var cleared = false
        override fun onCleared() { cleared = true }
    }
    private val context get() = instrumentation.targetContext
    private val notifications get() = context.getSystemService(NotificationManager::class.java)

    @Test(timeout = 240_000)
    fun publicAudioContinuesBehindHomeAndLockWithRealSystemControlsAndFocus(): Unit = runBlocking {
        withMain { scenario, owner, server ->
            open(owner, server.url("/audio"))
            click("Play fixture")
            val tab = owner.browser.state.value.tab!!.id
            await("native public playback") { owner.engine.media.value.any { it.owner.tabId == tab && it.playing } }
            val platform = platformController()
            await("native public metadata reached Android") { platform.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) == "Public playback fixture" }
            try { await("native Pause capability reached the platform session") {
                MediaAction.PAUSE in native(owner, tab)?.actions.orEmpty() &&
                    (platform.playbackState?.actions ?: 0L) and android.media.session.PlaybackState.ACTION_PAUSE != 0L
            } } catch (failure: Throwable) { mediaState("pause-capability", owner, tab, platform); throw failure }
            assertEquals(native(owner, tab)?.owner, owner.media.state.value?.owner)
            platform.transportControls.pause()
            try { await("platform pause reached Gecko") { native(owner, tab)?.playing == false } }
            catch (failure: Throwable) { mediaState("platform-pause", owner, tab, platform); throw failure }
            await("native Play capability after pause") { MediaAction.PLAY in native(owner, tab)?.actions.orEmpty() }
            platform.transportControls.play()
            await("platform play reached Gecko") { native(owner, tab)?.playing == true }
            await("native absolute seek capability") { MediaAction.SEEK_TO in native(owner, tab)?.actions.orEmpty() }
            platform.transportControls.seekTo(12_000)
            await("platform absolute seek reached actual media") { (native(owner, tab)?.positionSeconds ?: 0.0) >= 11.8 }
            shell("input keyevent 3")
            await("Main is stopped behind Home") { scenario.state == androidx.lifecycle.Lifecycle.State.CREATED }
            advances(owner, tab, "background audio")
            // These are actual Android media key events, handled through the system session.
            shell("input keyevent 127")
            await("system media-key pause") { native(owner, tab)?.playing == false }
            shell("input keyevent 126")
            await("system media-key resume") { native(owner, tab)?.playing == true }
            val audio = context.getSystemService(AudioManager::class.java)
            val interruption = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener { }.build()
            try {
                assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, audio.requestAudioFocus(interruption))
                await("real platform focus interruption paused Gecko") { native(owner, tab)?.playing == false }
            } finally { audio.abandonAudioFocusRequest(interruption) }
            await("focus return resumed interrupted media") { native(owner, tab)?.playing == true }
            shell("input keyevent 223")
            advances(owner, tab, "screen-off playback")
            shell("input keyevent 224"); shell("input keyevent 82")
            returnToOwnedMain(scenario)
            val oldOwner = native(owner, tab)!!.owner
            main { owner.browser.closeTab(tab) }
            await("closing the tab removes system controls") { mediaNotification() == null }
            platform.transportControls.play()
            delay(300)
            assertFalse(owner.engine.hasLiveSession(tab))
            assertFalse(owner.engine.mediaCommand(oldOwner, MediaCommand(MediaAction.PLAY)))
        }
    }

    @Test(timeout = 240_000)
    fun privateBackgroundFollowsLockSettingAndNeverExportsPageMetadata(): Unit = runBlocking {
        withMain { scenario, owner, server ->
            main { owner.browser.openUrl(server.url("/private-audio"), privately = true); owner.browser.unlockPrivate(true) }
            loaded(owner, "Private playback fixture")
            click("Play fixture")
            var tab = owner.browser.state.value.tab!!.id
            await("private native playback") { native(owner, tab)?.playing == true }
            assertNull("Locked-policy Private created system controls", mediaNotification())
            main { owner.browser.lockPrivate() }
            await("Private lock stops native media") { native(owner, tab)?.playing != true }
            main {
                owner.browser.updateSettings(owner.browser.state.value.settings.copy(lockPrivate = false))
                owner.browser.unlockPrivate(true)
                owner.browser.openUrl(server.url("/private-audio"), privately = true)
            }
            loaded(owner, "Private playback fixture")
            tab = owner.browser.state.value.tab!!.id
            click("Play fixture")
            await("unlocked-policy private playback") { native(owner, tab)?.playing == true }
            val platform = platformController()
            val metadata = requireNotNull(platform.metadata)
            assertEquals("Private media", metadata.getString(MediaMetadata.METADATA_KEY_TITLE))
            assertEquals("", metadata.getString(MediaMetadata.METADATA_KEY_ARTIST))
            assertEquals("", metadata.getString(MediaMetadata.METADATA_KEY_ALBUM))
            assertNull(metadata.getString(MediaMetadata.METADATA_KEY_MEDIA_URI))
            assertNull(metadata.getBitmap(MediaMetadata.METADATA_KEY_ART))
            val visibleExtras = mediaNotification()!!.extras.toString()
            assertFalse(visibleExtras.contains("Private playback fixture"))
            assertFalse(visibleExtras.contains(server.url("/private-audio")))
            shell("input keyevent 3")
            advances(owner, tab, "private background playback with lock disabled")
            returnToOwnedMain(scenario)
            main { owner.browser.updateSettings(owner.browser.state.value.settings.copy(lockPrivate = true)); owner.browser.lockPrivate() }
            await("changing policy removes private controls") { mediaNotification() == null }
            await("new lock stops the live private player") { native(owner, tab)?.playing != true }
            platform.transportControls.play()
            delay(300)
            assertFalse(native(owner, tab)?.playing == true)
            assertTrue(owner.browser.state.value.privateContentBlocked)
            assertFalse(owner.browser.publicSnapshot().toString().contains("/private-audio"))
            assertFalse(File(context.filesDir, "navigation/${UUID.nameUUIDFromBytes(tab.toByteArray())}.json").exists())
        }
    }

    @Test(timeout = 180_000)
    fun actualPublicFullscreenVideoEntersSystemPipAndReturnsTheSameSession(): Unit = runBlocking {
        pip(privateOrigin = false)
    }

    @Test(timeout = 180_000)
    fun actualPrivatePipRetainsSecureWindowAndGenericControls(): Unit = runBlocking {
        pip(privateOrigin = true)
    }

    private suspend fun pip(privateOrigin: Boolean) = withMain { scenario, owner, server ->
        main {
            owner.browser.updateSettings(owner.browser.state.value.settings.copy(lockPrivate = !privateOrigin))
            owner.browser.openUrl(server.url(if (privateOrigin) "/private-video" else "/video"), privately = privateOrigin)
            if (privateOrigin) owner.browser.unlockPrivate(true)
        }
        loaded(owner, if (privateOrigin) "Private playback fixture" else "Public playback fixture")
        click("Play fixture")
        val tab = owner.browser.state.value.tab!!
        val profile = owner.browser.state.value.space!!.websiteProfile
        val original = main { owner.engine.session(tab, profile) }
        await("native video playing") { native(owner, tab.id)?.playing == true }
        click("Fullscreen fixture")
        await("native fullscreen metadata") { native(owner, tab.id)?.let { it.fullscreen && it.hasVideo && it.videoWidth > 0 && it.videoHeight > 0 } == true }
        if (privateOrigin) scenario.onActivity { assertTrue(it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) }
        else BrowserInstrumentedTest().shot("media-public-fullscreen-before-home.png")
        shell("input keyevent 3")
        var entered = false
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (!entered && SystemClock.elapsedRealtime() < deadline) {
            scenario.onActivity { entered = it.isInPictureInPictureMode }
            delay(100)
        }
        val evidence = JSONObject().put("private", privateOrigin).put("enteredSystemPip", entered)
            .put("nativeVideo", true).put("nativePlaying", native(owner, tab.id)?.playing == true)
        scenario.onActivity { evidence.put("secureWindow", it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) }
        File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
            .resolve(if (privateOrigin) "private-pip.json" else "public-pip.json").writeText(evidence.toString(2))
        assertTrue(if (privateOrigin) "Owned device did not enter Private PiP with FLAG_SECURE; B18 Private PiP remains unverified" else "Public fullscreen video did not enter actual Android PiP", entered)
        assertTrue(native(owner, tab.id)?.playing == true)
        if (privateOrigin) assertEquals("Private media", requireNotNull(platformController().metadata).getString(MediaMetadata.METADATA_KEY_TITLE))
        else {
            // The mode callback precedes the system's surface transition. Retain
            // presented frames after it, rather than calling a transition-black
            // first capture proof that video is visible in the PiP window.
            for (frame in 0..2) {
                delay(500)
                scenario.onActivity { assertTrue(it.isInPictureInPictureMode) }
                assertTrue(native(owner, tab.id)?.playing == true)
                BrowserInstrumentedTest().shot("media-public-system-pip-$frame.png")
            }
        }
        returnToOwnedMain(scenario)
        await("returned from actual PiP") { var pip = true; scenario.onActivity { pip = it.isInPictureInPictureMode }; !pip }
        assertSame(original, main { owner.engine.session(tab, profile) })
        assertTrue(native(owner, tab.id)?.playing == true)
    }

    private suspend fun withMain(block: suspend (ActivityScenario<MainActivity>, BrowserSessionViewModel, MediaFixture) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        OwnedLoopbackSiteSettings.reset()
        val video = File(context.filesDir, "media-tests/gizmo.mp4")
        assertEquals(455255L, video.length())
        assertEquals("e907bff0e32529c99f282a2d954291a412692ac6e35265b1423e24ad2d5ed395", MessageDigest.getInstance("SHA-256").digest(video.readBytes()).joinToString("") { "%02x".format(it.toInt() and 255) })
        MediaFixture(video).use { server ->
            val repository = FileBrowserRepository(File(context.filesDir, "browser.json"))
            val initial = repository.load() ?: BrowserSnapshot(
                spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal")),
                selectedSpaceId = BrowserController.PERSONAL_SPACE)
            repository.save(initial.copy(settings = initial.settings.copy(welcomed = true)))
            val scenario = ActivityScenario.launch(MainActivity::class.java)
            lateinit var owner: BrowserSessionViewModel
            var restore: BrowserSnapshot? = null
            var ended: Ended? = null
            var bodyFailure: Throwable? = null
            try {
                scenario.onActivity { activity ->
                    owner = ViewModelProvider(activity)[BrowserSessionViewModel::class.java]
                    ended = ViewModelProvider(activity, object : androidx.lifecycle.ViewModelProvider.Factory {
                        @Suppress("UNCHECKED_CAST")
                        override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T {
                            check(modelClass == Ended::class.java); return Ended() as T
                        }
                    })[Ended::class.java]
                    val previous = owner.engine.onSessionCreated
                    owner.engine.onSessionCreated = { session ->
                        previous(session)
                        val shipped = checkNotNull(session.mediaSessionDelegate)
                        fun event(name: String, features: Long? = null) {
                            if (mediaEvents.length() < 64) mediaEvents.put(JSONObject().put("event", name).put("features", features))
                        }
                        // Gecko's Java default callbacks need explicit forwarding. A Kotlin
                        // delegated wrapper would drop metadata/position callbacks.
                        session.mediaSessionDelegate = object : org.mozilla.geckoview.MediaSession.Delegate {
                            override fun onActivated(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession) {
                                event("activated"); shipped.onActivated(s, media)
                            }
                            override fun onDeactivated(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession) {
                                event("deactivated"); shipped.onDeactivated(s, media)
                            }
                            override fun onFeatures(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession, features: Long) {
                                event("features", features); shipped.onFeatures(s, media, features)
                            }
                            override fun onPlay(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession) {
                                event("play"); shipped.onPlay(s, media)
                            }
                            override fun onPause(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession) {
                                event("pause"); shipped.onPause(s, media)
                            }
                            override fun onStop(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession) {
                                event("stop"); shipped.onStop(s, media)
                            }
                            override fun onMetadata(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession, meta: org.mozilla.geckoview.MediaSession.Metadata) {
                                event("metadata"); shipped.onMetadata(s, media, meta)
                            }
                            override fun onPositionState(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession, position: org.mozilla.geckoview.MediaSession.PositionState) {
                                event("position"); shipped.onPositionState(s, media, position)
                            }
                            override fun onFullscreen(s: org.mozilla.geckoview.GeckoSession, media: org.mozilla.geckoview.MediaSession, enabled: Boolean, meta: org.mozilla.geckoview.MediaSession.ElementMetadata?) {
                                event("fullscreen"); shipped.onFullscreen(s, media, enabled, meta)
                            }
                        }
                    }
                }
                await("Main profile") { !owner.browser.state.value.loading }
                restore = owner.browser.publicSnapshot()
                main {
                    owner.browser.updateSettings(owner.browser.state.value.settings.copy(welcomed = true, autoClearToday = false, lockPrivate = true))
                    BrowserInstrumentedTest().ownSpace(owner.browser, "Native media ${UUID.randomUUID()}")
                }
                block(scenario, owner, server)
            } catch (failure: Throwable) {
                bodyFailure = failure
                val out = File(context.getExternalFilesDir(null), "instrumentation/media-fixture").apply { mkdirs() }
                out.resolve("native-events.json").writeText(mediaEvents.toString(2))
                throw failure
            }
            finally {
              try {
                shell("input keyevent 224"); shell("input keyevent 82")
                if (restore != null) {
                    main {
                        owner.browser.state.value.spaces.filter(BrowserSpace::isPrivate).flatMap { it.tabs }.forEach { owner.browser.closeTab(it.id) }
                        owner.browser.applySyncedSnapshot(restore!!)
                    }
                    val end = SystemClock.elapsedRealtime() + 10_000
                    while (FileBrowserRepository(File(context.filesDir, "browser.json")).load() != restore && SystemClock.elapsedRealtime() < end) delay(50)
                }
              } catch (cleanup: Throwable) { bodyFailure?.addSuppressed(cleanup) ?: throw cleanup }
              finally {
                  scenario.close()
                  try { await("original media retained owner destroyed") { ended?.cleared != false } }
                  catch (cleanup: Throwable) { bodyFailure?.addSuppressed(cleanup) ?: throw cleanup }
              }
            }
        }
    }

    private suspend fun open(owner: BrowserSessionViewModel, url: String) { main { owner.browser.openUrl(url) }; loaded(owner, "Public playback fixture") }
    private suspend fun returnToOwnedMain(scenario: ActivityScenario<MainActivity>) {
        lateinit var original: MainActivity
        lateinit var entrance: Intent
        scenario.onActivity { activity ->
            original = activity
            // Retain the exact action/data ActivityScenario uses for lifecycle
            // matching. Discard ActivityScenario's initial CLEAR_TASK flag, which
            // would destroy this original task during a return from Home/PiP.
            // A lifecycle move alone cannot bring a task out of Home or OS PiP.
            entrance = Intent(activity.intent).setClass(activity, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        instrumentation.runOnMainSync { context.startActivity(entrance) }
        await("original Main resumed after actual task return") { scenario.state == androidx.lifecycle.Lifecycle.State.RESUMED }
        scenario.onActivity { assertSame(original, it) }
    }
    private fun mediaState(stage: String, owner: BrowserSessionViewModel, tab: String, platform: MediaController) {
        val page = native(owner, tab)
        val file = File(context.getExternalFilesDir(null), "instrumentation/media-fixture").apply { mkdirs() }
        file.resolve("$stage.json").writeText(JSONObject().put("nativePlaying", page?.playing)
            .put("nativeActive", page?.active).put("nativeActions", page?.actions?.joinToString(","))
            .put("systemOwnerMatches", page?.owner == owner.media.state.value?.owner)
            .put("platformActions", platform.playbackState?.actions).put("platformState", platform.playbackState?.state)
            .put("events", mediaEvents).put("nativeAcceptance", false).toString(2))
    }
    private suspend fun loaded(owner: BrowserSessionViewModel, title: String) = await("$title page", 30_000) {
        owner.browser.state.value.page.let { !it.loading && it.title == title }
    }
    private fun native(owner: BrowserSessionViewModel, tab: String) = owner.engine.media.value.firstOrNull { it.owner.tabId == tab }
    private suspend fun advances(owner: BrowserSessionViewModel, tab: String, label: String) {
        val before = native(owner, tab)!!.positionSeconds
        await("$label advances native position", 12_000) { native(owner, tab)?.let { it.playing && it.positionSeconds > before + 1 } == true }
    }
    private fun mediaNotification(): Notification? = notifications.activeNotifications.firstOrNull { it.id == PageMediaService.NOTIFICATION_ID }?.notification
    private suspend fun platformController(): MediaController {
        await("real platform media notification") { mediaNotification() != null }
        val token = requireNotNull(mediaNotification()!!.extras.getParcelable(Notification.EXTRA_MEDIA_SESSION, MediaSession.Token::class.java))
        return MediaController(context, token)
    }
    private suspend fun click(text: String) {
        fun node() = OwnedWebControl.find(text)
        try { await("$text web control") { node() != null } }
        catch (failure: Throwable) { NativeWebControlDiagnostics.capture(text); throw failure }
        var current = node()!!
        repeat(6) {
            if (current.isClickable && current.isEnabled) { assertTrue(current.performAction(AccessibilityNodeInfo.ACTION_CLICK)); return }
            current = current.parent ?: return@repeat
        }
        error("$text is not clickable")
    }
    private suspend fun await(label: String, timeout: Long = 15_000, ready: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + timeout
        while (SystemClock.elapsedRealtime() < end) { if (ready()) return; delay(100) }
        error("Timed out waiting for $label")
    }
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }

    private class MediaFixture(video: File) : Closeable {
        private val mp4 = video.readBytes()
        private val wav = wave()
        private val running = AtomicBoolean(true)
        private val sockets = ConcurrentHashMap.newKeySet<Socket>()
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val listener = Executors.newSingleThreadExecutor()
        private val clients = Executors.newFixedThreadPool(3)
        init { listener.submit { while (running.get()) {
            val client = try { server.accept() } catch (e: IOException) { if (running.get()) throw e else break }
            sockets.add(client)
            clients.submit { client.use { socket -> try {
                socket.soTimeout = 3000
                val input = socket.getInputStream().bufferedReader()
                val request = input.readLine() ?: return@use
                val headers = mutableMapOf<String, String>()
                while (true) { val line = input.readLine(); if (line.isNullOrEmpty()) break; headers[line.substringBefore(':').lowercase()] = line.substringAfter(':').trim() }
                val path = URI(request.split(' ')[1]).path
                val bytes = when (path) { "/fixture.mp4" -> mp4; "/fixture.wav" -> wav; else -> page(path).toByteArray() }
                val mime = when (path) { "/fixture.mp4" -> "video/mp4"; "/fixture.wav" -> "audio/wav"; else -> "text/html; charset=utf-8" }
                val range = headers["range"]?.let { Regex("bytes=([0-9]+)-([0-9]*)").matchEntire(it) }
                val first = range?.groupValues?.get(1)?.toIntOrNull() ?: 0
                val last = range?.groupValues?.get(2)?.toIntOrNull()?.coerceAtMost(bytes.lastIndex) ?: bytes.lastIndex
                if (first !in bytes.indices || last < first) return@use
                val head = "HTTP/1.1 ${if (range != null) "206 Partial Content" else "200 OK"}\r\nContent-Type: $mime\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nContent-Length: ${last - first + 1}\r\n" +
                    (if (range != null) "Content-Range: bytes $first-$last/${bytes.size}\r\n" else "") + "Connection: close\r\n\r\n"
                socket.getOutputStream().use { out -> out.write(head.toByteArray()); if (!request.startsWith("HEAD ")) out.write(bytes, first, last - first + 1) }
            } catch (_: IOException) { /* A cancelled media request owns only this socket. */ }
            finally { sockets.remove(socket) } } }
        } } }
        fun url(path: String) = "http://127.0.0.1:${server.localPort}$path"
        private fun page(path: String): String {
            val privatePage = path.startsWith("/private-")
            val video = path.endsWith("video")
            val title = if (privatePage) "Private playback fixture" else "Public playback fixture"
            val tag = if (video) "video" else "audio"
            return """<!doctype html><html lang='en'><meta name='viewport' content='width=device-width,initial-scale=1'><title>$title</title><main><h1>$title</h1>
                <$tag id='player' controls playsinline ${if (video) "loop style='width:100%;height:240px'" else ""} src='${if (video) "/fixture.mp4" else "/fixture.wav"}'></$tag>
                <button onclick="document.getElementById('player').play()">Play fixture</button><button onclick="document.getElementById('player').requestFullscreen()">Fullscreen fixture</button>
                <script>const p=document.getElementById('player');navigator.mediaSession.metadata=new MediaMetadata({title:'$title',artist:'Fixture artist',album:'Owned device'});
                navigator.mediaSession.setActionHandler('play',()=>p.play());navigator.mediaSession.setActionHandler('pause',()=>p.pause());
                navigator.mediaSession.setActionHandler('seekto',e=>{p.currentTime=e.seekTime});
                p.addEventListener('timeupdate',()=>{if(Number.isFinite(p.duration)&&p.duration>0)navigator.mediaSession.setPositionState({duration:p.duration,position:p.currentTime,playbackRate:p.playbackRate});});</script></main></html>""".trimIndent()
        }
        override fun close() { running.set(false); server.close(); sockets.forEach { runCatching { it.close() } }; listener.shutdownNow(); clients.shutdownNow() }
        private fun wave(): ByteArray {
            val samples = 8000 * 120
            val output = ByteBuffer.allocate(44 + samples * 2).order(ByteOrder.LITTLE_ENDIAN)
            output.put("RIFF".toByteArray()).putInt(36 + samples * 2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
                .putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(samples * 2)
            repeat(samples) { output.putShort((sin(2 * PI * 440 * it / 8000) * 3000).toInt().toShort()) }
            return output.array()
        }
    }
}

package dev.yab.browser

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoSession

/** Real virtual-device capture, native recording events and OS camera/audio ownership. */
@RunWith(AndroidJUnit4::class)
class PrivateCaptureTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun lockingPrivateReleasesActualCameraAndMicrophoneAndRequiresNewSiteConsent(): Unit = runBlocking {
        assumeTrue("Requires the disposable software-camera device", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val newlyGranted = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
            .filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        val camera = context.getSystemService(CameraManager::class.java)
        val audio = context.getSystemService(AudioManager::class.java)
        val cameraAvailability = ConcurrentHashMap<String, Boolean>()
        val availability = object : CameraManager.AvailabilityCallback() {
            override fun onCameraAvailable(cameraId: String) { cameraAvailability[cameraId] = true }
            override fun onCameraUnavailable(cameraId: String) { cameraAvailability[cameraId] = false }
        }
        val recording = ConcurrentHashMap<GeckoSession, Set<Long>>()
        val checkpoint = AtomicReference<String?>()
        val fixture = BrowserInstrumentedTest()
        try {
            // Only this installed debug app in the disposable device receives ordinary Android runtime permissions.
            // Gecko's website Allow/Deny prompt remains active and is clicked below.
            newlyGranted.forEach { instrumentation.uiAutomation.grantRuntimePermission(context.packageName, it) }
            camera.registerAvailabilityCallback(availability, Handler(Looper.getMainLooper()))
            assertTrue("Runner did not expose a software camera", camera.cameraIdList.isNotEmpty())
            await("initial camera availability") { camera.cameraIdList.all { cameraAvailability[it] == true } }
            BrowserInstrumentedTest.FixtureServer().use { server ->
                fixture.withBrowser(configure = { engine ->
                    engine.permissionRequest = { permissions, answer ->
                        answer(permissions.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED })
                    }
                    engine.onSessionCreated = { session ->
                        val shipped = requireNotNull(session.mediaDelegate)
                        session.mediaDelegate = object : GeckoSession.MediaDelegate {
                            override fun onRecordingStatusChanged(s: GeckoSession, devices: Array<out GeckoSession.MediaDelegate.RecordingDevice>) {
                                recording[s] = devices.filter { it.status == GeckoSession.MediaDelegate.RecordingDevice.Status.RECORDING }.map { it.type }.toSet()
                                shipped.onRecordingStatusChanged(s, devices)
                            }
                        }
                    }
                }) { browser, engine ->
                    main { fixture.ownSpace(browser, "Public capture control"); browser.openUrl(server.url("/safe/public-capture")) }
                    await("public control page") { browser.state.value.page.title == "Safe page public-capture" && !browser.state.value.page.loading }
                    val publicTab = browser.state.value.tab!!
                    val publicProfile = browser.state.value.space!!.websiteProfile
                    val publicSession = main { engine.session(publicTab, publicProfile) }
                    main {
                        browser.updateSettings(browser.state.value.settings.copy(lockPrivate = true))
                        browser.openUrl(server.url("/cookie/write?value=private-capture"), privately = true)
                        browser.unlockPrivate(true)
                    }
                    awaitText(browser, engine, "Cookie=private-capture")
                    main { browser.openUrl(server.url("/capture"), newTab = false) }
                    awaitText(browser, engine, "Stream=none")
                    assertTrue("The Private RAM keeper must be ready before this loaded page can capture",
                        main { engine.privateKeeperDiagnostics().getInt("ready") > 0 })
                    assertTrue(browser.state.value.page.canGoBack)
                    val privateTab = browser.state.value.tab!!
                    val profile = browser.state.value.space!!.websiteProfile
                    val original = main { engine.session(privateTab, profile) }
                    main {
                        val shipped = requireNotNull(original.progressDelegate)
                        original.progressDelegate = object : GeckoSession.ProgressDelegate {
                            override fun onPageStart(s: GeckoSession, url: String) { shipped.onPageStart(s, url) }
                            override fun onPageStop(s: GeckoSession, success: Boolean) { shipped.onPageStop(s, success) }
                            override fun onProgressChange(s: GeckoSession, progress: Int) { shipped.onProgressChange(s, progress) }
                            override fun onSecurityChange(s: GeckoSession, securityInfo: GeckoSession.ProgressDelegate.SecurityInformation) {
                                shipped.onSecurityChange(s, securityInfo)
                            }
                            override fun onSessionStateChange(s: GeckoSession, state: GeckoSession.SessionState) {
                                shipped.onSessionStateChange(s, state)
                                checkpoint.set(state.toString())
                            }
                        }
                        original.flushSessionState()
                    }
                    await("real private RAM Back checkpoint") { checkpoint.get()?.contains("/capture") == true }
                    click("Start camera and microphone")
                    await("native site capture consent") { node("Camera and microphone") != null && node("Allow") != null }
                    fixture.shot("private-capture-site-consent.png")
                    click("Allow")
                    awaitText(browser, engine, "Stream=audio:live,video:live")
                    await("actual native camera and microphone recording", 30_000) {
                        recording[original]?.containsAll(setOf(GeckoSession.MediaDelegate.RecordingDevice.Type.CAMERA,
                            GeckoSession.MediaDelegate.RecordingDevice.Type.MICROPHONE)) == true
                    }
                    await("OS camera allocated and audio recording active") {
                        cameraAvailability.values.any { !it } && audio.activeRecordingConfigurations.isNotEmpty()
                    }
                    val recordingSessions = audio.activeRecordingConfigurations.map { it.clientAudioSessionId }.toSet()
                    fixture.shot("private-capture-before-lock.png")
                    main {
                        browser.lockPrivate()
                        assertTrue(browser.state.value.privateContentBlocked)
                        assertFalse("Capturing Private document stayed live", engine.hasLiveSession(privateTab.id))
                        assertFalse("Native capture session remained open", original.isOpen)
                        engine.foreground()
                        assertFalse("Foreground bypassed the Private ownership gate", engine.owns(original))
                    }
                    await("OS capture devices released after Private lock", 30_000) {
                        camera.cameraIdList.all { cameraAvailability[it] == true } &&
                            audio.activeRecordingConfigurations.none { it.clientAudioSessionId in recordingSessions }
                    }
                    fixture.shot("private-capture-locked.png")
                    main {
                        assertSame("Private lock replaced an unrelated public session", publicSession, engine.session(publicTab, publicProfile))
                        browser.unlockPrivate(true)
                    }
                    awaitText(browser, engine, "Stream=none")
                    awaitText(browser, engine, "Cookie=private-capture")
                    val restored = main { engine.session(browser.state.value.tab!!, profile) }
                    assertNotSame("Unlock reused the document which had device access", original, restored)
                    assertTrue("Lock lost the private RAM Back stack", browser.state.value.page.canGoBack)
                    assertTrue(recording[restored].isNullOrEmpty())
                    click("Start camera and microphone")
                    await("fresh site permission after unlock") { node("Camera and microphone") != null && node("Allow") != null }
                    click("Don't allow")
                    awaitText(browser, engine, "Error=NotAllowedError")
                    assertTrue("Denied capture restarted a native recording device", recording[restored].isNullOrEmpty())
                    main { assertTrue(browser.back()) }
                    await("actual private native Back destination") {
                        browser.state.value.page.let { !it.loading && it.url == server.url("/cookie/write?value=private-capture") }
                    }
                    awaitText(browser, engine, "Cookie=private-capture")
                    assertEquals(server.url("/cookie/write?value=private-capture"), browser.state.value.page.url)
                    val stateFile = File(context.filesDir, "navigation/${UUID.nameUUIDFromBytes(privateTab.id.toByteArray())}.json")
                    assertFalse("Private capture checkpoint reached disk", stateFile.exists())
                    assertFalse(browser.publicSnapshot().toString().contains("private-capture"))
                }
            }
        } finally {
            camera.unregisterAvailabilityCallback(availability)
            // Revocation would kill this instrumentation process. The runner destroys its
            // whole owned device, including these per-app grants, after the suite finishes.
        }
    }

    private fun node(text: String): AccessibilityNodeInfo? =
        // AlertDialog exposes these native buttons in uppercase on this API/theme.
        if (text == "Allow" || text == "Don't allow")
            OwnedWebControl.find(text, ignoreCase = true, className = "android.widget.Button")
        else OwnedWebControl.find(text)

    private suspend fun click(text: String) {
        await("$text control") { node(text) != null }
        var current = node(text)!!
        repeat(6) {
            if (current.isEnabled && current.isClickable) {
                assertTrue("Could not click $text", current.performAction(AccessibilityNodeInfo.ACTION_CLICK)); return
            }
            current = current.parent ?: return@repeat
        }
        error("No clickable control for $text")
    }

    private suspend fun awaitText(browser: BrowserController, engine: GeckoEngine, text: String) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        var observed = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            if (!browser.state.value.page.loading) {
                observed = runCatching { main { engine.readText(browser.state.value.tab!!).text } }.getOrDefault("")
                if (observed.contains(text)) return
            }
            delay(100)
        }
        error("Document did not contain $text. Last content: $observed")
    }

    private suspend fun await(label: String, timeout: Long = 15_000, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (SystemClock.elapsedRealtime() < deadline) { if (ready()) return; delay(100) }
        NativeWebControlDiagnostics.capture(label)
        error("Timed out waiting for $label")
    }

    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }
}

package dev.yab.agent

import android.graphics.Bitmap
import android.net.Uri
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.android.YabApplication
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.EnginePageState
import dev.yab.browser.model.WebsiteProfile
import dev.yab.browser.OwnedWebControl
import dev.yab.browser.NativeWebControlDiagnostics
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.WebExtension

/** Normal release Gecko validates the unchanged upstream Mozilla-signed package. */
@RunWith(AndroidJUnit4::class)
class SignedExtensionTest {
    private var currentManager: GeckoSignedExtensionManager? = null
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val id = "{3d31c3e3-273e-4099-88d5-a135b62be61e}"
    private val digest = "99e19528b08319803ec19679673c8ae8f19646535254133c3826a3556ba2e6df"
    // Public BODY observed 2026-10-22; provenance is in parity/signed-xpi-fixture-notes.md.
    private val expectedBody = "This domain is for use in documentation examples without needing permission."

    @Test(timeout = 300_000)
    fun signedXpiNeedsConsentRunsRealContentScriptStaysOutOfPrivateAndUninstalls(): Unit = runBlocking {
        val required = InstrumentationRegistry.getArguments().getString("requireSignedExtension") == "true"
        val owned = InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true"
        if (required) assertTrue("Signed extension proof requires the disposable owned device", owned)
        else assumeTrue("Signed extension proof runs only on the disposable runner device", owned)
        val file = File(context.filesDir, "extension-tests/borderify.xpi")
        if (required) assertTrue("Runner did not preload the immutable signed fixture", file.isFile)
        else assumeTrue("No signed fixture preloaded", file.isFile)
        assertEquals(9221L, file.length())
        assertEquals(digest, MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it.toInt() and 255) })

        val scenario = ActivityScenario.launch(EngineTestActivity::class.java)
        val pages = ConcurrentHashMap<String, EnginePageState>()
        val starts = ConcurrentHashMap<String, AtomicInteger>()
        val installed = ConcurrentHashMap<String, WebExtension>()
        val view = AtomicReference<GeckoView>()
        val publicTab = BrowserTab(UUID.randomUUID().toString(), "https://example.com/", createdAt = System.currentTimeMillis())
        val privateTab = publicTab.copy(id = UUID.randomUUID().toString(), isPrivate = true)
        val publicProfile = WebsiteProfile("signed-test-${UUID.randomUUID()}")
        val privateProfile = WebsiteProfile("signed-private-${UUID.randomUUID()}", true)
        val selected = mutableStateOf(publicTab)
        val showExtensions = mutableStateOf(false)
        lateinit var engine: GeckoEngine
        lateinit var manager: GeckoSignedExtensionManager
        var initialized = false
        try {
            scenario.onActivity { activity ->
                val runtime = (activity.application as YabApplication).runtime
                engine = GeckoEngine(activity, runtime)
                engine.onState = { tab, page ->
                    val previous = pages.put(tab, page)
                    if (page.loading && previous?.loading != true) starts.computeIfAbsent(tab) { AtomicInteger() }.incrementAndGet()
                }
                manager = GeckoSignedExtensionManager(runtime, activity, { selected.value.isPrivate }, { installed[it.id] = it })
                currentManager = manager
                initialized = true
                activity.setContent {
                    MaterialTheme {
                        if (showExtensions.value) ExtensionScreen(manager, {}, { showExtensions.value = false })
                        else {
                            val tab = selected.value
                            val profile = if (tab.isPrivate) privateProfile else publicProfile
                            AndroidView(modifier = Modifier.fillMaxSize(), factory = { parent ->
                                GeckoView(parent).apply { setSession(engine.session(tab, profile)); tag = tab.id; engine.bindView(tab.id, this); view.set(this) }
                            }, update = { current ->
                                val session = engine.session(tab, profile)
                                if (current.session !== session) {
                                    (current.tag as? String)?.let { engine.unbindView(it, current) }
                                    current.releaseSession(); current.setSession(session); current.tag = tab.id
                                }
                                engine.bindView(tab.id, current); view.set(current)
                            }, onReset = null, onRelease = { current ->
                                (current.tag as? String)?.let { engine.unbindView(it, current) }
                                current.releaseSession(); view.compareAndSet(current, null)
                            })
                        }
                    }
                }
                engine.activate(publicTab, publicProfile)
            }
            loaded(publicTab, pages, engine)
            await("initial extension inventory") { !manager.state.value.busy && manager.state.value.error == null }
            assertTrue("Disposable profile unexpectedly has external extensions", manager.state.value.installed.isEmpty())
            val before = capture(view)
            val redBefore = redPixels(before)
            save(before, "signed-xpi-before.png")
            before.recycle()

            main { showExtensions.value = true; engine.setVisibleTabs(emptySet()) }
            mainSuspend { manager.install(Uri.fromFile(file)) }
            await("real install consent") { manager.state.value.consent != null }
            assertEquals("Borderify", manager.state.value.consent!!.name)
            assertTrue(manager.state.value.consent!!.origins.any { it.contains("example.com") })
            shot("signed-xpi-consent.png")
            val firstDialogWindow = click("Cancel")
            await("cancelled native install") { !manager.state.value.busy && manager.state.value.consent == null }
            assertTrue(manager.state.value.installed.none { it.id == id })
            main { manager.clearError() }
            // Let the original dialog actually leave the native window tree.
            // StateFlow's null -> new consent can otherwise be conflated before
            // Compose observes dismissal, leaving an old native Add callback.
            await("first consent native window dismissed") {
                val root = instrumentation.uiAutomation.rootInActiveWindow
                root?.packageName?.toString() == context.packageName && root.windowId != firstDialogWindow &&
                    OwnedWebControl.find("Extensions") != null && manager.state.value.consent == null &&
                    manager.state.value.error == null && !manager.state.value.busy
            }

            mainSuspend { manager.install(Uri.fromFile(file)) }
            await("second genuine install consent") { manager.state.value.consent != null }
            val secondDialogWindow = click("Add")
            assertNotEquals("Second install must use its fresh native consent window", firstDialogWindow, secondDialogWindow)
            await("signed native install", 40_000) { manager.state.value.installed.any { it.id == id && it.enabled && it.version == "1.0" } }
            val actual = installed[id] ?: error("Native manager did not deliver the installed extension")
            assertFalse(actual.isBuiltIn)
            assertFalse(actual.metaData!!.temporary)
            assertTrue(actual.metaData!!.signedState >= WebExtension.SignedStateFlags.SIGNED)
            assertFalse(actual.metaData!!.allowedInPrivateBrowsing)

            val firstReload = starts[publicTab.id]?.get() ?: 0
            main { showExtensions.value = false; engine.setVisibleTabs(setOf(publicTab.id)); engine.reload(publicTab.id) }
            await("native reload began") { (starts[publicTab.id]?.get() ?: 0) > firstReload }
            loaded(publicTab, pages, engine)
            awaitRed(view, redBefore, true, "signed-xpi-real-content-script.png")

            main { selected.value = privateTab; engine.setVisibleTabs(setOf(privateTab.id)); engine.activate(privateTab, privateProfile) }
            loaded(privateTab, pages, engine)
            awaitRed(view, redBefore, false, null)

            // Recreate an actual public GeckoSession; the installed addon must start in it too.
            val recreated = starts[publicTab.id]?.get() ?: 0
            main { engine.close(publicTab.id); selected.value = publicTab; engine.setVisibleTabs(setOf(publicTab.id)); engine.activate(publicTab, publicProfile) }
            await("new native session began loading") { (starts[publicTab.id]?.get() ?: 0) > recreated }
            loaded(publicTab, pages, engine)
            awaitRed(view, redBefore, true, "signed-xpi-new-native-session.png")

            main { showExtensions.value = true; engine.setVisibleTabs(emptySet()) }
            click("Remove")
            await("native uninstall") { manager.state.value.installed.none { it.id == id } }
            val uninstallReload = starts[publicTab.id]?.get() ?: 0
            main { showExtensions.value = false; engine.setVisibleTabs(setOf(publicTab.id)); engine.reload(publicTab.id) }
            await("uninstall reload began") { (starts[publicTab.id]?.get() ?: 0) > uninstallReload }
            loaded(publicTab, pages, engine)
            awaitRed(view, redBefore, false, "signed-xpi-uninstalled.png")
        } finally {
            withContext(NonCancellable) {
                if (initialized) {
                    main { manager.state.value.consent?.let { manager.resolveConsent(it.token, false) }; manager.remove(id) }
                    runCatching { await("fixture uninstall cleanup", 10_000) { manager.state.value.installed.none { it.id == id } } }
                    main { engine.close(publicTab.id); engine.close(privateTab.id); engine.dispose() }
                }
                scenario.close()
            }
        }
    }

    private suspend fun loaded(tab: BrowserTab, pages: Map<String, EnginePageState>, engine: GeckoEngine) {
        await("real example.com document", 45_000) { pages[tab.id]?.let { !it.loading && it.progress >= 1f && it.title?.contains("Example Domain") == true } == true }
        val deadline = android.os.SystemClock.elapsedRealtime() + 15_000
        var lastError: Exception? = null
        var received = false
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            try {
                if (mainSuspend { engine.readText(tab, diagnostics = true).text }.contains(expectedBody)) { received = true; break }
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (error: Exception) { lastError = error }
            delay(200)
        }
        assertTrue("${if (tab.isPrivate) "Private" else "Public"} content channel didn't return the expected BODY: ${main { engine.bridgeStatus(tab.id) }}; last=${lastError?.message}", received)
        delay(400)
    }
    private suspend fun capture(view: AtomicReference<GeckoView>): Bitmap {
        val answer = CompletableDeferred<Bitmap>()
        main { (view.get() ?: error("No real GeckoView")).capturePixels().accept({ bitmap ->
            if (bitmap != null) answer.complete(bitmap) else answer.completeExceptionally(IllegalStateException("No compositor pixels"))
        }, { error -> answer.completeExceptionally(error ?: IllegalStateException("Compositor capture failed")) }) }
        return withTimeout(10_000) { answer.await() }
    }
    private fun redPixels(bitmap: Bitmap): Int {
        assertTrue(bitmap.width > 10 && bitmap.height > 10)
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return pixels.count { (it ushr 24 and 255) > 200 && (it ushr 16 and 255) > 220 && (it ushr 8 and 255) < 45 && (it and 255) < 45 }
    }
    private suspend fun awaitRed(view: AtomicReference<GeckoView>, baseline: Int, expected: Boolean, name: String?) {
        withTimeout(15_000) {
            while (true) {
                val bitmap = capture(view)
                val count = redPixels(bitmap)
                val matches = if (expected) count > baseline + 300 else count <= baseline + 100
                if (matches) { if (name != null) save(bitmap, name); bitmap.recycle(); return@withTimeout }
                bitmap.recycle(); delay(250)
            }
        }
    }
    private fun save(bitmap: Bitmap, name: String) {
        val folder = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        File(folder, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
    private fun shot(name: String) { instrumentation.uiAutomation.takeScreenshot()?.let { save(it, name); it.recycle() } }
    private suspend fun click(text: String): Int {
        fun target(): AccessibilityNodeInfo? {
            var current = OwnedWebControl.find(text) ?: return null
            val window = current.windowId
            repeat(6) {
                if (current.packageName?.toString() != context.packageName || current.windowId != window ||
                    !current.isVisibleToUser || !current.isEnabled) return null
                if (current.isClickable && current.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }) return current
                current = current.parent ?: return null
            }
            return null
        }
        var original: AccessibilityNodeInfo? = null
        await("visible $text control", 10_000) {
            original = target()
            original != null
        }
        shot("signed-xpi-${text.lowercase()}-ready.png")
        assertTrue("Original native $text button rejected its single click",
            requireNotNull(original).performAction(AccessibilityNodeInfo.ACTION_CLICK))
        return requireNotNull(original).windowId
    }
    private suspend fun await(name: String, timeout: Long = 20_000, condition: () -> Boolean) {
        try { withTimeout(timeout) { while (!condition()) delay(100) } }
        catch (error: kotlinx.coroutines.TimeoutCancellationException) {
            NativeWebControlDiagnostics.capture("signed extension: $name")
            val state = currentManager?.state?.value
            val value = org.json.JSONObject().put("phase", name).put("busy", state?.busy)
                .put("error", state?.error ?: org.json.JSONObject.NULL)
                .put("consentPresent", state?.consent != null)
                .put("installed", org.json.JSONArray().apply {
                    state?.installed?.forEach { item -> put(org.json.JSONObject().put("id", item.id)
                        .put("version", item.version).put("enabled", item.enabled)) }
                })
            File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
                .resolve("signed-xpi-failure-state.json").writeText(value.toString())
            throw AssertionError("Timed out waiting for $name after ${timeout}ms", error)
        }
    }
    private suspend fun <T> main(action: () -> T): T = withContext(Dispatchers.Main) { action() }
    private suspend fun <T> mainSuspend(action: suspend () -> T): T = withContext(Dispatchers.Main) { action() }
}

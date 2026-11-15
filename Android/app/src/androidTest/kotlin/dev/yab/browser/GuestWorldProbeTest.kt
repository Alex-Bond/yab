package dev.yab.browser

import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.android.YabApplication
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.WebExtension

/** Only tests the pinned engine's sandbox primitives, not CRX or extension compatibility. */
@RunWith(AndroidJUnit4::class)
class GuestWorldProbeTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 120_000)
    fun userScriptWorldsHaveNativeIdentityWithoutHostPrivilegesAndRejectSpoofedOwners(): Unit = runBlocking {
        assumeTrue("Requires the runner's disposable owned emulator", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val events = CopyOnWriteArrayList<JSONObject>()
        val scenario = ActivityScenario.launch(EngineTestActivity::class.java)
        lateinit var runtime: GeckoRuntime
        var extension: WebExtension? = null
        var port: WebExtension.Port? = null
        var session: GeckoSession? = null
        var view: GeckoView? = null
        var passed = false
        var failure: String? = null
        try {
            scenario.onActivity { runtime = (it.application as YabApplication).runtime }
            val installed = checkNotNull(main { runtime.webExtensionController.installBuiltIn("resource://android/assets/guest-world-probe/").await() })
            extension = installed
            assertEquals(ID, installed.id)
            assertTrue("This probe must use only its own APK code", installed.isBuiltIn)
            main {
                runtime.webExtensionController.setAllowedInPrivateBrowsing(installed, false).await()
                installed.setMessageDelegate(object : WebExtension.MessageDelegate {
                    override fun onConnect(source: WebExtension.Port) {
                        val sender = source.sender
                        if (sender.webExtension.id != ID || !sender.webExtension.isBuiltIn || sender.session != null ||
                            sender.environmentType != WebExtension.MessageSender.ENV_TYPE_EXTENSION) {
                            source.disconnect(); return
                        }
                        port = source
                        source.setDelegate(object : WebExtension.PortDelegate {
                            override fun onPortMessage(message: Any, source: WebExtension.Port) {
                                if (port === source && message is JSONObject) events.add(message)
                            }
                        })
                    }
                }, NATIVE)
            }
            awaitEvent(events, "hello")
            // This grants only our debug host's declared optional API through the normal SDK.
            main { runtime.webExtensionController.addOptionalPermissions(ID, arrayOf("userScripts"), emptyArray(), emptyArray()).await() }
            BrowserInstrumentedTest.FixtureServer().use { server ->
                val url = server.url("/article")
                main { checkNotNull(port).postMessage(JSONObject().put("command", "configure").put("url", url)) }
                assertTrue(awaitEvent(events, "configured").getBoolean("available"))
                scenario.onActivity { activity ->
                    val page = GeckoSession()
                    session = page
                    page.open(runtime)
                    val nativeView = GeckoView(activity)
                    view = nativeView
                    nativeView.setSession(page)
                    activity.setContentView(nativeView)
                    page.setActive(true)
                    page.loadUri(url)
                }
                awaitEvent(events, "host-canary")
                withTimeout(20_000) {
                    while (events.count { it.optString("kind") == "finished" } < 2) {
                        failOnEngineError(events)
                        delay(25)
                    }
                }
                val completed = events.filter { it.optString("kind") == "finished" }
                assertEquals(setOf(A, B), completed.map { it.getString("actual") }.toSet())
                val expectedRecords = mapOf(A to "record-a", B to "record-b")
                for (event in completed) {
                    val actual = event.getString("actual")
                    val inspected = event.getJSONObject("inspection")
                    assertEquals("A guest inherited another world's global", "undefined", inspected.getString("before"))
                    for (api in listOf("hostCanary", "native", "nativePort", "storage", "tabs", "scripting", "componentClasses", "componentImport", "services", "chromeUtils")) {
                        assertEquals("Guest $actual received $api", "undefined", inspected.getString(api))
                    }
                    val own = event.getJSONObject("own")
                    assertEquals(actual, own.getString("actual")); assertFalse(own.getBoolean("denied"))
                    assertEquals(expectedRecords[actual], own.getString("value"))
                    val spoof = event.getJSONObject("spoof")
                    assertEquals(actual, spoof.getString("actual")); assertTrue(spoof.getBoolean("denied"))
                    assertFalse("Spoof leaked another guest's record", spoof.has("value"))
                }
                val decisions = events.filter { it.optString("kind") == "decision" }
                val spoofed = decisions.filter { it.optString("requested") != it.optString("actual") }
                assertEquals(2, spoofed.size)
                // Native JSON serialization may represent an absent JS value as null.
                assertTrue(spoofed.all { it.getBoolean("denied") && it.isNull("value") })
                assertTrue(decisions.all { it.getString("url") == url && it.getInt("frameId") == 0 && it.getString("documentId").isNotBlank() })
                assertEquals("The native sandbox reports must belong to the same actual document", 1, decisions.map { it.getString("documentId") }.toSet().size)
                assertEquals("object", events.first { it.optString("kind") == "host-canary" }.getString("storage"))
                passed = true
            }
        } catch (error: Throwable) {
            failure = error.javaClass.simpleName + ": " + error.message
            throw error
        } finally {
            val report = JSONObject().put("scope", "debug-owned-userScripts-primitives-only")
                .put("gecko", "158.0.20261021001945").put("passed", passed)
                .put("failure", failure ?: JSONObject.NULL).put("events", JSONArray(events))
            File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
                .resolve("guest-world-probe.json").writeText(report.toString(2))
            withContext(NonCancellable + Dispatchers.Main.immediate) {
                view?.releaseSession(); session?.close()
                port?.disconnect(); extension?.setMessageDelegate(null, NATIVE)
                extension?.let { owned -> runCatching { withTimeout(10_000) { runtime.webExtensionController.uninstall(owned).await() } } }
            }
            scenario.close()
        }
    }

    private suspend fun awaitEvent(events: List<JSONObject>, kind: String): JSONObject = withTimeout(20_000) {
        while (true) {
            failOnEngineError(events)
            events.firstOrNull { it.optString("kind") == kind }?.let { return@withTimeout it }
            delay(25)
        }
        @Suppress("UNREACHABLE_CODE") error("No $kind event")
    }
    private fun failOnEngineError(events: List<JSONObject>) {
        events.firstOrNull { it.optString("kind") in setOf("error", "guest-error", "unavailable") }?.let {
            error("Native guest probe failed: $it")
        }
    }
    private suspend fun <T> GeckoResult<T>.await(): T? {
        val result = CompletableDeferred<T?>()
        accept({ value -> result.complete(value) },
            { error -> result.completeExceptionally(error ?: IllegalStateException("Gecko request failed")) })
        return withTimeout(20_000) { result.await() }
    }
    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    private companion object {
        const val ID = "guest-world-probe@browser.local"
        const val NATIVE = "guest_probe"
        const val A = "probe-guest-a"
        const val B = "probe-guest-b"
    }
}

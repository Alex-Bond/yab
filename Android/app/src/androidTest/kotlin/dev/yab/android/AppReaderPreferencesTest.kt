package dev.yab.android

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.engine.ReaderPreferencesStore
import dev.yab.browser.model.*
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicBoolean
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
import org.junit.Rule
import org.junit.Test
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView

/** Genuine shipped Reader port and current compact Main controls. No content-script stub. */
class AppReaderPreferencesTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun actualCompactReaderPreferencesRestyleBothLiveDocumentsAndRollbackOriginalCustomize(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT in 36..37 && shell("getprop ro.kernel.qemu").trim() == "1")
        val size = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}"))
        val density = overrideValue(shell("wm density"), Regex("[0-9]{2,4}"))
        val app = context.applicationContext as YabApplication
        val before = app.readerPreferences.snapshot()
        val phases = JSONArray()
        var stage = "SETUP"
        var completed = false
        var restored = false
        var sameOriginal = false
        var bothStyled = false
        var secondOriginalReturned = false
        var readerPixels = false
        var primary: Throwable? = null
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        try {
            ui.run {
                val ownOutput = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation/reader-preferences").apply { check(isDirectory || mkdirs()) }
                listOf("01-paper-card-ui.png", "02-customized-card-ui.png", "03-reader-ui.png", "03-reader-native.png").forEach { name ->
                    File(ownOutput, name).let { check(!it.exists() || it.delete()) }
                }
                shell("wm density 480"); shell("wm size 1206x2622")
                Pages().use { pages ->
                    val fixture = NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                        NativeMainActivityFixture.Kind.APP_WORKSPACE)
                    fixture.use {
                        lateinit var model: BrowserSessionViewModel
                        fixture.onActivity { host ->
                            model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                            ui.bind(model.browser, model.engine) { model.browser.workspaceWindow.value.generation }
                            assertSame(app.readerPreferences, model.readerPreferences)
                            check(model.readerPreferences.set(ReaderPreferences()))
                        }
                        val browser = model.browser
                        val first = BrowserTab("reader-prefs-a", pages.a, "Reader fixture A", TabPlace.KEPT, createdAt = 1)
                        val second = BrowserTab("reader-prefs-b", pages.b, "Reader fixture B", TabPlace.KEPT, createdAt = 2)
                        await("the actual original Main is loaded and compact") {
                            !browser.state.value.loading && browser.workspaceWindow.value.let {
                                it.registered && it.geometry == BrowserWorkspaceWindow(402.0, 874.0)
                            }
                        }
                        lateinit var profile: WebsiteProfile
                        fixture.onActivity {
                            val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Reader fixture", tabs = listOf(first, second), currentTabId = first.id)
                            browser.applySyncedSnapshot(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                                settings = BrowserSettings(welcomed = true)))
                            browser.selectTab(first.id); profile = checkNotNull(browser.state.value.space).websiteProfile
                            model.engine.navigate(first, pages.a, profile)
                        }
                        suspend fun click(label: String) { compose.waitForIdle(); ui.click(label); compose.waitForIdle() }
                        fun shown(tag: String) = compose.onAllNodesWithTag(tag).fetchSemanticsNodes().size == 1
                        fun observation(id: String): JSONObject? = runCatching {
                            JSONObject(browser.state.value.pageStates[id]?.title.orEmpty()).takeIf { it.optBoolean("fixture") }
                        }.getOrNull()
                        suspend fun enter(id: String, url: String) {
                            await("original fixture article is readable under current Main") {
                                browser.state.value.let { it.tab?.id == id && it.tab?.url == url && !it.page.loading && it.page.readerAvailable }
                            }
                            click("Page menu"); click("Reader")
                            await("genuine production Reader command enabled this original document") {
                                browser.state.value.tab?.id == id && browser.state.value.page.readerEnabled && observation(id)?.optBoolean("reader") == true
                            }
                        }
                        stage = "FIRST_READER"; enter(first.id, first.url)
                        lateinit var firstSession: GeckoSession
                        fixture.onActivity {
                            firstSession = model.engine.session(first, profile)
                            // Arrange the second real document before the tested global prefs actions.
                            browser.selectTab(second.id); model.engine.navigate(second, second.url, profile)
                        }
                        stage = "SECOND_READER"; enter(second.id, second.url)
                        lateinit var secondSession: GeckoSession
                        lateinit var secondNative: GeckoEngine.ExternalActivityOwner
                        fixture.onActivity {
                            secondSession = model.engine.session(second, profile)
                            secondNative = checkNotNull(model.engine.captureExternalActivityOwner())
                            browser.selectTab(first.id)
                        }
                        await("both genuine original Readers stay live after returning to the first") {
                            browser.state.value.tab?.id == first.id && browser.state.value.page.readerEnabled &&
                                observation(first.id)?.optBoolean("reader") == true && observation(second.id)?.optBoolean("reader") == true
                        }
                        lateinit var host: MainActivity
                        lateinit var originalIntent: Intent
                        lateinit var originalConfig: Configuration
                        lateinit var originalBounds: Rect
                        lateinit var originalNative: GeckoEngine.ExternalActivityOwner
                        lateinit var view: GeckoView
                        val identity = app.sync.accountRecords.value
                        val lifetime = browser.settingsPresentationLifetime.value
                        fixture.onActivity { activity ->
                            host = activity; originalIntent = activity.intent; originalConfig = Configuration(activity.resources.configuration)
                            originalBounds = Rect(activity.windowManager.currentWindowMetrics.bounds)
                            originalNative = checkNotNull(model.engine.captureExternalActivityOwner())
                            val found = mutableListOf<GeckoView>(); var visited = 0
                            fun visit(node: View) {
                                check(++visited <= 256)
                                if (node is GeckoView && node.session === firstSession && node.tag == first.id) found.add(node)
                                if (node is ViewGroup) { val count = node.childCount; check(count <= 128); repeat(count) { visit(node.getChildAt(it)) } }
                            }
                            visit(activity.window.decorView); view = found.single()
                        }
                        fun original(): Boolean {
                            val state = browser.state.value
                            return host.intent === originalIntent && host.resources.configuration == originalConfig &&
                                host.windowManager.currentWindowMetrics.bounds == originalBounds && host.hasWindowFocus() &&
                                state.surface == BrowserSurface.PAGE && state.tab?.id == first.id && state.tab?.url == first.url &&
                                state.space?.websiteProfile == profile && !state.privateContentBlocked && state.page.readerEnabled &&
                                browser.settingsPresentationLifetime.value == lifetime && app.sync.nativeOwnerCurrent(identity) &&
                                model.engine.ownsExternalActivity(originalNative) && originalNative.session === firstSession &&
                                view.session === firstSession && view.isAttachedToWindow && view.isShown &&
                                firstSession.isOpen && secondSession.isOpen && model.engine.hasLiveSession(first.id) && model.engine.hasLiveSession(second.id)
                        }
                        suspend fun both(size: Int, font: String) {
                            await("both original live documents receive typed presentation only") {
                                listOf(first.id, second.id).all { id -> observation(id)?.let {
                                    it.optBoolean("reader") && it.optInt("size") == size && it.optString("bg") == "#f7f3ea" && it.optString("font") == font
                                } == true }
                            }
                            fixture.onActivity { check(original()); sameOriginal = true }
                            bothStyled = true
                        }
                        suspend fun capture(name: String, native: Boolean = false) {
                            compose.waitForIdle(); ui.requireOwnCurrent()
                            await("explicit original fixture DOM geometry and two-frame readiness before app-owned capture") {
                                observation(first.id)?.optBoolean("paintReady") == true
                            }
                            fixture.onActivity { check(original()); check(view.width > 0 && view.height > 0) }
                            val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation/reader-preferences").apply { check(isDirectory || mkdirs()) }
                            File(folder, "$name-ui.png").outputStream().use {
                                check(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it))
                            }
                            val screen = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
                            try { File(folder, "$name-screen.png").outputStream().use {
                                check(screen.compress(Bitmap.CompressFormat.PNG, 100, it))
                            } } finally { screen.recycle() }
                            if (native) {
                                val bitmap = withContext(Dispatchers.Main) {
                                    val answer = CompletableDeferred<Bitmap>()
                                    view.capturePixels().accept({ value ->
                                        if (value == null) answer.completeExceptionally(IllegalStateException("Original native Reader capture absent"))
                                        else if (!answer.complete(value)) value.recycle()
                                    }, { answer.completeExceptionally(IllegalStateException("Original native Reader capture failed")) })
                                    try { withTimeout(5_000) { answer.await() } } finally { if (!answer.isCompleted) answer.cancel() }
                                }
                                try {
                                    fixture.onActivity { check(original()) }
                                    check(bitmap.width > 8 && bitmap.height > 8)
                                    val pixel = bitmap.getPixel(4.coerceAtMost(bitmap.width - 1), 4.coerceAtMost(bitmap.height - 1))
                                    assertTrue(android.graphics.Color.alpha(pixel) > 240)
                                    assertTrue(kotlin.math.abs(android.graphics.Color.red(pixel) - 247) <= 4)
                                    assertTrue(kotlin.math.abs(android.graphics.Color.green(pixel) - 243) <= 4)
                                    assertTrue(kotlin.math.abs(android.graphics.Color.blue(pixel) - 234) <= 4)
                                    File(folder, "$name-native.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                                    readerPixels = true
                                } finally { bitmap.recycle() }
                            }
                        }
                        stage = "CARD"; click("Page menu")
                        compose.onNodeWithText("Original", substring = false).assertExists()
                        click("Themes & Settings")
                        await("actual compact Reader card mounted") { shown("reader.card") }
                        click("Appearance"); click("Light"); click("Paper"); click("Larger Text")
                        both(20, "charter"); capture("01-paper-card")
                        stage = "CANCEL"; click("Customize"); click("Font · Charter"); click("Georgia")
                        await("actual font control updates both documents") { observation(second.id)?.optString("font") == "georgia" }
                        val oldFont = dev.yab.browser.originalRenderedClick(compose.onNodeWithTag("reader.fonts.georgia").fetchSemanticsNode())
                        click("Back"); click("Cancel"); both(20, "charter")
                        fixture.onActivity { oldFont() }; compose.waitForIdle(); both(20, "charter")
                        stage = "DONE"; click("Customize"); click("Font · Charter"); click("Georgia"); click("Done")
                        both(20, "georgia"); capture("02-customized-card")
                        click("Close"); await("Reader card completes its own exit") { !shown("reader.card") && !shown("reader.layer") }
                        both(20, "georgia"); capture("03-reader", native = true)
                        fixture.onActivity {
                            assertEquals(model.readerPreferences.snapshot(), ReaderPreferencesStore(File(context.filesDir, "reader-preferences.json")).snapshot())
                            check(original()); assertEquals(2, browser.state.value.space!!.tabs.size)
                        }
                        // Explicit final observation stimulus, never a replacement owner for an old action.
                        stage = "SECOND_ORIGINAL_RETURN"
                        fixture.onActivity { browser.selectTab(second.id) }
                        await("the second current Reader retains its own original live document") {
                            browser.state.value.tab?.id == second.id && browser.state.value.page.readerEnabled &&
                                observation(second.id)?.let { it.optInt("size") == 20 && it.optString("font") == "georgia" } == true
                        }
                        fixture.onActivity {
                            val returned = checkNotNull(model.engine.captureExternalActivityOwner())
                            assertSame(secondSession, returned.session); assertSame(secondNative.session, returned.session)
                            assertEquals(secondNative.document, returned.document)
                            assertTrue(model.engine.ownsExternalActivity(secondNative))
                            assertEquals(second.url, browser.state.value.tab!!.url); assertEquals(profile, browser.state.value.space!!.websiteProfile)
                            secondOriginalReturned = true
                        }
                        phases.put("REAL_UI_TWO_LIVE_READERS").put("CANCEL_ROLLBACK").put("DONE_PERSISTED").put("ORIGINAL_NATIVE_PIXELS")
                        stage = "COMPLETE"
                    }
                }
            }
            completed = true
        } catch (error: Throwable) { primary = error; throw error }
        finally { withContext(NonCancellable) {
            var cleanup: Throwable? = null
            fun attempt(action: () -> Unit) { try { action() } catch (error: Throwable) { if (cleanup == null) cleanup = error else cleanup!!.addSuppressed(error) } }
            attempt { instrumentation.runOnMainSync { check(app.readerPreferences.set(before)) } }
            attempt { shell("wm size ${size ?: "reset"}") }; attempt { shell("wm density ${density ?: "reset"}") }
            attempt { restored = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}")) == size &&
                overrideValue(shell("wm density"), Regex("[0-9]{2,4}")) == density; check(restored) }
            attempt {
                val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation").apply { check(isDirectory || mkdirs()) }
                File(folder, "reader-preferences.json").writeText(JSONObject().put("schema", 1).put("stage", stage).put("completed", completed)
                    .put("sameOriginalSource", sameOriginal).put("bothLiveStyled", bothStyled).put("secondOriginalDocumentReturned", secondOriginalReturned)
                    .put("nativeReaderBackgroundSamplePassed", readerPixels)
                    .put("windowRestored", restored).put("phases", phases).put("productionPort", true)
                    .put("uiCaptureIncludesNativePagePixels", false).put("nativeScreenCaptureRequested", true)
                    .put("physicalDeviceAccepted", false).toString(2))
                val catalog = File(folder, "catalog-fixtures/reader-preferences").apply { check(isDirectory || mkdirs()) }
                for (name in listOf("01-paper-card-ui.png", "02-customized-card-ui.png", "03-reader-ui.png", "03-reader-native.png",
                    "01-paper-card-screen.png", "02-customized-card-screen.png", "03-reader-screen.png")) {
                    File(folder, "reader-preferences/$name").takeIf { it.isFile }?.copyTo(File(catalog, name), overwrite = true)
                }
                File(folder, "reader-preferences.json").copyTo(File(catalog, "receipt.json"), overwrite = true)
            }
            cleanup?.let { if (primary != null) primary!!.addSuppressed(it) else throw it }
        } }
    }

    private suspend fun await(message: String, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (true) { compose.waitForIdle(); if (ready()) return; check(SystemClock.elapsedRealtime() < deadline) { message }; delay(40) }
    }
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun overrideValue(text: String, pattern: Regex) = text.lineSequence().firstOrNull { it.startsWith("Override") }?.substringAfter(":")?.trim()?.takeIf(pattern::matches)
    /** Own original HTTP documents report only known Reader style/geometry, through normal title state. */
    private class Pages : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val stopped = AtomicBoolean(false)
        val a = "http://127.0.0.1:${server.localPort}/a"
        val b = "http://127.0.0.1:${server.localPort}/b"
        private val worker = Thread({
            while (!stopped.get()) try { server.accept().use { client ->
                client.soTimeout = 5000; val input = client.getInputStream().bufferedReader(); input.readLine() ?: return@use
                while (!input.readLine().isNullOrEmpty()) { }
                val prose = "This original local article describes the patient tide, a quiet town and its readers. ".repeat(9)
                val html = """<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:18px Arial,sans-serif;background:white;color:black}</style><title>Reader preferences fixture</title><article><h1>Reader preferences original article</h1><p>$prose</p><p>$prose</p><p>$prose</p></article><script>
                  let last='',ready='',waiting='';
                  const host=()=>[...document.documentElement.children].find(e=>e.style&&e.style.getPropertyValue('--s'));
                  function report(){const h=host(),stamp=h?[h.style.getPropertyValue('--s'),h.style.getPropertyValue('--bg'),h.style.getPropertyValue('--f')].join('|'):'';
                    if(h&&waiting!==stamp){waiting=stamp;ready='';requestAnimationFrame(()=>requestAnimationFrame(()=>{if(host()===h){ready=stamp;report();}}));}
                    const f=h?h.style.getPropertyValue('--f'):'',r=h&&h.getBoundingClientRect();
                    const value=JSON.stringify({fixture:true,reader:!!h,size:h?parseInt(h.style.getPropertyValue('--s')):0,bg:h?h.style.getPropertyValue('--bg'):'',font:f.includes('Georgia, serif')&&!f.includes('Charter')?'georgia':f.includes('Charter')?'charter':'site',paintReady:!!h&&ready===stamp&&r.width>0&&r.height>0});
                    if(value!==last){last=value;document.title=value;}}
                  new MutationObserver(report).observe(document.documentElement,{childList:true,subtree:true,attributes:true});report();
                </script>""".trimIndent().toByteArray()
                client.getOutputStream().apply { write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${html.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray()); write(html); flush() }
            } } catch (_: IOException) { if (stopped.get()) break }
        }, "reader-prefs-fixture").apply { isDaemon = true; start() }
        override fun close() { stopped.set(true); server.close(); worker.join(1000) }
    }
}

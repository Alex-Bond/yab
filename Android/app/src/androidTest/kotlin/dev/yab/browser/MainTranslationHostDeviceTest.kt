package dev.yab.browser

import android.content.Intent
import android.net.Uri
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.MainActivity
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import dev.yab.nativefeatures.PageTranslationController
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

/** Real MainActivity host wiring, with only finite read-only diagnostics.
 * No controller mutation, replacement UI, translator fixture or model response.
 */
class MainTranslationHostDeviceTest {
    @Test(timeout = 180_000)
    fun realMainActivityMenuOpensDownloadConsent(): Unit = runBlocking {
        val registry = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val folder = File(registry.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        fun labels(node: AccessibilityNodeInfo?): List<Pair<String, Rect>> {
            if (node == null) return emptyList()
            val box = Rect().also(node::getBoundsInScreen)
            val own = listOfNotNull(node.text?.toString(), node.contentDescription?.toString()).map { it to box }
            return own + (0 until node.childCount).flatMap { labels(node.getChild(it)) }
        }
        suspend fun waitLabel(label: String): Rect {
            repeat(120) {
                val found = labels(registry.uiAutomation.rootInActiveWindow).filter { it.first == label }.map { it.second }.distinct()
                if (found.size == 1) return found.single()
                delay(500)
            }
            error("Real MainActivity did not expose $label")
        }
        suspend fun tap(label: String) {
            val box = waitLabel(label)
            check(!box.isEmpty)
            val start = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(start, SystemClock.uptimeMillis(), action,
                    box.exactCenterX(), box.exactCenterY(), 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                try { check(registry.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
                delay(32)
            }
        }
        val observed = JSONObject()
        var consent = false
        try {
            TranslationDomTest.TranslationFixture().use { site ->
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(site.url)).setClass(registry.targetContext, MainActivity::class.java)
                ActivityScenario.launch<MainActivity>(intent).use { scenario ->
                    var menuReady = false
                    repeat(90) {
                        if (!menuReady) {
                            scenario.onActivity { activity ->
                                val translator = MainActivity::class.java.getDeclaredField("translator").apply { isAccessible = true }.get(activity) as PageTranslationController
                                menuReady = translator.menu.value?.let { it.page.source == "pt" && it.page.target == "en" } == true
                            }
                            delay(500)
                        }
                    }
                    assertTrue("Actual Portuguese translation projection did not become ready", menuReady)
                    tap("Page menu");tap("Translate to English")
                    repeat(120) {
                        if (!consent) {
                            consent = labels(registry.uiAutomation.rootInActiveWindow).any { it.first == "Download languages" }
                            scenario.onActivity { activity ->
                                val translator = MainActivity::class.java.getDeclaredField("translator").apply { isAccessible = true }.get(activity) as PageTranslationController
                                val state = translator.state.value
                                observed.put("phase", state.phase.name).put("source", state.source).put("target", state.target)
                            }
                            delay(500)
                        }
                    }
                    registry.uiAutomation.takeScreenshot()?.let { bitmap ->
                        File(folder, "main-translation-menu-consent.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                        bitmap.recycle()
                    }
                    assertTrue("Real MainActivity menu did not expose its native language-download consent", consent)
                }
            }
        } finally {
            File(folder, "main-translation-menu-consent.json").writeText(observed.put("passed", consent)
                .put("actualMainActivity", true).put("nativePointerInput", true).put("replacementUI", false).toString(2))
        }
    }

    @Test(timeout = 150_000)
    fun realMainActivityPublishesItsPortugueseTranslationMenu(): Unit = runBlocking {
        val registry = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val folder = File(registry.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        val observations = JSONArray()
        var ready = false
        fun <T> read(activity: MainActivity, name: String): T {
            @Suppress("UNCHECKED_CAST")
            return MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }.get(activity) as T
        }
        try {
            TranslationDomTest.TranslationFixture().use { site ->
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(site.url))
                    .setClass(registry.targetContext, MainActivity::class.java)
                ActivityScenario.launch<MainActivity>(intent).use { scenario ->
                    repeat(90) {
                        if (!ready) {
                            scenario.onActivity { activity ->
                                val browser = read<BrowserController>(activity, "browser")
                                val engine = read<GeckoEngine>(activity, "engine")
                                val translator = read<PageTranslationController>(activity, "translator")
                                val state = browser.state.value
                                val page = translator.state.value
                                val menu = translator.menu.value
                                val tab = state.tab
                                val value = JSONObject().put("surface", state.surface.name)
                                    .put("requestedTarget", activity.resources.configuration.locales[0].toLanguageTag())
                                    .put("welcomed", state.settings.welcomed).put("loading", state.loading)
                                    .put("privateBlocked", state.privateContentBlocked)
                                    .put("engineSelectionMatches", engine.selected == tab?.id)
                                    .put("phase", page.phase.name).put("source", page.source)
                                    .put("target", page.target).put("hasMenu", menu != null)
                                    // Fresh owned fixture only; this is the finite
                                    // error the public translation UI would show.
                                    .put("error", page.error?.replace(Regex("https?://\\S+"), "[URL]")?.take(200))
                                    .put("menuURLMatches", menu?.url == tab?.url)
                                    .put("bridge", tab?.id?.let(engine::bridgeStatus))
                                observations.put(value)
                                ready = menu != null && page.source == "pt" && page.target == "en" && menu.url == tab?.url
                            }
                            delay(1_000)
                        }
                    }
                    registry.uiAutomation.takeScreenshot()?.let { bitmap ->
                        File(folder, "main-translation-host.png").outputStream().use {
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                        }
                        bitmap.recycle()
                    }
                    assertTrue("MainActivity translation menu unavailable; finite diagnostics retained", ready)
                }
            }
        } finally {
            File(folder, "main-translation-host.json").writeText(JSONObject()
                .put("passed", ready).put("readOnlyDiagnostics", true).put("replacementUI", false)
                .put("modelResponseInjected", false).put("observations", observations).toString(2))
        }
    }
}

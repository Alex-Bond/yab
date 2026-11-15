package dev.yab.android

import android.graphics.Bitmap
import android.content.Intent
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.model.*
import java.io.File
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.mozilla.geckoview.GeckoSession

/** Actual Main controls use owned native input. Saved semantics are refusal checks only. */
class AppTabletSiteControlsTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun anchoredSiteChoicesToggleAndOriginalActionsRetireAcrossActualWindowAba(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36 && shell("getprop ro.kernel.qemu").trim() == "1")
        val size = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}"))
        val density = overrideValue(shell("wm density"), Regex("[0-9]{2,4}"))
        val phases = JSONArray()
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        var complete = false
        var restored = false
        var primary: Throwable? = null
        try {
            ui.run {
                shell("wm density 160"); shell("wm size 900x768")
                AppFlowTest.LocalPage().use { page ->
                    val fixture = NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                        NativeMainActivityFixture.Kind.APP_WORKSPACE)
                    var fixtureFailure: Throwable? = null
                    try { fixture.use {
                        lateinit var model: BrowserSessionViewModel
                        fixture.onActivity { host ->
                            model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                            ui.bind(model.browser, model.engine) { model.browser.workspaceWindow.value.generation }
                        }
                        val browser = model.browser
                        val id = "site-controls-original"
                        suspend fun window(width: Int, height: Int, after: Long? = null) {
                            await("the original retained Main owns its actual requested window") {
                                var ready = false
                                fixture.onActivity { host ->
                                    val bounds = host.windowManager.currentWindowMetrics.bounds
                                    val actual = browser.workspaceWindow.value
                                    ready = bounds.width() == width && bounds.height() == height && actual.registered &&
                                        actual.geometry == BrowserWorkspaceWindow(width.toDouble(), height.toDouble()) &&
                                        (after == null || actual.configuration > after)
                                }
                                ready
                            }
                        }
                        suspend fun nativeClick(label: String) { compose.waitForIdle(); ui.click(label); compose.waitForIdle() }
                        fun shown(tag: String) = compose.onAllNodesWithTag(tag).fetchSemanticsNodes().size == 1
                        suspend fun siteReady() {
                            await("one original Site panel with enabled real Zoom action") {
                                shown(PANEL) && shown(ZOOM) && compose.onNodeWithTag(ZOOM).isEnabled()
                            }
                            compose.onNodeWithTag(PANEL).assertIsDisplayed()
                            assertEquals(280f, compose.onNodeWithTag(PANEL).fetchSemanticsNode().boundsInRoot.width, 1f)
                            fixture.onActivity { assertTrue(it.hasWindowFocus()) }
                        }
                        fun mark(phase: String) { check(phases.length() < 8); phases.put(phase) }
                        suspend fun record(name: String) {
                            compose.waitForIdle(); ui.requireOwnCurrent()
                            fixture.onActivity { check(it.hasWindowFocus()) }
                            val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation/tablet-site-controls")
                            check(folder.isDirectory || folder.mkdirs())
                            File(folder, "$name.png").outputStream().use {
                                check(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it))
                            }
                        }
                        await("initial Controller loading has finished") { !browser.state.value.loading }
                        window(900, 768)
                        lateinit var profile: WebsiteProfile
                        lateinit var session: GeckoSession
                        fixture.onActivity {
                            val tab = BrowserTab(id, page.url, "Site original article", TabPlace.KEPT, createdAt = 1)
                            val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(tab), currentTabId = id)
                            check(browser.state.value.persistenceError == null)
                            browser.applySyncedSnapshot(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                                settings = BrowserSettings(welcomed = true)))
                            browser.selectTab(id)
                            val state = browser.state.value
                            check(state.tab?.id == id && state.tab?.url == page.url && state.surface == BrowserSurface.PAGE &&
                                !state.space!!.isPrivate && model.engine.hasLiveSession(id))
                            profile = state.space!!.websiteProfile
                            model.engine.navigate(checkNotNull(state.tab), page.url, profile)
                            session = model.engine.session(checkNotNull(state.tab), profile)
                        }
                        await("the original real document is loaded") {
                            browser.state.value.let { it.surface == BrowserSurface.PAGE && it.tab?.id == id && it.tab?.url == page.url &&
                                !it.page.loading && it.page.title == "Android flow article" } && shown(SITE)
                        }
                        fixture.onActivity {
                            check(browser.state.value.tab?.id == id && browser.state.value.tab?.url == page.url &&
                                browser.state.value.space?.websiteProfile == profile && model.engine.hasLiveSession(id))
                            // Only deterministic initial site preference setup; the tested changes use native controls.
                            check(model.engine.setZoom(id, 1.0))
                        }
                        await("the original fixture site starts at its explicit normal zoom") {
                            model.engine.sitePreferences(id).zoom == 1.0 && !browser.state.value.page.loading
                        }
                        val oldOpening = savedClick(SITE)
                        nativeClick("Site Controls"); siteReady(); mark("OPEN"); record("01-open")
                        val panel = compose.onNodeWithTag(PANEL).fetchSemanticsNode().boundsInRoot
                        val close = compose.onNodeWithTag(CLOSE).fetchSemanticsNode().boundsInRoot
                        assertTrue(panel.top >= close.bottom && panel.left >= 8 && panel.right <= 892)
                        val oldZoom = savedClick(ZOOM)
                        nativeClick("Zoom In")
                        await("real original native site zoom becomes 110 percent") {
                            model.engine.sitePreferences(id).zoom == 1.1
                        }
                        nativeClick("Zoom In")
                        await("current site zoom differs from the original saved 110 percent target") {
                            model.engine.sitePreferences(id).zoom == 1.2
                        }
                        nativeClick("More Site Settings")
                        await("More is a separate anchored choice menu") { shown(CHOICES) && shown(SETTINGS) }
                        record("02-more")
                        assertTrue(compose.onNodeWithTag(CHOICES).fetchSemanticsNode().boundsInRoot.top >= panel.top)
                        val originalSettings = savedClick(SETTINGS)
                        val outside = compose.onNodeWithTag(CHOICES_OUTSIDE).fetchSemanticsNode().boundsInRoot
                        check(!compose.onNodeWithTag(CHOICES).fetchSemanticsNode().boundsInRoot.contains(outside.center))
                        nativeClick("Dismiss Site Choices")
                        await("outside only dismisses the original choice and retains Site") { !shown(CHOICES) && shown(PANEL) }
                        fixture.onActivity { originalSettings() }
                        compose.waitForIdle()
                        assertTrue(shown(PANEL)); assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
                        nativeClick("Site Controls")
                        await("repeated original Site button closes its own popover") { !shown(PANEL) && shown(SITE) }
                        fixture.onActivity { oldOpening(); oldZoom() }
                        compose.waitForIdle()
                        assertFalse(shown(PANEL)); assertEquals(1.2, model.engine.sitePreferences(id).zoom, 0.0)
                        nativeClick("Site Controls"); siteReady()
                        fixture.onActivity { oldZoom() }
                        compose.waitForIdle()
                        assertEquals(1.2, model.engine.sitePreferences(id).zoom, 0.0)
                        val originalClose = savedClick(CLOSE)
                        val configuration = browser.workspaceWindow.value.configuration
                        shell("wm size 600x1000"); window(600, 1000, configuration)
                        await("compact original window has no tablet Site host") { !shown(PANEL) }
                        val compact = browser.workspaceWindow.value.configuration
                        shell("wm size 900x768"); window(900, 768, compact)
                        await("fresh tablet toolbar returns under its own current source") { shown(SITE) }
                        nativeClick("Site Controls"); siteReady()
                        fixture.onActivity { oldZoom(); originalClose(); oldOpening() }
                        compose.waitForIdle()
                        assertTrue(shown(PANEL)); assertEquals(1.2, model.engine.sitePreferences(id).zoom, 0.0)
                        nativeClick("Zoom In")
                        await("only the fresh native Site action can change the original site") {
                            model.engine.sitePreferences(id).zoom == 1.3
                        }
                        fixture.onActivity {
                            val state = browser.state.value
                            assertEquals(BrowserSurface.PAGE, state.surface); assertEquals(id, state.tab!!.id)
                            assertEquals(page.url, state.tab!!.url); assertEquals(profile, state.space!!.websiteProfile)
                            assertSame(session, model.engine.session(state.tab!!, profile)); assertTrue(model.engine.hasLiveSession(id))
                        }
                        nativeClick("Site Controls")
                        await("fresh retained Site session closes") { !shown(PANEL) }
                        mark("FRESH_WINDOW_ACTION_AND_CLOSE"); record("03-closed")
                    } } catch (error: Throwable) { fixtureFailure = error; throw error }
                    finally { preserve("native-main-activity-app_workspace.json", "activity", fixtureFailure) }
                }
            }
            complete = true
        } catch (error: Throwable) { primary = error; throw error }
        finally {
            withContext(NonCancellable) {
                var cleanup: Throwable? = null
                fun attempt(block: () -> Unit) { try { block() } catch (error: Throwable) {
                    if (cleanup == null) cleanup = error else cleanup!!.addSuppressed(error)
                } }
                attempt { preserve("owned-browser-app_workspace.json", "owned-ui", primary) }
                attempt { shell("wm size ${size ?: "reset"}") }
                attempt { shell("wm density ${density ?: "reset"}") }
                attempt {
                    restored = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}")) == size &&
                        overrideValue(shell("wm density"), Regex("[0-9]{2,4}")) == density
                    check(restored)
                }
                attempt {
                    val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
                    check(folder.isDirectory || folder.mkdirs())
                    File(folder, "app-tablet-site-controls.json").writeText(JSONObject().put("schema", 1)
                        .put("completed", complete).put("windowRestored", restored).put("phases", phases).toString(2))
                }
                cleanup?.let { if (primary != null) primary!!.addSuppressed(it) else throw it }
            }
        }
    }

    private fun savedClick(tag: String): () -> Boolean = dev.yab.browser.originalRenderedClick(compose.onNodeWithTag(tag).fetchSemanticsNode())
    private fun SemanticsNodeInteraction.isEnabled() = !fetchSemanticsNode().config.contains(
        androidx.compose.ui.semantics.SemanticsProperties.Disabled)
    private suspend fun await(message: String, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (true) {
            compose.waitForIdle()
            if (ready()) return
            check(SystemClock.elapsedRealtime() < deadline) { message }
            delay(40)
        }
    }
    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun overrideValue(text: String, pattern: Regex): String? = text.lineSequence()
        .firstOrNull { it.startsWith("Override") }?.substringAfter(":")?.trim()?.takeIf { pattern.matches(it) }
    private fun preserve(source: String, label: String, primary: Throwable?) {
        try {
            val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
            val input = File(folder, source)
            check(input.isFile && input.length() in 1..65536)
            File(folder, "site-controls-$label.json").writeBytes(input.readBytes())
        } catch (error: Throwable) { if (primary != null) primary.addSuppressed(error) else throw error }
    }
    companion object {
        private const val SITE = "browser.tablet.site-controls"
        private const val PANEL = "browser.tablet.site.panel"
        private const val CLOSE = "browser.tablet.site.close"
        private const val ZOOM = "browser.tablet.site.zoom-in"
        private const val CHOICES = "browser.tablet.site.choices"
        private const val CHOICES_OUTSIDE = "browser.tablet.site.choices.outside"
        private const val SETTINGS = "browser.tablet.site.settings"
    }
}

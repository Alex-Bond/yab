package dev.yab.android

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.KeyEvent
import android.view.View
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.Lifecycle
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

/** One real IME dismissal. No second Back, controller rest stimulus or semantics fallback. */
class AppTabletNewTabRestingTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun actualNewTabKeyboardDismissalShowsSidebarAndRetainsTheOriginalPairAndSessions(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36 && shell("getprop ro.kernel.qemu").trim() == "1")
        val size = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}"))
        val density = overrideValue(shell("wm density"), Regex("[0-9]{2,4}"))
        val phases = JSONArray()
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        var completed = false
        var restored = false
        var primary: Throwable? = null
        try {
            ui.run {
                shell("wm density 160"); shell("wm size 1280x800")
                AppFlowTest.LocalPage().use { page ->
                    val fixture = NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                        NativeMainActivityFixture.Kind.APP_WORKSPACE)
                    var activityFailure: Throwable? = null
                    try { fixture.use {
                        lateinit var model: BrowserSessionViewModel
                        fixture.onActivity { host ->
                            model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                            ui.bind(model.browser, model.engine) { model.browser.workspaceWindow.value.generation }
                        }
                        val browser = model.browser
                        suspend fun nativeClick(label: String) { compose.waitForIdle(); ui.click(label); compose.waitForIdle() }
                        fun shown(tag: String) = compose.onAllNodesWithTag(tag).fetchSemanticsNodes().size == 1
                        fun phase(name: String) { check(phases.length() < 8); phases.put(name) }
                        await("the original Main finishes loading and registers its actual tablet window") {
                            var ready = false
                            fixture.onActivity { host ->
                                val bounds = host.windowManager.currentWindowMetrics.bounds
                                ready = !browser.state.value.loading && bounds.width() == 1280 && bounds.height() == 800 &&
                                    host.resources.configuration.smallestScreenWidthDp >= 600 && browser.workspaceWindow.value.let {
                                        it.registered && it.geometry == BrowserWorkspaceWindow(1280.0, 800.0)
                                    }
                            }
                            ready
                        }
                        val first = BrowserTab("resting-original", page.url, "Resting original article", TabPlace.KEPT, createdAt = 1)
                        val second = BrowserTab("resting-companion", page.url + "?companion", "Resting companion article", TabPlace.KEPT, createdAt = 2)
                        lateinit var profile: WebsiteProfile
                        lateinit var firstSession: GeckoSession
                        lateinit var secondSession: GeckoSession
                        fixture.onActivity {
                            check(browser.state.value.persistenceError == null)
                            val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(first, second), currentTabId = first.id)
                            browser.applySyncedSnapshot(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                                settings = BrowserSettings(welcomed = true)))
                            browser.selectTab(first.id)
                            browser.openBeside(second.id); browser.selectTab(first.id)
                            val state = browser.state.value
                            check(state.surface == BrowserSurface.PAGE && state.tab?.id == first.id && state.tab?.url == first.url && state.workspace != null)
                            profile = checkNotNull(state.space).websiteProfile
                            check(model.engine.hasLiveSession(first.id) && model.engine.hasLiveSession(second.id))
                            model.engine.navigate(checkNotNull(state.tab), first.url, profile)
                            firstSession = model.engine.session(checkNotNull(state.tab), profile)
                            secondSession = model.engine.session(state.space!!.tabs.single { it.id == second.id }, profile)
                        }
                        await("the original real document and Sidebar control are ready") {
                            browser.state.value.let { it.surface == BrowserSurface.PAGE && it.tab?.id == first.id &&
                                it.tab?.url == first.url && !it.page.loading && it.page.title == "Android flow article" } &&
                                shown(SIDEBAR_TOGGLE) && shown(NEW_TAB)
                        }
                        assertEquals("Shown", compose.onNodeWithTag(SIDEBAR_TOGGLE).fetchSemanticsNode().config[SemanticsProperties.StateDescription])
                        nativeClick("Sidebar")
                        await("the original actual Sidebar is hidden before opening New Tab") {
                            shown(SIDEBAR_TOGGLE) && compose.onNodeWithTag(SIDEBAR_TOGGLE).fetchSemanticsNode()
                                .config.getOrNull(SemanticsProperties.StateDescription) == "Hidden" &&
                                compose.onAllNodesWithTag("browser.tablet.sidebar.tab.${first.id}").fetchSemanticsNodes().isEmpty()
                        }
                        val before = browser.state.value
                        val pair = checkNotNull(before.workspace)
                        val oldOpening = savedClick(NEW_TAB)
                        nativeClick("New Tab")
                        await("one actual focused tablet New Tab has a visible real OS keyboard") {
                            val editors = compose.onAllNodesWithTag(INPUT).fetchSemanticsNodes()
                            if (editors.size != 1) return@await false
                            var ready = false
                            fixture.onActivity { host ->
                                val state = browser.state.value
                                val insets = ViewCompat.getRootWindowInsets(host.window.decorView)
                                ready = state.surface == BrowserSurface.FIELD && state.fieldIsNewTab && !state.fieldIsPrivate &&
                                    !state.fieldResting && state.surfaceEpoch == before.surfaceEpoch + 1 &&
                                    insets?.isVisible(WindowInsetsCompat.Type.ime()) == true &&
                                    insets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom?.let { it > 0 } == true &&
                                    editors.single().config.getOrNull(SemanticsProperties.Focused) == true &&
                                    !editors.single().config.contains(SemanticsProperties.Disabled)
                            }
                            ready && shown(POPUP)
                        }
                        phase("REAL_TYPING_NEW_TAB")
                        compose.onNodeWithTag(INPUT).assertIsDisplayed().assertIsEnabled().assertIsFocused()
                        val originalNode = compose.onNodeWithTag(INPUT).fetchSemanticsNode()
                        val originalRoot = checkNotNull(originalNode.root)
                        val originalView = checkNotNull((originalRoot as? ViewRootForTest)?.view)
                        lateinit var originalHost: MainActivity
                        lateinit var originalPlacement: BrowserFieldPlacementLease
                        lateinit var originalWindow: WorkspaceWindowState
                        lateinit var originalConfiguration: Configuration
                        lateinit var originalIntent: Intent
                        lateinit var originalBounds: Rect
                        lateinit var originalDecor: View
                        var originalToken: Any? = null
                        lateinit var originalAccount: dev.yab.sync.AccountRecordsSnapshot
                        val sync = (context.applicationContext as YabApplication).sync
                        fixture.onActivity { host ->
                            originalHost = host; originalPlacement = BrowserFieldPlacementLease.capture(browser, true)
                            originalWindow = browser.workspaceWindow.value; originalConfiguration = Configuration(host.resources.configuration)
                            originalIntent = host.intent; originalBounds = Rect(host.windowManager.currentWindowMetrics.bounds)
                            originalDecor = host.window.decorView; originalToken = originalView.windowToken
                            originalAccount = sync.accountRecords.value
                            check(originalPlacement.current() && originalPlacement.input?.newTab == true)
                        }
                        // One original admission immediately before the existing native key API.
                        // No authority is acquired or input retried after this call begins.
                        ui.requireOwnCurrent()
                        fixture.onActivity { host ->
                            val insets = ViewCompat.getRootWindowInsets(originalDecor)
                            check(host === originalHost && host.window.decorView === originalDecor && host.intent === originalIntent &&
                                host.resources.configuration == originalConfiguration && host.windowManager.currentWindowMetrics.bounds == originalBounds &&
                                host.hasWindowFocus() && host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                                originalToken != null && originalView.windowToken === originalToken && originalView.rootView === originalDecor &&
                                originalDecor.windowToken === originalToken && originalView.isAttachedToWindow && originalView.isShown &&
                                originalNode.root === originalRoot && originalNode.layoutInfo.isAttached && originalNode.layoutInfo.isPlaced &&
                                originalNode.config.getOrNull(SemanticsProperties.Focused) == true &&
                                originalPlacement.current() && browser.workspaceWindow.value == originalWindow &&
                                sync.nativeOwnerCurrent(originalAccount) && insets?.isVisible(WindowInsetsCompat.Type.ime()) == true &&
                                insets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom?.let { it > 0 } == true &&
                                model.engine.hasLiveSession(first.id) && model.engine.hasLiveSession(second.id))
                        }
                        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
                        await("the one real keyboard dismissal closes original New Tab and shows Sidebar") {
                            var ready = false
                            fixture.onActivity { host ->
                                val state = browser.state.value
                                val insets = ViewCompat.getRootWindowInsets(host.window.decorView)
                                ready = state.surface == BrowserSurface.PAGE && state.fieldResting && state.tab?.id == first.id &&
                                    state.tab?.url == first.url && state.surfaceEpoch == before.surfaceEpoch + 1 &&
                                    insets?.isVisible(WindowInsetsCompat.Type.ime()) == false
                            }
                            ready && !shown(INPUT) && !shown(POPUP) && shown(SIDEBAR_TOGGLE) &&
                                compose.onNodeWithTag(SIDEBAR_TOGGLE).fetchSemanticsNode().config
                                    .getOrNull(SemanticsProperties.StateDescription) == "Shown" &&
                                compose.onAllNodesWithTag("browser.tablet.sidebar.tab.${first.id}").fetchSemanticsNodes().size == 1
                        }
                        fixture.onActivity {
                            val state = browser.state.value
                            assertEquals(pair, state.workspace); assertEquals(before.space!!.tabs, state.space!!.tabs)
                            assertEquals(profile, state.space!!.websiteProfile)
                            assertTrue(model.engine.hasLiveSession(first.id) && model.engine.hasLiveSession(second.id))
                            assertSame(firstSession, model.engine.session(checkNotNull(state.tab), profile))
                            assertSame(secondSession, model.engine.session(state.space!!.tabs.single { it.id == second.id }, profile))
                        }
                        phase("ORIGINAL_FIELD_CLOSED_SIDEBAR_SHOWN")
                        val completedState = browser.state.value
                        fixture.onActivity { oldOpening() }
                        compose.waitForIdle()
                        fixture.onActivity { assertEquals(completedState, browser.state.value) }
                        assertFalse(shown(INPUT)); phase("OLD_OPENING_REFUSED")
                    } } catch (error: Throwable) { activityFailure = error; throw error }
                    finally { preserve("native-main-activity-app_workspace.json", "activity", activityFailure) }
                }
            }
            completed = true
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
                    File(folder, "app-tablet-newtab-resting.json").writeText(JSONObject().put("schema", 1)
                        .put("completed", completed).put("windowRestored", restored).put("phases", phases).toString(2))
                }
                cleanup?.let { if (primary != null) primary!!.addSuppressed(it) else throw it }
            }
        }
    }

    private fun savedClick(tag: String): () -> Boolean = dev.yab.browser.originalRenderedClick(compose.onNodeWithTag(tag).fetchSemanticsNode())
    private suspend fun await(message: String, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (true) { compose.waitForIdle(); if (ready()) return
            check(SystemClock.elapsedRealtime() < deadline) { message }; delay(40) }
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
            File(folder, "newtab-resting-$label.json").writeBytes(input.readBytes())
        } catch (error: Throwable) { if (primary != null) primary.addSuppressed(error) else throw error }
    }
    companion object {
        private const val SIDEBAR_TOGGLE = "browser.tablet.sidebar.toggle"
        private const val NEW_TAB = "browser.tablet.new-tab"
        private const val INPUT = "browser.field.input"
        private const val POPUP = "browser.tablet.omnibox"
    }
}

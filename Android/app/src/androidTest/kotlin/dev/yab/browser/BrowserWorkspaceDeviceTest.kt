package dev.yab.browser

import android.graphics.Rect
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dev.yab.android.EngineTestActivity
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserTab
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.GeckoSession

/** Actual page surfaces keep their physical side and native session on window resize. */
class BrowserWorkspaceDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 240_000)
    fun nativePanesKeepOrderFocusAndHistoryAcrossWidePortraitAndCover(): Unit = runBlocking {
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.WORKSPACE)
        ui.run {
            check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
            check(shell("getprop ro.kernel.qemu").trim() == "1")
            val previousSize = overrideValue(shell("wm size"))
            val previousDensity = overrideValue(shell("wm density"))
            val fixture = BrowserInstrumentedTest()
            try {
                shell("wm density 160"); shell("wm size 1280x800")
                BrowserInstrumentedTest.FixtureServer().use { server ->
                    fixture.withBrowser { browser, engine ->
                        main { ui.bind(browser, engine) }
                        ui.checkpoint("browser_ready")
                        main { browser.openUrl(server.url("/safe/first")) }
                        await("first real page") { !browser.state.value.page.loading && browser.state.value.page.title == "Safe page first" }
                        main { browser.openUrl(server.url("/safe/first-next"), newTab = false) }
                        await("first page native history") { !browser.state.value.page.loading && browser.state.value.page.title == "Safe page first-next" && browser.state.value.page.canGoBack }
                        val first = browser.state.value.tab!!
                        main { browser.openUrl(server.url("/safe/second")) }
                        await("second real page") { !browser.state.value.page.loading && browser.state.value.page.title == "Safe page second" }
                        val second = browser.state.value.tab!!
                        // Keep First physically left, Second right, initially controlling Second.
                        main {
                            browser.selectTab(first.id); browser.openBeside(second.id)
                            engine.setVisibleTabs(setOf(first.id, second.id))
                        }
                        await("two real horizontal surfaces") {
                            val frames = frames()
                            frames[first.id]?.let { a -> frames[second.id]?.let { b -> a.left < b.left && a.height() == b.height() } } == true
                        }
                        val before = frames()
                        val firstSession = main { engine.session(first, browser.state.value.space!!.websiteProfile) }
                        val secondSession = main { engine.session(second, browser.state.value.space!!.websiteProfile) }
                        tap(ui, browser, engine, first, firstSession, before.getValue(first.id))
                        await("native companion focuses") { browser.state.value.tab?.id == first.id }
                        assertEquals("Focus swapped physical page positions", before, frames())
                        fixture.shot("workspace-landscape-first-focus.png")
                        tap(ui, browser, engine, second, secondSession, before.getValue(second.id))
                        await("second focus") { browser.state.value.tab?.id == second.id }
                        assertEquals(before, frames())
                        shell("wm size 1600x800")
                        await("two wider panes") { frames()[second.id]?.width()?.let { it >= 790 } == true }
                        val wideBefore = frames()
                        main { browser.openField(newTab = false) }
                        await("sidebar reserves only its focused pane") {
                            val current = frames()
                            current[first.id]?.let { it.left == wideBefore.getValue(first.id).left && it.width() == wideBefore.getValue(first.id).width() } == true && current[second.id]?.let { frame ->
                                frame.left == wideBefore.getValue(second.id).left + 320 && frame.width() == wideBefore.getValue(second.id).width() - 320
                            } == true
                        }
                        fixture.shot("workspace-field-beside-page.png")
                        main { browser.dismissSurface() }
                        await("field closes into the same two native panes") { frames() == wideBefore }
                        shell("wm size 800x1280")
                        await("portrait only selected surface") { frames().keys == setOf(second.id) }
                        assertEquals(dev.yab.browser.model.BrowserWorkspace(first.id, second.id, second.id), browser.state.value.workspace)
                        main {
                            assertSame(firstSession, engine.session(first, browser.state.value.space!!.websiteProfile))
                            assertSame(secondSession, engine.session(second, browser.state.value.space!!.websiteProfile))
                        }
                        fixture.shot("workspace-portrait.png")
                        shell("wm size 480x1000")
                        await("cover only selected surface") { frames().keys == setOf(second.id) }
                        assertNotNull(browser.state.value.workspace)
                        shell("wm size 1280x800")
                        await("spread restored from cover") { frames().keys == setOf(first.id, second.id) }
                        main {
                            assertSame(firstSession, engine.session(first, browser.state.value.space!!.websiteProfile))
                            assertSame(secondSession, engine.session(second, browser.state.value.space!!.websiteProfile))
                            browser.closeWorkspacePage()
                        }
                        await("close returns to companion") { browser.state.value.tab?.id == first.id && frames().keys == setOf(first.id) }
                        assertNull(browser.state.value.workspace)
                        main { assertTrue(browser.back()) }
                        await("real Back survived pane and window changes") { !browser.state.value.page.loading && browser.state.value.page.title == "Safe page first" }
                        fixture.shot("workspace-closed-to-companion.png")
                    }
                }
            } finally {
                shell("wm size ${previousSize ?: "reset"}")
                shell("wm density ${previousDensity ?: "reset"}")
            }
        }
    }

    private fun overrideValue(text: String) = text.lineSequence().firstOrNull { it.startsWith("Override ") }?.substringAfter(": ")?.trim()
    private fun shell(command: String): String = instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
        android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
    }
    private fun frames(): Map<String, Rect> {
        val result = mutableMapOf<String, Rect>()
        instrumentation.runOnMainSync {
            val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<EngineTestActivity>().singleOrNull() ?: return@runOnMainSync
            fun visit(view: View) {
                if (view is GeckoView && view.isAttachedToWindow && view.width > 0 && view.session != null) {
                    val tag = view.tag as? String
                    if (tag != null) {
                        val origin = IntArray(2); view.getLocationOnScreen(origin)
                        result[tag] = Rect(origin[0], origin[1], origin[0] + view.width, origin[1] + view.height)
                    }
                }
                if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(activity.window.decorView)
        }
        return result
    }
    private suspend fun tap(ui: OwnedBrowserTestUi, browser: BrowserController, engine: GeckoEngine,
        target: BrowserTab, session: GeckoSession, frame: Rect) {
        val current: () -> Boolean = main {
            val captured = browser.state.value
            val profile = requireNotNull(captured.space).websiteProfile
            val pair = requireNotNull(captured.workspace)
            val originalTab = requireNotNull(captured.tab).id
            val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<EngineTestActivity>().single()
            var visited = 0
            val matches = mutableListOf<GeckoView>()
            fun visit(view: View) {
                check(++visited <= 512) { "Owned workspace view tree exceeded its fixture bound" }
                if (view is GeckoView && view.tag == target.id) matches += view
                if (view is ViewGroup) {
                    check(view.childCount <= 128)
                    repeat(view.childCount) { visit(view.getChildAt(it)) }
                }
            }
            visit(activity.window.decorView)
            val view = matches.single()
            val lease: () -> Boolean = {
                val state = browser.state.value
                val workspace = state.workspace
                val origin = IntArray(2); view.getLocationOnScreen(origin)
                !state.loading && !state.privateContentBlocked && state.selectedSpaceId == captured.selectedSpaceId &&
                    state.surface == captured.surface && state.surfaceEpoch == captured.surfaceEpoch &&
                    state.space?.websiteProfile == profile && state.space?.tabs?.any { it.id == target.id && it.url == target.url } == true &&
                    workspace != null && workspace.first == pair.first && workspace.second == pair.second && workspace.newPage == pair.newPage &&
                    state.tab?.id in setOf(originalTab, target.id) && activity.hasWindowFocus() &&
                    view.isAttachedToWindow && view.isShown && view.session === session && engine.hasLiveSession(target.id) &&
                    Rect(origin[0], origin[1], origin[0] + view.width, origin[1] + view.height) == frame
            }
            check(lease()) { "Captured workspace pane is no longer current" }
            lease
        }
        ui.tapBounds(frame, current)
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun await(name: String, test: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (!test()) { check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $name" }; delay(80) }
    }
}

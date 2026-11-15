package dev.yab.browser

import android.os.Build
import android.os.IBinder
import android.view.View
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.min

/** Requires a real tablet-class owned window with both sides >=800dp. The first
 * three cases control only the Compose clock; the IME case uses the real clock
 * and real window insets. No configuration override or keyboard simulation. */
class BrowserTabletSettingsDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()

    private class Scene(val activity: EngineTestActivity) {
        var shift by mutableFloatStateOf(0f)
        var compact by mutableStateOf(false)
        @Volatile var imeBottom = 0
        @Volatile var windowHeight = 0
        @Volatile var frame = SettingsFrame()
        lateinit var view: View
            private set
        private var token: IBinder? = null
        @Volatile var ownerRevoked = false
            private set
        var hideKeyboard: (() -> Unit)? = null
        fun bindView(value: View) {
            if (value.windowToken == null) return
            if (!::view.isInitialized) { view = value; token = value.windowToken }
            else if (view !== value || value.windowToken !== token) ownerRevoked = true
        }
        fun windowCurrent() = !ownerRevoked && ::view.isInitialized && view.isAttachedToWindow &&
            view.windowToken === token && activity.window.decorView.windowToken === token
    }

    private val sheet get() = compose.onNodeWithTag("settings.sheet", useUnmergedTree = true)
    private fun activate(node: SemanticsNodeInteraction) = node.performSemanticsAction(SemanticsActions.OnClick) { it() }
    private fun drag() = compose.onNodeWithTag("settings.motion").fetchSemanticsNode().config[SettingsDragKey]

    @Test fun actualCenteredSheetRetainsItsRouteQueryAndFreshForegroundControlsAcrossViewportChanges() = fixture { browser, scene ->
        val density = compose.activity.resources.displayMetrics.density
        val root = compose.onNodeWithTag("settings.motion").fetchSemanticsNode().boundsInRoot
        val bounds = sheet.fetchSemanticsNode().boundsInRoot
        assertTrue(sheet.fetchSemanticsNode().config[SettingsTabletKey])
        assertEquals(600f * density, bounds.width, 1f)
        assertEquals(min(760f * density, root.height - 80 * density), bounds.height, 1f)
        assertEquals(root.center.x, bounds.center.x, 1f)
        assertEquals(root.center.y, bounds.center.y, 1f)
        compose.onNodeWithTag("settings.search").performTextReplacement("swipe")
        compose.mainClock.advanceTimeBy(250)
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Swipe from Anywhere").fetchSemanticsNodes().size == 1 }
        activate(compose.onNodeWithText("Swipe from Anywhere"))
        compose.mainClock.advanceTimeBy(550)
        val control = compose.onNodeWithText("Swipe from Anywhere")
        val originalNode = control.fetchSemanticsNode().id
        val old = originalRenderedClick(control.fetchSemanticsNode())
        val before = browser.state.value.settings.swipeAnywhere
        compose.runOnIdle { scene.compact = true }
        compose.mainClock.advanceTimeByFrame()
        assertFalse(sheet.fetchSemanticsNode().config[SettingsTabletKey])
        assertEquals(originalNode, control.fetchSemanticsNode().id)
        compose.runOnIdle { scene.compact = false; scene.shift = 24f }
        compose.mainClock.advanceTimeByFrame()
        assertTrue(sheet.fetchSemanticsNode().config[SettingsTabletKey])
        assertEquals(originalNode, control.fetchSemanticsNode().id)
        compose.runOnIdle { browser.backgrounded(); old(); browser.foregrounded(); old() }
        compose.mainClock.advanceTimeByFrame()
        assertEquals(before, browser.state.value.settings.swipeAnywhere)
        control.assertIsEnabled().performTouchInput { click() }
        compose.runOnIdle { assertEquals(!before, browser.state.value.settings.swipeAnywhere); old(); assertEquals(!before, browser.state.value.settings.swipeAnywhere) }
        activate(compose.onNodeWithContentDescription("Back"))
        compose.mainClock.advanceTimeBy(450)
        compose.onNodeWithTag("settings.search").assertTextEquals("swipe")
    }

    @Test fun movingTheActualTargetFrameCancelsAHeldHeaderWithoutClosingAndAFreshPullUsesSheetHeight() = fixture { browser, scene ->
        val density = compose.activity.resources.displayMetrics.density
        val header = compose.onNodeWithTag("settings.header")
        val originalNode = header.fetchSemanticsNode().id
        val lease = compose.runOnIdle { browser.captureSettingsPresentation()!! }
        val originalBounds = sheet.fetchSemanticsNode().boundsInRoot
        var pressed = false
        var failure: Throwable? = null
        try {
            requireOwner(browser, lease, scene)
            header.performTouchInput { down(center); pressed = true; moveBy(Offset(0f, 80 * density), delayMillis = 80) }
            compose.mainClock.advanceTimeByFrame()
            assertEquals(80f, drag(), .5f)
            val height = originalBounds.height / density
            assertEquals(1 - 80 / height, compose.onNodeWithTag("settings.motion").fetchSemanticsNode().config[SettingsPresenceKey], .001f)
            // boundsInRoot is clipped by the outer viewport while held. Compare
            // the same held pose on both sides of the root-frame translation.
            val heldBounds = sheet.fetchSemanticsNode().boundsInRoot
            compose.runOnIdle { scene.shift = 24f }
            compose.mainClock.advanceTimeByFrame()
            val movedBounds = sheet.fetchSemanticsNode().boundsInRoot
            assertEquals(heldBounds.width, movedBounds.width, 0f)
            assertEquals(heldBounds.height, movedBounds.height, 0f)
            assertNotEquals(heldBounds.left, movedBounds.left, 0f)
            assertEquals(originalNode, header.fetchSemanticsNode().id)
            requireOwner(browser, lease, scene)
            header.performTouchInput { up() }; pressed = false
            compose.mainClock.advanceTimeBy(1500)
            assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
            assertEquals(0f, drag(), .001f)
            requireOwner(browser, lease, scene)
            header.performTouchInput { down(center); pressed = true; moveBy(Offset(0f, 150 * density), delayMillis = 80) }
            compose.mainClock.advanceTimeByFrame()
            assertEquals(150f, drag(), .5f)
            requireOwner(browser, lease, scene)
            header.performTouchInput { up() }; pressed = false
            compose.mainClock.advanceTimeBy(64)
            assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
            assertTrue(drag() > 150f)
            compose.mainClock.advanceTimeBy(1500)
            sheet.assertDoesNotExist()
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (pressed) runCatching {
                requireOwner(browser, lease, scene)
                assertEquals(originalNode, header.fetchSemanticsNode().id)
                header.performTouchInput { cancel(delayMillis = 0) }
            }.exceptionOrNull()?.let { cleanup -> failure?.addSuppressed(cleanup) ?: throw cleanup }
        }
    }

    @Test fun movingTheActualTargetFrameCancelsAHeldEdgeWithoutPoppingTheRetainedRoute() = fixture { browser, scene ->
        activate(compose.onNodeWithText("General"))
        compose.mainClock.advanceTimeBy(550)
        val page = compose.onNodeWithTag("settings.route.1")
        val originalNode = page.fetchSemanticsNode().id
        val lease = compose.runOnIdle { browser.captureSettingsPresentation()!! }
        val density = compose.activity.resources.displayMetrics.density
        val bounds = page.fetchSemanticsNode().boundsInRoot
        val originalSheet = sheet.fetchSemanticsNode().boundsInRoot
        var pressed = false
        var failure: Throwable? = null
        try {
            requireOwner(browser, lease, scene)
            page.performTouchInput { down(Offset(8 * density, bounds.height / 2)); pressed = true; moveTo(Offset(bounds.width * .55f, bounds.height / 2), delayMillis = 240) }
            compose.mainClock.advanceTimeByFrame()
            assertTrue(page.fetchSemanticsNode().config[SettingsRouteXKey] > .5f)
            compose.runOnIdle { scene.shift = 24f }
            compose.mainClock.advanceTimeByFrame()
            val movedSheet = sheet.fetchSemanticsNode().boundsInRoot
            assertEquals(originalSheet.width, movedSheet.width, 0f)
            assertEquals(originalSheet.height, movedSheet.height, 0f)
            assertNotEquals(originalSheet.left, movedSheet.left, 0f)
            assertEquals(originalNode, page.fetchSemanticsNode().id)
            requireOwner(browser, lease, scene)
            page.performTouchInput { up() }; pressed = false
            compose.mainClock.advanceTimeBy(550)
            assertEquals(0f, page.fetchSemanticsNode().config[SettingsRouteXKey], .001f)
            compose.onNodeWithTag("settings.search").assertDoesNotExist()
            compose.onNodeWithText("Swipe from Anywhere").assertIsDisplayed()
            assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
            activate(compose.onNodeWithContentDescription("Back"))
            compose.mainClock.advanceTimeBy(450)
            compose.onNodeWithTag("settings.search").assertExists()
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (pressed) runCatching {
                requireOwner(browser, lease, scene)
                assertEquals(originalNode, page.fetchSemanticsNode().id)
                page.performTouchInput { cancel(delayMillis = 0) }
            }.exceptionOrNull()?.let { cleanup -> failure?.addSuppressed(cleanup) ?: throw cleanup }
        }
    }

    @Test fun realImeInsetUsesActualWindowAndSheetCoordinatesAndHideRetainsTheQuery() = fixture(controlledClock = false) { browser, scene ->
        val lease = compose.runOnIdle { browser.captureSettingsPresentation()!! }
        compose.runOnIdle { scene.shift = 24f }
        compose.waitForIdle()
        requireOwner(browser, lease, scene)
        compose.onNodeWithTag("settings.search").performClick()
        compose.waitUntil(10_000) { scene.imeBottom > 0 && scene.imeBottom == platformImeBottom(scene) }
        compose.onNodeWithTag("settings.search").performTextReplacement("appearance")
        compose.waitForIdle()
        val windowHeight = compose.runOnIdle { platformWindowHeight() }
        assertEquals(windowHeight, scene.windowHeight)
        val viewOrigin = IntArray(2)
        compose.runOnIdle { scene.view.getLocationInWindow(viewOrigin) }
        val bounds = sheet.fetchSemanticsNode().boundsInRoot
        val expected = (bounds.bottom + viewOrigin[1] - (windowHeight - scene.imeBottom)).coerceIn(0f, bounds.height)
        val density = compose.activity.resources.displayMetrics.density
        assertEquals(expected, sheet.fetchSemanticsNode().config[SettingsKeyboardOverlapKey] * density, 1f)
        assertTrue(compose.onNodeWithTag("settings.search").fetchSemanticsNode().boundsInRoot.bottom + viewOrigin[1] <= windowHeight - scene.imeBottom)
        requireOwner(browser, lease, scene)
        compose.runOnIdle { scene.hideKeyboard!!.invoke() }
        compose.waitUntil(10_000) { scene.imeBottom == 0 }
        assertEquals(0f, sheet.fetchSemanticsNode().config[SettingsKeyboardOverlapKey], 0f)
        compose.onNodeWithTag("settings.search").assertTextEquals("appearance")
        requireOwner(browser, lease, scene)
        assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
    }

    private fun requireOwner(browser: BrowserController, lease: SettingsPresentationLease, scene: Scene) = compose.runOnIdle {
        assertTrue(browser.settingsActionsCurrent(lease))
        assertSame(scene.activity, compose.activity)
        assertTrue(scene.windowCurrent())
        assertTrue(compose.activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        assertTrue(scene.view.isAttachedToWindow && scene.view.isShown && scene.view.hasWindowFocus())
        assertSame(compose.activity.window.decorView.windowToken, scene.view.windowToken)
    }

    private fun platformImeBottom(scene: Scene): Int {
        check(scene.windowCurrent()) { "The original tablet window changed" }
        return if (Build.VERSION.SDK_INT >= 30) scene.view.rootWindowInsets?.getInsets(android.view.WindowInsets.Type.ime())?.bottom ?: 0
            else error("Actual tablet IME verification requires API30+")
    }

    private fun platformWindowHeight(): Int = if (Build.VERSION.SDK_INT >= 30)
        compose.activity.windowManager.currentWindowMetrics.bounds.height()
        else error("Actual tablet window verification requires API30+")

    private fun fixture(controlledClock: Boolean = true, body: (BrowserController, Scene) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT >= 30) { "Actual tablet window/IME verification requires API30+" }
        check(compose.activity.resources.configuration.smallestScreenWidthDp >= 600) { "Requires the actual existing Android tablet classification" }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val scene = Scene(compose.activity)
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}
            override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}
            override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        lateinit var browser: BrowserController
        compose.runOnIdle { browser = BrowserController(object : BrowserRepository {
            override suspend fun load(): BrowserSnapshot? = null
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope) }
        var failure: Throwable? = null
        try {
            compose.waitUntil(5000) { !browser.state.value.loading }
            compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
                val density = LocalDensity.current
                val imeBottom = WindowInsets.ime.getBottom(density)
                val windowHeight = LocalWindowInfo.current.containerSize.height
                val view = LocalView.current
                val keyboard = LocalSoftwareKeyboardController.current
                val focus = LocalFocusManager.current
                SideEffect { scene.imeBottom = imeBottom; scene.windowHeight = windowHeight; scene.bindView(view)
                    scene.hideKeyboard = { check(scene.windowCurrent()); focus.clearFocus(force = true); keyboard?.hide() } }
                CompositionLocalProvider(LocalSettingsAnimationsEnabled provides (if (controlledClock) true else null),
                    LocalSettingsFrameObserver provides { scene.frame = it }) {
                    Box(Modifier.fillMaxSize()) {
                        BrowserScreen(browser, modifier = Modifier.padding(24.dp).offset(x = scene.shift.dp, y = scene.shift.dp)
                            .then(if (scene.compact) Modifier.fillMaxWidth().height(640.dp) else Modifier.fillMaxSize()),
                            pageContent = { _, _, _ -> Text("OWNED-PUBLIC-TABLET-FIXTURE") })
                    }
                }
            } }
            compose.mainClock.autoAdvance = !controlledClock
            compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
            if (controlledClock) compose.mainClock.advanceTimeBy(700)
            else compose.waitUntil(10_000) { scene.frame.phase == SettingsPhase.OPEN && !scene.frame.running }
            val root = compose.onNodeWithTag("settings.motion").fetchSemanticsNode().boundsInRoot
            val density = compose.activity.resources.displayMetrics.density
            check(min(root.width, root.height) / density >= 800) { "Requires an actual own viewport >=800dp on both sides; compact profiles cannot qualify this suite" }
            body(browser, scene)
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            compose.mainClock.autoAdvance = true
            runCatching { compose.runOnIdle { try { scene.hideKeyboard?.invoke() } finally { scope.cancel() } } }
                .exceptionOrNull()?.let { cleanup -> failure?.addSuppressed(cleanup) ?: throw cleanup }
        }
    }
}

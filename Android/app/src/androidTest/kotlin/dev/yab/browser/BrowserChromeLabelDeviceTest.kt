package dev.yab.browser

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Native label pixels and real BrowserScreen consumers; explicit fake page, no motion acceptance. */
class BrowserChromeLabelDeviceTest {
    private data class LabelFixtureOwner(val document: Any, val windowToken: android.os.IBinder)
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val label get() = compose.onNodeWithTag("browser.chrome.label", useUnmergedTree = true)
    private val viewport get() = compose.onNodeWithTag("browser.chrome.label.viewport", useUnmergedTree = true)
    private fun actualText(): TextLayoutResult {
        val result = mutableListOf<TextLayoutResult>()
        label.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { assertTrue(it(result)) }
        return result.single()
    }

    @Test fun actualPlateKeepsShortAndPortHostsAndLongDomainTailWithoutBreakingPageActions() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var reloads = 0
        var fixtureDocument = Any()
        val tab = BrowserTab("label-tab", "https://www.example.com", createdAt = 1)
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("label-space", "Label fixture", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "label-space")
        val repository = object : BrowserRepository { override suspend fun load() = snapshot; override suspend fun save(snapshot: BrowserSnapshot) {} }
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) { fixtureDocument = Any() }
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { fixtureDocument = Any() }
            override fun goBack(tabId: String) {}; override fun goForward(tabId: String) {}
            override fun reload(tabId: String) { reloads++; fixtureDocument = Any() }; override fun stop(tabId: String) {}; override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(repository, engine, scope)
        val window = compose.activity.window
        val decor = window.decorView
        fun fixtureMenuCurrent(lease: PageMenuLease): Boolean {
            val owner = lease.nativeOwner as? LabelFixtureOwner ?: return false
            return owner.document === fixtureDocument && compose.activity.window === window &&
                window.decorView === decor && decor.windowToken === owner.windowToken &&
                decor.isAttachedToWindow && decor.isShown && decor.hasWindowFocus() &&
                !compose.activity.isFinishing && !compose.activity.isDestroyed &&
                lease.account == null && lease.accountEpoch == 0L && lease.device == null &&
                lease.url?.let { lease.ownsSource(browser.state.value, it) } == true
        }
        try {
            // Explicit fake page with its own document/window provenance. The menu
            // now requires a lease provider; omitting it correctly refuses entry.
            // Actual Gecko menu/readiness is covered by BrowserActionsDeviceTest.
            compose.setContent { BrowserScreen(browser,
                capturePageMenuLease = capture@ { generation ->
                    val source = browser.state.value
                    val selected = source.tab ?: return@capture null
                    val space = source.space ?: return@capture null
                    val token = decor.windowToken ?: return@capture null
                    PageMenuLease(null, 0, selected.id, space.id, space.websiteProfile,
                        LabelFixtureOwner(fixtureDocument, token), source.surfaceEpoch, generation, url = selected.url)
                        .takeIf(::fixtureMenuCurrent)
                }, pageMenuCurrent = ::fixtureMenuCurrent
            ) { _, _, modifier -> Box(modifier.fillMaxSize().background(Color.White)) } }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            label.assertTextEquals("example.com")
            assertChromeEdge(28f)
            compose.runOnIdle { browser.pageChanged(tab.id, browser.state.value.page.copy(scrollY = 120f, userScrollY = 120f)) }
            compose.waitForIdle()
            var pose = viewport.fetchSemanticsNode().config[ChromeLabelPoseKey]
            assertEquals(0f, pose[3], 0f)
            assertFalse(actualText().hasVisualOverflow)
            assertChromeEdge(16f)
            record("01-short-folded")
            val portUrl = "http://127.0.0.1:49281/motion?q=fixture#part"
            compose.runOnIdle { browser.openUrl(portUrl, newTab = false) }
            label.assertTextEquals("127.0.0.1:49281")
            compose.runOnIdle { assertEquals(portUrl, browser.state.value.tab?.url) }
            record("02-explicit-port")
            val longUrl = "https://a-very-long-subdomain-for-the-native-browser-label.example.com:8443/path"
            compose.runOnIdle { browser.openUrl(longUrl, newTab = false); browser.pageChanged(tab.id, browser.state.value.page.copy(scrollY = 180f, userScrollY = 180f)) }
            compose.waitForIdle()
            val text = actualText()
            assertEquals("a-very-long-subdomain-for-the-native-browser-label.example.com:8443", text.layoutInput.text.text)
            assertFalse(text.isLineEllipsized(0))
            pose = viewport.fetchSemanticsNode().config[ChromeLabelPoseKey]
            assertTrue(pose[2] < 0)
            assertEquals(pose[1], pose[0] + pose[2], 1f)
            record("03-long-domain-tail")
            compose.runOnIdle { browser.pageChanged(tab.id, browser.state.value.page.copy(scrollY = 0f, userScrollY = 0f)) }
            compose.onNodeWithContentDescription("Reload").performClick()
            compose.runOnIdle {
                assertEquals(1, reloads); assertEquals(longUrl, browser.state.value.tab?.url)
                // This label-only fixture has a non-network engine. Complete its
                // reload before testing the real menu's loaded-document gate.
                browser.pageChanged(tab.id, browser.state.value.page.copy(loading = false, progress = 1f))
            }
            compose.waitForIdle()
            compose.onNodeWithContentDescription("Page menu").performClick()
            compose.waitUntil(5_000) { compose.onAllNodesWithText("Find on Page").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Find on Page").assertExists()
            record("04-existing-page-menu")
        } finally { scope.cancel() }
    }

    @Test fun actualNativeMaskFadesTheHeadAndKeepsTheDomainTailOpaque() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        compose.setContent {
            Box(Modifier.fillMaxSize().background(Color.White).padding(24.dp)) {
                CompositionLocalProvider(LocalContentColor provides Color.Black) {
                    BrowserChromeLabel("abcdefghijklmnopqrstuvwxyz.native-domain.example:8443", 13f, Modifier.width(114.dp))
                }
            }
        }
        val text = actualText()
        assertFalse(text.isLineEllipsized(0))
        val pose = viewport.fetchSemanticsNode().config[ChromeLabelPoseKey]
        val density = instrumentation.targetContext.resources.displayMetrics.density
        assertEquals(26f * density, pose[3], 1f)
        val image = viewport.captureToImage().toPixelMap()
        var headDarkness = 0f
        var tailDarkness = 0f
        var tailInk = 0
        for (y in 0 until image.height) for (x in 0 until image.width) {
            val color = image[x, y]
            val darkness = 1 - (color.red + color.green + color.blue) / 3
            if (x < 4f * density) headDarkness = maxOf(headDarkness, darkness)
            if (x > image.width - 24f * density) {
                tailDarkness = maxOf(tailDarkness, darkness)
                if (darkness > .6f) tailInk++
            }
        }
        assertTrue("The beginning was clipped without the current Phone fade", headDarkness <= .25f)
        assertTrue("The last domain/port glyphs were faded or replaced", tailDarkness > .8f && tailInk >= 10)
        record("05-native-head-fade")
    }

    private fun assertChromeEdge(requested: Float) {
        var height = 0
        var tappable = 0
        var navigation = 0
        var mandatory = 0
        compose.runOnIdle {
            val decor = compose.activity.window.decorView
            height = decor.height
            val insets = checkNotNull(ViewCompat.getRootWindowInsets(decor))
            tappable = insets.getInsets(WindowInsetsCompat.Type.tappableElement()).bottom
            navigation = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            mandatory = insets.getInsets(WindowInsetsCompat.Type.mandatorySystemGestures()).bottom
        }
        val density = instrumentation.targetContext.resources.displayMetrics.density
        val capsule = compose.onNodeWithTag("browser.chrome.capsule", useUnmergedTree = true).fetchSemanticsNode().boundsInWindow
        val touch = compose.onNodeWithTag("browser.chrome.plate", useUnmergedTree = true).fetchSemanticsNode().boundsInWindow
        val minimumForTouch = tappable / density + (touch.height - capsule.height) / density / 2
        val expected = maxOf(requested, minimumForTouch)
        val actual = (height - capsule.bottom) / density
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/chrome-label").apply { mkdirs() }
        File(folder, "edge-${requested.toInt()}.json").writeText(JSONObject().put("windowHeightPx", height)
            .put("density", density).put("requestedScreenBottomDp", requested).put("actualScreenBottomDp", actual)
            .put("navigationBottomPx", navigation).put("tappableBottomPx", tappable).put("mandatoryGesturesBottomPx", mandatory)
            .put("capsule", JSONArray(listOf(capsule.left, capsule.top, capsule.width, capsule.height)))
            .put("touch", JSONArray(listOf(touch.left, touch.top, touch.width, touch.height)))
            .put("frameParityVerified", false).toString(2))
        assertEquals("Chrome added the navigation safe area to its screen-edge distance", expected, actual, 0.6f)
        assertTrue("Chrome's retained touch target overlaps system-owned navigation taps", touch.bottom <= height - tappable + 1)
    }

    private fun record(name: String) {
        compose.waitForIdle()
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/chrome-label").apply { mkdirs() }
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { File(folder, "$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        val roots = compose.onAllNodes(isRoot(), useUnmergedTree = true)
        File(folder, "$name-semantics.txt").writeText((0 until roots.fetchSemanticsNodes().size).joinToString("\n") { roots[it].printToString() })
        File(folder, "evidence.json").writeText("""{"kind":"native-chrome-label-stills","pageEngine":"explicit-fixture-fake","frameParityVerified":false,"physicalDeviceSmoothnessVerified":false}""")
    }
}

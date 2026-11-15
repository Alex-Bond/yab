package dev.yab.browser

import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.AppFlowTest
import dev.yab.android.BrowserSessionViewModel
import dev.yab.android.MainActivity
import dev.yab.android.NativeMainActivityFixture
import dev.yab.browser.model.*
import kotlinx.coroutines.runBlocking
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual Main + Gecko + local page. Original pixels, title geometry and real zoom actions. */
class PageMenuZoomLayoutDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val folder get() = File(context.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
    private fun shot(name: String) {
        compose.waitForIdle()
        val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { File(folder, "$name.png").outputStream().use { assertTrue(image.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { image.recycle() }
        File(folder, "$name.json").writeText("""{"kind":"actual-main-owned-emulator","realGecko":true,"fictionalLocalPage":true,"externalActions":false,"screen":"$name"}""")
    }
    @Test(timeout = 180_000) fun zoomSharesTheMenuTitleColumnAndKeepsItsThreeActions(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        OwnedLoopbackSiteSettings.reset()
        val path = File(context.filesDir, "browser.json")
        val prior = path.takeIf(File::exists)?.readBytes()
        try {
            AppFlowTest.LocalPage().use { page ->
                val tab = BrowserTab("zoom-page", page.url, "Local document", createdAt = 1)
                val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(tab), currentTabId = tab.id)
                FileBrowserRepository(path).save(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                    settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT)))
                NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                    NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                    lateinit var model: BrowserSessionViewModel
                    fixture.onActivity { host -> model = ViewModelProvider(host)[BrowserSessionViewModel::class.java] }
                    compose.waitUntil(60_000) { !model.browser.state.value.loading && !model.browser.state.value.page.loading &&
                        model.browser.state.value.page.title == "Android flow article" }
                    compose.onNodeWithContentDescription("Page menu").performTouchInput { click() }
                    compose.waitUntil(20_000) { compose.onAllNodesWithText("Page Zoom").fetchSemanticsNodes().size == 1 }
                    try {
                        compose.onNodeWithText("Page Zoom").performScrollTo().assertIsDisplayed()
                        shot("parity-page-menu.zoom-light")
                        var width = 0
                        fixture.onActivity { width = it.window.decorView.width }
                        // The inactive Site body is deliberately measured offscreen.
                        // Inspect the rendered menu title, not that hidden duplicate.
                        val inWindow = SemanticsMatcher("inside the original menu window") { node ->
                            node.boundsInRoot.width > 0 && node.boundsInRoot.left >= 0 && node.boundsInRoot.right <= width
                        }
                        val title = compose.onNode(hasText("Page Zoom") and inWindow, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                        val desktop = compose.onNode(hasText("Request Desktop Site") and inWindow, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                        File(folder, "page-menu-zoom-geometry.json").writeText(JSONObject()
                            .put("zoomTitleLeftPx", title.left).put("desktopTitleLeftPx", desktop.left).toString(2))
                        assertEquals("Page Zoom title must align with neighbouring menu titles", desktop.left, title.left, 1f)
                        val density = context.resources.displayMetrics.density
                        val stepper = compose.onNodeWithTag("browser.page.zoom.stepper").fetchSemanticsNode().boundsInRoot
                        assertEquals(120f * density, stepper.width, 1f)
                        assertEquals(38f * density, stepper.height, 1f)
                        assertTrue("Page Zoom title overlaps its controls", title.right <= stepper.left)
                        compose.onNodeWithContentDescription("Zoom In").performTouchInput { click() }
                        compose.waitUntil(20_000) { model.engine.sitePreferences(tab.id).zoom == 1.1 }
                        compose.onNodeWithContentDescription("Page Zoom 110 percent").assertExists()
                        shot("parity-page-menu.zoom-110")
                        compose.onNodeWithContentDescription("Page Zoom 110 percent").performTouchInput { click() }
                        compose.waitUntil(20_000) { model.engine.sitePreferences(tab.id).zoom == 1.0 }
                        compose.onNodeWithContentDescription("Zoom Out").performTouchInput { click() }
                        compose.waitUntil(20_000) { model.engine.sitePreferences(tab.id).zoom == .9 }
                        compose.onNodeWithContentDescription("Page Zoom 90 percent").assertExists()
                        fixture.onActivity {
                            assertEquals(tab.id, model.browser.state.value.tab?.id)
                            model.browser.updateSettings(model.browser.state.value.settings.copy(appearance = BrowserAppearance.DARK))
                        }
                        shot("parity-page-menu.zoom-dark")
                    } catch (failure: Throwable) {
                        runCatching { shot("diagnostic-page-menu.zoom") }
                        throw failure
                    }
                }
            }
        } finally { if (prior == null) path.delete() else path.writeBytes(prior) }
    }
}

package dev.yab.browser

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserScreen
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Public production rows and native pager gestures, with local inert pages. */
class FieldRowSwipeDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private fun shot(name: String) {
        compose.waitForIdle(); android.os.SystemClock.sleep(300)
        val i = InstrumentationRegistry.getInstrumentation()
        val folder = File(i.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val image = checkNotNull(i.uiAutomation.takeScreenshot())
        File(folder, "parity-$name.png").outputStream().use { assertTrue(image.compress(Bitmap.CompressFormat.PNG, 100, it)) }; image.recycle()
        File(folder, "parity-$name.json").writeText("""{"kind":"production-component-fixture","reference":"iphone-0.1.13","screen":"$name","pageEngine":"inert","externalActions":false}""")
    }
    @Test fun interiorRevealsActionsWhileTheEdgePagesAndVerticalMovementStillScrolls() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val document = BrowserTab("docs", "https://example.test/docs", "Planning the next week", createdAt = 1)
        val originalPins = (1..4).map { BrowserTab(id = "pin-$it", url = "https://example.test/pin-$it",
            title = "Original pin $it", place = TabPlace.PINNED, createdAt = it.toLong()) }
        val personal = BrowserSpace("personal", "Personal", tabs = originalPins + listOf(document) + (1..18).map {
            BrowserTab("page-$it", "https://example.test/$it", "A useful page $it", createdAt = it.toLong() + 1)
        }, currentTabId = document.id)
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
        val browser = BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(personal, BrowserSpace("work", "Work")), selectedSpaceId = personal.id,
                settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT))
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope)
        try {
            compose.setContent { BrowserScreen(browser, pageContent = { _, _, modifier -> Box(modifier) }) }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.runOnIdle { browser.show(BrowserSurface.SPACES) }
            val row = compose.onNodeWithTag("browser.row.swipe.docs")
            row.assertExists(); shot("spaces.page")
            row.performTouchInput { swipe(center, center + Offset(width * .35f, 0f), 450) }
            compose.onNodeWithTag("browser.row.action.docs.keep").assertExists()
            assertEquals(personal.id, browser.state.value.selectedSpaceId)
            assertEquals(TabPlace.TODAY, browser.state.value.space!!.tabs.single { it.id == document.id }.place)
            shot("spaces.swipe-keep")
            compose.onNodeWithTag("browser.row.action.docs.keep").performTouchInput { click() }
            compose.waitUntil(10_000) { browser.state.value.space!!.tabs.single { it.id == document.id }.place == TabPlace.KEPT }
            // Finish the row's placement before beginning the opposite gesture.
            compose.mainClock.advanceTimeBy(600)
            compose.waitForIdle()
            row.assertIsDisplayed()
            shot("spaces.kept")
            row.performTouchInput { swipe(center, center - Offset(width * .35f, 0f), 450) }
            compose.onNodeWithTag("browser.row.action.docs.close").assertExists()
            shot("spaces.swipe-close")
            // Tapping the shifted row first closes its actions, without opening the page.
            row.performTouchInput { click(Offset(width * .3f, height * .5f)) }
            compose.onNodeWithTag("browser.row.action.docs.close").assertDoesNotExist()
            assertEquals(BrowserSurface.SPACES, browser.state.value.surface)
            // Current iPhone actions: Pin moves the original row to the grid;
            // its actual hold menu returns the pin to the top of Today.
            row.performTouchInput { swipe(center, center + Offset(width * .35f, 0f), 450) }
            compose.onNodeWithTag("browser.row.action.docs.pin").assertExists()
            shot("spaces.swipe-pin")
            compose.onNodeWithTag("browser.row.action.docs.pin").performClick()
            compose.waitUntil(10_000) { browser.state.value.space!!.tabs.single { it.id == document.id }.place == TabPlace.PINNED }
            row.assertDoesNotExist()
            compose.onNodeWithTag("browser.pin.docs").assertIsDisplayed()
            assertEquals(5, browser.state.value.space!!.tabs.count { it.place == TabPlace.PINNED })
            shot("spaces.pinned")
            compose.onNodeWithTag("browser.pin.docs").performTouchInput { longClick() }
            shot("spaces.pin-hold")
            compose.onNodeWithText("Move to Space", substring = false).performClick()
            compose.onNodeWithTag("browser.tab.move.work").assertIsDisplayed()
            shot("spaces.pin-move")
            compose.onNodeWithText("Back", substring = false).performClick()
            compose.onNodeWithText("Unpin", substring = false).performClick()
            compose.waitUntil(10_000) { browser.state.value.space!!.tabs.single { it.id == document.id }.place == TabPlace.TODAY }
            originalPins.forEach { pin ->
                assertEquals(TabPlace.PINNED, browser.state.value.space!!.tabs.single { it.id == pin.id }.place)
                compose.onNodeWithTag("browser.pin.${pin.id}").assertIsDisplayed()
            }
            compose.onNodeWithTag("browser.pin.docs").assertDoesNotExist()
            row.assertIsDisplayed()
            shot("spaces.unpinned")
            // A vertical pan beginning in a row remains the list's own scrolling gesture.
            compose.onNodeWithTag("browser.row.swipe.page-1").performTouchInput { swipe(center, center - Offset(0f, 180f), 450) }
            assertEquals(personal.id, browser.state.value.selectedSpaceId)
            compose.onNodeWithTag("browser.row.action.page-1.close").assertDoesNotExist()
            compose.onNodeWithTag("browser.row.swipe.page-2").performScrollTo().performTouchInput {
                swipe(center, center - Offset(width * .85f, 0f), 600)
            }
            compose.waitUntil(10_000) { browser.state.value.space!!.tabs.none { it.id == "page-2" } }
            shot("spaces.full-close")
            // The outer 28 points remain the native pager's touch area.
            compose.onNodeWithTag("browser.field.pages").performTouchInput {
                swipe(Offset(width - 8f, height * .5f), Offset(width * .25f, height * .5f), 450)
            }
            compose.waitUntil(10_000) { browser.state.value.selectedSpaceId == "work" }
            assertNotNull(browser.state.value.spaces.single { it.id == personal.id }.tabs.singleOrNull { it.id == document.id })
            shot("spaces.edge-page")
        } finally { scope.cancel() }
    }
}

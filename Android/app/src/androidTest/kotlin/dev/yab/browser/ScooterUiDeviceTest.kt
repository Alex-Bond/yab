package dev.yab.browser

import android.content.Intent
import android.graphics.Bitmap
import android.os.SystemClock
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
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Same actual Main/Gecko route on both retained baseline and current app; no account or OS grants. */
class ScooterUiDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val i get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = i.targetContext
    private fun shot(name: String) {
        compose.waitForIdle(); SystemClock.sleep(450)
        val folder = File(context.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(i.uiAutomation.takeScreenshot())
        try { File(folder, "scooter-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        File(folder, "scooter-$name.json").writeText("""{"kind":"actual-main-owned-emulator","realGecko":true,"fictionalLocalPage":true,"realMac":false,"osPermissionsChanged":false}""")
    }
    private fun awaitText(title: String) { compose.waitUntil(30_000) { compose.onAllNodesWithText(title).fetchSemanticsNodes().isNotEmpty() } }
    private fun click(title: String) { compose.onNodeWithText(title).performScrollTo().performTouchInput { click() } }
    @Test(timeout = 240_000) fun baselineBeforeScooter() = run(false)
    @Test(timeout = 240_000) fun currentScooterMenusHistoryAndSettings() = run(true)
    private fun run(checkUi: Boolean): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        OwnedLoopbackSiteSettings.reset()
        val file = File(context.filesDir, "browser.json"); val prior = file.takeIf(File::exists)?.readBytes()
        try {
            AppFlowTest.LocalPage().use { page ->
                val tab = BrowserTab("scooter-page", page.url, "Local document", createdAt = 1)
                val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(tab), currentTabId = tab.id)
                FileBrowserRepository(file).save(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                    settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT),
                    history = listOf(BrowserVisit(page.url, "Local article", System.currentTimeMillis()))))
                NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                    NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                    lateinit var model: BrowserSessionViewModel
                    fixture.onActivity { model = ViewModelProvider(it)[BrowserSessionViewModel::class.java] }
                    compose.waitUntil(60_000) { !model.browser.state.value.loading && !model.browser.state.value.page.loading &&
                        model.browser.state.value.page.title == "Android flow article" }
                    fun openMenu() {
                        compose.onNodeWithContentDescription("Page menu").performTouchInput { click() }
                        awaitText("Page Zoom")
                    }
                    fun openSettings() {
                        fixture.onActivity { host -> host.startActivity(Intent(context, MainActivity::class.java)
                            .setAction(Intent.ACTION_VIEW).setData(android.net.Uri.parse("yab://new")).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)) }
                        compose.waitUntil(30_000) { compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes().size == 1 }
                        compose.onNodeWithContentDescription("Settings", useUnmergedTree = true).performTouchInput { click() }
                        compose.waitUntil(30_000) { compose.onAllNodesWithTag("settings.search").fetchSemanticsNodes().size == 1 }
                    }
                    try {
                        openMenu(); shot("menu-light")
                        if (checkUi) {
                            compose.onNodeWithTag("page.menu.tile.Find on Page").assertExists()
                            compose.onNodeWithText("Reader").assertExists()
                            compose.onNodeWithText("Copy", substring = false).assertDoesNotExist()
                            compose.onNodeWithContentDescription("Zoom In").performTouchInput { click() }
                            compose.waitUntil(20_000) { model.engine.sitePreferences(tab.id).zoom == 1.1 }
                            compose.onNodeWithContentDescription("Page Zoom 110 percent").performTouchInput { click() }
                            compose.waitUntil(20_000) { model.engine.sitePreferences(tab.id).zoom == 1.0 }
                        }
                        click("Site Settings"); awaitText("Request Desktop Site"); shot("site-light")
                        if (checkUi) compose.onNodeWithText("Not secure").assertExists()
                        click("Yab Settings")
                        compose.waitUntil(30_000) { compose.onAllNodesWithTag("settings.search").fetchSemanticsNodes().size == 1 }
                        click("General"); awaitText("Default Browser"); shot("general-light")
                        if (checkUi) {
                            compose.onNodeWithText("Notifications").assertExists()
                            compose.onNodeWithText("Choose Yab in Android settings").assertDoesNotExist()
                            val roles = context.getSystemService(android.app.role.RoleManager::class.java)
                            val value = if (roles == null || !roles.isRoleAvailable(android.app.role.RoleManager.ROLE_BROWSER)) "Unavailable"
                                else if (roles.isRoleHeld(android.app.role.RoleManager.ROLE_BROWSER)) "Yab" else "Not Yet"
                            compose.onNodeWithText(value, substring = false).assertExists()
                            val settingIntent = Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
                            val systemPackage = checkNotNull(context.packageManager.resolveActivity(settingIntent,
                                android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)).activityInfo.packageName
                            assertNotEquals(context.packageName, systemPackage)
                            compose.onNodeWithText("Notifications").performTouchInput { click() }
                            val deadline = SystemClock.elapsedRealtime() + 15_000
                            var settingsWindow: Int? = null
                            while (settingsWindow == null && SystemClock.elapsedRealtime() < deadline) {
                                val root = i.uiAutomation.rootInActiveWindow
                                if (root != null) try {
                                    if (root.packageName?.toString() == systemPackage) settingsWindow = root.windowId
                                } finally { root.recycle() }
                                if (settingsWindow == null) SystemClock.sleep(30)
                            }
                            assertNotNull("The notification action must open the resolved Android Settings", settingsWindow)
                            val root = checkNotNull(i.uiAutomation.rootInActiveWindow)
                            try {
                                check(root.packageName?.toString() == systemPackage && root.windowId == settingsWindow)
                                check(i.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK))
                            } finally { root.recycle() }
                            fixture.onActivity { assertEquals(tab.id, model.browser.state.value.tab?.id) }
                            compose.onNodeWithText("Notifications").assertExists()
                            val priorSwipe = model.browser.state.value.settings.swipeAnywhere
                            compose.onNodeWithText("Swipe from Anywhere").performTouchInput { click() }
                            compose.waitUntil(10_000) { model.browser.state.value.settings.swipeAnywhere != priorSwipe }
                            compose.onNodeWithText("Swipe from Anywhere").performTouchInput { click() }
                            compose.waitUntil(10_000) { model.browser.state.value.settings.swipeAnywhere == priorSwipe }
                            shot("general-return-from-system")
                        }
                        compose.onNodeWithContentDescription("Back").performTouchInput { click() }
                        click("History"); compose.waitUntil(30_000) { model.browser.state.value.surface == BrowserSurface.HISTORY }; shot("history-light")
                        compose.onNodeWithTag("history.search").performTextReplacement("nothing-to-match-scooter")
                        compose.onNodeWithText("No pages found").assertExists()
                        if (checkUi) {
                            val field = compose.onNodeWithTag("history.search").fetchSemanticsNode().boundsInRoot
                            val empty = compose.onNodeWithTag("history.search.empty").fetchSemanticsNode().boundsInRoot
                            val density = context.resources.displayMetrics.density
                            assertTrue("No-results text must follow search, not sit in the middle of the screen",
                                empty.top >= field.bottom && empty.top - field.bottom < 100 * density)
                        }
                        shot("history-search-empty")
                        fixture.onActivity {
                            assertEquals(tab.id, model.browser.state.value.tab?.id)
                            model.browser.updateSettings(model.browser.state.value.settings.copy(appearance = BrowserAppearance.DARK))
                        }
                        compose.onNodeWithTag("history.search.clear").performTouchInput { click() }
                        shot("history-dark")
                        if (checkUi) {
                            compose.onNodeWithTag("history.clear").performTouchInput { click() }
                            awaitText("Clear History?"); shot("history-clear-dark")
                            compose.onNodeWithText("Cancel").performTouchInput { click() }
                            assertTrue(model.browser.state.value.history.isNotEmpty())
                            compose.onNodeWithTag("history.clear").performTouchInput { click() }
                            compose.onNodeWithTag("history.clear.ALL_TIME").performTouchInput { click() }
                            compose.waitUntil(20_000) { model.browser.state.value.history.isEmpty() }
                            awaitText("No History"); shot("history-empty-dark")
                        }
                        compose.onNodeWithContentDescription("Back").performTouchInput { click() }
                        openSettings()
                        click("General"); awaitText("Default Browser"); shot("general-dark")
                        compose.onNodeWithContentDescription("Back").performTouchInput { click() }
                        compose.onNodeWithContentDescription("Close").performTouchInput { click() }
                        // Close the Field and return to its retained local page without selecting another tab.
                        fixture.onActivity { model.browser.show(BrowserSurface.PAGE) }
                        compose.waitUntil(20_000) { compose.onAllNodesWithContentDescription("Page menu").fetchSemanticsNodes().size == 1 }
                        openMenu(); shot("menu-dark")
                        click("Site Settings"); awaitText("Request Desktop Site"); shot("site-dark")
                    } catch (failure: Throwable) { runCatching { shot("diagnostic") }; throw failure }
                }
            }
        } finally { if (prior == null) file.delete() else file.writeBytes(prior) }
    }
}

package dev.yab.android

import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class SettingsSearchDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test(timeout = 120_000)
    fun aSettingSearchOpensTheDestinationAndKeepsItsActionUntouched(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val blank = BrowserTab("settings-search-empty", createdAt = 1)
        FileBrowserRepository(File(context.filesDir, "browser.json")).save(BrowserSnapshot(
            spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(blank), currentTabId = blank.id)),
            selectedSpaceId = BrowserController.PERSONAL_SPACE, settings = BrowserSettings(welcomed = true)))
        ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java)).use { scenario ->
            compose.waitUntil(30_000) { compose.onAllNodesWithContentDescription("Page menu").fetchSemanticsNodes().isNotEmpty() }
            scenario.onActivity { host -> ViewModelProvider(host)[BrowserSessionViewModel::class.java].browser.show(BrowserSurface.SETTINGS) }
            compose.waitUntil(20_000) { compose.onAllNodesWithTag("settings.search").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("settings.search").performTextInput("website data")
            compose.onNodeWithTag("settings.search.result.PRIVACY.privacy.clearData").performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithText("Clear History and Website Data").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Clear History and Website Data").assertIsDisplayed()
            // A result is a destination, never a proxy click on a destructive row.
            compose.onNodeWithText("Clear History and Website Data?").assertDoesNotExist()
            scenario.onActivity { host ->
                val state = ViewModelProvider(host)[BrowserSessionViewModel::class.java].browser.state.value
                assertEquals(BrowserSurface.SETTINGS, state.surface)
                assertTrue(state.settings.lockPrivate)
                assertEquals(blank.id, state.tab?.id)
            }
            // This is the active preference's navigation, not the covered browser toolbar.
            compose.onNode(hasContentDescription("Back") and hasAnyAncestor(hasTestTag("settings.header"))).assertIsEnabled().performClick()
            compose.onNodeWithTag("settings.search").assertTextContains("website data")
            compose.onNodeWithContentDescription("Clear search").performClick()
            assertEquals("", compose.onNodeWithTag("settings.search").fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            compose.onNodeWithTag("settings.search").performTextInput("daily")
            compose.onNodeWithTag("settings.search.empty").assertIsDisplayed()
        }
    }
}

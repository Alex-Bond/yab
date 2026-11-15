package dev.yab.browser

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Production Field and Controller with local fixture data and a recording engine; no web request. */
class GoogleFieldSurfaceDeviceTest {
    @get:Rule val compose = createComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun shot(name: String) {
        compose.waitForIdle(); SystemClock.sleep(450)
        val dir = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { File(dir, "field-fixture-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        File(dir, "field-fixture-$name.json").writeText("""{"kind":"controlled-component-fixture","productionField":true,"productionController":true,"realGecko":false,"realMac":false,"networkRequests":false,"privateScreenshotBypass":false}""")
    }
    @Test(timeout = 100_000) fun googleWordsDraftAndReturnFollowTheSameChosenPrimaryAction() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("google-ui", "https://www.google.com/search?q=lisbon+weather", "Search result", createdAt = 1)
        val another = BrowserTab("coffee-ui", "https://coffee.example/", "Quiet coffee", createdAt = 2)
        val space = BrowserSpace("personal", "Personal", tabs = listOf(tab, another), currentTabId = tab.id)
        val snapshot = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
            settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT),
            history = listOf(BrowserVisit("https://archive.example/coffee", "Coffee archive", System.currentTimeMillis())))
        val opened = mutableListOf<String>()
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { opened += url }
            override fun goBack(tabId: String) {}; override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}; override fun stop(tabId: String) {}; override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        lateinit var browser: BrowserController
        try {
            compose.runOnIdle { browser = BrowserController(object : BrowserRepository {
                override suspend fun load() = snapshot
                override suspend fun save(snapshot: BrowserSnapshot) {}
            }, engine, scope) }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.setContent { BrowserScreen(browser, onAskQuestion = { _, _ -> }) { _, _, modifier -> Box(modifier.fillMaxSize()) { Text("Controlled page") } } }
            compose.runOnIdle { browser.openField(newTab = false) }
            compose.waitUntil(10_000) { compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes().size == 1 }
            val field = compose.onNodeWithTag("browser.field.input")
            field.assertTextContains("lisbon weather")
            compose.onNodeWithTag("browser.field.favicon").assertDoesNotExist()
            compose.onNodeWithTag("browser.field.search-glyph").assertExists(); shot("google-edit")
            field.performTextReplacement("quiet coffee")
            shot("search-draft")
            compose.onNodeWithTag("browser.field.close").performTouchInput { click() }
            compose.waitUntil(10_000) { browser.state.value.surface != BrowserSurface.FIELD }
            compose.runOnIdle { browser.openField(newTab = false) }
            compose.onNodeWithTag("browser.field.input").assertTextContains("quiet coffee")
            compose.onNode(hasText("quiet coffee") and hasClickAction() and hasAnyAncestor(hasTestTag("browser.field.rows")))
                .performTouchInput { click() }
            compose.waitUntil(10_000) { browser.state.value.surface == BrowserSurface.PAGE }
            val byRow = browser.state.value.tab?.url
            assertEquals("google-ui", browser.state.value.tab?.id)
            assertEquals("https://www.google.com/search?q=quiet%20coffee", byRow)
            compose.runOnIdle { browser.openField(newTab = false) }
            compose.onNodeWithTag("browser.field.input").performTextReplacement("quiet coffee")
            compose.onNodeWithTag("browser.field.input").performImeAction()
            compose.waitUntil(10_000) { browser.state.value.surface == BrowserSurface.PAGE }
            // As on Phone fieldReturn, Return chooses the highlighted open tab, not the secondary search row.
            assertEquals(another.url, browser.state.value.tab?.url); assertEquals(another.id, browser.state.value.tab?.id)
            compose.runOnIdle { browser.selectTab(tab.id); browser.openField(newTab = false) }
            compose.onNodeWithTag("browser.field.input").performTextReplacement("river weather today")
            compose.waitForIdle(); SystemClock.sleep(450)
            compose.onNode(hasText("river weather today") and hasClickAction() and hasAnyAncestor(hasTestTag("browser.field.rows")))
                .performTouchInput { click() }
            compose.waitUntil(10_000) { browser.state.value.surface == BrowserSurface.PAGE }
            val searchByTap = browser.state.value.tab?.url
            assertEquals("https://www.google.com/search?q=river%20weather%20today", searchByTap)
            compose.runOnIdle { browser.openField(newTab = false) }
            compose.onNodeWithTag("browser.field.input").performTextReplacement("river weather today")
            compose.onNodeWithTag("browser.field.input").performImeAction()
            compose.waitUntil(10_000) { browser.state.value.surface == BrowserSurface.PAGE }
            assertEquals(searchByTap, browser.state.value.tab?.url); assertEquals(tab.id, browser.state.value.tab?.id)
            compose.runOnIdle { browser.openField(newTab = false) }
            compose.onNodeWithTag("browser.field.input").performTextReplacement("coffee"); shot("tabs-and-history")
            compose.onNodeWithTag("browser.field.input").performTextReplacement("12 * 7"); shot("calculator")
            compose.onNodeWithTag("browser.field.input").performTextReplacement("Where should I go in Lisbon?"); shot("question")
            compose.onNodeWithTag("browser.field.input").performTextReplacement("https://example.com/article"); shot("url")
            compose.runOnIdle { assertTrue(opened.size >= 2); assertEquals(2, browser.state.value.space?.tabs?.size) }
        } finally { compose.runOnIdle { scope.cancel() } }
    }
}

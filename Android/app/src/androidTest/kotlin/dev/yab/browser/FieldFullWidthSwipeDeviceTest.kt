package dev.yab.browser

import androidx.compose.foundation.layout.Box
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import dev.yab.android.EngineTestActivity
import dev.yab.agent.FieldChatDeleteQuestion
import dev.yab.agent.FieldChatsPage
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserScreen
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Exercise production pager and row dispatch without changing their gesture ownership. */
class FieldFullWidthSwipeDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()

    @Test fun emptyAreaChatsAndRowEdgesPageWhileRowMiddleKeepsItsActions() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("docs", "https://example.test/docs", "Document", createdAt = 1)
        val personal = BrowserSpace("personal", "Personal", tabs = listOf(tab), currentTabId = tab.id)
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
            override suspend fun load() = BrowserSnapshot(
                spaces = listOf(personal, BrowserSpace("work", "Work")), selectedSpaceId = personal.id,
                settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT))
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope)
        try {
            compose.setContent {
                BrowserScreen(browser, fieldChatsContent = { modifier, enabled ->
                    FieldChatsPage(chats = emptyList(), query = "", archived = false, sourceKey = Unit,
                        enabled = enabled, current = { true }, onSelect = {}, onNewChat = {}, onArchive = {},
                        canAct = { _, _ -> false }, onAction = {},
                        deleteQuestion = { FieldChatDeleteQuestion("Delete Chat") }, modifier = modifier)
                }, pageContent = { _, _, modifier -> Box(modifier) })
            }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.runOnIdle { browser.show(BrowserSurface.SPACES) }
            val pages = compose.onNodeWithTag("browser.field.pages")
            val row = compose.onNodeWithTag("browser.row.swipe.docs")
            row.assertIsDisplayed()
            row.performTouchInput { swipe(center, center - Offset(width * .3f, 0f), 450) }
            compose.onNodeWithTag("browser.row.action.docs.close").assertExists()
            assertEquals(personal.id, browser.state.value.selectedSpaceId)
            // A tap on the shifted content dismisses actions without opening the tab.
            row.performTouchInput { click(Offset(width * .3f, height * .5f)) }
            compose.onNodeWithTag("browser.row.action.docs.close").assertDoesNotExist()
            assertEquals(BrowserSurface.SPACES, browser.state.value.surface)

            fun swipeAtRowEdge(fromRight: Boolean) {
                val pageBounds = pages.fetchSemanticsNode().boundsInRoot
                val y = row.fetchSemanticsNode().boundsInRoot.center.y - pageBounds.top
                val inset = 14f * compose.activity.resources.displayMetrics.density
                pages.performTouchInput {
                    val start = if (fromRight) width - inset else inset
                    val end = if (fromRight) width * .2f else width * .8f
                    swipe(Offset(start, y), Offset(end, y), 450)
                }
            }
            swipeAtRowEdge(true)
            compose.waitUntil(10_000) { browser.state.value.selectedSpaceId == "work" }
            compose.waitForIdle()
            // Return from the empty Work page, starting well inside both edge strips.
            pages.performTouchInput {
                swipe(Offset(width * .25f, height * .65f), Offset(width * .8f, height * .65f), 450)
            }
            compose.waitUntil(10_000) { browser.state.value.selectedSpaceId == personal.id }
            compose.waitForIdle()
            val bounds = pages.fetchSemanticsNode().boundsInRoot
            val bottom = row.fetchSemanticsNode().boundsInRoot.bottom - bounds.top
            val y = bottom + 40f * compose.activity.resources.displayMetrics.density
            assertTrue("Start below the actual list row", y < bounds.height - 40f)
            pages.performTouchInput {
                swipe(Offset(width * .75f, y), Offset(width * .2f, y), 450)
            }
            compose.waitUntil(10_000) { browser.state.value.selectedSpaceId == "work" }
            compose.waitForIdle()
            pages.performTouchInput {
                swipe(Offset(width * .25f, height * .65f), Offset(width * .8f, height * .65f), 450)
            }
            compose.waitUntil(10_000) { browser.state.value.selectedSpaceId == personal.id }
            compose.waitForIdle()
            swipeAtRowEdge(false)
            compose.onNodeWithTag("newtab.chats").assertIsDisplayed()
            compose.onNodeWithTag("newtab.chats").performTouchInput {
                swipe(Offset(width * .75f, height * .5f), Offset(width * .2f, height * .5f), 450)
            }
            row.assertIsDisplayed()
            compose.onNodeWithTag("newtab.chats").assertDoesNotExist()
            assertEquals(personal.id, browser.state.value.selectedSpaceId)
            assertEquals(TabPlace.TODAY, browser.state.value.space!!.tabs.single().place)
        } finally { scope.cancel() }
    }
}

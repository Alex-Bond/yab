package dev.yab.android

import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Uses the actual retained app, without a fabricated AI answer or a remote provider. */
class ParkedChatDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test(timeout = 120_000)
    fun quickAnswerLineSurvivesRecreationRestoresAndLetsGo(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val blank = BrowserTab("parked-empty", createdAt = 1)
        FileBrowserRepository(File(context.filesDir, "browser.json")).save(BrowserSnapshot(
            spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(blank), currentTabId = blank.id)),
            selectedSpaceId = BrowserController.PERSONAL_SPACE, settings = BrowserSettings(welcomed = true)))
        NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java), NativeMainActivityFixture.Kind.PARKED_CHAT).use { scenario ->
            compose.waitUntil(30_000) { compose.onAllNodesWithContentDescription("Page menu").fetchSemanticsNodes().isNotEmpty() }
            var chat = ""
            scenario.onActivity { host ->
                host.startActivity(Intent(host, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
                    .setData(android.net.Uri.parse("yab://ask")).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
            }
            compose.waitUntil(20_000) { compose.onAllNodesWithTag("chat.header").fetchSemanticsNodes().isNotEmpty() }
            scenario.onActivity { host -> chat = ViewModelProvider(host)[BrowserSessionViewModel::class.java].agent.newChat(ephemeral = true) }
            compose.waitUntil(20_000) { compose.onAllNodesWithContentDescription("More").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("More").performClick()
            compose.onNodeWithText("Hide Chat").performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithText("Now").fetchSemanticsNodes().isNotEmpty() }
            scenario.recreate()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Now").fetchSemanticsNodes().isNotEmpty() }
            scenario.onActivity { host -> assertEquals(chat, ViewModelProvider(host)[BrowserSessionViewModel::class.java].parkedChats.state.value?.chat) }
            compose.onNodeWithText("Now").performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithContentDescription("More").fetchSemanticsNodes().isNotEmpty() }
            scenario.onActivity { host -> assertEquals(chat, ViewModelProvider(host)[BrowserSessionViewModel::class.java].agent.state.value.current?.id) }
            compose.onNodeWithContentDescription("More").performClick()
            compose.onNodeWithText("Hide Chat").performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithContentDescription("Let Go").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Let Go").performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithText("Now").fetchSemanticsNodes().isEmpty() }
            scenario.onActivity { host -> assertTrue(ViewModelProvider(host)[BrowserSessionViewModel::class.java].agent.state.value.chats.none { it.id == chat }) }
        }
    }
}

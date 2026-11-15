package dev.yab.android

import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.agent.*
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserScreen
import dev.yab.browser.ui.BrowserTheme
import dev.yab.sync.AccountRecordsSnapshot
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Full inline consumer with controlled account publications and an in-memory chat store.
 * This proves UI routing/retired callbacks, not real Sync/provider or presented-frame cadence. */
class FieldChatsHostDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()

    @Test fun fieldArchiveUsesTheRealHostAndAnOldButtonCannotToggleAPrivateField() = fixture { f ->
        enterChats(f)
        compose.onNodeWithContentDescription("Show Archived Chats").performClick()
        compose.onNodeWithText("Archived", substring = false).assertExists()
        compose.onNodeWithContentDescription("Show Chats").performClick()
        compose.onNodeWithTag("newtab.chat.alpha").assertExists()
        val retained = dev.yab.browser.originalRenderedClick(compose.onNodeWithTag("browser.field.archive").fetchSemanticsNode())
        compose.runOnIdle { f.browser.openField(privately = true) }
        compose.waitForIdle()
        compose.runOnIdle {
            retained()
            assertTrue(f.browser.state.value.fieldIsPrivate)
            assertEquals(0, f.inferenceCalls)
            assertEquals(0, f.remoteCalls)
        }
        compose.onNodeWithTag("browser.field.archive").assertDoesNotExist()
        compose.onNodeWithText("PRIVATE-CHAT-CANARY").assertDoesNotExist()
    }

    @Test fun originalFieldQueryOpensItsActualPublicChatWithoutStartingAnyAgent() = fixture { f ->
        enterChats(f)
        compose.onNodeWithText("PRIVATE-CHAT-CANARY").assertDoesNotExist()
        compose.onNodeWithTag("browser.field.input").performTextReplacement("answerneedle")
        compose.onNodeWithTag("newtab.chat.alpha").assertIsDisplayed()
        compose.onNodeWithTag("newtab.chat.beta").assertDoesNotExist()
        compose.onNodeWithTag("newtab.chat.alpha").performClick()
        compose.runOnIdle {
            assertEquals("alpha", f.opened?.id)
            assertEquals("alpha", f.agent.state.value.current?.id)
            assertEquals(BrowserSurface.PAGE, f.browser.state.value.surface)
            assertEquals(0, f.inferenceCalls)
            assertEquals(0, f.remoteCalls)
        }
    }

    @Test fun retainedRenameCannotCrossSameAccountReconnectOrReviveAfterAccountABA() = fixture { f ->
        enterChats(f)
        openRename()
        compose.onNode(hasSetTextAction() and hasText("Fixture Alpha")).performTextReplacement("Stale rename")
        val oldConfirm = dev.yab.browser.originalRenderedClick(compose.onNodeWithText("Rename", substring = false).fetchSemanticsNode())
        compose.runOnIdle { f.accounts.value = f.accounts.value.copy(epoch = 8); f.connection.value = f.connection.value.copy(epoch = 8) }
        compose.waitForIdle()
        compose.runOnIdle { oldConfirm() }
        assertEquals("Fixture Alpha", f.agent.state.value.chats.single { it.id == "alpha" }.title)
        compose.runOnIdle { f.accounts.value = f.accounts.value.copy(epoch = 7); f.connection.value = f.connection.value.copy(epoch = 7) }
        compose.waitForIdle()
        compose.runOnIdle { oldConfirm() }
        assertEquals("Fixture Alpha", f.agent.state.value.chats.single { it.id == "alpha" }.title)
        openRename()
        compose.onNode(hasSetTextAction() and hasText("Fixture Alpha")).performTextReplacement("Current rename")
        compose.onNodeWithText("Rename", substring = false).performClick()
        compose.waitUntil(5000) { f.agent.state.value.chats.single { it.id == "alpha" }.title == "Current rename" }
        compose.runOnIdle { assertEquals(0, f.inferenceCalls); assertEquals(0, f.remoteCalls) }
    }

    private fun openRename() {
        compose.onNodeWithTag("newtab.chat.alpha").performTouchInput { longClick() }
        compose.onNodeWithText("Rename Chat…", substring = false).performClick()
    }
    private fun enterChats(f: Fixture) {
        compose.runOnIdle { f.browser.openField() }
        compose.onNodeWithContentDescription("Chats").performClick()
        compose.onNodeWithTag("newtab.chats").assertIsDisplayed()
    }

    private class Fixture(val scope: CoroutineScope) {
        val accounts = MutableStateFlow(AccountRecordsSnapshot(account = "fixture-account", device = "fixture-phone", epoch = 7))
        val connection = MutableStateFlow(RemoteConnection(account = "fixture-account", epoch = 7))
        var inferenceCalls = 0
        var remoteCalls = 0
        var opened: AgentChat? = null
        private val transport = object : RemoteAgentTransport {
            override val connection get() = this@Fixture.connection
            override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
            override suspend fun send(command: AgentSendCommand): AgentSendReceipt { remoteCalls++; error("No remote inference is authorized by this fixture") }
            override suspend fun stop(owner: RemoteOwner) { remoteCalls++; error("No remote mutation in this local fixture") }
            override suspend fun delete(owner: RemoteOwner) { remoteCalls++; error("No remote mutation in this local fixture") }
            override suspend fun answerApproval(answer: ApprovalAnswer) { remoteCalls++; error("No approval in this fixture") }
        }
        private var saved = ChatSnapshot(chats = listOf(
            AgentChat("alpha", "Fixture Alpha", messages = listOf(AgentMessage("answer-alpha", MessageRole.ASSISTANT, "answerneedle", 1)), updatedAt = 3),
            AgentChat("beta", "Fixture Beta", updatedAt = 2)))
        val agent = AgentRepository(object : ChatPersistence {
            override suspend fun load() = saved
            override suspend fun save(snapshot: ChatSnapshot) { saved = snapshot }
        }, object : LocalAiAdapter {
            override suspend fun answer(question: LocalQuestion): String { inferenceCalls++; error("Opening a list must not start inference") }
        }, transport)
        private val tab = BrowserTab("inline-page", "about:blank", "New tab", createdAt = 1L)
        private val space = BrowserSpace("inline-space", "Personal", tabs = listOf(tab), currentTabId = tab.id)
        val browser = BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)
            override suspend fun save(snapshot: BrowserSnapshot) = Unit
        }, object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) = Unit
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) = Unit
            override fun goBack(tabId: String) = Unit
            override fun goForward(tabId: String) = Unit
            override fun reload(tabId: String) = Unit
            override fun stop(tabId: String) = Unit
            override fun close(tabId: String) = Unit
            override suspend fun clearWebsiteData(profileIds: Set<String>) = Unit
        }, scope)
    }
    private fun fixture(body: (Fixture) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        lateinit var f: Fixture
        compose.runOnIdle {
            f = Fixture(scope)
            runBlocking {
                f.agent.load()
                f.agent.setPrivacy(true)
                val privateChat = f.agent.newChat()
                f.agent.rename(privateChat, "PRIVATE-CHAT-CANARY")
                f.agent.setPrivacy(false)
            }
        }
        compose.waitUntil(5000) { !f.browser.state.value.loading }
        compose.setContent {
            BrowserTheme(BrowserAppearance.LIGHT) {
                BrowserScreen(f.browser, fieldChatsContent = { modifier, enabled ->
                    FieldChatsHost(f.browser, f.agent, f.accounts, f.connection, enabled, modifier) {
                        f.opened = it; f.browser.dismissSurface()
                    }
                }) { _, _, _ -> }
            }
        }
        try { body(f) }
        finally { compose.runOnIdle { scope.cancel() } }
    }
}

package dev.yab.agent

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import dev.yab.core.sync.Record
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Native consumer controls and retained projection, using clearly isolated owned wire fixtures. */
@RunWith(AndroidJUnit4::class)
class ChatScreenTest {
    @get:Rule val compose = createComposeRule()
    @Test fun ownerAwareActionsTypedCardsAndReadingSurviveSnapshotRefresh() {
        val remote = object : RemoteAgentTransport {
            override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, setOf(AgentProvider.CLAUDE)))))
            override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
            override suspend fun send(command: AgentSendCommand) = AgentSendReceipt(command.owner)
            override suspend fun stop(owner: RemoteOwner) {}
            override suspend fun delete(owner: RemoteOwner) {}
            override suspend fun answerApproval(answer: ApprovalAnswer) {}
        }
        val memory = object : ChatPersistence {
            var snapshot = ChatSnapshot()
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: ChatSnapshot) { this.snapshot = snapshot }
        }
        val repository = AgentRepository(memory, UnavailableLocalAiAdapter(), remote)
        val owner = RemoteOwner("account", "mac", "a:native", AgentProvider.CLAUDE)
        val card = ChatResultCard.parse("{\"kind\":\"links\",\"rows\":[{\"title\":\"Found page\",\"url\":\"https://site.test/result\"}]}")!!
        val comparison = ChatResultCard.parse("{\"kind\":\"table\",\"rows\":[{\"title\":\"Comparison source\",\"url\":\"https://site.test/comparison\",\"cells\":[\"Included\",\"42\"]}]}")!!
        val messages = (0..30).map { index -> AgentMessage("message-$index", MessageRole.ASSISTANT, "Message $index\n\n" + "A retained paragraph from the Mac. ".repeat(8), index.toLong(), AnswerOrigin.MAC,
            cards = if (index == 0) listOf(card, comparison) else emptyList()) }
        val privacy = mutableStateOf(false)
        var opened: String? = null
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { AgentScreen(repository, privacy.value, onOpenWebsite = { opened = it }) } }
        compose.runOnIdle { remote.conversations.value = listOf(RemoteConversation(null, owner, "Owned conversation", messages, false)) }
        compose.onNodeWithText("Owned conversation").performClick()
        compose.onNodeWithContentDescription("More").performClick(); compose.onNodeWithText("Mark as Unread").performClick()
        compose.runOnIdle { assertTrue(repository.state.value.current!!.unread) }
        compose.onNodeWithContentDescription("More").performClick(); compose.onNodeWithText("Chat Info").performClick()
        compose.onNodeWithText("Links").assertExists()
        // The transcript retains the same card behind the Info surface; inspect its copy.
        compose.onNode(hasText("Found page") and hasAnyAncestor(hasTestTag("chat.info"))).assertExists()
        compose.onNodeWithContentDescription("Back to chat").performClick()
        compose.onNodeWithTag("chat.transcript").performScrollToIndex(0)
        compose.onNodeWithText("Comparison source").performClick()
        compose.runOnIdle { assertEquals("https://site.test/comparison", opened) }
        compose.onNodeWithTag("chat.transcript").performScrollToIndex(8)
        compose.waitUntil(5_000) { repository.state.value.current?.reading?.let { it.message == "message-8" && !it.atBottom } == true }
        val reading = repository.state.value.current!!.reading!!
        compose.runOnIdle { remote.conversations.value = listOf(RemoteConversation(null, owner, "Owned conversation", messages, false, updatedAt = 99)) }
        compose.runOnIdle { assertEquals(reading, repository.state.value.current!!.reading) }
        compose.onNodeWithContentDescription("Back to Chats").performClick()
        compose.onNodeWithText("Owned conversation").performClick()
        compose.onNodeWithTag("chat.message.${reading.message}").assertIsDisplayed()
        compose.runOnIdle { privacy.value = true }
        compose.onNodeWithText("Owned conversation").assertDoesNotExist()
        assertEquals("https://site.test/comparison", opened)
    }
}

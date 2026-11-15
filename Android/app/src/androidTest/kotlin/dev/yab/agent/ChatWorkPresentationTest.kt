package dev.yab.agent

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import dev.yab.core.sync.Record
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual Compose presentation of isolated wire fixtures; no provider or network result is simulated. */
@RunWith(AndroidJUnit4::class)
class ChatWorkPresentationTest {
    @get:Rule val compose = createComposeRule()
    private val owner = RemoteOwner("fixture-account", "fixture-mac", "a:work", AgentProvider.CLAUDE)

    private class Port : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection("fixture-account", listOf(
            RemoteMac("fixture-mac", "Fixture Mac", true, setOf(AgentProvider.CLAUDE)))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("This presentation fixture must not send")
        override suspend fun stop(owner: RemoteOwner): Unit = error("This presentation fixture must not stop a provider")
        override suspend fun delete(owner: RemoteOwner): Unit = error("This presentation fixture must not delete a provider chat")
        override suspend fun answerApproval(answer: ApprovalAnswer): Unit = error("No approval is part of this fixture")
    }
    private class Memory : ChatPersistence {
        private var snapshot = ChatSnapshot()
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: ChatSnapshot) { this.snapshot = snapshot }
    }
    private fun item(id: String, n: Int, kind: String, text: String = "", name: String = "", detail: String = "",
                     state: String = "done", began: Double? = null, ended: Double? = null) = Record("chatitem", id, buildJsonObject {
        put("chat", owner.chat); put("n", n); put("kind", kind); put("text", text); put("name", name); put("detail", detail); put("state", state)
        began?.let { put("began", it) }; ended?.let { put("ended", it) }
    })
    private fun head(state: String, updated: Double, answer: String = "", choices: List<String> = emptyList()) = Record("chat", owner.chat, buildJsonObject {
        put("state", state); put("updated", updated); put("cli", "claude"); put("answer", answer)
        put("choices", JsonArray(choices.map(::JsonPrimitive)))
    })
    private fun publish(port: Port, repository: AgentRepository, head: Record, items: List<Record>, now: Long) {
        val messages = ChatTranscript.messages(head, items, emptyList(), now)
        compose.runOnIdle {
            port.conversations.value = listOf(RemoteConversation(null, owner, "Work fixture", messages,
                ChatTurnSemantics.isLive(head, now), updatedAt = now,
                remoteState = head["state"]!!.jsonPrimitive.content, choices = ChatTurnSemantics.choices(head)))
        }
        compose.waitUntil(5_000) { repository.state.value.chats.firstOrNull { it.owner == owner }?.let {
            it.messages == messages && it.remoteState == head["state"]!!.jsonPrimitive.content
        } == true }
    }
    private fun scrollTo(matcher: SemanticsMatcher) {
        compose.onNodeWithTag("chat.transcript").performScrollToNode(matcher)
    }

    @Test fun liveNameUsesTheAndroidGraphemeMatcherWithoutChangingTheOriginalText(): Unit {
        fun point(value: Int) = String(Character.toChars(value))
        val clusters = listOf(
            "decomposed accent" to "e\u0301",
            "joined family" to listOf(0x1F468, 0x1F469, 0x1F467, 0x1F466).joinToString("\u200D", transform = ::point),
            "regional flag" to (point(0x1F1F5) + point(0x1F1F9)),
            "skin tone" to (point(0x1F44D) + point(0x1F3FD)),
            "astral" to point(0x1F9EA))
        for ((label, cluster) in clusters) {
            val expected = "A".repeat(79) + cluster
            val item = ChatTurnItem("agent", 1.0, "subagent", "spawnAgent", "  ${expected}Z  ", "", "running", null, null)
            assertEquals(label, expected, ChatTurnSemantics.live(listOf(item)).single().name)
        }
    }

    @Test fun thoughtsAndReportsFoldWhileRawWorkStaysHiddenAndAskAgainKeepsTheQuestion(): Unit {
        val port = Port(); val repository = AgentRepository(Memory(), UnavailableLocalAiAdapter(), port)
        val retries = mutableListOf<Pair<String, String>>()
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
            AgentScreen(repository, false, onRetry = { id, words -> retries += id to words })
        } }
        val report = "Subagent Euler (s1) is done (done, sonnet, 3/3 completed).\n\nThe log fails on SyncKit.\nNothing else is new."
        val items = listOf(
            item("q", 0, "asked", "Why does CI fail?", began = 0.0),
            item("t1", 1, "thinking", "Clean checkout.", "thought", began = 1.0, ended = 6.0),
            item("t2", 2, "thinking", "Submodules.", "thought", began = 7.0, ended = 10.0),
            item("command", 3, "command", "RAW_COMMAND_OUTPUT", "command", "PRIVATE_IMPLEMENTATION_DETAIL", began = 11.0, ended = 12.0),
            item("a", 4, "message", "Add submodules.", began = 20.0, ended = 21.0),
            item("report", 5, "asked", report), item("quiet", 6, "message", " (quiet) \n"))
        publish(port, repository, head("done", 100.0), items, 100_000L)
        compose.onNodeWithText("Work fixture").performClick()
        scrollTo(hasText("Thought for 8s"))
        compose.onNodeWithText("Clean checkout.\n\nSubmodules.").assertDoesNotExist()
        compose.onNodeWithText("Thought for 8s").performClick()
        compose.onNodeWithText("Clean checkout.\n\nSubmodules.").assertIsDisplayed()
        compose.onNodeWithText("RAW_COMMAND_OUTPUT").assertDoesNotExist()
        compose.onNodeWithText("PRIVATE_IMPLEMENTATION_DETAIL").assertDoesNotExist()
        // Ask Again belongs to the answer's held menu, as in the shipped UI.
        scrollTo(hasText("Add submodules."))
        compose.onNodeWithText("Add submodules.").performTouchInput { longClick() }
        compose.onNodeWithText("Ask Again").performClick()
        compose.runOnIdle { assertEquals(listOf(owner.chat to "Why does CI fail?"), retries) }
        scrollTo(hasText("Show Report")); compose.onNodeWithText("Show Report").performClick()
        scrollTo(hasText("The log fails on SyncKit.\nNothing else is new."))
        compose.onNodeWithText("The log fails on SyncKit.\nNothing else is new.").assertIsDisplayed()
        compose.onNodeWithText(report).assertDoesNotExist()
        compose.onNodeWithText("(quiet)").assertDoesNotExist()
        compose.onNodeWithText("Worked for 21s").assertDoesNotExist()
    }

    @Test fun liveCardsUseRealOptionalTimesAndStaleRunningChoicesAndFailureHaveDifferentPresentations(): Unit {
        val port = Port(); val repository = AgentRepository(Memory(), UnavailableLocalAiAdapter(), port)
        val retries = mutableListOf<Pair<String, String>>()
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
            AgentScreen(repository, false, onRetry = { id, words -> retries += id to words })
        } }
        val now = System.currentTimeMillis(); val seconds = now / 1000.0
        val running = listOf(item("q", 0, "asked", "Compare both fares", began = seconds - 20),
            item("partial", 1, "message", "I will compare both.", began = seconds - 18),
            item("spawn", 2, "subagent", name = "spawnAgent", detail = "Check TAP fares", state = "running", began = seconds - 10),
            item("no-time", 3, "tool", name = "subagent", detail = "Check the source", state = "running"),
            item("control", 4, "subagent", name = "wait", detail = "CONTROL_WAIT_SHOULD_NOT_BE_A_CARD", state = "running"))
        publish(port, repository, head("running", seconds - 1), running, now)
        compose.onNodeWithText("Work fixture").performClick()
        scrollTo(hasTestTag("chat.work.subagent.spawn"))
        compose.onNodeWithTag("chat.work.clock.spawn").assertExists()
        scrollTo(hasTestTag("chat.work.subagent.no-time"))
        compose.onNodeWithTag("chat.work.subagent.no-time").assertIsDisplayed()
        compose.onNodeWithTag("chat.work.clock.no-time").assertDoesNotExist()
        compose.onNodeWithText("CONTROL_WAIT_SHOULD_NOT_BE_A_CARD").assertDoesNotExist()
        scrollTo(hasText("Answering…")); compose.onNodeWithText("Answering…").assertIsDisplayed()

        publish(port, repository, head("running", seconds - 21_600), running, now)
        compose.onNodeWithText("Answering…").assertDoesNotExist()
        compose.onNodeWithTag("chat.work.subagent.spawn").assertDoesNotExist()
        compose.onNodeWithTag("chat.work.subagent.no-time").assertDoesNotExist()
        scrollTo(hasText("I will compare both.")); compose.onNodeWithText("I will compare both.").assertIsDisplayed()
        compose.onNodeWithText("Ask Again").assertDoesNotExist()

        publish(port, repository, head("waiting", seconds, choices = listOf("Friday", "Saturday")), listOf(
            item("q", 0, "asked", "Choose a date"), item("question", 1, "message", "Which day?", "question")), now)
        compose.onNodeWithText("Friday").assertIsDisplayed().performClick()
        compose.onNodeWithText("Answering…").assertDoesNotExist()
        compose.runOnIdle { assertEquals(owner.chat to "Friday", retries.last()) }

        val raw = "API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"
        publish(port, repository, head("failed", seconds, raw), listOf(item("q", 0, "asked", "Summarize the pull requests"),
            item("repeat", 1, "message", raw, state = "failed"), item("error", 2, "message", raw, "error")), now)
        scrollTo(hasText("Try Again"))
        compose.onNodeWithText("Claude’s server failed partway.").assertIsDisplayed()
        compose.onNodeWithText(raw).assertDoesNotExist()
        compose.onNodeWithText("Friday").assertDoesNotExist()
        compose.onNodeWithText("Try Again").performClick()
        compose.runOnIdle { assertEquals(owner.chat to "Summarize the pull requests", retries.last()) }
    }
}

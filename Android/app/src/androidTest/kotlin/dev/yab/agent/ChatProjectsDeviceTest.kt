package dev.yab.agent

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import dev.yab.core.sync.SyncProject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real Compose component actions with synthetic in-memory records. No Main, Sync, Mac, key,
 * provider, native page, FINGER, frame or navigation-transition acceptance is claimed. */
@RunWith(AndroidJUnit4::class)
class ChatProjectsDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private class Port : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection("fixture-account", listOf(RemoteMac("fixture-mac", "Fixture Mac", true,
            setOf(AgentProvider.CLAUDE), takesMetadata = true, takesProjects = true)), epoch = 4))
        override val projects = MutableStateFlow(ChatProjectsSnapshot("fixture-account", "fixture-phone", 4,
            listOf(SyncProject("prj-fixture", "Fixture Project", "", "blue", instructions = "Read-only synthetic instructions",
                memoryOn = false, pinned = true, order = "", created = 0.0, updated = 0.0))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        var writes = 0
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt { writes++; error("No remote send in component fixture") }
        override suspend fun stop(owner: RemoteOwner) { writes++ }
        override suspend fun delete(owner: RemoteOwner) { writes++ }
        override suspend fun answerApproval(answer: ApprovalAnswer) { writes++ }
    }
    private class Memory(private val initial: ChatSnapshot) : ChatPersistence {
        var saved = initial
        override suspend fun load() = saved
        override suspend fun save(snapshot: ChatSnapshot) { saved = snapshot }
    }
    private fun click(tag: String): () -> Boolean = dev.yab.browser.originalRenderedClick(compose.onNodeWithTag(tag).fetchSemanticsNode())
    private fun edit(tag: String): (AnnotatedString) -> Boolean = checkNotNull(compose.onNodeWithTag(tag).fetchSemanticsNode().config[SemanticsActions.SetText].action)

    @Test(timeout = 90_000)
    fun actualProjectComponentsKeepOwnedPinsInfoDraftNestedBackAndRefuseRetiredActions() {
        val port = Port()
        val chat = AgentChat("fixture-chat", "Fixture Conversation", owner = RemoteOwner("fixture-account", "fixture-mac", "a:fixture", AgentProvider.CLAUDE),
            messages = listOf(AgentMessage("fixture-answer", MessageRole.ASSISTANT, "Synthetic answer", 1)), project = "prj-fixture")
        val disk = Memory(ChatSnapshot(chats = listOf(chat)))
        val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        runBlocking { repository.load() }
        val presentation = ChatProjectsPresentation()
        val originalActivity = compose.activity
        val originalWindow = originalActivity.window
        val originalIntent = originalActivity.intent
        var hostGeneration = 1L
        var actionEnabled by mutableStateOf(true)
        var actionGeneration by mutableLongStateOf(1L)
        var openedLoose = 0
        compose.setContent {
            BrowserTheme(BrowserAppearance.LIGHT) {
                val state by repository.state.collectAsState()
                val projects by repository.projects.collectAsState()
                val frame by presentation.frame.collectAsState()
                val entryRevision by presentation.revision.collectAsState()
                val source = projects
                val generation = hostGeneration
                fun original() = originalActivity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED) && originalActivity.window === originalWindow &&
                    originalActivity.intent === originalIntent && hostGeneration == generation
                val capturedAction = actionGeneration
                val action = remember(capturedAction, actionEnabled) { ProjectUiLifetime {
                    original() && actionEnabled && actionGeneration == capturedAction
                } }
                fun entryCurrent() = original() && action.current() && port.projects.value == source &&
                    presentation.frame.value == null && presentation.revision.value == entryRevision
                Box(Modifier.fillMaxSize()) {
                    FieldChatsPage(state.copy(privateContext = false).listed(), "", false, listOf(source, entryRevision), frame == null,
                        current = ::entryCurrent,
                        onSelect = { openedLoose++ }, onNewChat = { }, onArchive = { }, canAct = { _, _ -> false }, onAction = { },
                        deleteQuestion = { FieldChatDeleteQuestion("Delete this chat?") },
                        modifier = if (frame == null) Modifier else Modifier.clearAndSetSemantics { },
                        projects = source.listed, projectKey = source.generation,
                        onProject = { project -> if (entryCurrent())
                            presentation.open(source, port.connection.value, project.id, ::original) })
                    ChatProjectsCover(repository, presentation, actionCurrent = action::current)
                }
            }
        }
        val pin = click("newtab.project.prj-fixture")
        compose.onNodeWithTag("newtab.project.prj-fixture").performClick()
        compose.onNodeWithTag("project.page").assertExists()
        compose.onNodeWithTag("project.field").performTextReplacement("Original project draft")
        val oldField = edit("project.field")
        val oldBack = click("project.back")
        val owner = compose.runOnIdle { checkNotNull(presentation.frame.value).owner }
        compose.runOnIdle { actionEnabled = false; actionGeneration++ }
        compose.waitForIdle()
        compose.runOnIdle { oldField(AnnotatedString("Blocked edit")); oldBack(); assertSame(owner, presentation.frame.value!!.owner)
            assertEquals("Original project draft", presentation.draft.value) }
        compose.runOnIdle { actionEnabled = true; actionGeneration++ }
        compose.onNodeWithTag("project.field").assertTextEquals("Original project draft")
        compose.runOnIdle { oldField(AnnotatedString("Retired approval edit")); oldBack(); assertSame(owner, presentation.frame.value!!.owner)
            assertEquals("Original project draft", presentation.draft.value) }
        compose.onNodeWithTag("project.title").performClick()
        compose.onNodeWithTag("project.info.instructions").assertTextEquals("Read-only synthetic instructions")
        compose.onNodeWithTag("project.info.memory").assertExists()
        compose.onNodeWithText("Off").assertExists()
        compose.onNodeWithText("Instructions and memory are edited on your Mac.").assertExists()
        val oldInfoBack = click("project.info.back")
        compose.onNodeWithTag("project.info.back").performClick()
        compose.onNodeWithTag("project.field").assertTextEquals("Original project draft")
        compose.runOnIdle { oldField(AnnotatedString("Retired edit")); oldBack(); oldInfoBack() }
        compose.runOnIdle { assertSame(owner, presentation.frame.value!!.owner); assertFalse(presentation.frame.value!!.info); assertEquals("Original project draft", presentation.draft.value) }
        compose.onNodeWithTag("project.chat.fixture-chat").performClick()
        compose.onNodeWithTag("chat.transcript").assertExists()
        compose.onNodeWithText("Synthetic answer").assertExists()
        compose.onNodeWithContentDescription("Back to Chats").performClick()
        compose.onNodeWithTag("project.field").assertTextEquals("Original project draft")
        compose.runOnIdle { assertNull(presentation.frame.value!!.conversation); assertSame(owner, presentation.frame.value!!.owner) }
        val freshBack = click("project.back")
        compose.runOnIdle {
            val old = port.projects.value
            port.projects.value = ChatProjectsSnapshot.publish(old, old.account, old.device, old.epoch,
                old.projects.map { it.copy(name = "Updated Project") }, connection = port.connection.value)
        }
        compose.onNodeWithTag("project.title").assertExists()
        compose.runOnIdle { freshBack(); assertSame(owner, presentation.frame.value!!.owner); assertEquals("Original project draft", presentation.draft.value) }
        compose.onNodeWithTag("project.back").performClick()
        compose.onNodeWithTag("newtab.project.prj-fixture").assertExists()
        compose.runOnIdle { pin(); assertNull(presentation.frame.value) }
        compose.onNodeWithTag("newtab.project.prj-fixture").performClick()
        compose.runOnIdle { assertNotSame(owner, presentation.frame.value!!.owner); assertEquals("", presentation.draft.value) }
        val secondOwner = compose.runOnIdle { presentation.frame.value!!.owner }
        compose.runOnIdle {
            val old = port.projects.value
            val absent = ChatProjectsSnapshot.publish(old, old.account, old.device, old.epoch, emptyList(), connection = port.connection.value)
            port.projects.value = ChatProjectsSnapshot.publish(absent, old.account, old.device, old.epoch, old.projects, connection = port.connection.value)
        }
        compose.waitForIdle()
        compose.runOnIdle { assertNull(presentation.frame.value); assertFalse(secondOwner.current(port.projects.value, port.connection.value)) }
        compose.onNodeWithTag("newtab.project.prj-fixture").performClick()
        compose.runOnIdle {
            hostGeneration++
            presentation.observe(port.projects.value, port.connection.value)
            assertNull(presentation.frame.value)
            assertEquals(0, port.writes); assertEquals(0, openedLoose)
            assertSame(originalActivity, compose.activity); assertSame(originalWindow, compose.activity.window); assertSame(originalIntent, compose.activity.intent)
        }
    }
    /** Old-API actual component consumer, unrun. Its own finite flow observers retire
     * fixture action authority during the real project-draft clear publication. No
     * dispatcher timing, Main approval, Keyguard, Bridge or provider is assumed. */
    @Test(timeout = 90_000)
    fun projectSendKeepsOriginalWordsWhenItsActionRetiresDuringDraftHandoff() {
        val port = Port()
        val repository = AgentRepository(Memory(ChatSnapshot()), UnavailableLocalAiAdapter(), port)
        runBlocking { repository.load() }
        val presentation = ChatProjectsPresentation()
        var actionGeneration by mutableLongStateOf(1L)
        var sourceAlive by mutableStateOf(true)
        compose.setContent {
            BrowserTheme(BrowserAppearance.LIGHT) {
                val captured = actionGeneration
                val action = remember(captured, sourceAlive) { ProjectUiLifetime {
                    sourceAlive && actionGeneration == captured
                } }
                ChatProjectsCover(repository, presentation, actionCurrent = action::current)
            }
        }
        compose.runOnIdle {
            assertTrue(presentation.open(port.projects.value, port.connection.value, "prj-fixture") { true })
        }
        compose.onNodeWithTag("project.field").performTextReplacement("Original project words")
        val savedSend = click("project.send")
        var original: String? = null
        var retired = false
        val markers = mutableListOf<String>()
        val observerJob = kotlinx.coroutines.SupervisorJob()
        val observers = kotlinx.coroutines.CoroutineScope(observerJob + kotlinx.coroutines.Dispatchers.Unconfined)
        try {
            compose.runOnUiThread {
                observers.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                    repository.state.collect { state ->
                        val chat = state.current
                        if (original == null && chat?.project == "prj-fixture" && chat.ephemeral && chat.owner == null) {
                            original = chat.id
                            markers += "ORIGINAL_CREATED"
                        }
                    }
                }
                observers.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                    presentation.draft.collect { words ->
                        if (!retired && original != null && words.isEmpty()) {
                            retired = true
                            markers += "PROJECT_DRAFT_CLEARED"
                            sourceAlive = false
                            actionGeneration++
                            markers += "ACTION_RETIRED"
                        }
                    }
                }
                assertEquals("Original project words", presentation.draft.value)
                assertEquals(0, port.writes)
                savedSend()
                assertEquals("The original consumer must create, clear and retire in this call", listOf(
                    "ORIGINAL_CREATED", "PROJECT_DRAFT_CLEARED", "ACTION_RETIRED"), markers)
                assertNotNull("The actual project Send closure must create an original chat", original)
                assertNull("Retirement must precede conversation publication and queued coroutine entry", presentation.frame.value?.conversation)
                assertEquals("No transport admission can precede this retirement", 0, port.writes)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val chat = repository.state.value.chats.single { it.id == original }
                assertEquals("PROJECT_ADMITTED_WORDS_MUST_SURVIVE_SOURCE_RETIREMENT", "Original project words", chat.draft)
                assertTrue(chat.messages.isEmpty()); assertEquals("prj-fixture", chat.project)
                assertEquals("", presentation.draft.value)
                assertEquals(0, port.writes)
                val successor = repository.newChat(forceMac = true)
                runBlocking { repository.draft("Successor words") }
                assertTrue(presentation.open(port.projects.value, port.connection.value, "prj-fixture") { true })
                val chatCount = repository.state.value.chats.size
                savedSend()
                assertEquals(chatCount, repository.state.value.chats.size)
                assertEquals(successor, repository.state.value.current!!.id)
                assertEquals("Successor words", repository.state.value.current!!.draft)
                assertEquals("Original project words", repository.state.value.chats.single { it.id == original }.draft)
                assertEquals(0, port.writes)
            }
        } finally { observerJob.cancel() }
    }

}

package dev.yab.agent

import android.graphics.Bitmap
import androidx.compose.runtime.*
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import dev.yab.core.sync.*
import kotlinx.coroutines.runBlocking
import androidx.compose.ui.test.hasSetTextAction
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Actual production components with explicitly fictional local records. No real Mac/auth/payment. */
@RunWith(AndroidJUnit4::class)
class ScreenCatalogFixtureTest {
    @get:Rule val compose = createComposeRule()
    private val remote = object : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection("catalog", listOf(RemoteMac("mac", "Studio Mac", true,
            setOf(AgentProvider.CLAUDE, AgentProvider.CODEX), controlsChats = true,
            models = listOf(RemoteModel("fixture-model", "Example model", AgentProvider.CLAUDE, listOf("low", "high")))))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("Catalog never sends work")
        override suspend fun stop(owner: RemoteOwner): Unit = error("Catalog never stops work")
        override suspend fun delete(owner: RemoteOwner): Unit = error("Catalog never deletes work")
        override suspend fun answerApproval(answer: ApprovalAnswer): Unit = error("Catalog never approves")
    }
    @Composable private fun CatalogHost(content: @Composable () -> Unit) {
        Surface(Modifier.fillMaxSize()) { Box(Modifier.fillMaxSize().safeDrawingPadding()) { content() } }
    }
    private fun shot(name: String) {
        compose.waitForIdle()
        android.os.SystemClock.sleep(450)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(folder, "$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
        File(folder, "$name.json").writeText("""{"kind":"production-component-fixture","screen":"$name","realMac":false,"externalActions":false}""")
    }

    @Test fun chatScreensWithFictionalConversation() {
        val memory = object : ChatPersistence {
            var value = ChatSnapshot()
            override suspend fun load() = value
            override suspend fun save(snapshot: ChatSnapshot) { value = snapshot }
        }
        val repository = AgentRepository(memory, UnavailableLocalAiAdapter(), remote)
        var appearance by mutableStateOf(BrowserAppearance.LIGHT)
        compose.setContent { BrowserTheme(appearance) { CatalogHost { AgentScreen(repository, false) } } }
        val owner = RemoteOwner("catalog", "mac", "catalog-chat", AgentProvider.CLAUDE)
        val messages = listOf(
            AgentMessage("user", MessageRole.USER, "Find a quiet place to work this weekend.", 1, AnswerOrigin.MAC),
            AgentMessage("answer", MessageRole.ASSISTANT, "## A quiet weekend\n\nStart with a library in the morning, then take a long walk. Keep the afternoon free.\n\n- A comfortable place to read\n- A short list of places nearby\n- Time away from notifications", 2, AnswerOrigin.MAC,
                cards = listOf(checkNotNull(ChatResultCard.parse("""{"kind":"links","rows":[{"title":"Explore the library","url":"https://example.com/library"}]}"""))))
        )
        compose.runOnIdle { remote.conversations.value = listOf(RemoteConversation(null, owner, "A quiet weekend", messages, false)) }
        compose.onNodeWithText("A quiet weekend").assertExists()
        shot("chat-list")
        compose.onNodeWithText("A quiet weekend").performClick()
        compose.onNodeWithTag("chat.transcript").assertExists()
        shot("chat-conversation")
        compose.onNodeWithTag("chat.message.answer").performTouchInput { longClick() }
        shot("chat-message-menu")
        compose.onNodeWithText("Share", useUnmergedTree = true).assertExists()
        compose.onNodeWithText("Translate", useUnmergedTree = true).assertExists()
        compose.onNodeWithText("Copy", useUnmergedTree = true).performClick()
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Chat Info").assertExists()
        shot("chat-menu")
        compose.onNodeWithText("Chat Info").performClick()
        compose.onNodeWithContentDescription("Back to chat").assertExists()
        shot("chat-info")
        compose.onNodeWithContentDescription("Back to chat").performClick()
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Rename Chat").performClick()
        shot("chat-rename")
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Model and reasoning").performClick()
        compose.onNodeWithText("Model and reasoning").assertExists()
        shot("chat-model-and-reasoning")
        compose.onNodeWithText("Done").performClick()
        compose.runOnIdle { appearance = BrowserAppearance.DARK }
        shot("chat-conversation-dark")
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Chat Info").performClick()
        shot("chat-info-dark")
        compose.onNodeWithContentDescription("Back to chat").performClick()
        compose.onNodeWithContentDescription("Back to Chats").performClick()
        shot("chat-list-dark")
        compose.runOnIdle {
            appearance = BrowserAppearance.LIGHT
            remote.conversations.value = listOf(RemoteConversation(null, owner, "Code and table", listOf(
                AgentMessage("structured", MessageRole.ASSISTANT, "A small example.\n\n```kotlin\nval count = 3\n```\n\n| Day | Plan |\n|---|---|\n| Sat | Library |\n\nLeave the evening free.", 3, AnswerOrigin.MAC)), false))
        }
        compose.onNodeWithText("Code and table").performClick()
        compose.onNodeWithTag("chat.block.structured.1", useUnmergedTree = true).assertExists()
        compose.onNodeWithText("val count = 3").assertExists()
        compose.onNodeWithText("Copy code").assertDoesNotExist()
        shot("chat-code-table")

    }

    @Test fun projectUiWithFictionalRecords() {
        val project = SyncProject("catalog-project", "Lisbon Trip", "🌊", "teal", instructions = "Keep the plan relaxed and walkable.",
            memoryOn = true, pinned = true, order = "", created = 0.0, updated = 0.0)
        val port = object : RemoteAgentTransport by remote {
            override val connection = MutableStateFlow(remote.connection.value.copy(macs = remote.connection.value.macs.map { it.copy(takesMetadata = true, takesProjects = true) }))
            override val projects = MutableStateFlow(ChatProjectsSnapshot("catalog", "catalog-phone", 0, listOf(project)))
        }
        val chat = AgentChat("project-chat", "A quiet morning", project = project.id,
            owner = RemoteOwner("catalog", "mac", "project-chat", AgentProvider.CLAUDE),
            messages = listOf(AgentMessage("project-answer", MessageRole.ASSISTANT, "Start with coffee near the river, then take a walk.", 1)))
        val memory = object : ChatPersistence {
            override suspend fun load() = ChatSnapshot(chats = listOf(chat))
            override suspend fun save(snapshot: ChatSnapshot) {}
        }
        val repository = AgentRepository(memory, UnavailableLocalAiAdapter(), port)
        runBlocking { repository.load() }
        val presentation = ChatProjectsPresentation()
        var appearance by mutableStateOf(BrowserAppearance.LIGHT)
        compose.setContent { BrowserTheme(appearance) { CatalogHost {
            LaunchedEffect(Unit) { repository.run() }
            val state by repository.state.collectAsState()
            val projects by repository.projects.collectAsState()
            Box(Modifier.fillMaxSize()) {
                FieldChatsPage(state.copy(privateContext = false).listed(), "", false, projects, true, { true },
                    onSelect = {}, onNewChat = {}, onArchive = {}, canAct = { _, _ -> false }, onAction = {},
                    deleteQuestion = { FieldChatDeleteQuestion("Unused") }, projects = projects.listed, projectKey = projects.generation,
                    onProject = { presentation.open(projects, port.connection.value, it.id) { true } })
                ChatProjectsCover(repository, presentation, actionCurrent = { true })
            }
        } } }
        compose.onNodeWithTag("newtab.project.catalog-project").assertExists()
        shot("projects-pinned")
        compose.onNodeWithTag("newtab.project.catalog-project").performClick()
        compose.onNodeWithTag("project.field").assertExists()
        shot("project-page")
        compose.onNodeWithTag("project.title").performClick()
        compose.onNodeWithTag("project.info.instructions").assertExists()
        shot("project-info")
        compose.onNodeWithTag("project.info.back").performClick()
        compose.onNodeWithTag("project.field").performClick().performTextInput("A short walking plan")
        compose.waitUntil(10_000) {
            var visible = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                visible = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).any {
                        androidx.core.view.ViewCompat.getRootWindowInsets(it.window.decorView)
                            ?.isVisible(androidx.core.view.WindowInsetsCompat.Type.ime()) == true
                    }
            }
            visible
        }
        shot("project-keyboard")
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        compose.onNodeWithTag("project.chat.project-chat").performTouchInput {
            swipe(androidx.compose.ui.geometry.Offset(width * .85f, centerY), androidx.compose.ui.geometry.Offset(width * .45f, centerY), 350)
        }
        compose.onNode(hasText("Archive") and hasAnyAncestor(hasTestTag("project.page")), useUnmergedTree = true).assertIsDisplayed()
        compose.onNode(hasText("Pin") and hasAnyAncestor(hasTestTag("project.page")), useUnmergedTree = true).assertIsDisplayed()
        shot("project-swipe")
        compose.runOnIdle { appearance = BrowserAppearance.DARK }
        shot("project-page-dark")
        compose.onNodeWithTag("project.title").performClick()
        shot("project-info-dark")
    }

    @Test fun approvalScreensWithoutActing() {
        val until = System.currentTimeMillis() + 600_000
        fun request(id: String, title: String, kind: ApprovalKind, lines: List<String> = emptyList(),
                    payment: ApprovalPayment? = null, mails: List<ApprovalMail> = emptyList(), files: List<ApprovalFile> = emptyList(),
                    person: String? = null, text: String? = null) = ApprovalRequest(id, "catalog", "mac", 1, until,
            "Claude", title, "Local demonstration", kind, lines = lines, payment = payment, mails = mails, files = files,
            person = person, text = text, verb = "Approve", requestDigest = "catalog-$id")
        val mail = ApprovalMail("you@example.com", listOf("team@example.com"), "A quiet weekend", "Hello,\n\nThe plan is ready for your review.\n\nThank you.")
        val requests = listOf(
            request("action", "Open the selected pages?", ApprovalKind.LINES, lines = listOf("Read three public pages", "Bring the results back here")),
            request("payment", "Pay for this book?", ApprovalKind.PAYMENT, payment = ApprovalPayment("books.example", "A book for the weekend", "$24.00", facts = listOf("One item", "No subscription"))),
            request("mail", "Send this email?", ApprovalKind.MAIL, mails = listOf(mail)),
            request("mail-batch", "Send these emails?", ApprovalKind.MAIL_BATCH, mails = listOf(mail, mail.copy(to = listOf("friend@example.com"), subject = "Weekend reading"))),
            request("files", "Share these files?", ApprovalKind.FILES, files = listOf(ApprovalFile("document", "Weekend notes.pdf", "application/pdf", 84_000, pages = 3))),
            request("message", "Send this message?", ApprovalKind.MESSAGE, person = "Example contact", text = "The weekend plan is ready. Would you like to take a look?"),
            request("mail-search", "Read matching email?", ApprovalKind.MAIL_SEARCH, lines = listOf("Search your inbox for travel confirmations")),
            request("accounts", "Use this account?", ApprovalKind.ACCOUNTS, lines = listOf("Personal account", "Only for this request"))
        )
        val current = mutableStateOf(requests.first())
        val authentication = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof? = error("Catalog never authenticates")
        }
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { CatalogHost {
            key(current.value.id) {
                val controller = remember { ApprovalController(remote).apply { replaceValidated(listOf(current.value)) } }
                ApprovalPrompt(controller, authentication)
            }
        } } }
        for (request in requests) {
            compose.runOnIdle { current.value = request }
            compose.onNodeWithText(request.title).assertExists()
            shot("approval-${request.id}")
        }
    }

    @Test fun readOnlyTaskScreensFromLocalRecords() {
        val origin = AgentTaskOrigin("space", "tab", "https://example.com/article", "Weekend reading")
        val request = TaskRecords.Request.create("catalog", "android", "mac", origin.space, "Read these pages and prepare a short plan.",
            "00000000-0000-0000-0000-000000000031", origin.tab, origin.url, origin.title)
        val checked = TaskRecords.Request.read(Record(TaskRecords.REQUEST, request.id).updated(request.fields(), Clock("android")), "catalog", "android")
        val response = buildJsonObject {
            put("version", 1); put("task", request.id); put("requestDigest", request.digest()); put("account", "catalog"); put("phone", "android"); put("mac", "mac")
            put("revision", 2); put("session", "catalog"); put("status", "done"); put("title", "Weekend reading plan"); put("progress", "Read all requested pages")
            put("result", "# Your reading plan\n\nStart with the main article, save two useful references, and leave time to reflect."); put("resultURL", "https://example.com/result")
        }
        val observation = TaskRecords.Observation.read(Record(TaskRecords.OBSERVATION, request.id).updated(buildJsonObject { put("body", response.toString()) }, Clock("mac")), checked)
        val task = ReadOnlyTask(checked, observation, "Studio Mac", true)
        val port = object : AgentTaskPort {
            override val tasks = MutableStateFlow(listOf(task))
            override val taskMacs = MutableStateFlow(emptyList<TaskMac>())
            override fun updateTaskScope(origin: AgentTaskOrigin?) {}
            override suspend fun sendTask(words: String, origin: AgentTaskOrigin, mac: String, epoch: String): ReadOnlyTask = error("Catalog never sends tasks")
            override suspend fun openTaskResult(task: ReadOnlyTask, url: String): String? = null
        }
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { CatalogHost { TaskScreen(port, origin, onOpenWebsite = {}, onBack = {}) } } }
        compose.onNodeWithTag("tasks.screen").assertExists()
        shot("tasks-list")
        compose.onNodeWithTag("tasks.row.${request.id}").performClick()
        compose.onNodeWithTag("tasks.title").assertExists()
        shot("task-result")
    }
}

package dev.yab.agent

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserScreen
import dev.yab.browser.ui.BrowserTheme
import dev.yab.core.sync.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Identical fictional text to iphone-0.1.12's mira world. Production UI, no remote actions. */
@RunWith(AndroidJUnit4::class)
class PhoneParityFixtureTest {
    @get:Rule val compose = createAndroidComposeRule<dev.yab.android.EngineTestActivity>()
    private val owner = RemoteOwner("parity", "mac", "anna", AgentProvider.CLAUDE)
    private val port = object : RemoteAgentTransport {
        override val connection = MutableStateFlow(RemoteConnection("parity", listOf(RemoteMac("mac", "MacBook Pro", true,
            setOf(AgentProvider.CLAUDE), takesFiles = true, controlsChats = true, takesMetadata = true, takesProjects = true))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override val projects = MutableStateFlow(ChatProjectsSnapshot("parity", "phone", 0, listOf(project)))
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("Visual fixture never sends")
        override suspend fun stop(owner: RemoteOwner): Unit = error("Visual fixture never stops")
        override suspend fun delete(owner: RemoteOwner): Unit = error("Visual fixture never deletes")
        override suspend fun answerApproval(answer: ApprovalAnswer): Unit = error("Visual fixture never approves")
    }
    private val messages = listOf(
        AgentMessage("u1", MessageRole.USER, "what does anna want?", 1),
        AgentMessage("a1", MessageRole.ASSISTANT, "Anna wants a “same as last week” button on the hours picker, so people don’t set their focus hours from scratch every Monday. She left it on frame 2, Pick your focus hours.", 2, AnswerOrigin.DEVICE),
        AgentMessage("u2", MessageRole.USER, "and what did she say about the sprint?", 3),
        AgentMessage("a2", MessageRole.ASSISTANT, "On Thursday in Slack she asked to move it to the next sprint: the beta needs the invite flow first. She’ll pair with you on it next Monday.", 4, AnswerOrigin.MAC))
    private val anna get() = AgentChat("anna", "Anna’s hours picker", messages, owner = owner,
        page = PageContext("Onboarding v3", "https://figma.com/design/onboarding", ""), updatedAt = java.time.LocalDate.now().atTime(18, 43).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli())
    private fun repository(chats: List<AgentChat>): AgentRepository {
        val memory = object : ChatPersistence {
            override suspend fun load() = ChatSnapshot(chats = chats)
            override suspend fun save(snapshot: ChatSnapshot) {}
        }
        return AgentRepository(memory, UnavailableLocalAiAdapter(), port).also { runBlocking { it.load() } }
    }
    @Composable private fun Host(appearance: BrowserAppearance, content: @Composable () -> Unit) {
        dev.yab.browser.ParitySystemBars(appearance)
        BrowserTheme(appearance) { Surface(Modifier.fillMaxSize()) { Box(Modifier.fillMaxSize().safeDrawingPadding()) { content() } } }
    }
    private fun shot(name: String) {
        compose.waitForIdle()
        android.os.SystemClock.sleep(500)
        val i = InstrumentationRegistry.getInstrumentation()
        val folder = File(i.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(i.uiAutomation.takeScreenshot())
        File(folder, "parity-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
        File(folder, "parity-$name.json").writeText("""{"kind":"production-component-fixture","reference":"iphone-0.1.12","screen":"$name","realMac":false,"externalActions":false,"logicalWidth":402}""")
    }
    @Test fun conversationAndInfoMatchPhoneFixture() {
        val repository = repository(listOf(anna))
        repository.open("anna")
        var appearance by mutableStateOf(BrowserAppearance.LIGHT)
        compose.setContent { Host(appearance) { AgentScreen(repository, false, collectInScreen = false) } }
        compose.onNodeWithTag("chat.transcript").assertExists()
        compose.onNodeWithTag("chat.pagePill").assertExists()
        compose.onNodeWithText("Claude carries on, on your Mac").assertExists()
        shot("chat.3")
        compose.runOnIdle { appearance = BrowserAppearance.DARK }
        shot("chat.3-dark")
        compose.onNodeWithTag("chat.title").performClick()
        compose.onNodeWithTag("chat.info").assertExists()
        shot("chat.info-dark")
        compose.runOnIdle { appearance = BrowserAppearance.LIGHT }
        shot("chat.info")
        compose.onNodeWithText("Copy Answer").assertExists()
        compose.onNodeWithText("Copy Page Link").assertExists()
        val i = InstrumentationRegistry.getInstrumentation()
        val movie = File(i.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures/chat-info-transition.mp4")
        val recording = i.uiAutomation.executeShellCommand("screenrecord --bit-rate 6000000 --time-limit 8 ${movie.absolutePath}")
        android.os.SystemClock.sleep(250)
        compose.mainClock.autoAdvance = false
        fun frames(count: Int) = repeat(count) {
            compose.mainClock.advanceTimeByFrame()
            compose.waitForIdle()
            android.os.SystemClock.sleep(16)
        }
        fun pull(distance: Float, count: Int) {
            val bounds = compose.onNodeWithTag("chat.info").fetchSemanticsNode().boundsInRoot
            val start = androidx.compose.ui.geometry.Offset(bounds.center.x, bounds.top + bounds.width * .5f)
            val root = compose.onRoot()
            root.performTouchInput { down(start) }
            repeat(count) { step ->
                root.performTouchInput { moveTo(start + androidx.compose.ui.geometry.Offset(0f, distance * (step + 1) / count)) }
                frames(1)
            }
            root.performTouchInput { up() }
        }
        try {
            compose.onNodeWithContentDescription("Back to chat").performClick()
            frames(24)
            compose.onNodeWithTag("chat.title").performClick()
            frames(40)
            val width = compose.onNodeWithTag("chat.info").fetchSemanticsNode().boundsInRoot.width
            pull(width * .1f, 20)
            frames(30)
            compose.onNodeWithTag("chat.info").assertExists()
            pull(width * .9f, 30)
            frames(30)
            compose.onNodeWithTag("chat.info").assertDoesNotExist()
            compose.onNodeWithTag("chat.title").assertExists()
        } finally { compose.mainClock.autoAdvance = true }
        android.os.ParcelFileDescriptor.AutoCloseInputStream(recording).use { it.readBytes() }
        assertTrue("The actual transition film was written", movie.length() > 1024)
        compose.onNodeWithTag("chat.message.a2").performTouchInput { longClick() }
        compose.onNodeWithText("Select Text").assertExists()
        compose.onNodeWithText("Share").assertExists()
        shot("chat.message-menu")
    }
    @Test fun groupedBubblesAndWideTableMatchPhoneFixture() {
        val code = "Ship it behind a flag first, so the beta keeps its invite flow.\n\n## Before Monday\nThree things:\n- the **same as last week** button on frame 2\n- copy for the empty week\n- a check that the hours carry over\n\n```\nflags.sameAsLastWeek = true\n```\n\nAnna pairs with you on it then."
        val table = "I opened the profiles of about 30 news accounts on X. Only TRT World and Al Jazeera English carry a nonstop TV channel stream.\n\n| Account | What's live | 24/7? | Source |\n|---|---|---|---|\n| @trtworld | TRT World “Live Now”, started 3 weeks ago | Yes | x.com |\n| @AJEnglish | “LIVE: AL JAZEERA ENGLISH”, started 21 hours ago, the stream restarts now and then | Looks like it | [x.com](https://x.com/AJEnglish) |\n| @Reuters | Only single events: press conferences and launches | No | x.com |"
        val a = anna.copy(id = "bubbles", messages = messages + listOf(AgentMessage("u3", MessageRole.USER, "how should we ship it?", 5), AgentMessage("a3", MessageRole.ASSISTANT, code, 6, AnswerOrigin.MAC)))
        val b = anna.copy(id = "table", messages = messages + listOf(AgentMessage("u3", MessageRole.USER, "which accounts on X stream live 24/7?", 5), AgentMessage("a3", MessageRole.ASSISTANT, table, 6, AnswerOrigin.MAC)))
        val repository = repository(listOf(a, b))
        repository.open(a.id)
        compose.setContent { Host(BrowserAppearance.LIGHT) { AgentScreen(repository, false, collectInScreen = false) } }
        compose.onNodeWithTag("chat.transcript").performScrollToIndex(5)
        compose.onNodeWithText("flags.sameAsLastWeek = true").assertExists()
        compose.onNodeWithText("Copy code").assertDoesNotExist()
        shot("chat.bubbles")
        compose.runOnIdle { repository.open(b.id) }
        compose.onNodeWithTag("chat.transcript").performScrollToIndex(5)
        compose.onNodeWithTag("chat.table.cards", useUnmergedTree = true).assertExists()
        compose.onNodeWithTag("chat.table.card.2", useUnmergedTree = true).assertExists()
        shot("chat.table")
    }
    @Test fun projectsMatchPhoneFixture() {
        val flight = AgentChat("lisbon", "Lisbon flights", project = project.id, unread = true, origin = "task", updatedAt = java.time.LocalDate.now().atTime(18,31).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli(),
            owner = owner.copy(chat = "lisbon"), messages = listOf(AgentMessage("flights", MessageRole.ASSISTANT, "Booked · TAP, Oct 13 18:35, seat 14A", 1, AnswerOrigin.MAC)))
        val repository = repository(listOf(flight))
        val presentation = ChatProjectsPresentation()
        var appearance by mutableStateOf(BrowserAppearance.LIGHT)
        compose.setContent { Host(appearance) {
            LaunchedEffect(Unit) { repository.run() }
            val state by repository.state.collectAsState()
            val projects by repository.projects.collectAsState()
            Box(Modifier.fillMaxSize()) {
                FieldChatsPage(state.listed(), "", false, projects, true, { true }, {}, {}, {}, { _, _ -> false }, {},
                    { FieldChatDeleteQuestion("Unused") }, projects = projects.listed, onProject = { presentation.open(projects, port.connection.value, it.id) { true } })
                ChatProjectsCover(repository, presentation, actionCurrent = { true })
            }
        } }
        compose.onNodeWithTag("newtab.project.${project.id}").performClick()
        compose.onNodeWithTag("project.chat.lisbon").assertExists()
        shot("projects.page")
        compose.onNodeWithTag("project.title").performClick()
        compose.onNodeWithTag("project.info.instructions").assertExists()
        shot("projects.info")
        compose.runOnIdle { appearance = BrowserAppearance.DARK }
        shot("projects.info-dark")
        compose.onNodeWithTag("project.info.back").performClick()
        shot("projects.page-dark")
        compose.runOnIdle { appearance = BrowserAppearance.LIGHT }
        compose.onNodeWithTag("project.field").performClick().performTextInput("Is the 7:05 return worth it?")
        compose.waitUntil(10_000) {
            var shown = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                shown = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).any {
                        androidx.core.view.ViewCompat.getRootWindowInsets(it.window.decorView)?.isVisible(androidx.core.view.WindowInsetsCompat.Type.ime()) == true }
            }
            shown
        }
        shot("projects.typed")
    }
    @Test fun newTabCardsAndSearchUseSameMiraTexts() {
        val now = java.time.LocalDate.now().atTime(19, 0).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        fun chat(id: String, title: String, answer: String, minutes: Long, pinned: Boolean = false, unread: Boolean = false, device: Boolean = false, sites: List<String> = emptyList()) = AgentChat(id, title,
            messages = listOf(AgentMessage(id + "-answer", MessageRole.ASSISTANT, answer, 1, if (device) AnswerOrigin.DEVICE else AnswerOrigin.MAC,
                work = if (sites.isEmpty()) null else ChatWork("worked", "sites", steps = sites.mapIndexed { i, site -> ChatStep("site-$i", "tool", "Read", "https://$site", "", "done") }))),
            owner = if (device) null else owner.copy(chat = id), pinned = pinned, unread = unread, updatedAt = now - minutes * 60_000)
        val rows = listOf(
            chat("plan", "Tern 2.0 launch plan", "The invite flow. It blocks the beta, and Jonas has it next to the billing work. If it slips past Oct 9, move the beta, not the launch.", 3 * 24 * 60, pinned = true),
            chat("lisbon", "Lisbon flights", "Booked · TAP, Oct 13 18:35, seat 14A", 29, sites = listOf("google.com", "flytap.com", "tap.pt")),
            chat("lumen", "Design Systems Night", "Spot requested · in Daybook", 62, unread = true, sites = listOf("lumen.events", "daybook.app")),
            chat("cafe", "Quiet cafés near Mariatorget", "Kaffe Söder on Hornsgatan opens at 7:30 and has one long table by the window. Bönor & Bröd opens at 8, quieter, with small tables only.", 410),
            chat("grinder", "Espresso grinders under $300", "The only one under $200 that grinds fine enough for espresso and still does pour-over. 40 steps, and quiet.", 1280),
            chat("crdt", "CRDTs, simply", "Two people edit the same list offline. Each change carries enough to be merged in any order, so when the copies meet they agree without asking who was first.", 2025, device = true))
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("figma", "https://figma.com/design/onboarding", "Onboarding v3", TabPlace.KEPT, createdAt = 1)
        val work = BrowserSpace("work", "Work", color = 0xFFE2E9F4, emoji = "💼", tabs = listOf(
            BrowserTab("pin-daybook", "https://daybook.app", "Daybook", TabPlace.PINNED, createdAt = 1),
            BrowserTab("pin-linear", "https://linear.app/tern/view/my-issues", "My issues · Linear", TabPlace.PINNED, createdAt = 1),
            BrowserTab("pin-slack", "https://slack.com/client/design", "#design · Slack", TabPlace.PINNED, createdAt = 1),
            BrowserTab("pin-figma", "https://figma.com/files/recents", "Recents · Figma", TabPlace.PINNED, createdAt = 1),
            tab.copy(folderId = "onboarding"),
            BrowserTab("spec", "https://paper.so/tern/onboarding-v3-spec", "Onboarding v3 spec · Paper", TabPlace.KEPT, createdAt = 1, folderId = "onboarding"),
            BrowserTab("funnel", "https://orbit.com/tern/funnels/activation", "Activation funnel · Orbit", TabPlace.KEPT, createdAt = 1, folderId = "onboarding"),
            BrowserTab("launch", "https://paper.so/tern/launch-notes", "Launch notes · Tern 2.0 · Paper", TabPlace.KEPT, createdAt = 1),
            BrowserTab("ledger", "https://ledger.app/tern/overview", "Overview · Ledger", TabPlace.KEPT, createdAt = 1),
            BrowserTab("work-hn", "https://news.ycombinator.com", "Hacker News", createdAt = 1),
            BrowserTab("work-gh-pr", "https://github.com/excalidraw/excalidraw/pull/12192", "feat(editor): wrap text at 800 and keep it clear of the side panels", createdAt = 1),
            BrowserTab("work-tern-local", "http://localhost:5173", "Tern · Calm scheduling for busy teams", createdAt = 1),
            BrowserTab("work-lumen", "https://lumen.events/e/design-systems-night", "Design Systems Night · Stockholm", createdAt = 1),
            BrowserTab("work-linear-method", "https://linear.app/method", "The Linear Method", createdAt = 1)),
            currentTabId = tab.id, folders = listOf(BrowserFolder("onboarding", "Onboarding v3", open = false)))
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("personal", "Personal"), work, BrowserSpace("lisbon", "Lisbon")), selectedSpaceId = work.id,
            settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT))
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
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope)
        try {
            compose.setContent { dev.yab.browser.ParitySystemBars(BrowserAppearance.LIGHT)
                BrowserScreen(browser, onAskQuestion = { _, _ -> }, onOpenChats = {},
                fieldChatsContent = { modifier, enabled ->
                    val field by browser.state.collectAsState()
                    val input = remember(field.surfaceEpoch, field.selectedSpaceId) { browser.captureFieldInput() }
                    var archived by remember(input) { mutableStateOf(false) }
                    val latestEnabled by rememberUpdatedState(enabled)
                    val source = remember(input, archived) { Any() }
                    dev.yab.browser.ui.BindBrowserFieldChatArchive(source, archived,
                        { latestEnabled && input?.let(browser::fieldInputCurrent) == true }) { archived = !archived }
                    FieldChatsPage(if (archived) emptyList() else rows, "", archived, source, enabled, { true }, {}, {}, { archived = it }, { _, _ -> false }, {},
                        { FieldChatDeleteQuestion("Unused") }, modifier, now = now, showArchiveControl = false)
                }, pageContent = { _, _, modifier -> Box(modifier) }) }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.runOnIdle { browser.openField(newTab = true) }
            val switchChats = compose.onNodeWithContentDescription("Spaces").fetchSemanticsNode()
                .config[androidx.compose.ui.semantics.SemanticsActions.CustomActions].single { it.label == "Switch to Chats" }.action
            compose.runOnIdle { assertTrue(switchChats()) }
            compose.onNodeWithTag("browser.field.archive").assertExists()
            val planCard = compose.onNodeWithTag("newtab.chat.plan").fetchSemanticsNode().boundsInRoot
            val lisbonCard = compose.onNodeWithTag("newtab.chat.lisbon").fetchSemanticsNode().boundsInRoot
            org.junit.Assert.assertEquals(planCard.height, lisbonCard.height, 1f)
            shot("chats.page")
            // Each Phone named state starts afresh on Work. Close this real card
            // completely before opening the address field, so its outgoing Chats page
            // is not mistaken for the new field's live background.
            val switchWork = compose.onNodeWithContentDescription("Spaces").fetchSemanticsNode()
                .config[androidx.compose.ui.semantics.SemanticsActions.CustomActions].single { it.label == "Switch to Work" }.action
            compose.runOnIdle { assertTrue(switchWork()) }
            compose.runOnIdle { browser.dismissSurface() }
            compose.waitUntil(10_000) { compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes().isEmpty() }
            compose.runOnIdle { browser.openField(newTab = false) }
            val input = compose.onNodeWithTag("browser.field.input")
            input.performTextReplacement("lisbon weather october")
            compose.onNodeWithText("Ask Claude", substring = true).assertExists()
            compose.waitUntil(10_000) {
                var visible = false
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    visible = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                        .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).any {
                            androidx.core.view.ViewCompat.getRootWindowInsets(it.window.decorView)?.isVisible(androidx.core.view.WindowInsetsCompat.Type.ime()) == true }
                }
                visible
            }
            compose.waitUntil(10_000) {
                var keyboardTop = 0
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                        .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).singleOrNull()?.let { activity ->
                            val decor = activity.window.decorView
                            val insets = androidx.core.view.ViewCompat.getRootWindowInsets(decor)
                            keyboardTop = decor.height - (insets?.getInsets(androidx.core.view.WindowInsetsCompat.Type.ime())?.bottom ?: 0)
                        }
                }
                val field = input.fetchSemanticsNode().boundsInWindow
                val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
                keyboardTop > 0 && keyboardTop - field.bottom in 0f..(60f * density)
            }
            shot("field.3")
            input.performTextReplacement("what does anna want?")
            shot("field.4")
        } finally { scope.cancel() }
    }
    companion object {
        val project = SyncProject("prj-1a2b3c4d", "Lisbon Trip", "🧳", "orange", instructions = "Trip Nov 14 to 19, two people, budget €2,000 all in. Walkable areas, Alfama or Chiado. Short lists with prices in euros.", memoryOn = true, pinned = true, order = "", created = 0.0, updated = 0.0)
    }
}

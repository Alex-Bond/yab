package dev.yab.android

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.ViewModelProvider
import dev.yab.browser.model.*
import dev.yab.agent.AnswerOrigin
import dev.yab.agent.DeliveryState
import dev.yab.agent.MessageRole
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real MainActivity browser -> typed quick question -> actual native CPU answer. */
class AppLocalQuestionTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test(timeout = 240_000)
    fun visiblePageQuestionUsesActualLocalModelWithoutMacAndStaysEphemeral(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(InstrumentationRegistry.getArguments().getString("requireModel") == "true")
        val blank = BrowserTab("question-empty", createdAt = 1)
        FileBrowserRepository(File(context.filesDir, "browser.json")).save(BrowserSnapshot(
            spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(blank), currentTabId = blank.id)),
            selectedSpaceId = BrowserController.PERSONAL_SPACE, settings = BrowserSettings(welcomed = true)))
        val question = "What city is the delivery going to? Answer with the city name."
        AppFlowTest.LocalPage().use { page ->
            val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse(page.url))
            ActivityScenario.launch<MainActivity>(intent).use { activity ->
                val diagnostics = AppFixtureDiagnostics(activity, "app-local-question")
                var phase = "awaiting_page"
                var bodyCompleted = false
                try {
                    lateinit var retained: BrowserSessionViewModel
                    activity.onActivity { retained = ViewModelProvider(it)[BrowserSessionViewModel::class.java] }
                    withTimeout(60_000) {
                        var loaded = false
                        while (!loaded) {
                            // This functional fixture owns a Compose test clock. Drain its
                            // real AndroidView attachment before asking the native bridge.
                            compose.waitForIdle()
                            loaded = try {
                                withContext(Dispatchers.Main) {
                                    val source = retained.browser.state.value
                                    source.tab?.takeIf { it.url == page.url && source.page.title == "Android flow article" &&
                                        !source.page.loading && source.page.progress >= 1f }?.let {
                                        retained.engine.readText(it).text.contains("The delivery city is Oslo.")
                                    } == true
                                }
                            } catch (cancelled: CancellationException) { throw cancelled }
                            catch (_: Exception) { false }
                            if (!loaded) delay(50)
                        }
                    }
                    phase = "page_ready"
                    diagnostics.capture(phase, "checkpoint")
                    // This is the address field's quick answer, rather than the Mac chat action.
                    compose.onNodeWithTag("browser.chrome.capsule", useUnmergedTree = true).performClick()
                    phase = "awaiting_question_field"
                    compose.waitUntil(15_000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().size == 1 }
                    compose.onNode(hasSetTextAction()).performTextReplacement(question)
                    phase = "awaiting_ask_action"
                    compose.waitUntil(15_000) { compose.onAllNodesWithText("About Page", substring = true).fetchSemanticsNodes().isNotEmpty() }
                    phase = "before_ask"
                    diagnostics.capture(phase, "checkpoint")
                    compose.onNodeWithText("About Page", substring = true).performClick()
                    phase = "after_ask"
                    diagnostics.capture(phase, "checkpoint")
                    phase = "awaiting_answer"
                    compose.waitUntil(120_000) {
                        val reply = retained.agent.state.value.current
                        reply != null && reply.delivery == DeliveryState.IDLE && reply.ephemeral && reply.owner == null &&
                            reply.page?.url == page.url && reply.messages.lastOrNull { it.role == MessageRole.ASSISTANT }?.let {
                                it.origin == AnswerOrigin.DEVICE && it.text.contains("Oslo", ignoreCase = true)
                            } == true && compose.onAllNodesWithText("Oslo", substring = true, ignoreCase = true).fetchSemanticsNodes().isNotEmpty()
                    }
                    phase = "answer_ready"
                    diagnostics.capture(phase, "checkpoint")
                    // The current chat uses the device avatar. Prove the real
                    // answer origin and absent Mac owner, rather than an old caption.
                    val reply = checkNotNull(retained.agent.state.value.current)
                    assertTrue(reply.ephemeral)
                    assertNull(reply.owner)
                    assertNull(retained.agent.state.value.connection.account)
                    assertEquals(AnswerOrigin.DEVICE, reply.messages.last { it.role == MessageRole.ASSISTANT }.origin)
                    val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
                    val output = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
                    File(output, "app-page-local-answer.png").outputStream().use { target ->
                        assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, target))
                    }
                    bitmap.recycle()
                    val saved = File(context.filesDir, "local-chats.json")
                    assertFalse("A quick answer must not become a saved chat before promotion", saved.isFile && saved.readText().contains(question))
                    assertTrue(page.requests.any { it.contains("/article") })
                    phase = "body_complete"
                    bodyCompleted = true
                } catch (failure: Throwable) {
                    diagnostics.capture(phase, "failure", bodyCompleted, screenshot = true)
                    throw failure
                } finally {
                    diagnostics.capture(phase, "before_close", bodyCompleted)
                }
            }
        }
    }
}

package dev.yab.agent

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.core.sync.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Native consumer view proof from owned wire fixtures, not a Mac producer execution claim. */
@RunWith(AndroidJUnit4::class)
class TaskScreenTest {
    @get:Rule val compose = createComposeRule()
    @Test fun retainedRequestAndActualObservationHaveADistinctScopedNativeSurface() {
        val epoch = "00000000-0000-0000-0000-000000000031"
        val origin = AgentTaskOrigin("space", "tab", "https://site.test/source", "Source")
        val request = TaskRecords.Request.create("account", "android", "mac", origin.space, "Read this exact public source", epoch, origin.tab, origin.url, origin.title)
        val saved = Record(TaskRecords.REQUEST, request.id).updated(request.fields(), Clock("android"))
        val checkedRequest = TaskRecords.Request.read(saved, "account", "android")
        val result = "# Actual result\n\n" + (1..25).joinToString("\n\n") { "Paragraph $it from the retained Mac observation." }
        val response = buildJsonObject {
            put("version", 1); put("task", request.id); put("requestDigest", request.digest()); put("account", "account"); put("phone", "android"); put("mac", "mac")
            put("revision", 2); put("session", "session"); put("status", "done"); put("title", "Observed task title"); put("progress", "Read all requested pages")
            put("result", result); put("resultURL", "https://site.test/result")
        }
        val observed = TaskRecords.Observation.read(Record(TaskRecords.OBSERVATION, request.id).updated(buildJsonObject { put("body", response.toString()) }, Clock("mac")), checkedRequest)
        val current = MutableStateFlow(listOf(ReadOnlyTask(checkedRequest, null, "My Mac", true)))
        var opened: String? = null
        var supplied: ReadOnlyTask? = null
        val source = mutableStateOf<AgentTaskOrigin?>(origin)
        val port = object : AgentTaskPort {
            override val tasks = current
            override val taskMacs = MutableStateFlow(emptyList<TaskMac>())
            override fun updateTaskScope(origin: AgentTaskOrigin?) {}
            override suspend fun sendTask(words: String, origin: AgentTaskOrigin, mac: String, epoch: String): ReadOnlyTask = error("This consumer proof cannot start a producer")
            override suspend fun openTaskResult(task: ReadOnlyTask, url: String): String? { supplied = task; return url.takeIf { current.value.single().observation == task.observation } }
        }
        compose.setContent { MaterialTheme { TaskScreen(port, source.value, request.id, onOpenWebsite = { opened = it }, onBack = {}) } }
        compose.onNodeWithTag("tasks.request").assertTextEquals(request.words)
        compose.onNodeWithTag("tasks.progress").assertTextEquals("Queued for your Mac")
        compose.onNodeWithTag("tasks.result").assertDoesNotExist()
        compose.runOnIdle { current.value = listOf(ReadOnlyTask(checkedRequest, observed, "My Mac", true)) }
        compose.onNodeWithTag("tasks.title").assertTextEquals("Observed task title")
        compose.onNodeWithTag("tasks.progress").assertTextEquals("Read all requested pages")
        compose.onNodeWithTag("tasks.result-url").performScrollTo().performClick()
        compose.runOnIdle { assertEquals("https://site.test/result", opened); assertEquals(observed, supplied?.observation) }
        val picture = compose.onRoot().captureToImage().asAndroidBitmap()
        val output = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "instrumentation/task-consumer.png")
        check(output.parentFile!!.isDirectory || output.parentFile!!.mkdirs())
        output.outputStream().use { assertTrue(picture.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
        compose.runOnIdle { source.value = null }
        compose.onNodeWithText(request.words).assertDoesNotExist()
        compose.onNodeWithText("Observed task title").assertDoesNotExist()
        compose.onNodeWithText("Read-only tasks").assertExists()
    }
}

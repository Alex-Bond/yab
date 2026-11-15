package dev.yab.android

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.view.WindowManager
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentLinkedQueue
import dev.yab.agent.MessageRole
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real application entrances and persistence, without replacing MainActivity's content. */
@RunWith(AndroidJUnit4::class)
class AppFlowTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 180_000)
    fun welcomeBrowseKeepRecreateAndPrivateEntrance() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") {
            "This test resets the disposable app profile and requires the owned emulator runner"
        }
        // The inference model and sync fixtures are deliberately retained.
        listOf("browser.json", "browser.json.pending", "browser.json.bak").forEach { File(context.filesDir, it).delete() }
        LocalPage().use { page ->
            ActivityScenario.launch(MainActivity::class.java).use { activity ->
                var originalIntent: Intent? = null
                activity.onActivity { originalIntent = Intent(it.intent) }
                val diagnostics = AppFixtureDiagnostics(activity, "app-flow")
                var phase = "awaiting_welcome"
                var bodyCompleted = false
                try {
                    compose.completeStandaloneFirstRun()
                    shot("app-welcome-completed.png")
                    phase = "opening_page"
                    compose.waitUntil(20_000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().size == 1 }
                    compose.onNode(hasSetTextAction()).performTextInput(page.url)
                    compose.onNode(hasSetTextAction()).performImeAction()
                    waitDescription("Reload")
                    waitForProfile { it.contains("Android flow article") && it.contains(page.url) }
                    shot("app-page.png")
                    phase = "keeping_page"
                    compose.onNodeWithContentDescription("Page menu").performClick()
                    waitText("Keep")
                    compose.onNodeWithText("Keep").performClick()
                    waitForProfile { it.contains("\"place\":\"KEPT\"") }
                    phase = "recreating_activity"
                    activity.recreate()
                    waitDescription("Reload")
                    compose.onNodeWithContentDescription("Page menu").performClick()
                    waitText("Kept")
                    shot("app-restored-kept.png")
                    phase = "private_entrance"
                    // Deliver a real singleTop launcher/deep-link entrance to the running Activity.
                    activity.onActivity { host ->
                        host.startActivity(Intent(host, MainActivity::class.java)
                            .setAction(Intent.ACTION_VIEW).setData(Uri.parse("yab://private"))
                            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    }
                    waitText("Search privately")
                    compose.onNode(hasSetTextAction()).performTextInput("private ephemeral phrase")
                    compose.waitUntil(10_000) {
                        var secure = false
                        activity.onActivity { secure = it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0 }
                        secure
                    }
                    assertFalse(File(context.filesDir, "browser.json").readText().contains("private ephemeral phrase"))
                    phase = "public_entrance"
                    // A public entrance must clear the private field and return to a public surface.
                    activity.onActivity { host ->
                        host.startActivity(Intent(host, MainActivity::class.java)
                            .setAction(Intent.ACTION_VIEW).setData(Uri.parse("yab://new"))
                            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    }
                    waitText("Search, ask or give a task")
                    compose.onAllNodesWithText("private ephemeral phrase").assertCountEquals(0)
                    shot("app-public-entrance.png")
                    phase = "keeping_shared_page"
                    val keptShare = page.url.replace("/article", "/keep-from-share")
                    activity.onActivity { host ->
                        host.startActivity(Intent(host, MainActivity::class.java).setAction(Intent.ACTION_SEND)
                            .setType("text/plain").putExtra(Intent.EXTRA_TEXT, "A shared article\n$keptShare")
                            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    }
                    waitText("Keep for Later")
                    shot("app-share-choices.png")
                    compose.onNodeWithText("Keep for Later").performClick()
                    waitForProfile { it.contains(keptShare) }
                    assertFalse("Keeping a share must not load the page", page.requests.any { it.contains("/keep-from-share") })
                    phase = "body_complete"
                    bodyCompleted = true
                } catch (failure: Throwable) {
                    diagnostics.capture(phase, "failure", bodyCompleted, screenshot = true)
                    throw failure
                } finally {
                    // This runs before ActivityScenario.close, even if close later times out.
                    diagnostics.capture(phase, "before_close", bodyCompleted, screenshot = true)
                    // AndroidX 1.7 tracks lifecycle only while getIntent matches its launch.
                    // Product onNewIntent correctly keeps the latest entrance; restore only
                    // this fixture's original tracker identity after proving all entrances.
                    activity.onActivity { host -> host.intent = Intent(requireNotNull(originalIntent)) }
                }
            }
        }
    }

    private fun waitText(text: String) = compose.waitUntil(30_000) {
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
    }
    private fun waitDescription(text: String) = compose.waitUntil(60_000) {
        compose.onAllNodesWithContentDescription(text).fetchSemanticsNodes().isNotEmpty()
    }
    private fun waitForProfile(predicate: (String) -> Boolean) = compose.waitUntil(20_000) {
        runCatching { predicate(File(context.filesDir, "browser.json").readText()) }.getOrDefault(false)
    }
    private fun shot(name: String) {
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val folder = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        File(folder, name).outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }

    internal class LocalPage : Closeable {
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val stopped = AtomicBoolean(false)
        val requests = ConcurrentLinkedQueue<String>()
        val url = "http://127.0.0.1:${socket.localPort}/article"
        private val worker = Thread({
            while (!stopped.get()) try {
                socket.accept().use { client ->
                    client.soTimeout = 5_000
                    val reader = client.getInputStream().bufferedReader()
                    var line = reader.readLine()
                    if (line != null) requests.add(line)
                    while (!line.isNullOrEmpty()) line = reader.readLine()
                    val body = "<!doctype html><title>Android flow article</title><h1>Android flow article</h1><p>The delivery city is Oslo. The parcel arrives on Friday.</p><p>This local page proves the shipped application can browse, keep and restore a real Gecko document.</p>".toByteArray()
                    client.getOutputStream().apply {
                        write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(body); flush()
                    }
                }
            } catch (error: Exception) {
                // Gecko may cancel speculative/fav-icon connections while the
                // Activity is recreated. A closed client must not kill the app.
                if (!stopped.get() && error !is IOException) throw error
            }
        }, "app-flow-page").apply { isDaemon = true; start() }
        override fun close() { stopped.set(true); socket.close(); worker.join(1_000) }
    }
}

/** Only fixed phases, booleans and counts from this disposable fixture enter the JSON. */
internal class AppFixtureDiagnostics(
    private val scenario: ActivityScenario<MainActivity>,
    private val prefix: String,
) {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val samples = JSONArray()
    private val folder = File(context.getExternalFilesDir(null), "instrumentation")

    init {
        require(prefix in setOf("app-flow", "app-local-question"))
        // A later successful run must not export an older failure screenshot.
        listOf("$prefix-diagnostics.json", "$prefix-failure.png", "$prefix-before-close.png")
            .forEach { File(folder, it).delete() }
    }

    fun capture(phase: String, point: String, bodyCompleted: Boolean = false, screenshot: Boolean = false) {
        require(phase.matches(Regex("[a-z_]{1,48}")) && point in setOf("checkpoint", "failure", "before_close"))
        val row = JSONObject().put("phase", phase).put("point", point).put("bodyCompleted", bodyCompleted)
            .put("stateAvailable", false).put("screenshotCaptured", false)
        var secureWindow = true
        // Diagnostics must not replace the original assertion or ActivityScenario.close failure.
        runCatching {
            row.put("scenarioLifecycle", scenario.state.name)
            scenario.onActivity { host ->
                row.put("activityLifecycle", host.lifecycle.currentState.name)
                    .put("activityFinishing", host.isFinishing).put("activityDestroyed", host.isDestroyed)
                    .put("activityWindowFocused", host.hasWindowFocus())
                row.put("questionStage", host.pageQuestionStage.name).put("questionActive", host.pageQuestionActive)
                secureWindow = host.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
                row.put("secureWindow", secureWindow)
                val retained = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                val agent = retained.agent.state.value
                val current = agent.current
                val model = retained.models.state.value
                val browser = retained.browser.state.value
                val roles = JSONObject()
                MessageRole.values().forEach { role -> roles.put(role.name, current?.messages?.count { it.role == role } ?: 0) }
                row.put("agent", JSONObject().put("loaded", agent.loaded).put("currentExists", current != null)
                    .put("privateContext", agent.privateContext).put("currentPrivate", current?.privateOrigin ?: JSONObject.NULL)
                    .put("currentPublic", current?.let { !it.privateOrigin } ?: JSONObject.NULL)
                    .put("ephemeral", current?.ephemeral ?: JSONObject.NULL)
                    .put("delivery", current?.delivery?.name ?: JSONObject.NULL)
                    .put("pageContextPresent", current?.page != null).put("pageTextCharacters", current?.page?.text?.length ?: 0)
                    .put("pageAnswerMode", agent.preferences.pageAnswers.name)
                    .put("messageRoleCounts", roles).put("errorPresent", agent.error != null))
                row.put("model", JSONObject().put("ready", model.ready).put("importing", model.importing)
                    .put("running", model.running).put("bytes", model.bytes).put("errorPresent", model.error != null))
                row.put("browser", JSONObject().put("loading", browser.loading).put("pageLoading", browser.page.loading)
                    .put("surface", browser.surface.name).put("privateBlocked", browser.privateContentBlocked)
                    .put("nativeOwnerAvailable", retained.engine.captureExternalActivityOwner() != null))
                row.put("pageRead", retained.engine.textReadDiagnostics(browser.tab?.id))
                row.put("stateAvailable", true)
            }
        }
        if (screenshot && !secureWindow) runCatching {
            val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: return@runCatching
            try {
                folder.mkdirs()
                val name = if (point == "before_close") "$prefix-before-close.png" else "$prefix-failure.png"
                File(folder, name).outputStream().use {
                    row.put("screenshotCaptured", bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
                }
            } finally { bitmap.recycle() }
        }
        if (samples.length() < 12) samples.put(row)
        runCatching {
            folder.mkdirs()
            File(folder, "$prefix-diagnostics.json").writeText(JSONObject().put("schema", 1).put("samples", samples).toString(2))
        }
    }
}

package dev.yab.agent

import android.graphics.Bitmap
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Native wall-clock proof: no Compose test rule, virtual clock or artificial frame pacing. */
class ChatInfoRealtimeDeviceTest {
    @Test fun nativeZoomAndCancelledAndCompletedPullReturnToTheSameChat() {
        val i = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(i.uiAutomation.executeShellCommand(command)).use { it.readBytes() }
        fun find(label: String): android.view.accessibility.AccessibilityNodeInfo? {
            val root = i.uiAutomation.rootInActiveWindow ?: return null
            fun visit(node: android.view.accessibility.AccessibilityNodeInfo): android.view.accessibility.AccessibilityNodeInfo? {
                if (node.isVisibleToUser && (node.text?.toString() == label || node.contentDescription?.toString() == label)) return node
                for (index in 0 until node.childCount) { node.getChild(index)?.let { visit(it)?.let { match -> return match } } }
                return null
            }
            return visit(root)
        }
        fun waitFor(label: String, shown: Boolean = true): Boolean {
            val until = SystemClock.elapsedRealtime() + 10_000
            while (SystemClock.elapsedRealtime() < until) {
                if ((find(label) != null) == shown) return true
                SystemClock.sleep(50)
            }
            return false
        }
        fun click(label: String) {
            val node = checkNotNull(find(label))
            val bounds = android.graphics.Rect().also { node.getBoundsInScreen(it) }
            shell("input tap ${bounds.centerX()} ${bounds.centerY()}")
        }
        val chat = AgentChat("native-motion", "Anna’s hours picker", messages = listOf(
            AgentMessage("u1", MessageRole.USER, "what does anna want?", 1),
            AgentMessage("a1", MessageRole.ASSISTANT, "Anna wants a “same as last week” button on the hours picker, so people don’t set their focus hours from scratch every Monday. She left it on frame 2, Pick your focus hours.", 2, AnswerOrigin.DEVICE),
            AgentMessage("u2", MessageRole.USER, "and what did she say about the sprint?", 3),
            AgentMessage("a2", MessageRole.ASSISTANT, "On Thursday in Slack she asked to move it to the next sprint: the beta needs the invite flow first. She’ll pair with you on it next Monday.", 4, AnswerOrigin.DEVICE)),
            page = PageContext("Onboarding v3", "https://figma.com/design/onboarding", ""))
        val port = object : RemoteAgentTransport {
            override val connection = MutableStateFlow(RemoteConnection())
            override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
            override suspend fun send(command: AgentSendCommand): AgentSendReceipt = error("No external actions")
            override suspend fun stop(owner: RemoteOwner): Unit = error("No external actions")
            override suspend fun delete(owner: RemoteOwner): Unit = error("No external actions")
            override suspend fun answerApproval(answer: ApprovalAnswer): Unit = error("No external actions")
        }
        val repository = AgentRepository(object : ChatPersistence {
            override suspend fun load() = ChatSnapshot(chats = listOf(chat))
            override suspend fun save(snapshot: ChatSnapshot) {}
        }, UnavailableLocalAiAdapter(), port).also { runBlocking { it.load() }; it.open(chat.id) }
        val folder = File(i.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        fun shot(name: String) {
            val bitmap = checkNotNull(i.uiAutomation.takeScreenshot())
            File(folder, "parity-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }; bitmap.recycle()
        }
        ActivityScenario.launch(EngineTestActivity::class.java).use { activity ->
            activity.onActivity { host -> host.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
                Surface(Modifier.fillMaxSize()) { Box(Modifier.fillMaxSize().safeDrawingPadding()) { AgentScreen(repository, false, collectInScreen = false) } }
            } } }
            assertTrue(waitFor(chat.title))
            shot("chat.realtime")
            val movie = File(folder, "chat-info-realtime.mp4")
            val recording = i.uiAutomation.executeShellCommand("screenrecord --bit-rate 8000000 --time-limit 12 ${movie.absolutePath}")
            SystemClock.sleep(400)
            click(chat.title)
            assertTrue(waitFor("Back to chat"))
            SystemClock.sleep(700); shot("chat.info-realtime")
            val density = i.targetContext.resources.displayMetrics.density
            val x = i.targetContext.resources.displayMetrics.widthPixels / 2
            val y = (200 * density).toInt()
            shell("input swipe $x $y $x ${y + (40 * density).toInt()} 350")
            SystemClock.sleep(500)
            assertTrue(waitFor("Back to chat"))
            shell("input swipe $x $y $x ${y + (350 * density).toInt()} 500")
            assertTrue(waitFor("Back to chat", false))
            assertTrue(waitFor("Message"))
            assertTrue(waitFor(chat.title))
            SystemClock.sleep(350)
            click(chat.title)
            assertTrue(waitFor("Back to chat"))
            SystemClock.sleep(700)
            click("Back to chat")
            assertTrue(waitFor("Back to chat", false))
            ParcelFileDescriptor.AutoCloseInputStream(recording).use { it.readBytes() }
            assertTrue(movie.length() > 1024)
            File(folder, "chat-info-realtime.json").writeText("""{"kind":"production-component-fixture","reference":"iphone-0.1.13","nativeWallClock":true,"composeTestClock":false,"cancelledPull":true,"completedPull":true,"externalActions":false,"realMac":false}""")
        }
    }
}

package dev.yab.agent

import android.content.Intent
import android.graphics.Rect
import android.net.Uri
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.MainActivity
import dev.yab.browser.TranslationDomTest
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** Actual MainActivity and native keyboard events; no replacement chat UI or model. */
class MainChatDraftDeviceTest {
    @Test(timeout = 180_000)
    fun longNativeDraftSurvivesEveryKeyboardEvent(): Unit = runBlocking {
        val registry = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        fun labels(node: AccessibilityNodeInfo?): List<Pair<String, Rect>> {
            if (node == null) return emptyList()
            val box = Rect().also(node::getBoundsInScreen)
            return listOfNotNull(node.text?.toString(), node.contentDescription?.toString()).map { it to box } +
                (0 until node.childCount).flatMap { labels(node.getChild(it)) }
        }
        suspend fun point(label: String): Rect {
            repeat(120) {
                val matches = labels(registry.uiAutomation.rootInActiveWindow).filter { it.first == label }.map { it.second }.distinct()
                if (matches.size == 1) return matches.single()
                delay(500)
            }
            error("Actual MainActivity control unavailable: $label")
        }
        suspend fun tap(label: String, hold: Long = 32) {
            val box = point(label); val start = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(start, SystemClock.uptimeMillis(), action, box.exactCenterX(), box.exactCenterY(), 0)
                    .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                try { check(registry.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
                if (action == MotionEvent.ACTION_DOWN) delay(hold)
            }
            delay(500)
        }
        val expected = "Open only http://127.0.0.1:12345/approval-fixture/0123456789abcdef0123456789abcdef in a new browser tab. " +
            "Use the normal browser click tool to attempt the Delete synthetic draft button exactly once. " +
            "Wait for the actual Yab approval which I will decline on Android. Never bypass or retry the declined action. " +
            "Once the tool confirms the decline reply only validationtoken. Do not inspect files use other sites or change anything else."
        val result = JSONObject().put("expectedLength", expected.length).put("actualMainActivity", true).put("modelInvoked", false)
        val folder = File(registry.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        try {
            TranslationDomTest.TranslationFixture().use { site ->
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(site.url)).setClass(registry.targetContext, MainActivity::class.java)
                ActivityScenario.launch<MainActivity>(intent).use { scenario ->
                    tap("Tabs, hold for new tab", 850);tap("New Chat")
                    delay(1_000)
                    val current = labels(registry.uiAutomation.rootInActiveWindow)
                    listOf("Don’t allow", "Don't allow").firstOrNull { label -> current.any { it.first == label } }?.let { tap(it) }
                    val afterPermission = labels(registry.uiAutomation.rootInActiveWindow)
                    if (afterPermission.none { it.first == "Message" } && afterPermission.any { it.first == "New Chat" }) tap("New Chat")
                    tap("Message")
                    val events = checkNotNull(KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(expected.toCharArray()))
                    for (event in events) check(registry.uiAutomation.injectInputEvent(event, true))
                    delay(1_000)
                    var actual = ""
                    scenario.onActivity { activity ->
                        val repository = MainActivity::class.java.getDeclaredField("agent").apply { isAccessible = true }.get(activity) as AgentRepository
                        actual = repository.state.value.current?.draft.orEmpty()
                    }
                    result.put("actualLength", actual.length).put("passed", actual == expected)
                    registry.uiAutomation.takeScreenshot()?.let { image ->
                        File(folder, "main-chat-long-draft.png").outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                        image.recycle()
                    }
                    assertEquals("The real chat draft lost native keyboard input", expected, actual)
                }
            }
        } finally { File(folder, "main-chat-long-draft.json").writeText(result.toString(2)) }
    }
}

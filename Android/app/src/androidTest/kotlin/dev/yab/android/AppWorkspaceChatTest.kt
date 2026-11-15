package dev.yab.android

import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.view.View
import android.view.KeyEvent
import android.view.ViewGroup
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.OwnedBrowserTestUi
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView

/** Actual app chat and page share the retained session through rotation and recreation. */
class AppWorkspaceChatTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 180_000)
    fun wideConversationKeepsTheLivePageAndRestoresItAfterThePhoneCover(): Unit = runBlocking {
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        ui.run {
            check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
            check(shell("getprop ro.kernel.qemu").trim() == "1")
            val size = overrideValue(shell("wm size"))
            val density = overrideValue(shell("wm density"))
            val blank = BrowserTab("workspace-chat-empty", createdAt = 1)
            FileBrowserRepository(File(context.filesDir, "browser.json")).save(BrowserSnapshot(
                spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(blank), currentTabId = blank.id)),
                selectedSpaceId = BrowserController.PERSONAL_SPACE, settings = BrowserSettings(welcomed = true)))
            try {
                shell("wm density 160"); shell("wm size 1280x800")
                AppFlowTest.LocalPage().use { page ->
                    val entrance = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse(page.url))
                    ui.checkpoint("before_activity_launch")
                    NativeMainActivityFixture.launch(entrance, NativeMainActivityFixture.Kind.APP_WORKSPACE).use { scenario ->
                        ui.checkpoint("after_activity_launch")
                        compose.waitUntil(60_000) { compose.onAllNodesWithContentDescription("Reload").fetchSemanticsNodes().isNotEmpty() }
                        lateinit var session: GeckoSession
                        var fullWidth = 0
                        scenario.onActivity { host ->
                            val retained = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                            ui.bind(retained.browser, retained.engine)
                            val view = pageView(host)
                            session = checkNotNull(view.session); fullWidth = view.width
                            host.startActivity(Intent(host, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
                                .setData(Uri.parse("yab://ask")).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
                        }
                        waitChats()
                        compose.waitUntil(15_000) {
                            var narrowed = false
                            scenario.onActivity { host ->
                                val view = pageView(host)
                                narrowed = view.width in 320 until fullWidth && view.session === session
                            }
                            narrowed
                        }
                        assertChatOutsideSystemBars(scenario)
                        shot("app-wide-chat-and-page.png")
                        ui.checkpoint("before_recreate")
                        scenario.recreate()
                        ui.checkpoint("after_recreate")
                        waitChats()
                        scenario.onActivity { host ->
                            assertSame("Activity recreation replaced the native document", session, pageView(host).session)
                            assertEquals(page.url, ViewModelProvider(host)[BrowserSessionViewModel::class.java].browser.state.value.tab?.url)
                        }
                        shell("wm size 480x1000")
                        waitChats()
                        compose.waitUntil(15_000) {
                            var covered = false
                            scenario.onActivity { host -> covered = pageView(host).let {
                                it.width >= 460 && it.session === session && it.importantForAccessibility == View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                            } }
                            covered
                        }
                        assertChatOutsideSystemBars(scenario)
                        shot("app-phone-chat-cover.png")
                        shell("wm size 1280x800")
                        compose.waitUntil(15_000) {
                            var wide = false
                            scenario.onActivity { host ->
                                wide = host.window.decorView.width == 1280 && host.resources.configuration.screenWidthDp >= 1200
                            }
                            wide && compose.onAllNodesWithTag("chat.header").fetchSemanticsNodes().singleOrNull()
                                ?.boundsInWindow?.right?.let { it > 1200f } == true
                        }
                        compose.waitForIdle()
                        ui.requireOwnCurrent()
                        shot("app-wide-chat-after-rotation.png")
                        val chatDiagnostics = org.json.JSONArray()
                        fun chatStatus(phase: String) {
                            scenario.onActivity { host -> chatDiagnostics.put(org.json.JSONObject(host.projectUiDiagnostics?.invoke().orEmpty()).put("phase", phase)) }
                            val output = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
                            File(output, "app-workspace-chat-return.json").writeText(chatDiagnostics.toString(2))
                        }
                        chatStatus("before_back")
                        compose.onNodeWithContentDescription("Back to Chats").performClick()
                        chatStatus("after_back")
                        compose.waitUntil(15_000) { compose.onAllNodesWithTag("chat.header").fetchSemanticsNodes().isEmpty() }
                        ui.requireOwnCurrent()
                        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
                        compose.waitUntil(15_000) {
                            var restored = false
                            scenario.onActivity { host -> restored = pageView(host).let {
                                it.width == fullWidth && it.session === session && it.importantForAccessibility == View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
                            } }
                            restored
                        }
                        shot("app-wide-page-after-chat.png")
                    }
                }
            } finally {
                shell("wm size ${size ?: "reset"}"); shell("wm density ${density ?: "reset"}")
            }
        }
    }

    private fun pageView(host: MainActivity): GeckoView {
        val found = mutableListOf<GeckoView>()
        fun visit(view: View) {
            if (view is GeckoView && view.isAttachedToWindow && view.session != null) found += view
            if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(host.window.decorView)
        return found.single()
    }
    private fun waitChats() = compose.waitUntil(20_000) { compose.onAllNodesWithTag("chat.header").fetchSemanticsNodes().isNotEmpty() }
    private fun assertChatOutsideSystemBars(scenario: NativeMainActivityFixture) {
        var top = 0
        var bottom = 0
        var height = 0
        scenario.onActivity { host ->
            val view = host.window.decorView
            val bars = checkNotNull(ViewCompat.getRootWindowInsets(view)).getInsets(WindowInsetsCompat.Type.systemBars())
            top = bars.top; bottom = bars.bottom; height = view.height
        }
        val close = compose.onNodeWithTag("chat.header").fetchSemanticsNode().boundsInWindow
        val composer = compose.onNodeWithTag("chat.composer").fetchSemanticsNode().boundsInWindow
        assertTrue("Chat controls overlap the Android status bar", close.top >= top)
        assertTrue("Chat composer overlaps the Android navigation bar", composer.bottom <= height - bottom)
    }
    private fun overrideValue(text: String) = text.lineSequence().firstOrNull { it.startsWith("Override ") }?.substringAfter(": ")?.trim()
    private fun shell(command: String): String = instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
    }
    private fun shot(name: String) {
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val output = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        File(output, name).outputStream().use { assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }
}

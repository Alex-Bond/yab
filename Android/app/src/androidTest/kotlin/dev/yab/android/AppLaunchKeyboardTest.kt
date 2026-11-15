package dev.yab.android

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** The registered test process opts out unless this actual Main launch explicitly opts in. */
class AppLaunchKeyboardTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 180_000)
    fun actualRegisteredFixtureOptsOutAndExplicitPublicLaunchOpensOneFocusedEditorWithRealIme(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36 && shell("getprop ro.kernel.qemu").trim() == "1")
        val file = File(context.filesDir, "browser.json")
        val oldBrowser = file.takeIf { it.isFile }?.readBytes()
        val preferences = context.getSharedPreferences("launch-keyboard", Context.MODE_PRIVATE)
        val oldMemory = preferences.getString("front", null)
        val phases = JSONArray()
        val samples = JSONArray()
        var complete = false
        var restored = false
        var primary: Throwable? = null
        fun phase(name: String) { check(phases.length() < 4); phases.put(name) }
        try {
            assertTrue("The actual public AndroidX registry is registered in this native process", LaunchKeyboardTestEnvironment.registered())
            AppFlowTest.LocalPage().use { page ->
                val tab = BrowserTab("launch-keyboard-public", page.url, "Launch keyboard original", TabPlace.KEPT, createdAt = 1)
                val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(tab), currentTabId = tab.id)
                val snapshot = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                    settings = BrowserSettings(welcomed = true, openKeyboardAtLaunch = true))
                val sync = (context.applicationContext as YabApplication).sync
                for (explicit in listOf(false, true)) {
                    FileBrowserRepository(file).save(snapshot)
                    check(preferences.edit().remove("front").commit())
                    val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
                    if (explicit) intent.putExtra(LaunchKeyboardTestEnvironment.EXTRA, true)
                    NativeMainActivityFixture.launch(intent, NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                        lateinit var model: BrowserSessionViewModel
                        fixture.onActivity { host -> model = ViewModelProvider(host)[BrowserSessionViewModel::class.java] }
                        val browser = model.browser
                        await("the same original public tab and actual Main launch decision") {
                            val editors = compose.onAllNodesWithTag(INPUT).fetchSemanticsNodes()
                            var ready = false
                            fixture.onActivity { host ->
                                val state = browser.state.value
                                val account = sync.accountRecords.value
                                val insets = ViewCompat.getRootWindowInsets(host.window.decorView)
                                val editor = editors.singleOrNull()
                                val editorView = (editor?.root as? ViewRootForTest)?.view
                                val source = model.launchKeyboardSource()
                                val common = !state.loading && state.settings.welcomed && state.settings.openKeyboardAtLaunch &&
                                    state.tab?.id == tab.id && state.tab?.url == tab.url && state.selectedSpaceId == space.id &&
                                    state.space?.websiteProfile == space.websiteProfile && !state.privateContentBlocked &&
                                    state.workspace == null && model.engine.hasLiveSession(tab.id) && sync.nativeOwnerCurrent(account) &&
                                    source?.active == true && !source.removed && model.launchKeyboard.arrival.value == null &&
                                    host.intent.action == Intent.ACTION_MAIN && host.intent.getBooleanExtra(LaunchKeyboardTestEnvironment.EXTRA, false) == explicit
                                val focused = editor?.config?.getOrNull(SemanticsProperties.Focused) == true
                                val enabled = editor != null && !editor.config.contains(SemanticsProperties.Disabled)
                                val ownRoot = editorView != null && editorView.isAttachedToWindow && editorView.isShown &&
                                    editorView.rootView === host.window.decorView && editorView.windowToken != null &&
                                    editorView.windowToken === host.window.decorView.windowToken
                                val ime = insets?.isVisible(WindowInsetsCompat.Type.ime()) == true &&
                                    insets.getInsets(WindowInsetsCompat.Type.ime()).bottom > 0
                                ready = common && if (explicit) state.surface == BrowserSurface.FIELD && state.fieldIsNewTab &&
                                    !state.fieldIsPrivate && !state.fieldResting && editors.size == 1 && focused && enabled && ownRoot && ime
                                else state.surface == BrowserSurface.PAGE && editors.isEmpty() &&
                                    !state.page.loading && state.page.title == "Android flow article"
                                if (samples.length() == 4) samples.remove(0)
                                samples.put(JSONObject().put("explicit", explicit).put("samePublicFront", state.tab?.id == tab.id && state.tab?.url == tab.url)
                                    .put("sameProfile", state.space?.websiteProfile == space.websiteProfile).put("loading", state.loading)
                                    .put("page", state.surface == BrowserSurface.PAGE).put("newTab", state.surface == BrowserSurface.FIELD && state.fieldIsNewTab)
                                    .put("private", state.fieldIsPrivate).put("arrivalPresent", model.launchKeyboard.arrival.value != null)
                                    .put("editorCount", editors.size.coerceAtMost(2)).put("focused", focused).put("enabled", enabled)
                                    .put("sameMainRoot", ownRoot).put("imeVisible", ime).put("accountCurrent", sync.nativeOwnerCurrent(account)))
                            }
                            ready
                        }
                        fixture.onActivity {
                            val state = browser.state.value
                            assertEquals(tab.id, state.tab?.id); assertEquals(tab.url, state.tab?.url)
                            assertEquals(space.websiteProfile, state.space?.websiteProfile)
                            assertEquals(listOf(tab.id), state.space?.tabs?.map(BrowserTab::id))
                            assertNull(state.workspace); assertTrue(model.engine.hasLiveSession(tab.id))
                            assertNull(model.launchKeyboard.arrival.value)
                        }
                        if (explicit) {
                            compose.onNodeWithTag(INPUT).assertIsDisplayed().assertIsEnabled().assertIsFocused()
                            phase("EXPLICIT_PUBLIC_LAUNCH_REAL_EDITOR_IME")
                        } else {
                            compose.onAllNodesWithTag(INPUT).assertCountEquals(0)
                            phase("REGISTERED_FIXTURE_KEEPS_ORIGINAL_PAGE")
                        }
                    }
                }
            }
            complete = true
        } catch (error: Throwable) { primary = error; throw error }
        finally {
            var cleanup: Throwable? = null
            fun attempt(block: () -> Unit) { try { block() } catch (error: Throwable) {
                if (cleanup == null) cleanup = error else cleanup!!.addSuppressed(error)
            } }
            attempt {
                if (oldBrowser != null) file.writeBytes(oldBrowser) else check(!file.exists() || file.delete())
                val editor = preferences.edit()
                if (oldMemory == null) editor.remove("front") else editor.putString("front", oldMemory)
                check(editor.commit())
                restored = (if (oldBrowser == null) !file.exists() else file.readBytes().contentEquals(oldBrowser)) &&
                    preferences.getString("front", null) == oldMemory
                check(restored)
            }
            attempt {
                val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
                check(folder.isDirectory || folder.mkdirs())
                File(folder, "app-launch-keyboard.json").writeText(JSONObject().put("schema", 1).put("completed", complete)
                    .put("ownLocalFixtureDataRestored", restored).put("registeredInstrumentation", LaunchKeyboardTestEnvironment.registered())
                    .put("phases", phases).put("samples", samples).toString(2))
            }
            cleanup?.let { if (primary != null) primary!!.addSuppressed(it) else throw it }
        }
    }

    private suspend fun await(reason: String, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (true) { compose.waitForIdle(); if (ready()) return
            check(SystemClock.elapsedRealtime() < deadline) { reason }; delay(40) }
    }
    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    companion object { private const val INPUT = "browser.field.input" }
}

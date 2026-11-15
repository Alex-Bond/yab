package dev.yab.android

import android.app.role.RoleManager
import android.content.Intent
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.model.*
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** The ordinary No Mac journey. No pairing completion, role request or OS permission is synthesized. */
class AppFirstRunContinuationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun actualNoMacJourneyRetiresItsOldActivityControlsThenOpensExactlyOneRealNewTab(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36 && shell("getprop ro.kernel.qemu").trim() == "1")
        val oldSize = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}"))
        val oldDensity = overrideValue(shell("wm density"), Regex("[0-9]{2,4}"))
        val phases = JSONArray(); val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        var completed = false; var restored = false; var primary: Throwable? = null
        try { ui.run {
            shell("wm density 160"); shell("wm size 900x768")
            AppFlowTest.LocalPage().use { page ->
                NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                    NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                    lateinit var model: BrowserSessionViewModel
                    fixture.onActivity { host ->
                        model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                        ui.bind(model.browser, model.engine) { model.browser.workspaceWindow.value.generation }
                    }
                    val browser = model.browser
                    fun shown(tag: String) = compose.onAllNodesWithTag(tag).fetchSemanticsNodes().size == 1
                    suspend fun click(label: String) { compose.waitForIdle(); ui.click(label); compose.waitForIdle() }
                    await("the actual Main registers its full tablet window") {
                        !browser.state.value.loading && browser.workspaceWindow.value.let {
                            it.registered && it.geometry == BrowserWorkspaceWindow(900.0, 768.0)
                        }
                    }
                    val first = BrowserTab("first-run-document", page.url, "First run original page", TabPlace.KEPT, createdAt = 1)
                    fixture.onActivity { host ->
                        check((host.application as YabApplication).sync.identityLease() == null)
                        val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(first), currentTabId = first.id)
                        browser.applySyncedSnapshot(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                            settings = BrowserSettings(welcomed = false)))
                        browser.selectTab(first.id)
                        browser.updateSettings(browser.state.value.settings.copy(welcomed = false))
                        check(browser.state.value.surface == BrowserSurface.PAGE)
                        model.engine.navigate(checkNotNull(browser.state.value.tab), first.url, space.websiteProfile)
                    }
                    await("the real underlying document and first choice are ready") {
                        browser.state.value.let { it.tab?.id == first.id && it.tab?.url == first.url &&
                            !it.page.loading && it.page.title == "Android flow article" && !it.settings.welcomed } && shown("welcome.noMac")
                    }
                    assertFalse(browser.state.value.settings.welcomed)
                    click("No Mac yet")
                    await("the original No Mac body is visible") { shown("welcome.withoutMac") }
                    val originalFlow = requireNotNull(model.firstRun.value)
                    val oldUse = dev.yab.browser.originalRenderedClick(
                        compose.onNodeWithTag("welcome.withoutMac").fetchSemanticsNode())
                    fixture.recreate()
                    await("the same logical journey has fresh No Mac controls") {
                        model.firstRun.value === originalFlow && shown("welcome.withoutMac")
                    }
                    fixture.onActivity { oldUse() }
                    assertFalse(browser.state.value.settings.welcomed)
                    assertEquals(FirstRunPresentation.Step.NO_MAC, originalFlow.state.value.step)
                    phases.put("OLD_ACTIVITY_CONTROL_REFUSED")
                    var linksExpected = false
                    fixture.onActivity { host ->
                        val roles = host.getSystemService(RoleManager::class.java)
                        linksExpected = roles.isRoleAvailable(RoleManager.ROLE_BROWSER) && !roles.isRoleHeld(RoleManager.ROLE_BROWSER)
                    }
                    val before = browser.state.value
                    click("Use Without a Mac")
                    if (linksExpected) {
                        await("the actual available role is offered without requesting it") { shown("welcome.linksNotNow") }
                        assertFalse(browser.state.value.settings.welcomed)
                        assertEquals(FirstRunPresentation.Step.LINKS, originalFlow.state.value.step)
                        assertTrue(shown("welcome.makeDefault"))
                        click("Not Now"); phases.put("LINKS_DECLINED_WITHOUT_OS_REQUEST")
                    } else phases.put("ROLE_ALREADY_HELD_OR_UNAVAILABLE")
                    await("completion opens one focused real New Tab and its real keyboard") {
                        val editors = compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes()
                        if (editors.size != 1) return@await false
                        var nativeReady = false
                        fixture.onActivity { host ->
                            val state = browser.state.value
                            val insets = ViewCompat.getRootWindowInsets(host.window.decorView)
                            nativeReady = state.settings.welcomed && state.surface == BrowserSurface.FIELD && state.fieldIsNewTab &&
                                !state.fieldIsPrivate && !state.fieldResting && state.surfaceEpoch == before.surfaceEpoch + 1 &&
                                insets?.isVisible(WindowInsetsCompat.Type.ime()) == true &&
                                insets.getInsets(WindowInsetsCompat.Type.ime()).bottom > 0 &&
                                editors.single().config.getOrNull(SemanticsProperties.Focused) == true
                        }
                        nativeReady && !shown("welcome.withoutMac") && !shown("welcome.linksNotNow")
                    }
                    compose.onNodeWithTag("browser.field.input").assertIsDisplayed().assertIsEnabled().assertIsFocused()
                    assertEquals(first.id, browser.state.value.tab?.id)
                    assertEquals(first.url, browser.state.value.tab?.url)
                    assertNull(model.firstRun.value)
                    val accepted = browser.state.value
                    fixture.onActivity { oldUse() }
                    assertEquals(accepted, browser.state.value)
                    phases.put("REAL_NEW_TAB_IME"); completed = true
                }
            }
        } } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            val cleanup = runCatching {
                shell(if (oldSize == null) "wm size reset" else "wm size $oldSize")
                shell(if (oldDensity == null) "wm density reset" else "wm density $oldDensity")
                check(overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}")) == oldSize)
                check(overrideValue(shell("wm density"), Regex("[0-9]{2,4}")) == oldDensity)
                restored = true
            }.exceptionOrNull()
            val folder = File(context.getExternalFilesDir(null), "instrumentation"); check(folder.isDirectory || folder.mkdirs())
            File(folder, "first-run-continuation.json").writeText(JSONObject().put("schema", 1).put("completed", completed)
                .put("wmRestored", restored).put("phases", phases).put("pairingProof", false)
                .put("roleRequestExecuted", false).put("roleGrantedClaim", false).put("rawOSCaptured", false).toString(2))
            if (cleanup != null) { if (primary != null) primary.addSuppressed(cleanup) else throw cleanup }
        }
    }
    private suspend fun await(reason: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (true) {
            compose.waitForIdle()
            if (predicate()) return
            check(SystemClock.elapsedRealtime() < deadline) { reason }
            delay(40)
        }
    }
    private fun overrideValue(output: String, value: Regex): String? = output.lineSequence()
        .map(String::trim).firstOrNull { it.startsWith("Override ") }?.substringAfter(':')?.trim()?.also { check(value.matches(it)) }
    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
        .bufferedReader().use { it.readText() }
}

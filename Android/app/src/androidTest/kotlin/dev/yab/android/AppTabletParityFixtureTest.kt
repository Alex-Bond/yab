package dev.yab.android

import android.content.Intent
import android.graphics.Bitmap
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.model.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Actual Main, retained Gecko documents and real tablet windows. No Mac account or remote work. */
class AppTabletParityFixtureTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val i get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = i.targetContext
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(i.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun override(text: String) = text.lineSequence().firstOrNull { it.startsWith("Override") }?.substringAfter(':')?.trim()
    private fun stage(value: String) {
        val folder = File(context.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        File(folder, "tablet-stages.txt").appendText(value + "\n")
    }
    private fun shot(name: String) {
        compose.waitForIdle(); SystemClock.sleep(500)
        val folder = File(context.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(i.uiAutomation.takeScreenshot())
        File(folder, "parity-tablet-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
        File(folder, "parity-tablet-$name.json").writeText("""{"kind":"actual-main-owned-emulator","reference":"iphone-0.1.13","screen":"$name","realGecko":true,"fictionalLocalPages":true,"realMac":false}""")
    }
    @Test(timeout = 180_000) fun actualPhoneSettingsFromTheFocusedField(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(shell("getprop ro.kernel.qemu").trim() == "1")
        val size = override(shell("wm size")); val density = override(shell("wm density"))
        val path = File(context.filesDir, "browser.json")
        val prior = path.takeIf(File::exists)?.readBytes()
        try {
            shell("wm size 1206x2622"); shell("wm density 480")
            AppFlowTest.LocalPage().use { page ->
                val tab = BrowserTab("phone-settings-page", page.url, "Local document", createdAt = 1)
                FileBrowserRepository(path).save(BrowserSnapshot(spaces = listOf(BrowserSpace(
                    BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(tab), currentTabId = tab.id)),
                    selectedSpaceId = BrowserController.PERSONAL_SPACE,
                    settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT)))
                NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                    NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                    lateinit var model: BrowserSessionViewModel
                    fixture.onActivity { host -> model = ViewModelProvider(host)[BrowserSessionViewModel::class.java] }
                    compose.waitUntil(60_000) { !model.browser.state.value.loading &&
                        !model.browser.state.value.page.loading && model.browser.state.value.page.title == "Android flow article" }
                    fixture.onActivity { host ->
                        host.startActivity(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
                            .setData(android.net.Uri.parse("yab://new")).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    }
                    compose.waitUntil(30_000) { compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes().size == 1 }
                    compose.onNodeWithTag("browser.field.input").performClick()
                    compose.waitUntil(20_000) {
                        var shown = false
                        fixture.onActivity { host -> shown = androidx.core.view.ViewCompat.getRootWindowInsets(host.window.decorView)
                            ?.getInsets(androidx.core.view.WindowInsetsCompat.Type.ime())?.bottom?.let { it > 0 } == true }
                        shown
                    }
                    stage("phone-settings: field and real IME ready")
                    shot("phone.field-before-settings")
                    compose.onNodeWithContentDescription("Settings", useUnmergedTree = true).performTouchInput { click() }
                    try {
                        compose.waitUntil(20_000) { compose.onAllNodesWithTag("settings.search").fetchSemanticsNodes().size == 1 }
                    } catch (failure: Throwable) {
                        stage("phone-settings failed: surface=${model.browser.state.value.surface}")
                        shot("phone.settings-entry-failed")
                        throw failure
                    }
                    shot("phone.settings")
                    compose.onNodeWithText("General", substring = false).performTouchInput { click() }
                    compose.onNodeWithTag("settings.route.1").assertIsDisplayed()
                    shot("phone.settings-general")
                }
            }
        } finally {
            shell("wm size ${size ?: "reset"}"); shell("wm density ${density ?: "reset"}")
            if (prior == null) path.delete() else path.writeBytes(prior)
        }
    }
    @Test(timeout = 180_000) fun actualTabletChatMenuAfterClosingTheKeyboard(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(shell("getprop ro.kernel.qemu").trim() == "1")
        val size = override(shell("wm size")); val density = override(shell("wm density"))
        val path = File(context.filesDir, "browser.json")
        val prior = path.takeIf(File::exists)?.readBytes()
        try {
            shell("wm size 2560x1600"); shell("wm density 240")
            AppFlowTest.LocalPage().use { page ->
                val tab = BrowserTab("tablet-chat-page", page.url, "Local document", createdAt = 1)
                FileBrowserRepository(path).save(BrowserSnapshot(spaces = listOf(BrowserSpace(
                    BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(tab), currentTabId = tab.id)),
                    selectedSpaceId = BrowserController.PERSONAL_SPACE,
                    settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT)))
                NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                    NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                    lateinit var model: BrowserSessionViewModel
                    fixture.onActivity { host -> model = ViewModelProvider(host)[BrowserSessionViewModel::class.java] }
                    compose.waitUntil(60_000) { !model.browser.state.value.loading &&
                        !model.browser.state.value.page.loading && model.browser.state.value.page.title == "Android flow article" }
                    fixture.onActivity { host ->
                        host.startActivity(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
                            .setData(android.net.Uri.parse("yab://ask")).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    }
                    compose.waitUntil(30_000) { compose.onAllNodesWithTag("chat.composer").fetchSemanticsNodes().size == 1 }
                    compose.onNodeWithTag("chat.composer").performClick().performTextReplacement("Plan a quiet weekend")
                    compose.waitUntil(10_000) { model.agent.state.value.current?.draft == "Plan a quiet weekend" }
                    fixture.onActivity { assertTrue(it.hasWindowFocus()) }
                    i.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
                    compose.waitUntil(20_000) {
                        var hidden = false
                        fixture.onActivity { host -> hidden = androidx.core.view.ViewCompat.getRootWindowInsets(host.window.decorView)
                            ?.getInsets(androidx.core.view.WindowInsetsCompat.Type.ime())?.bottom == 0 }
                        hidden
                    }
                    fixture.onActivity { assertTrue(it.hasWindowFocus()) }
                    shot("chat.before-menu")
                    compose.onNodeWithContentDescription("More").performTouchInput { click() }
                    compose.onNodeWithText("Chat Info", substring = false).assertIsDisplayed()
                    shot("chat.menu")
                    compose.onNodeWithText("Chat Info", substring = false).performTouchInput { click() }
                    compose.onNodeWithTag("chat.info").assertIsDisplayed()
                    shot("chat.info")
                    assertEquals("Plan a quiet weekend", model.agent.state.value.current?.draft)
                }
            }
        } finally {
            shell("wm size ${size ?: "reset"}"); shell("wm density ${density ?: "reset"}")
            if (prior == null) path.delete() else path.writeBytes(prior)
        }
    }
    @Test(timeout = 240_000) fun actualTabletWorkspaceAndSettingsMatchCurrentIPadLayout(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(shell("getprop ro.kernel.qemu").trim() == "1")
        val size = override(shell("wm size")); val density = override(shell("wm density"))
        val path = File(context.filesDir, "browser.json")
        val prior = path.takeIf(File::exists)?.readBytes()
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        try { ui.run {
            shell("wm size 2064x2752"); shell("wm density 320")
            AppFlowTest.LocalPage().use { page ->
                val first = BrowserTab("tablet-first", page.url, "First document", TabPlace.KEPT, createdAt = 1)
                val second = BrowserTab("tablet-second", page.url, "Second document", createdAt = 2)
                FileBrowserRepository(path).save(BrowserSnapshot(spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal",
                    emoji = "🏠", tabs = listOf(first, second), currentTabId = first.id),
                    BrowserSpace("work", "Work", emoji = "💼", tabs = listOf(first.copy(id = "work-first")), currentTabId = "work-first"),
                    BrowserSpace("lisbon", "Lisbon", emoji = "🧳")), selectedSpaceId = BrowserController.PERSONAL_SPACE,
                    settings = BrowserSettings(welcomed = true, appearance = BrowserAppearance.LIGHT)))
                stage("before-main-launch")
                NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN), NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                    lateinit var model: BrowserSessionViewModel
                    fixture.onActivity { host ->
                        model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                        ui.bind(model.browser, model.engine) { model.browser.workspaceWindow.value.generation }
                    }
                    stage("main-bound-before-ready")
                    val changes = java.util.IdentityHashMap<Any, Int>()
                    val observer = androidx.compose.runtime.snapshots.Snapshot.registerApplyObserver { changed, _ ->
                        synchronized(changes) { changed.forEach { value ->
                            if (changes.size < 2000 || changes.containsKey(value)) changes[value] = (changes[value] ?: 0) + 1
                        } }
                    }
                    try {
                        compose.waitUntil(60_000) { !model.browser.state.value.loading && !model.browser.state.value.page.loading && model.browser.state.value.page.title == "Android flow article" &&
                            compose.onAllNodesWithTag("browser.tablet.toolbar").fetchSemanticsNodes().size == 1 }
                    } catch (failure: Throwable) {
                        val state = model.browser.state.value
                        stage("ready-failed: ${failure.javaClass.simpleName}, loading=${state.loading}, pageLoading=${state.page.loading}, title=${state.page.title}, surface=${state.surface}, space=${state.selectedSpaceId}, window=${model.browser.workspaceWindow.value}")
                        runCatching {
                            val folder = File(context.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
                            val top = synchronized(changes) { changes.entries.sortedByDescending { it.value }.take(40).map { entry ->
                                "${entry.value} ${entry.key.javaClass.name} ${runCatching { entry.key.toString() }.getOrDefault("unreadable").take(400)}"
                            } }
                            File(folder, "tablet-snapshot-changes.txt").writeText(top.joinToString("\n"))
                            File(folder, "tablet-ready-error.txt").writeText(failure.stackTraceToString())
                            val dump = StringBuilder()
                            fun inspect(value: Any, depth: Int) {
                                if (depth > 2) return
                                dump.appendLine("  ".repeat(depth) + value.javaClass.name)
                                value.javaClass.declaredFields.forEach { field -> runCatching {
                                    field.isAccessible = true
                                    val item = field.get(value)
                                    dump.appendLine("  ".repeat(depth) + field.name + "=" + item.toString().take(900))
                                    if (item != null && (field.name.startsWith("this$") || field.name in setOf("compositionInvalidations", "compositionsAwaitingApply", "movableContentAwaitingInsert"))) {
                                        if (item is Collection<*>) item.filterNotNull().take(3).forEach { inspect(it, depth + 1) }
                                        else inspect(item, depth + 1)
                                    }
                                } }
                            }
                            androidx.compose.runtime.Recomposer.runningRecomposers.value.forEach { inspect(it, 0) }
                            File(folder, "tablet-recomposer.txt").writeText(dump.toString())
                            i.uiAutomation.takeScreenshot()?.let { bitmap ->
                                File(folder, "tablet-failure.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
                            }
                        }
                        throw failure
                    } finally { observer.dispose() }
                    stage("loaded-main")
                    if (InstrumentationRegistry.getArguments().getString("tabletReadyOnly") == "true") {
                        shot("ready-only")
                        return@use
                    }
                    val sidebar = compose.onNodeWithTag("browser.tablet.workspace.sidebar").fetchSemanticsNode().boundsInRoot
                    assertEquals(528f, sidebar.width, 1f)
                    val toolbar = compose.onNodeWithTag("browser.tablet.toolbar").fetchSemanticsNode().boundsInRoot
                    assertEquals(88f, toolbar.height, 1f)
                    stage("tap-work")
                    compose.onNodeWithTag("browser.tablet.sidebar.space.work").performTouchInput { click() }
                    compose.waitUntil(30_000) { model.browser.state.value.selectedSpaceId == "work" && !model.browser.state.value.page.loading }
                    stage("tap-personal")
                    compose.onNodeWithTag("browser.tablet.sidebar.space.${BrowserController.PERSONAL_SPACE}").performTouchInput { click() }
                    compose.waitUntil(30_000) { model.browser.state.value.selectedSpaceId == BrowserController.PERSONAL_SPACE && !model.browser.state.value.page.loading }
                    stage("spaces-returned")
                    shot("workspace.single")
                    stage("resize-sidebar")
                    compose.onNodeWithTag("browser.tablet.sidebar.resize").performTouchInput {
                        swipe(center, center + androidx.compose.ui.geometry.Offset(80f, 0f), 400)
                    }
                    compose.waitUntil(10_000) { compose.onNodeWithTag("browser.tablet.workspace.sidebar").fetchSemanticsNode().boundsInRoot.width > 600f }
                    shot("workspace.sidebar-resized")
                    stage("recreate-width")
                    fixture.recreate()
                    compose.waitUntil(30_000) { compose.onAllNodesWithTag("browser.tablet.sidebar.resize").fetchSemanticsNodes().size == 1 }
                    assertEquals(608f, compose.onNodeWithTag("browser.tablet.workspace.sidebar").fetchSemanticsNode().boundsInRoot.width, 3f)
                    stage("recreated-before-drag: pageLoading=${model.browser.state.value.page.loading}, window=${model.browser.workspaceWindow.value}")
                    compose.onNodeWithTag("browser.tablet.sidebar.resize").performTouchInput {
                        swipe(center, center - androidx.compose.ui.geometry.Offset(80f, 0f), 400)
                    }
                    try {
                        compose.waitUntil(10_000) { compose.onNodeWithTag("browser.tablet.workspace.sidebar").fetchSemanticsNode().boundsInRoot.width < 532f }
                    } catch (failure: Throwable) {
                        stage("recreated-drag-failed: width=${compose.onNodeWithTag("browser.tablet.workspace.sidebar").fetchSemanticsNode().boundsInRoot.width}, pageLoading=${model.browser.state.value.page.loading}")
                        shot("workspace.recreated-drag-failed")
                        throw failure
                    }
                    shot("workspace.recreated-resized")
                    stage("open-settings")
                    ui.click("Settings")
                    compose.onNodeWithTag("settings.search").assertExists()
                    shot("settings.1")
                    compose.onNodeWithText("Appearance").performTouchInput { click() }
                    compose.onNodeWithText("Darken Websites").assertExists()
                    shot("settings.page-appearance")
                    compose.onNodeWithContentDescription("Back").performTouchInput { click() }
                    compose.onNodeWithContentDescription("Close").performTouchInput { click() }
                    compose.waitUntil(10_000) { model.browser.state.value.surface == BrowserSurface.PAGE }
                    stage("rotate-landscape")
                    shell("wm size 2752x2064")
                    compose.waitUntil(20_000) { model.browser.workspaceWindow.value.geometry == BrowserWorkspaceWindow(1376.0, 1032.0) }
                    // Initial public layout fixture only; the capture does not claim a Split menu interaction.
                    stage("open-beside")
                    fixture.onActivity { model.browser.openBeside(second.id) }
                    compose.waitUntil(30_000) { model.browser.state.value.workspace != null && !model.browser.state.value.page.loading }
                    compose.waitForIdle()
                    compose.onNodeWithTag("browser.tablet.sidebar.pair").assertExists()
                    compose.onNodeWithTag("browser.tablet.sidebar.pair.${second.id}").performTouchInput { click() }
                    compose.waitUntil(10_000) { model.browser.state.value.workspace?.focused == second.id }
                    compose.onNodeWithTag("browser.tablet.sidebar.tab.${second.id}").assertDoesNotExist()
                    shot("workspace.two")
                    stage("resize-split")
                    val dividerBefore = compose.onNodeWithTag("browser.tablet.split.resize").fetchSemanticsNode().boundsInRoot.center.x
                    compose.onNodeWithTag("browser.tablet.split.resize").performTouchInput {
                        swipe(center, center + androidx.compose.ui.geometry.Offset(160f, 0f), 500)
                    }
                    compose.waitUntil(10_000) { compose.onNodeWithTag("browser.tablet.split.resize").fetchSemanticsNode().boundsInRoot.center.x > dividerBefore + 150f }
                    shot("workspace.split-resized")
                    fixture.onActivity { host ->
                        assertTrue(host.hasWindowFocus())
                        assertTrue(model.engine.hasLiveSession(first.id)); assertTrue(model.engine.hasLiveSession(second.id))
                    }
                    ui.click("Sidebar")
                    compose.waitForIdle()
                    shot("workspace.two-no-sidebar")
                }
            }
        } } finally {
            shell("wm size ${size ?: "reset"}"); shell("wm density ${density ?: "reset"}")
            if (prior == null) path.delete() else path.writeBytes(prior)
        }
    }
}

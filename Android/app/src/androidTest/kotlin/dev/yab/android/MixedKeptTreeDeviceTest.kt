package dev.yab.android

import android.content.Intent
import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.BrowserController
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual Main; identical local tree JSON can also be read by the retained pre-fix APK. */
abstract class MixedKeptTreeScenario {
    @get:Rule val compose = createEmptyComposeRule()
    private val i get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = i.targetContext
    private val titles = listOf("Before folder", "Research", "First inside", "Nested folder", "Nested tab", "After folder")
    private fun shot(name: String) {
        compose.waitForIdle(); SystemClock.sleep(450)
        val dir = File(context.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(i.uiAutomation.takeScreenshot())
        try { File(dir, "mixed-kept-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        File(dir, "mixed-kept-$name.json").writeText("""{"kind":"actual-main-owned-emulator","realGecko":true,"fictionalLocalPage":true,"localTreeFixture":true,"realMac":false,"syncWireWrites":false}""")
    }
    protected fun runScenario(after: Boolean): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val file = File(context.filesDir, "browser.json")
        val prior = file.takeIf(File::exists)?.readBytes()
        try {
            AppFlowTest.LocalPage().use { page ->
                fun tab(id: String, title: String, folder: String? = null, kept: Boolean = true) = JSONObject()
                    .put("id", id).put("url", page.url).put("title", title).put("createdAt", 1)
                    .put("place", if (kept) "KEPT" else "TODAY").apply { folder?.let { put("folderId", it) } }
                val tree = JSONObject().put("id", BrowserController.PERSONAL_SPACE).put("name", "Personal").put("currentTabId", "front")
                    .put("look", JSONObject().put("swatch", "custom").put("color", "#D1F1FF"))
                    .put("tabs", JSONArray(listOf(tab("before", titles[0]), tab("inside", titles[2], "f"),
                        tab("nested-tab", titles[4], "n"), tab("after", titles[5]), tab("front", "Local page", kept = false))))
                    .put("folders", JSONArray(listOf(JSONObject().put("id", "f").put("name", titles[1]).put("open", true),
                        JSONObject().put("id", "n").put("name", titles[3]).put("parentId", "f").put("open", true))))
                    .put("keptOrder", JSONArray(listOf("tab:before", "folder:f", "tab:inside", "folder:n", "tab:nested-tab", "tab:after")))
                file.writeText(JSONObject().put("schema", 1).put("spaces", JSONArray(listOf(tree)))
                    .put("selectedSpaceId", BrowserController.PERSONAL_SPACE).put("settings", JSONObject()
                        .put("welcomed", true).put("openKeyboardAtLaunch", false).put("appearance", "LIGHT")).toString())

                fun ordered(expected: List<String>) {
                    val tops = expected.map { compose.onNodeWithText(it, substring = false).fetchSemanticsNode().boundsInRoot.top }
                    assertEquals(expected.size, tops.distinct().size)
                    assertEquals("Mixed sibling order: $expected", tops.sorted(), tops)
                }
                fun openField(fixture: NativeMainActivityFixture) {
                    lateinit var model: BrowserSessionViewModel
                    fixture.onActivity { model = ViewModelProvider(it)[BrowserSessionViewModel::class.java] }
                    compose.waitUntil(60_000) { !model.browser.state.value.loading && !model.browser.state.value.page.loading &&
                        model.browser.state.value.page.title == "Android flow article" }
                    compose.onNodeWithTag("browser.chrome.capsule", useUnmergedTree = true).performTouchInput { click() }
                    compose.waitUntil(20_000) { compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes().size == 1 }
                    compose.waitForIdle(); SystemClock.sleep(450)
                    var ime = false
                    fixture.onActivity { ime = it.window.decorView.rootWindowInsets?.isVisible(android.view.WindowInsets.Type.ime()) == true }
                    if (ime) check(i.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK))
                    compose.waitForIdle()
                    // The search sheet's spaces are its pull up. Rows show while it
                    // travels and take presses only once it has arrived.
                    // A fresh activity may bring the sheet back already pulled: a swipe then
                    // moves the list, and a press on a moving list only stops it.
                    val up = SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription, "spaces")
                    fun pulled() = compose.onAllNodes(hasTestTag("search.sheet") and up).fetchSemanticsNodes().isNotEmpty()
                    SystemClock.sleep(1_000)
                    if (!pulled()) {
                        val screen = context.resources.displayMetrics
                        i.uiAutomation.executeShellCommand("input swipe ${screen.widthPixels / 2} ${screen.heightPixels / 2} ${screen.widthPixels / 2} ${screen.heightPixels / 12} 300").close()
                    }
                    compose.waitUntil(30_000) { pulled() }
                    compose.waitUntil(30_000) { compose.onAllNodes(hasTestTag("browser.folder.f") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
                    compose.onNodeWithText(titles[0]).assertExists()
                }
                fun launch() = NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                    NativeMainActivityFixture.Kind.APP_WORKSPACE)

                launch().use { fixture ->
                    openField(fixture)
                    if (after) ordered(titles) else ordered(listOf("Research", "Before folder", "After folder"))
                    shot("01-open")
                    compose.onNodeWithText("Research").performTouchInput { click() }
                    // A folder's rows go on the Mac's clock, fading out.
                    compose.waitUntil(5_000) { compose.onAllNodesWithText("First inside").fetchSemanticsNodes().isEmpty() }
                    compose.onNodeWithText("Nested tab").assertDoesNotExist()
                    if (after) ordered(listOf("Before folder", "Research", "After folder"))
                    shot("02-folded")
                    compose.waitUntil(10_000) { runCatching { JSONObject(file.readText()).getJSONArray("spaces").getJSONObject(0)
                        .getJSONArray("folders").getJSONObject(0).getBoolean("open") == false }.getOrDefault(false) }
                }
                launch().use { fixture ->
                    openField(fixture)
                    compose.onNodeWithText("First inside").assertDoesNotExist()
                    if (after) ordered(listOf("Before folder", "Research", "After folder"))
                    compose.onNodeWithText("Research").performTouchInput { click() }
                    compose.waitUntil(5_000) { compose.onAllNodesWithText("Nested tab").fetchSemanticsNodes().isNotEmpty() }
                    if (after) ordered(titles)
                    shot("03-reopened")
                }
            }
        } finally { if (prior == null) file.delete() else file.writeBytes(prior) }
    }
}

class MixedKeptTreeDeviceTest : MixedKeptTreeScenario() {
    @Test(timeout = 180_000) fun mixedOrderSurvivesFoldingAndFreshActivity() = runScenario(true)
}

package dev.yab.android

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.model.*
import java.io.File
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView

/** Actual Main window and Page Menu consumers. No injected configuration or layout clock. */
class AppWorkspacePageMenuTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun originalMenuRowCannotReviveAcrossActualMainPortraitAndLandscapeAba(): Unit = runBlocking {
        scene(Case.CONFIGURATION) { scene ->
            val first = scene.browser.state.value.tab!!
            val profile = scene.browser.state.value.space!!.websiteProfile
            val original = scene.captureSession(first)
            val ids = scene.browser.state.value.space!!.tabs.map { it.id }
            val initial = scene.window(1280, 800, Phase.LANDSCAPE)
            scene.captureMenuCallback(original)
            scene.menuStep(MenuStep.BEFORE_PAGE_MENU)
            scene.nativeClick("Page menu")
            scene.menuStep(MenuStep.AFTER_PAGE_MENU)
            scene.ui.requireOwnCurrent()
            val saved = savedClick("Open Beside")

            shell("wm size 800x1280")
            val portrait = scene.window(800, 1280, Phase.PORTRAIT, newerThan = initial)
            assertTrue(portrait > initial)
            scene.fixture.onActivity { saved() }
            compose.waitForIdle()
            scene.assertUnchanged(first, ids)
            scene.fixture.onActivity {
                assertSame(original, scene.session(first))
                assertFalse(scene.browser.workspaceWindow.value.geometry!!.canSplit)
            }

            shell("wm size 1280x800")
            val restored = scene.window(1280, 800, Phase.LANDSCAPE_ABA, newerThan = portrait)
            assertTrue(restored > portrait)
            // Invoke the original node callback, never a fresh selector or replacement lease.
            scene.fixture.onActivity { saved() }
            compose.waitForIdle()
            scene.assertUnchanged(first, ids)
            await("old menu released") { compose.onAllNodesWithText("Open Beside").fetchSemanticsNodes().isEmpty() }
            scene.nativeClick("Page menu")
            scene.menuStep(MenuStep.BEFORE_OPEN_BESIDE)
            scene.nativeClick("Open Beside")
            scene.menuStep(MenuStep.AFTER_OPEN_BESIDE)
            scene.newField(first, ids)
            scene.fixture.onActivity {
                assertSame(original, scene.session(first))
                assertEquals(profile, scene.browser.state.value.space!!.websiteProfile)
            }
            scene.record(Phase.FRESH_ROW, true)
        }
    }

    @Test(timeout = 240_000)
    fun actualMenuRowsOpenSpreadAndCloseOnlyTheirCapturedPageWithRetainedGeckoSessions(): Unit = runBlocking {
        scene(Case.ACTIONS) { scene ->
            val first = scene.browser.state.value.tab!!
            val firstSession = scene.captureSession(first)
            val originalIds = scene.browser.state.value.space!!.tabs.map { it.id }
            scene.window(1280, 800, Phase.LANDSCAPE)

            scene.captureMenuCallback(firstSession)
            scene.menuStep(MenuStep.BEFORE_PAGE_MENU)
            scene.nativeClick("Page menu")
            scene.menuStep(MenuStep.AFTER_PAGE_MENU)
            scene.menuStep(MenuStep.BEFORE_OPEN_BESIDE)
            scene.nativeClick("Open Beside")
            scene.menuStep(MenuStep.AFTER_OPEN_BESIDE)
            val secondId = scene.newField(first, originalIds)
            AppFlowTest.LocalPage().use { secondPage ->
                scene.navigateField(secondPage.url)
                val second = scene.browser.state.value.tab!!
                assertEquals(secondId, second.id)
                val secondSession = scene.captureSession(second)
                scene.twoPanes(first, firstSession, second, secondSession)
                scene.record(Phase.OPEN_BESIDE, true)

                scene.nativeClick("Page menu")
                scene.nativeClick("Full Spread")
                await("actual Full Spread") { scene.browser.state.value.workspace == null }
                scene.fixture.onActivity {
                    assertEquals(second.id, scene.browser.state.value.tab!!.id)
                    assertEquals((originalIds + second.id).toSet(), scene.browser.state.value.space!!.tabs.map { it.id }.toSet())
                    assertSame(firstSession, scene.session(first))
                    assertSame(secondSession, scene.session(second))
                    assertTrue(scene.model.engine.hasLiveSession(first.id))
                    assertTrue(scene.model.engine.hasLiveSession(second.id))
                }
                scene.record(Phase.FULL_SPREAD, true)

                val beforeThird = scene.browser.state.value.space!!.tabs.map { it.id }
                scene.nativeClick("Page menu")
                scene.nativeClick("Open Beside")
                val thirdId = scene.newField(second, beforeThird)
                scene.navigateField(scene.firstUrl)
                val third = scene.browser.state.value.tab!!
                assertEquals(thirdId, third.id)
                val thirdSession = scene.captureSession(third)
                scene.twoPanes(second, secondSession, third, thirdSession)
                scene.nativeClick("Page menu")
                scene.nativeClick("Close Page")
                await("actual Close Page returns to captured companion") {
                    var closed = false
                    scene.fixture.onActivity {
                        closed = scene.browser.state.value.let { it.workspace == null && it.tab?.id == second.id &&
                            it.space!!.tabs.none { tab -> tab.id == third.id } } && !scene.model.engine.hasLiveSession(third.id)
                    }
                    closed
                }
                scene.fixture.onActivity {
                    assertEquals(beforeThird.toSet(), scene.browser.state.value.space!!.tabs.map { it.id }.toSet())
                    assertSame(firstSession, scene.session(first))
                    assertSame(secondSession, scene.session(second))
                    assertTrue(scene.model.engine.hasLiveSession(first.id))
                    assertTrue(scene.model.engine.hasLiveSession(second.id))
                    assertFalse(scene.model.engine.hasLiveSession(third.id))
                    assertEquals(secondPage.url, scene.browser.state.value.tab!!.url)
                }
                scene.record(Phase.CLOSE_PAGE, true)
            }
        }
    }

    @Test(timeout = 240_000)
    fun oneActualEditorRetainsTextAndSelectionAcrossTabletCompactAbaAndRejectsItsOriginalSetText(): Unit = runBlocking {
        scene(Case.EDITOR) { scene ->
            val front = scene.browser.state.value.tab!!
            val originalSession = scene.captureSession(front)
            val originalIds = scene.browser.state.value.space!!.tabs.map { it.id }
            scene.window(1280, 800, Phase.LANDSCAPE)
            scene.captureMenuCallback(originalSession)
            scene.menuStep(MenuStep.BEFORE_PAGE_MENU)
            scene.nativeClick("Page menu")
            scene.menuStep(MenuStep.AFTER_PAGE_MENU)
            scene.menuStep(MenuStep.BEFORE_OPEN_BESIDE)
            scene.nativeClick("Open Beside")
            scene.menuStep(MenuStep.AFTER_OPEN_BESIDE)
            val newId = scene.newField(front, originalIds)
            val words = "tablet selection retained"
            val selection = TextRange(4, 13)
            val editor = compose.onNodeWithTag("browser.field.input")
            editor.performTextReplacement(words)
            editor.performTextInputSelection(selection)
            scene.editorReady(words, selection, tablet = true)
            val originalSetText = checkNotNull(editor.fetchSemanticsNode().config[SemanticsActions.SetText].action)
            val tablet = scene.window(1280, 800, Phase.TABLET_EDITOR)

            shell("wm size 480x1000")
            val compact = scene.window(480, 1000, Phase.COMPACT_EDITOR, newerThan = tablet)
            assertTrue(compact > tablet)
            scene.editorReady(words, selection, tablet = false)
            scene.fixture.onActivity {
                assertEquals(newId, scene.browser.state.value.tab!!.id)
                assertSame(originalSession, scene.session(front))
            }

            shell("wm size 1280x800")
            val restored = scene.window(1280, 800, Phase.TABLET_EDITOR_ABA, newerThan = compact)
            assertTrue(restored > compact)
            scene.editorReady(words, selection, tablet = true)
            // Retained first-tablet action, not the current editor's replacement semantics.
            scene.fixture.onActivity {
                originalSetText(AnnotatedString("retired editor must not write"))
                assertEquals(words, scene.browser.state.value.fieldText)
            }
            compose.waitForIdle()
            compose.onNodeWithTag("browser.field.input").assertTextContains(words)
            assertEquals(selection, compose.onNodeWithTag("browser.field.input").fetchSemanticsNode()
                .config[SemanticsProperties.TextSelectionRange])
            scene.editorReady(words, selection, tablet = true)
            scene.fixture.onActivity {
                assertEquals(words, scene.browser.state.value.fieldText)
                assertEquals(newId, scene.browser.state.value.tab!!.id)
                assertSame(originalSession, scene.session(front))
            }

            val fresh = compose.onNodeWithTag("browser.field.input")
            fresh.performTextInput("!")
            val changed = words.replaceRange(selection.start, selection.end, "!")
            scene.editorReady(changed, TextRange(selection.start + 1), tablet = true)
            scene.fixture.onActivity {
                assertEquals(changed, scene.browser.state.value.fieldText)
                assertEquals(BrowserSurface.FIELD, scene.browser.state.value.surface)
                assertEquals(BrowserWorkspace(front.id, newId, newId, newPage = newId), scene.browser.state.value.workspace)
                assertSame(originalSession, scene.session(front))
            }
            scene.record(Phase.FRESH_EDITOR, true)
        }
    }

    @Test(timeout = 240_000)
    fun actualTabletAddressReopensOneEditorAndRejectsItsRetiredOriginalCallback(): Unit = runBlocking {
        scene(Case.ADDRESS) { scene ->
            val first = scene.browser.state.value.tab!!
            val firstSession = scene.captureSession(first)
            val initialIds = scene.browser.state.value.space!!.tabs.map { it.id }
            scene.window(1280, 800, Phase.LANDSCAPE)
            scene.captureMenuCallback(firstSession)
            scene.nativeClick("Page menu")
            scene.nativeClick("Open Beside")
            scene.newField(first, initialIds)
            AppFlowTest.LocalPage().use { secondPage ->
                scene.navigateField(secondPage.url)
                val second = scene.browser.state.value.tab!!
                val secondSession = scene.captureSession(second)
                val pair = BrowserWorkspace(first.id, second.id, second.id)
                val ids = scene.browser.state.value.space!!.tabs.map { it.id }
                scene.twoPanes(first, firstSession, second, secondSession)
                await("one original tablet PAGE address") {
                    compose.onAllNodesWithTag("browser.tablet.address").fetchSemanticsNodes().size == 1
                }
                val address = compose.onNodeWithTag("browser.tablet.address")
                address.assertIsDisplayed().assertIsEnabled()
                val originalAddress = dev.yab.browser.originalRenderedClick(address.fetchSemanticsNode())
                scene.nativeClick("Search or enter address")
                await("original address opens the existing page Field") {
                    scene.browser.state.value.let { it.surface == BrowserSurface.FIELD && !it.fieldIsNewTab &&
                        it.tab?.id == second.id && it.workspace == pair }
                }
                compose.onAllNodesWithTag("browser.tablet.address").assertCountEquals(0)
                val words = "original page address draft"
                val selection = TextRange(3, 12)
                compose.onNodeWithTag("browser.field.input").performTextReplacement(words)
                compose.onNodeWithTag("browser.field.input").performTextInputSelection(selection)
                scene.editorReady(words, selection, tablet = true)
                scene.fixture.onActivity {
                    assertEquals(ids, scene.browser.state.value.space!!.tabs.map { it.id })
                    assertEquals(pair, scene.browser.state.value.workspace)
                    assertSame(firstSession, scene.session(first)); assertSame(secondSession, scene.session(second))
                }
                scene.nativeClick("Close Search")
                await("native Field close returns to the original pair without IME") {
                    var ready = false
                    scene.fixture.onActivity { host ->
                        ready = scene.browser.state.value.surface == BrowserSurface.PAGE &&
                            ViewCompat.getRootWindowInsets(host.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime()) == false
                    }
                    ready
                }
                scene.twoPanes(first, firstSession, second, secondSession)
                val closedEpoch = scene.browser.state.value.surfaceEpoch
                scene.fixture.onActivity {
                    originalAddress()
                    assertEquals(BrowserSurface.PAGE, scene.browser.state.value.surface)
                    assertEquals(closedEpoch, scene.browser.state.value.surfaceEpoch)
                    assertEquals(words, scene.browser.state.value.fieldText)
                    assertEquals(second.id, scene.browser.state.value.tab!!.id)
                    assertEquals(ids, scene.browser.state.value.space!!.tabs.map { it.id })
                    assertEquals(pair, scene.browser.state.value.workspace)
                }
                compose.waitForIdle()
                scene.fixture.onActivity {
                    assertEquals(BrowserSurface.PAGE, scene.browser.state.value.surface)
                    assertEquals(closedEpoch, scene.browser.state.value.surfaceEpoch)
                }
                compose.onAllNodesWithTag("browser.field.input").assertCountEquals(0)
                compose.onNodeWithTag("browser.tablet.address").assertIsDisplayed().assertIsEnabled()
                scene.nativeClick("Search or enter address")
                await("fresh address reopens the saved page draft") {
                    scene.browser.state.value.let { it.surface == BrowserSurface.FIELD && !it.fieldIsNewTab &&
                        it.tab?.id == second.id && it.fieldText == words && it.workspace == pair }
                }
                compose.onNodeWithTag("browser.field.input").assertTextContains(words)
                // This is a fresh user selection, not a requirement to restore an old Field epoch's selection.
                val freshSelection = TextRange(words.length)
                compose.onNodeWithTag("browser.field.input").performTextInputSelection(freshSelection)
                scene.editorReady(words, freshSelection, tablet = true)
                scene.fixture.onActivity {
                    assertEquals(ids, scene.browser.state.value.space!!.tabs.map { it.id })
                    assertEquals(pair, scene.browser.state.value.workspace)
                    assertSame(firstSession, scene.session(first)); assertSame(secondSession, scene.session(second))
                }
            }
        }
    }

    private enum class Case { CONFIGURATION, ACTIONS, EDITOR, ADDRESS }
    private enum class MenuStep { SETUP, BEFORE_PAGE_MENU, AFTER_PAGE_MENU, BEFORE_OPEN_BESIDE, AFTER_OPEN_BESIDE }
    private enum class Phase { LANDSCAPE, PORTRAIT, LANDSCAPE_ABA, FRESH_ROW, OPEN_BESIDE, IME, FULL_SPREAD, CLOSE_PAGE,
        TABLET_EDITOR, COMPACT_EDITOR, TABLET_EDITOR_ABA, FRESH_EDITOR, COMPLETE }

    private data class MenuCallbackSource(val host: MainActivity, val root: View, val token: Any,
        val intent: Intent, val configuration: Configuration, val windowBounds: Rect,
        val width: Int, val height: Int, val state: BrowserState, val window: WorkspaceWindowState,
        val lifetime: SettingsPresentationLifetime, val sourceGeneration: Long,
        val account: dev.yab.sync.AccountRecordsSnapshot, val native: dev.yab.browser.engine.GeckoEngine.ExternalActivityOwner?,
        val session: GeckoSession, val reportQuestionPresent: Boolean)

    private inner class Scene(val fixture: NativeMainActivityFixture, val model: BrowserSessionViewModel,
        val ui: OwnedBrowserTestUi, val firstUrl: String, val rows: JSONArray) {
        val browser get() = model.browser
        private var firstObservedActivity: MainActivity? = null
        private var firstObservedStore: Any? = null
        private var menuStep = MenuStep.SETUP
        private var beforeMenu: BrowserState? = null
        private var beforeWindow: WorkspaceWindowState? = null
        private val menuSamples = JSONArray()
        private var originalMenuCallback: (() -> Boolean)? = null
        private var originalMenuSource: MenuCallbackSource? = null
        private var callbackCaptureSucceeded = false
        private var callbackCaptureSourceCurrent = false
        private var callbackAttempted = false
        private var failureClock: Long? = null
        private var lastVerifiedWindow: WorkspaceWindowState? = null
        private var lastVerifiedWindowPhase: Phase? = null
        private val editorReadiness = JSONArray()

        /** Diagnostic capture only. Failure cannot prevent the unchanged original native press. */
        fun captureMenuCallback(session: GeckoSession) {
            runCatching {
                var source: MenuCallbackSource? = null
                fixture.onActivity { host ->
                    val state = browser.state.value
                    val native = model.engine.captureExternalActivityOwner()
                    val root = host.window.decorView
                    val token = root.windowToken ?: return@onActivity
                    val entrance = host.intent ?: return@onActivity
                    source = MenuCallbackSource(host, root, token, entrance, Configuration(host.resources.configuration),
                        Rect(host.windowManager.currentWindowMetrics.bounds), root.width, root.height, state,
                        browser.workspaceWindow.value, browser.settingsPresentationLifetime.value,
                        browser.historyPresentationLifetime.value, (context.applicationContext as YabApplication).sync.accountRecords.value,
                        native, session, model.reports.state.value.question != null)
                }
                val captured = source ?: return@runCatching
                originalMenuSource = captured
                val nodes = compose.onAllNodesWithContentDescription(menuEntryLabel()).fetchSemanticsNodes()
                if (nodes.size != 1 || nodes.single().config.getOrNull(SemanticsProperties.Disabled) != null) return@runCatching
                val callback = dev.yab.browser.originalRenderedClick(nodes.single())
                fixture.onActivity { host ->
                    if (host === captured.host && host.window.decorView === captured.root && captured.root.windowToken === captured.token) {
                        originalMenuCallback = callback; callbackCaptureSucceeded = true
                        callbackCaptureSourceCurrent = menuCallbackCurrent(captured, host)
                    }
                }
            }
        }

        /** No data from these comparisons is exported; only the fixed booleans below leave RAM. */
        private fun menuCallbackCurrent(source: MenuCallbackSource, host: MainActivity): Boolean {
            val state = browser.state.value
            val original = source.state
            val profile = original.space?.websiteProfile ?: return false
            val sync = (context.applicationContext as YabApplication).sync
            val account = sync.accountRecords.value
            return host === source.host && host.window.decorView === source.root &&
                host.intent === source.intent && host.resources.configuration == source.configuration &&
                host.windowManager.currentWindowMetrics.bounds == source.windowBounds &&
                source.root.windowToken === source.token && source.root.isAttachedToWindow && source.root.isShown &&
                source.root.width == source.width && source.root.height == source.height && source.width > 0 && source.height > 0 &&
                host.hasWindowFocus() && !host.isDestroyed &&
                browser.workspaceWindow.value == source.window && source.window.registered && source.window.geometry?.valid == true &&
                browser.settingsPresentationLifetime.value == source.lifetime && source.lifetime.active &&
                browser.historyPresentationLifetime.value == source.sourceGeneration &&
                !state.loading && !state.privateContentBlocked && state.find == null && state.surface == BrowserSurface.PAGE &&
                original.surface == BrowserSurface.PAGE && state.surfaceEpoch == original.surfaceEpoch &&
                state.selectedSpaceId == original.selectedSpaceId && state.space?.websiteProfile == profile &&
                original.tab != null && state.tab == original.tab && state.tab === original.tab && state.workspace == original.workspace &&
                account.account == source.account.account && account.device == source.account.device && account.epoch == source.account.epoch &&
                account.removed == source.account.removed && !account.removed && sync.nativeOwnerCurrent(source.account) &&
                source.native?.session === source.session && source.session.settings.contextId == profile.id &&
                source.session.settings.usePrivateMode == profile.isPrivate && source.native?.let(model.engine::ownsExternalActivity) == true &&
                (model.reports.state.value.question != null) == source.reportQuestionPresent
        }

        fun beginFailureProbe() { failureClock = compose.mainClock.currentTime }

        fun callbackFailure(case: Case) {
            val row = JSONObject().put("schema", 1).put("case", case.name).put("observerOnly", true)
                .put("callbackCaptured", callbackCaptureSucceeded).put("originalFailureAlwaysRethrown", true)
                .put("captureCompleteOriginalSourceCurrent", callbackCaptureSourceCurrent)
                .put("clockAutoAdvance", compose.mainClock.autoAdvance)
                .put("clockAdvancedByOriginalFailureProjection", failureClock?.let { compose.mainClock.currentTime > it } == true)
                .put("probeAttempted", false).put("probeSkippedAlreadyMounted", false)
            val source = originalMenuSource
            val callback = originalMenuCallback
            var originalWindowObserved = false
            runCatching {
                fixture.onActivity { host ->
                    originalWindowObserved = source != null && host === source.host && host.window.decorView === source.root &&
                        source.root.windowToken === source.token && source.root.isAttachedToWindow && host.hasWindowFocus()
                }
            }
            row.put("originalWindowObserved", originalWindowObserved)
            if (!originalWindowObserved) { writeCallbackProjection(case, row); return }
            val preHost = menuControl("HOST")
            val preRows = menuControl("OPEN_BESIDE")
            row.put("preProbeHost", preHost).put("preProbeOpenBeside", preRows)
            if (preRows.optBoolean("querySucceeded") && preRows.optBoolean("present")) row.put("probeSkippedAlreadyMounted", true)
            runCatching {
                fixture.onActivity { host ->
                    if (source == null || host !== source.host || host.window.decorView !== source.root ||
                        source.root.windowToken !== source.token) return@onActivity
                    val state = browser.state.value
                    val account = (context.applicationContext as YabApplication).sync.accountRecords.value
                    val profile = source?.state?.space?.websiteProfile
                    val current = source != null && menuCallbackCurrent(source, host)
                    row.put("mainObserved", true).put("mainFocused", host.hasWindowFocus()).put("completeOriginalSourceCurrent", current)
                        .put("fixedMenuNotReadyMessage", state.message == "Page menu isn't ready yet")
                        .put("accountRemoved", account.removed)
                        .put("sameAccountIdentity", source != null && account.account == source.account.account &&
                            account.device == source.account.device && account.epoch == source.account.epoch)
                        .put("originalSessionContextMatchesProfile", source != null && profile != null && source.session.settings.contextId == profile.id)
                        .put("originalSessionPrivateMatchesProfile", source != null && profile != null && source.session.settings.usePrivateMode == profile.isPrivate)
                        .put("originalNativeCaptured", source?.native != null)
                        .put("originalNativeCurrent", source?.native?.let(model.engine::ownsExternalActivity) == true)
                        .put("reportQuestionPresent", model.reports.state.value.question != null)
                    if (!callbackAttempted && callbackCaptureSourceCurrent && current && callback != null && preHost.optBoolean("querySucceeded") &&
                        preRows.optBoolean("querySucceeded") && !preRows.optBoolean("present") && menuCallbackCurrent(source, host)) {
                        // Exactly the original merged control callback. True means callback return, never menu admission.
                        callbackAttempted = true; row.put("probeAttempted", true)
                        row.put("callbackReturned", callback())
                    }
                }
                val beforeIdle = compose.mainClock.currentTime
                compose.waitForIdle()
                row.put("clockAdvancedByPostProbeIdle", compose.mainClock.currentTime > beforeIdle)
                row.put("postProbeHost", menuControl("HOST")).put("postProbeOpenBeside", menuControl("OPEN_BESIDE"))
                fixture.onActivity { host ->
                    if (source != null && host === source.host && host.window.decorView === source.root && source.root.windowToken === source.token)
                        row.put("postProbeFixedMenuNotReadyMessage", browser.state.value.message == "Page menu isn't ready yet")
                }
                row.put("probeObservationCompleted", true)
            }
            writeCallbackProjection(case, row)
        }

        /** Observer only: retain the actual original values/reference, never mint a new action lease. */
        fun menuStep(step: MenuStep) {
            menuStep = step
            if (step == MenuStep.BEFORE_PAGE_MENU && beforeMenu == null) {
                beforeMenu = browser.state.value
                beforeWindow = browser.workspaceWindow.value
            }
            runCatching {
                if (menuSamples.length() < 6) menuSamples.put(menuState().put("step", step.name))
            }
        }

        private fun menuState(): JSONObject {
            val original = beforeMenu
            val state = browser.state.value
            val window = browser.workspaceWindow.value
            return JSONObject().put("frontCaptured", original?.tab != null)
                .put("sameFrontValues", original?.tab != null && state.tab == original.tab)
                .put("sameFrontIdentity", original?.tab != null && state.tab === original.tab)
                .put("sameFrontId", original?.tab != null && state.tab?.id == original.tab?.id)
                .put("sameFrontUrl", original?.tab != null && state.tab?.url == original.tab?.url)
                .put("sameFrontTitle", original?.tab != null && state.tab?.title == original.tab?.title)
                .put("sameFrontPlace", original?.tab != null && state.tab?.place == original.tab?.place)
                .put("sameFrontActivity", original?.tab != null && state.tab?.lastActiveAt == original.tab?.lastActiveAt)
                .put("sameSurfaceEpoch", original != null && state.surfaceEpoch == original.surfaceEpoch)
                .put("sameSelectedSpace", original != null && state.selectedSpaceId == original.selectedSpaceId)
                .put("sameProfile", original != null && state.space?.websiteProfile == original.space?.websiteProfile)
                .put("sameWindowGeneration", beforeWindow != null && window.generation == beforeWindow?.generation)
                .put("sameConfiguration", beforeWindow != null && window.configuration == beforeWindow?.configuration)
                .put("windowRegistered", window.registered).put("geometryPresent", window.geometry != null)
                .put("canSplit", window.geometry?.canSplit == true).put("browserLoading", state.loading)
                .put("pageLoading", state.page.loading).put("privateBlocked", state.privateContentBlocked)
                .put("pageSurface", state.surface == BrowserSurface.PAGE)
                .put("fieldSurface", state.surface == BrowserSurface.FIELD)
                .put("workspacePresent", state.workspace != null)
        }

        fun menuFailure(): JSONObject = JSONObject().put("step", menuStep.name)
            .put("samples", menuSamples).put("state", menuState()).put("editorReadiness", editorReadiness)

        /** Layout selector only. No fallback to the hidden bottom control in a tablet layout. */
        fun menuEntryLabel(): String {
            var toolbarLayout = false
            fixture.onActivity { host ->
                val window = browser.workspaceWindow.value
                val state = browser.state.value
                toolbarLayout = window.registered && window.geometry?.let {
                    BrowserTabletWorkspaceGeometry.eligible(it, host.resources.configuration.smallestScreenWidthDp)
                } == true && state.space?.isPrivate == false && state.tab?.isPrivate != true
            }
            return if (toolbarLayout) "Split View" else "Page menu"
        }

        /** Native AX/input does not synchronize the Compose test rule's pending work. */
        suspend fun nativeClick(label: String) {
            compose.waitForIdle()
            ui.click(if (label == "Page menu") menuEntryLabel() else label)
            compose.waitForIdle()
        }

        // Engine access is confined to the original fixture's guarded Main callback.
        fun session(tab: BrowserTab): GeckoSession = model.engine.session(tab, browser.state.value.space!!.websiteProfile)
        fun captureSession(tab: BrowserTab): GeckoSession {
            var captured: GeckoSession? = null
            fixture.onActivity { captured = session(tab) }
            return checkNotNull(captured)
        }

        /** Real full-window metrics, not the keyboard-resized content hierarchy. */
        suspend fun window(width: Int, height: Int, phase: Phase, newerThan: Long? = null): Long {
            var token = -1L
            var sample: JSONObject? = null
            await("registered Main window matches actual OS") {
                var ready = false
                fixture.onActivity { host ->
                    val state = browser.workspaceWindow.value
                    assertTrue(state.registered)
                    // Window service metrics may change before this Activity receives its callback.
                    if (newerThan != null && state.configuration <= newerThan) return@onActivity
                    val actual = if (Build.VERSION.SDK_INT >= 30) host.windowManager.currentWindowMetrics.bounds
                        else error("This consumer requires the original API36 profile")
                    val density = host.resources.displayMetrics.density.toDouble()
                    val geometry = state.geometry
                    // Compare changed windows only after the original configuration token advanced.
                    if (geometry != null) {
                        assertEquals(actual.width() / density, geometry.width, 0.0)
                        assertEquals(actual.height() / density, geometry.height, 0.0)
                    }
                    ready = actual.width() == width && actual.height() == height && density == 1.0 && geometry != null
                    if (ready) {
                        assertEquals(width > height && width >= 641, geometry!!.canSplit)
                        if (phase == Phase.LANDSCAPE && firstObservedActivity == null) {
                            firstObservedActivity = host
                            firstObservedStore = host.viewModelStore
                        }
                        token = state.configuration
                        lastVerifiedWindow = state; lastVerifiedWindowPhase = phase
                        sample = JSONObject().put("phase", phase.name).put("passed", true)
                            .put("actualWidthPx", actual.width()).put("actualHeightPx", actual.height())
                            .put("actualDensity", density).put("registeredWidth", geometry.width).put("registeredHeight", geometry.height)
                            .put("configurationGeneration", token).put("windowGeneration", state.generation)
                            .put("configurationAdvanceRequired", newerThan != null)
                            .put("postConfigurationAdvanceVerified", newerThan != null && token > newerThan)
                            .put("registered", state.registered).put("canSplit", geometry.canSplit)
                            .put("smallestScreenWidthDp", host.resources.configuration.smallestScreenWidthDp)
                            .put("sameFirstObservedActivity", host === firstObservedActivity)
                            .put("sameFirstObservedStore", host.viewModelStore === firstObservedStore)
                    }
                }
                ready
            }
            check(rows.length() < 24)
            rows.put(checkNotNull(sample))
            return token
        }

        fun assertUnchanged(front: BrowserTab, ids: List<String>) = fixture.onActivity {
            assertNull(browser.state.value.workspace)
            assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
            assertEquals(front.id, browser.state.value.tab!!.id)
            assertEquals(front.url, browser.state.value.tab!!.url)
            assertEquals(ids, browser.state.value.space!!.tabs.map { it.id })
        }

        suspend fun newField(front: BrowserTab, previousIds: List<String>): String {
            await("original Open Beside opens one new Field") {
                browser.state.value.let { it.surface == BrowserSurface.FIELD && it.workspace?.first == front.id &&
                    it.workspace?.newPage == it.tab?.id && it.tab?.isBlank == true }
            }
            var id = ""
            fixture.onActivity {
                val state = browser.state.value
                id = state.tab!!.id
                assertFalse(previousIds.contains(id))
                assertEquals(previousIds.toSet() + id, state.space!!.tabs.map { it.id }.toSet())
                assertEquals(previousIds.size + 1, state.space!!.tabs.size)
                assertEquals(BrowserWorkspace(front.id, id, id, newPage = id), state.workspace)
                assertTrue(model.engine.hasLiveSession(front.id))
            }
            await("one actual new Field editor") { compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes().size == 1 }
            compose.onNodeWithTag("browser.field.input").assertIsDisplayed()
            return id
        }

        suspend fun navigateField(url: String) {
            lateinit var input: FieldInputLease
            fixture.onActivity { input = checkNotNull(browser.captureFieldInput()) }
            await("real editor owns OS IME") {
                var visible = false
                fixture.onActivity { host ->
                    check(browser.fieldInputCurrent(input))
                    visible = ViewCompat.getRootWindowInsets(host.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime()) == true
                }
                visible
            }
            val editor = compose.onNodeWithTag("browser.field.input")
            editor.assertIsDisplayed().assertIsEnabled().assertIsFocused()
            fixture.onActivity { check(browser.fieldInputCurrent(input)) }
            editor.performTextReplacement(url)
            editor.assertTextContains(url).assertIsFocused()
            window(1280, 800, Phase.IME)
            fixture.onActivity { host ->
                check(browser.fieldInputCurrent(input))
                assertEquals(url, browser.state.value.fieldText)
                assertTrue(ViewCompat.getRootWindowInsets(host.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime()) == true)
            }
            // Exercise the actual editor's guarded IME Return action while the OS IME is present.
            editor.performImeAction()
            await("actual editor Return loads a Gecko page") {
                browser.state.value.let { it.surface == BrowserSurface.PAGE && it.tab?.url == url &&
                    !it.page.loading && it.page.title == "Android flow article" }
            }
            ui.requireOwnCurrent()
        }

        suspend fun editorReady(words: String, selection: TextRange, tablet: Boolean) {
            val source = browser.state.value
            check(source.surface == BrowserSurface.FIELD)
            val sourceTab = checkNotNull(source.tab)
            var prepared: FieldInputLease? = null
            // Window registration can precede resumed/focused action admission.
            // Prepare one lease only for this original Field before using it;
            // never recapture after any guarded operation has started.
            await("original Field can admit its rendered input") {
                fixture.onActivity { host ->
                    val now = browser.state.value
                    check(now.surface == source.surface && now.surfaceEpoch == source.surfaceEpoch &&
                        now.selectedSpaceId == source.selectedSpaceId && now.space?.websiteProfile == source.space?.websiteProfile &&
                        now.tab?.id == sourceTab.id && now.tab?.url == sourceTab.url)
                    if (host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && host.hasWindowFocus())
                        prepared = browser.captureFieldInput()
                }
                prepared != null
            }
            val input = checkNotNull(prepared)
            var last = JSONObject()
            var inputCurrent: Boolean? = null
            var passed = false
            try {
                await("one current editor retains text selection focus and real OS IME") {
                    var current = false
                    var textMatches = false
                    var imeVisible = false
                    var imeObserved = false
                    var fieldResting = false
                    var fieldSurface = false
                    var sameInputEpoch = false
                    var observedDecor: View? = null
                    var observedToken: Any? = null
                    var decorObserved = false
                    var insetsObserved = false
                    var insetsPresent = false
                    var insetsDetailsObserved = false
                    var imeInsetBottomPositive = false
                    var insetsConsumed = false
                    fixture.onActivity { host ->
                        check(browser.fieldInputCurrent(input).also { inputCurrent = it })
                        runCatching {
                            observedDecor = host.window.decorView
                            observedToken = observedDecor?.windowToken
                            decorObserved = true
                        }
                        current = browser.state.value.let { state ->
                            fieldResting = state.fieldResting
                            fieldSurface = state.surface == BrowserSurface.FIELD
                            sameInputEpoch = state.surfaceEpoch == input.epoch
                            (state.fieldText == words).also { textMatches = it }
                        } && (ViewCompat.getRootWindowInsets(host.window.decorView).also { insets ->
                            runCatching {
                                insetsObserved = true
                                insetsPresent = insets != null
                                if (insets != null) {
                                    imeInsetBottomPositive = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom > 0
                                    insetsConsumed = insets.isConsumed
                                    insetsDetailsObserved = true
                                }
                            }
                        }?.isVisible(WindowInsetsCompat.Type.ime()) == true)
                            .also { imeObserved = true; imeVisible = it }
                    }
                    val editors = compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes()
                    val popups = compose.onAllNodesWithTag("browser.tablet.omnibox").fetchSemanticsNodes()
                    var editorFocused = false
                    var focusObserved = false
                    var selectionMatches = false
                    var selectionObserved = false
                    val ready = current && editors.size == 1 && popups.size == (if (tablet) 1 else 0) &&
                        (editors.single().config.getOrNull(SemanticsProperties.Focused) == true)
                            .also { focusObserved = true; editorFocused = it } &&
                        (editors.single().config.getOrNull(SemanticsProperties.TextSelectionRange) == selection)
                            .also { selectionObserved = true; selectionMatches = it }
                    runCatching {
                        last = JSONObject().put("textMatchesExpected", textMatches).put("imeObserved", imeObserved)
                            .put("imeVisible", imeVisible).put("fieldResting", fieldResting).put("fieldSurface", fieldSurface)
                            .put("sameInputEpoch", sameInputEpoch).put("editorCountCapped", editors.size.coerceAtMost(4))
                            .put("popupCountCapped", popups.size.coerceAtMost(4)).put("tabletExpected", tablet)
                            .put("popupMatchesExpected", popups.size == (if (tablet) 1 else 0))
                            .put("focusObserved", focusObserved).put("editorFocused", editorFocused)
                            .put("selectionObserved", selectionObserved).put("selectionMatchesExpected", selectionMatches)
                        last.put("snapshotCompleted", false)
                        runCatching {
                            // Observe the same fetched node even when the original IME-first
                            // predicate short-circuited. These values cannot make it pass.
                            val editorSnapshot = editors.singleOrNull()
                            val config = editorSnapshot?.config
                            val snapshotFocus = config?.getOrNull(SemanticsProperties.Focused)
                            val snapshotSelection = config?.getOrNull(SemanticsProperties.TextSelectionRange)
                            val snapshotText = config?.getOrNull(SemanticsProperties.EditableText)
                            val editorRoot = editorSnapshot?.root
                            val rootView = (editorRoot as? ViewRootForTest)?.view
                            last
                                .put("snapshotUniqueEditor", editorSnapshot != null)
                                .put("snapshotFocusPresent", snapshotFocus != null).put("snapshotFocused", snapshotFocus == true)
                                .put("snapshotSelectionPresent", snapshotSelection != null)
                                .put("snapshotSelectionMatchesExpected", snapshotSelection == selection)
                                .put("snapshotSelectionCollapsed", snapshotSelection?.collapsed == true)
                                .put("snapshotCaretAtExpectedMax", snapshotSelection?.let { it.collapsed && it.start == selection.max } == true)
                                .put("snapshotCaretAtTextEnd", snapshotSelection != null && snapshotText != null && snapshotSelection.collapsed && snapshotSelection.start == snapshotText.length)
                                .put("snapshotSelectionEqualsExpectedReversed", snapshotSelection == TextRange(selection.end, selection.start))
                                .put("snapshotEditableTextPresent", snapshotText != null)
                                .put("snapshotEditableTextMatchesExpected", snapshotText?.text == words)
                                .put("snapshotEnabled", config != null && config.getOrNull(SemanticsProperties.Disabled) == null)
                                .put("snapshotNodeRootPresent", editorRoot != null).put("snapshotViewRootPresent", rootView != null)
                                .put("snapshotMainDecorObserved", decorObserved).put("snapshotMainTokenPresent", observedToken != null)
                                .put("snapshotRootSameMainDecor", rootView != null && observedDecor != null && rootView.rootView === observedDecor)
                                .put("snapshotRootSameWindowToken", rootView != null && observedToken != null && rootView.windowToken === observedToken)
                                .put("snapshotRootAttached", rootView?.isAttachedToWindow == true).put("snapshotRootShown", rootView?.isShown == true)
                                .put("snapshotInsetsObserved", insetsObserved).put("snapshotInsetsPresent", insetsPresent)
                                .put("snapshotInsetsDetailsObserved", insetsDetailsObserved)
                                .put("snapshotImeInsetBottomPositive", imeInsetBottomPositive).put("snapshotInsetsConsumed", insetsConsumed)
                                .put("snapshotCompleted", true)
                        }
                    }
                    ready
                }
                compose.onAllNodesWithTag("browser.field.input", useUnmergedTree = true).assertCountEquals(1)
                compose.onNodeWithTag("browser.field.input").assertIsDisplayed().assertIsFocused().assertTextContains(words)
                check(rows.length() < 24)
                rows.put(JSONObject().put("phase", if (tablet) "TABLET_EDITOR_READY" else "COMPACT_EDITOR_READY")
                    .put("passed", true).put("editorCount", 1).put("tabletOmniboxTagCount", if (tablet) 1 else 0)
                    .put("selectionRetained", true).put("actualImeVisible", true))
                passed = true
            } finally {
                runCatching {
                    val window = lastVerifiedWindow
                    last.put("passed", passed).put("inputCurrentObserved", inputCurrent != null).put("inputCurrent", inputCurrent == true)
                        .put("tabletExpected", tablet).put("lastVerifiedWindowPhase", lastVerifiedWindowPhase?.name ?: "NONE")
                        .put("lastVerifiedWindowRegistered", window?.registered == true)
                        .put("lastVerifiedWindowGeometryValid", window?.geometry?.valid == true)
                        .put("lastVerifiedWindowCanSplit", window?.geometry?.canSplit == true)
                    if (editorReadiness.length() >= 4) editorReadiness.remove(0)
                    editorReadiness.put(last)
                }
            }
        }

        suspend fun twoPanes(first: BrowserTab, firstSession: GeckoSession, second: BrowserTab, secondSession: GeckoSession) {
            await("two original real native panes") {
                var ready = false
                fixture.onActivity { host ->
                    val views = pageViews(host)
                    val a = views.singleOrNull { it.session === firstSession }
                    val b = views.singleOrNull { it.session === secondSession }
                    val firstFrame = a?.let(::nativeFrame)
                    val secondFrame = b?.let(::nativeFrame)
                    ready = firstFrame != null && secondFrame != null &&
                        firstFrame.left < secondFrame.left && firstFrame.height() == secondFrame.height()
                    if (ready) {
                        assertEquals(2, views.size)
                        assertSame(firstSession, session(first)); assertSame(secondSession, session(second))
                        assertEquals(BrowserWorkspace(first.id, second.id, second.id), browser.state.value.workspace)
                    }
                }
                ready
            }
        }

        fun record(phase: Phase, passed: Boolean) {
            check(rows.length() < 24)
            rows.put(JSONObject().put("phase", phase.name).put("passed", passed))
        }
    }

    private suspend fun scene(case: Case, block: suspend (Scene) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36)
        check(shell("getprop ro.kernel.qemu").trim() == "1")
        val size = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}"))
        val density = overrideValue(shell("wm density"), Regex("[0-9]{2,4}"))
        val rows = JSONArray()
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        var completed = false
        var restored = false
        var failure: Throwable? = null
        try {
            ui.run {
                shell("wm density 160"); shell("wm size 1280x800")
                val blank = BrowserTab("workspace-menu-empty", createdAt = 1)
                FileBrowserRepository(File(context.filesDir, "browser.json")).save(BrowserSnapshot(
                    spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = listOf(blank), currentTabId = blank.id)),
                    selectedSpaceId = BrowserController.PERSONAL_SPACE, settings = BrowserSettings(welcomed = true)))
                AppFlowTest.LocalPage().use { page ->
                    val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse(page.url))
                    ui.checkpoint("before_activity_launch")
                    NativeMainActivityFixture.launch(intent, NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                        var diagnosticScene: Scene? = null
                        try {
                        lateinit var model: BrowserSessionViewModel
                        fixture.onActivity { host ->
                            model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                            val originalModel = model
                            ui.bind(originalModel.browser, originalModel.engine) { originalModel.browser.workspaceWindow.value.generation }
                        }
                        await("original Main Gecko page") { model.browser.state.value.let {
                            it.surface == BrowserSurface.PAGE && it.tab?.url == page.url && !it.page.loading && it.page.title == "Android flow article"
                        } }
                        ui.requireOwnCurrent()
                        val scene = Scene(fixture, model, ui, page.url, rows)
                        diagnosticScene = scene
                        block(scene)
                        scene.record(Phase.COMPLETE, true)
                        } catch (error: Throwable) {
                            runCatching { diagnosticScene?.beginFailureProbe() }
                            runCatching { menuFailure(case, diagnosticScene) }
                            runCatching { preserveOwnedUi(case) }
                            runCatching { diagnosticScene?.callbackFailure(case) }
                            throw error
                        } finally {
                            // Preserve the original helper's bytes before Activity teardown and the next case's init/save.
                            runCatching { preserveOwnedUi(case) }
                        }
                    }
                }
            }
            completed = true
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            withContext(NonCancellable) {
                var cleanup: Throwable? = null
                fun attempt(action: () -> Unit) {
                    try { action() } catch (error: Throwable) { if (cleanup == null) cleanup = error else cleanup!!.addSuppressed(error) }
                }
                attempt { shell("wm size ${size ?: "reset"}") }
                attempt { shell("wm density ${density ?: "reset"}") }
                attempt {
                    restored = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}")) == size &&
                        overrideValue(shell("wm density"), Regex("[0-9]{2,4}")) == density
                    check(restored)
                }
                attempt { receipt(case, completed, restored, rows) }
                cleanup?.let { if (failure != null) failure!!.addSuppressed(it) else throw it }
            }
        }
    }

    private suspend fun savedClick(label: String): () -> Boolean {
        await("one original workspace row") { compose.onAllNodesWithText(label).fetchSemanticsNodes().size == 1 }
        return dev.yab.browser.originalRenderedClick(compose.onNodeWithText(label).fetchSemanticsNode())
    }

    private fun pageViews(host: MainActivity): List<GeckoView> {
        val views = mutableListOf<GeckoView>()
        var visited = 0
        fun visit(view: View) {
            check(++visited <= 512)
            if (view is GeckoView && view.isAttachedToWindow && view.isShown && view.width > 0 && view.height > 0 && view.session != null) views += view
            if (view is ViewGroup) { check(view.childCount <= 128); repeat(view.childCount) { visit(view.getChildAt(it)) } }
        }
        visit(host.window.decorView)
        return views
    }

    private fun nativeFrame(view: GeckoView): Rect {
        val origin = IntArray(2)
        view.getLocationOnScreen(origin)
        return Rect(origin[0], origin[1], origin[0] + view.width, origin[1] + view.height)
    }

    private suspend fun await(label: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (true) {
            compose.waitForIdle()
            if (predicate()) return
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out: $label" }
            delay(40)
        }
    }

    private fun overrideValue(text: String, pattern: Regex): String? {
        val matches = text.lineSequence().filter { it.startsWith("Override ") }.toList()
        check(matches.size <= 1)
        return matches.singleOrNull()?.substringAfter(": ")?.trim()?.also { check(pattern.matches(it)) }
    }

    private fun shell(command: String): String = instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { reader ->
            val buffer = CharArray(4096)
            val output = StringBuilder()
            while (true) {
                val count = reader.read(buffer)
                if (count < 0) break
                check(output.length + count <= 4096)
                output.append(buffer, 0, count)
            }
            output.toString()
        }
    }

    /** Fixed own Compose selectors, observation only. They never authorize or perform an action. */
    private fun writeCallbackProjection(case: Case, row: JSONObject) {
        val bytes = row.toString(2).toByteArray(Charsets.UTF_8)
        if (bytes.size <= 8_192) {
            val folder = File(context.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
            File(folder, "${caseFile(case)}-callback-probe.json").writeBytes(bytes)
        }
    }

    private fun menuControl(control: String): JSONObject {
        val row = JSONObject().put("querySucceeded", false)
        runCatching {
            val nodes = when (control) {
                "HOST" -> compose.onAllNodesWithTag("browser.pageMenu.host", useUnmergedTree = true)
                "OPEN_BESIDE" -> compose.onAllNodesWithText("Open Beside", useUnmergedTree = true)
                else -> return row
            }.fetchSemanticsNodes()
            row.put("querySucceeded", true).put("present", nodes.isNotEmpty()).put("unique", nodes.size == 1)
                .put("matchesCapped", nodes.size > 4)
                .put("uniqueEnabled", nodes.size == 1 && nodes.single().config.getOrNull(SemanticsProperties.Disabled) == null)
        }
        return row
    }

    private fun menuFailure(case: Case, scene: Scene?) {
        val projection = scene?.menuFailure() ?: JSONObject().put("step", MenuStep.SETUP.name)
        val controls = JSONArray()
        for (control in listOf("PAGE_MENU", "OPEN_BESIDE", "FULL_SPREAD", "CLOSE_PAGE", "FIELD_INPUT", "TABLET_OMNIBOX")) {
            val row = JSONObject().put("control", control).put("querySucceeded", false)
            runCatching {
                val nodes = when (control) {
                    "PAGE_MENU" -> compose.onAllNodesWithContentDescription(scene?.menuEntryLabel() ?: "Page menu", useUnmergedTree = true)
                    "OPEN_BESIDE" -> compose.onAllNodesWithText("Open Beside", useUnmergedTree = true)
                    "FULL_SPREAD" -> compose.onAllNodesWithText("Full Spread", useUnmergedTree = true)
                    "CLOSE_PAGE" -> compose.onAllNodesWithText("Close Page", useUnmergedTree = true)
                    "FIELD_INPUT" -> compose.onAllNodesWithTag("browser.field.input", useUnmergedTree = true)
                    else -> compose.onAllNodesWithTag("browser.tablet.omnibox", useUnmergedTree = true)
                }.fetchSemanticsNodes()
                row.put("querySucceeded", true).put("present", nodes.isNotEmpty()).put("unique", nodes.size == 1)
                    .put("matchesCapped", nodes.size > 4)
                    .put("uniqueEnabled", nodes.size == 1 && nodes.single().config.getOrNull(SemanticsProperties.Disabled) == null)
            }
            controls.put(row)
        }
        val bytes = JSONObject().put("schema", 1).put("case", case.name).put("projection", projection)
            .put("controls", controls).put("observerOnly", true).toString(2).toByteArray(Charsets.UTF_8)
        if (bytes.size <= 16_384) {
            val folder = File(context.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
            File(folder, "${caseFile(case)}-diagnostic.json").writeBytes(bytes)
        }
    }

    private fun preserveOwnedUi(case: Case) {
        val folder = File(context.getExternalFilesDir(null), "instrumentation")
        val bytes = File(folder, "owned-browser-app_workspace.json").inputStream().use { input ->
            val buffer = ByteArray(65_537)
            var count = 0
            while (count < buffer.size) {
                val read = input.read(buffer, count, buffer.size - count)
                if (read < 0) break
                count += read
            }
            check(count <= 65_536)
            buffer.copyOf(count)
        }
        File(folder, "${caseFile(case)}-owned-ui.json").writeBytes(bytes)
    }

    private fun caseFile(case: Case): String = when (case) {
        Case.CONFIGURATION -> "app-workspace-menu-config"
        Case.ACTIONS -> "app-workspace-menu-actions"
        Case.EDITOR -> "app-workspace-menu-editor"
        Case.ADDRESS -> "app-workspace-menu-address"
    }

    private fun receipt(case: Case, completed: Boolean, restored: Boolean, rows: JSONArray) {
        val folder = File(context.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
        val name = when (case) { Case.CONFIGURATION -> "app-workspace-menu-config.json"; Case.ACTIONS -> "app-workspace-menu-actions.json"
            Case.EDITOR -> "app-workspace-menu-editor.json"; Case.ADDRESS -> "app-workspace-menu-address.json" }
        val measuredMainWindow = (0 until rows.length()).any { rows.getJSONObject(it).has("actualWidthPx") }
        File(folder, name).writeText(JSONObject().put("schema", 1).put("case", case.name)
            .put("completed", completed && restored).put("wmOverridesRestored", restored).put("actualMainAndGecko", measuredMainWindow)
            .put("osConfigurationUsed", measuredMainWindow).put("localConfigurationInjected", false).put("samples", rows)
            .put("api29CacheRaceProven", false).put("physicalDeviceVerified", false).put("providerAccepted", false)
            .put("frameParityVerified", false).put("wholeTablet63Accepted", false).toString(2))
    }
}

package dev.yab.android

import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.OwnedBrowserTestUi
import dev.yab.browser.model.*
import java.io.File
import kotlin.math.abs
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

/** Real Main, OS window changes and retained Gecko sessions. Positive actions use the
 * unchanged owned native UI adapter; retained semantics are invoked only to prove refusal. */
class AppWorkspaceSidebarTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun actualInsetProjectionRetainsPairAndOriginalControlsCannotReviveThroughSidebarAba(): Unit = runBlocking {
        scene(Case.PROJECTION) { scene ->
            scene.projection(shown = true, split = true, pageWidth = 1000)
            val oldRow = savedClick(ROOT_TAG)
            val oldToggle = savedClick(TOGGLE_TAG)
            val original = scene.snapshot()

            scene.nativeClick("Sidebar")
            scene.projection(shown = false, split = true, pageWidth = 1280)
            scene.assertRetained(original, sameWindow = true)
            scene.ui.requireLabelAbsent(ROOT_TITLE)
            scene.record(Phase.HIDDEN, 2)

            scene.nativeClick("Sidebar")
            scene.projection(shown = true, split = true, pageWidth = 1000)
            scene.assertRetained(original, sameWindow = true)
            // Original mutable-node callbacks must not acquire the new shown layout.
            scene.fixture.onActivity { oldRow(); oldToggle() }
            compose.waitForIdle()
            scene.assertRetained(original, sameWindow = true)
            scene.projection(shown = true, split = true, pageWidth = 1000)
            scene.record(Phase.OLD_CALLBACKS_REFUSED, 2)

            scene.nativeClick(ROOT_TITLE)
            await("fresh native kept row selects its original public target") {
                scene.browser.state.value.let { it.surface == BrowserSurface.PAGE && it.tab?.id == ROOT_ID }
            }
            scene.fixture.onActivity {
                val state = scene.browser.state.value
                assertEquals(scene.rootUrl, state.tab!!.url)
                assertEquals(original.profile, state.space!!.websiteProfile)
                assertEquals(original.ids.toSet(), state.space!!.tabs.map { it.id }.toSet())
                assertEquals(original.epoch, state.surfaceEpoch)
                scene.assertOriginalSessions()
            }
            scene.record(Phase.FRESH_ROW)
        }
    }

    @Test(timeout = 240_000)
    fun actual700And600BoundaryRetainsSessionsAndFreshSidebarFolderClearAndNewTabWork(): Unit = runBlocking {
        scene(Case.BOUNDARY_ACTIONS) { scene ->
            val initial = scene.snapshot()
            val landscape = scene.browser.workspaceWindow.value.configuration
            shell("wm size 700x1000")
            val portrait = scene.window(700, 1000, landscape)
            scene.projection(shown = true, split = false, pageWidth = 420)
            scene.assertRetained(initial)
            val oldRow = savedClick(ROOT_TAG)
            val oldToggle = savedClick(TOGGLE_TAG)

            shell("wm size 600x1000")
            val compact = scene.window(600, 1000, portrait)
            await("compact actual Main has no tablet sidebar or toolbar") {
                compose.onAllNodesWithTag(TOGGLE_TAG).fetchSemanticsNodes().isEmpty() &&
                    compose.onAllNodesWithTag(WORKSPACE_TAG).fetchSemanticsNodes().isEmpty()
            }
            scene.ui.requireLabelAbsent(ROOT_TITLE)
            scene.oneFocusedNativePage()
            scene.fixture.onActivity { oldRow(); oldToggle() }
            compose.waitForIdle()
            scene.assertRetained(initial)
            scene.record(Phase.COMPACT_REFUSED, 1)

            shell("wm size 700x1000")
            scene.window(700, 1000, compact)
            scene.projection(shown = true, split = false, pageWidth = 420)
            scene.fixture.onActivity { oldRow(); oldToggle() }
            compose.waitForIdle()
            scene.assertRetained(initial)
            scene.projection(shown = true, split = false, pageWidth = 420)
            scene.nativeClick("Sidebar")
            scene.projection(shown = false, split = false, pageWidth = 700)
            scene.nativeClick("Sidebar")
            scene.projection(shown = true, split = false, pageWidth = 420)
            scene.record(Phase.PORTRAIT_ABA_REFUSED, 1)

            scene.ui.requireLabelAbsent(CHILD_TITLE)
            scene.nativeClick(FOLDER_TITLE)
            await("fresh native folder opens its actual kept child") {
                scene.browser.state.value.space!!.folders.single { it.id == FOLDER_ID }.open &&
                    compose.onAllNodesWithTag(CHILD_TAG).fetchSemanticsNodes().size == 1
            }
            scene.nativeClick(CHILD_TITLE)
            await("fresh native child selection remains an ordinary PAGE") {
                scene.browser.state.value.let { it.surface == BrowserSurface.PAGE && it.tab?.id == CHILD_ID &&
                    !it.page.loading && it.page.title == "Android flow article" }
            }
            scene.fixture.onActivity { scene.assertOriginalSessions() }
            scene.record(Phase.FOLDER_AND_CHILD)

            val protected = scene.browser.state.value.space!!.tabs.filter { it.place != TabPlace.TODAY }.map { it.id }.toSet()
            scene.nativeClick("Clear")
            scene.clearAndNewTabReady(protected)
            scene.fixture.onActivity {
                assertEquals(CHILD_ID, scene.browser.state.value.tab!!.id)
                assertTrue(scene.browser.state.value.space!!.folders.single { it.id == FOLDER_ID }.open)
                assertEquals(initial.profile, scene.browser.state.value.space!!.websiteProfile)
                scene.assertOriginalSessions()
            }
            scene.record(Phase.CLEAR_TODAY)

            val beforeField = scene.browser.state.value
            scene.nativeSidebarNewTab()
            scene.realField(beforeField)
            scene.record(Phase.NEW_TAB_REAL_FIELD)
        }
    }

    private data class Original(val pair: BrowserWorkspace, val ids: List<String>, val front: String,
        val space: String, val profile: WebsiteProfile, val epoch: Long, val window: BrowserWorkspaceWindow)

    private inner class Scene(val fixture: NativeMainActivityFixture, val model: BrowserSessionViewModel,
        val ui: OwnedBrowserTestUi, val rootUrl: String, private val rows: JSONArray) {
        val browser get() = model.browser
        private lateinit var first: BrowserTab
        private lateinit var second: BrowserTab
        private lateinit var firstSession: GeckoSession
        private lateinit var secondSession: GeckoSession

        suspend fun preparePair() {
            window(1280, 800)
            fixture.onActivity {
                first = checkNotNull(browser.state.value.tab)
                check(first.id == FIRST_ID && model.engine.hasLiveSession(first.id))
                firstSession = model.engine.session(first, browser.state.value.space!!.websiteProfile)
                second = browser.state.value.space!!.tabs.single { it.id == SECOND_ID }
                // Initial fixture state only. Every action under test below is native UI.
                browser.openBeside(second.id)
            }
            await("initial companion has a real loaded Gecko document") {
                browser.state.value.let { it.tab?.id == SECOND_ID && !it.page.loading && it.page.title == "Android flow article" }
            }
            fixture.onActivity {
                check(model.engine.hasLiveSession(second.id))
                secondSession = model.engine.session(second, browser.state.value.space!!.websiteProfile)
                assertEquals(BrowserWorkspace(FIRST_ID, SECOND_ID, SECOND_ID), browser.state.value.workspace)
            }
            ui.requireOwnCurrent()
            projection(shown = true, split = true, pageWidth = 1000)
            record(Phase.ORIGINAL_PAIR, 2)
        }

        suspend fun nativeClick(label: String) {
            compose.waitForIdle()
            ui.click(label)
            compose.waitForIdle()
        }

        suspend fun nativeSidebarNewTab() {
            compose.waitForIdle()
            val row = compose.onNodeWithTag("browser.tablet.sidebar.new-tab").fetchSemanticsNode()
            val label = compose.onNode(hasContentDescription("New Tab") and hasAnyAncestor(hasTestTag("browser.tablet.sidebar.new-tab")),
                useUnmergedTree = true).fetchSemanticsNode()
            lateinit var target: SidebarNewTabNativeTarget
            fixture.onActivity { host -> target = SidebarNewTabNativeTarget.capture(host, model, row, label) }
            target.tap(ui)
            compose.waitForIdle()
        }

        /** The original post-Clear30s budget includes native accessibility queue idle
         * and the same actual row's geometry. This is readiness only, never a click retry. */
        suspend fun clearAndNewTabReady(protected: Set<String>) {
            val deadline = SystemClock.elapsedRealtime() + 30_000
            fun cleared(): Boolean {
                val tabs = browser.state.value.space!!.tabs
                return tabs.none { it.place == TabPlace.TODAY } && tabs.map { it.id }.toSet() == protected
            }
            while (true) {
                compose.waitForIdle()
                if (cleared()) {
                    val row = compose.onAllNodesWithTag("browser.tablet.sidebar.new-tab").fetchSemanticsNodes().singleOrNull()
                    val before = row?.boundsInRoot
                    if (row != null && before != null && before.width > 0 && before.height > 0) {
                        val remaining = deadline - SystemClock.elapsedRealtime()
                        check(remaining > 0) { "Timed out: native Clear and settled New Tab" }
                        instrumentation.uiAutomation.waitForIdle(100, remaining)
                        compose.waitForIdle()
                        val after = compose.onAllNodesWithTag("browser.tablet.sidebar.new-tab").fetchSemanticsNodes().singleOrNull()
                        check(SystemClock.elapsedRealtime() < deadline) { "Timed out: native Clear and settled New Tab" }
                        if (cleared() && after != null && after.id == row.id && after.boundsInRoot == before) {
                            ui.requireOwnCurrent()
                            check(SystemClock.elapsedRealtime() < deadline) { "Timed out: native Clear and settled New Tab" }
                            return
                        }
                    }
                }
                check(SystemClock.elapsedRealtime() < deadline) { "Timed out: native Clear and settled New Tab" }
                delay(40)
            }
        }

        suspend fun window(width: Int, height: Int, newerThan: Long? = null): Long {
            var configuration = -1L
            await("registered full Main window matches the actual OS configuration") {
                var ready = false
                fixture.onActivity { host ->
                    val registered = browser.workspaceWindow.value
                    if (newerThan != null && registered.configuration <= newerThan) return@onActivity
                    val actual = if (Build.VERSION.SDK_INT >= 30) host.windowManager.currentWindowMetrics.bounds
                        else error("This consumer requires the original API36 profile")
                    val density = host.resources.displayMetrics.density.toDouble()
                    val geometry = registered.geometry
                    ready = registered.registered && actual.width() == width && actual.height() == height && density == 1.0 &&
                        geometry == BrowserWorkspaceWindow(width.toDouble(), height.toDouble())
                    if (ready) {
                        assertEquals(width > height && width >= 641, geometry!!.canSplit)
                        assertTrue(host.resources.configuration.smallestScreenWidthDp >= if (width >= 700) 700 else 600)
                        configuration = registered.configuration
                    }
                }
                ready
            }
            return configuration
        }

        fun snapshot(): Original {
            var original: Original? = null
            fixture.onActivity {
                val state = browser.state.value
                original = Original(checkNotNull(state.workspace), state.space!!.tabs.map { it.id }, state.tab!!.id,
                    state.selectedSpaceId, state.space!!.websiteProfile, state.surfaceEpoch,
                    checkNotNull(browser.workspaceWindow.value.geometry))
            }
            return checkNotNull(original)
        }

        fun assertOriginalSessions() {
            assertTrue(model.engine.hasLiveSession(first.id)); assertTrue(model.engine.hasLiveSession(second.id))
            val profile = browser.state.value.space!!.websiteProfile
            assertSame(firstSession, model.engine.session(first, profile))
            assertSame(secondSession, model.engine.session(second, profile))
            assertEquals(profile.id, firstSession.settings.contextId)
            assertEquals(profile.id, secondSession.settings.contextId)
            assertFalse(firstSession.settings.usePrivateMode); assertFalse(secondSession.settings.usePrivateMode)
        }

        fun assertRetained(original: Original, sameWindow: Boolean = false) = fixture.onActivity {
            val state = browser.state.value
            assertEquals(BrowserSurface.PAGE, state.surface)
            assertEquals(original.pair, state.workspace)
            assertEquals(original.front, state.tab!!.id)
            assertEquals(original.ids, state.space!!.tabs.map { it.id })
            assertEquals(original.space, state.selectedSpaceId)
            assertEquals(original.profile, state.space!!.websiteProfile)
            assertEquals(original.epoch, state.surfaceEpoch)
            if (sameWindow) assertEquals(original.window, browser.workspaceWindow.value.geometry)
            assertOriginalSessions()
        }

        suspend fun projection(shown: Boolean, split: Boolean, pageWidth: Int) {
            await("actual inset page and visible retained native panes agree") {
                val pages = compose.onAllNodesWithTag(PAGE_TAG).fetchSemanticsNodes()
                val toggle = compose.onAllNodesWithTag(TOGGLE_TAG).fetchSemanticsNodes()
                if (pages.size != 1 || toggle.size != 1) return@await false
                val page = pages.single()
                val bounds = page.boundsInWindow
                if (abs(bounds.width - pageWidth) > 1f || bounds.height <= 0) return@await false
                val root = (page.root as? ViewRootForTest)?.view ?: return@await false
                var ready = false
                fixture.onActivity { host ->
                    if (root.windowToken !== host.window.decorView.windowToken || !root.isAttachedToWindow || !root.isShown) return@onActivity
                    val origin = IntArray(2).also(host.window.decorView::getLocationOnScreen)
                    val pageBounds = Rect((bounds.left + origin[0]).toInt(), (bounds.top + origin[1]).toInt(),
                        (bounds.right + origin[0]).toInt(), (bounds.bottom + origin[1]).toInt())
                    val views = pageViews(host)
                    val visible = views.mapNotNull { view -> visibleFrame(view)?.let { view to it } }
                    if (visible.size != if (split) 2 else 1) return@onActivity
                    val firstFrame = visible.singleOrNull { it.first.session === firstSession }?.second
                    val focusedFrame = visible.singleOrNull { it.first.session === secondSession }?.second
                    if (focusedFrame == null || split && firstFrame == null) return@onActivity
                    val frames = visible.map { it.second }.sortedBy { it.left }
                    ready = near(frames.first().left, pageBounds.left) && near(frames.last().right, pageBounds.right) &&
                        frames.all { near(it.top, pageBounds.top) && near(it.bottom, pageBounds.bottom) } &&
                        (!split || frames[1].left - frames[0].right in 7..9)
                    if (ready) {
                        assertTrue(browser.workspaceWindow.value.geometry!!.canSplit || !split)
                        assertEquals(if (shown) 264 + 8 else 0, pageBounds.left - origin[0])
                        assertOriginalSessions()
                    }
                }
                ready
            }
        }

        suspend fun oneFocusedNativePage() {
            await("compact Main shows only its original focused native session") {
                var ready = false
                fixture.onActivity { host ->
                    val views = pageViews(host)
                    ready = views.size == 1 && views.single().session === secondSession && visibleFrame(views.single()) != null
                    if (ready) assertOriginalSessions()
                }
                ready
            }
        }

        suspend fun realField(before: BrowserState) {
            await("fresh native New Tab owns the single existing Field and real OS IME") {
                val editors = compose.onAllNodesWithTag("browser.field.input").fetchSemanticsNodes()
                if (editors.size != 1) return@await false
                var ready = false
                fixture.onActivity { host ->
                    val state = browser.state.value
                    ready = state.surface == BrowserSurface.FIELD && state.fieldIsNewTab && !state.fieldIsPrivate &&
                        !state.fieldResting && ViewCompat.getRootWindowInsets(host.window.decorView)
                            ?.isVisible(WindowInsetsCompat.Type.ime()) == true
                    if (ready) {
                        assertEquals(before.workspace, state.workspace)
                        assertEquals(before.space!!.tabs, state.space!!.tabs)
                        assertEquals(before.surfaceEpoch + 1, state.surfaceEpoch)
                        assertOriginalSessions()
                    }
                }
                ready
            }
            compose.onNodeWithTag("browser.field.input").assertIsDisplayed().assertIsEnabled().assertIsFocused()
        }

        fun record(phase: Phase, visible: Int? = null) {
            check(rows.length() < 24)
            val row = JSONObject().put("phase", phase.name).put("passed", true)
            if (visible != null) row.put("visibleNativeViews", visible)
            rows.put(row)
        }
    }

    private suspend fun scene(case: Case, block: suspend (Scene) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36)
        check(shell("getprop ro.kernel.qemu").trim() == "1")
        val size = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}"))
        val density = overrideValue(shell("wm density"), Regex("[0-9]{2,4}"))
        val rows = JSONArray()
        val initialDocument = JSONObject()
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        var completed = false
        var restored = false
        var failure: Throwable? = null
        try {
            ui.run {
                shell("wm density 160"); shell("wm size 1280x800")
                AppFlowTest.LocalPage().use { firstPage -> AppFlowTest.LocalPage().use { secondPage ->
                    val rootUrl = firstPage.url + "?sidebar-root"
                    val tabs = listOf(
                        BrowserTab(FIRST_ID, firstPage.url, "Sidebar original first", TabPlace.KEPT, createdAt = 1),
                        BrowserTab(SECOND_ID, secondPage.url, "Sidebar original second", TabPlace.KEPT, createdAt = 2),
                        BrowserTab(ROOT_ID, rootUrl, ROOT_TITLE, TabPlace.KEPT, createdAt = 3),
                        BrowserTab(CHILD_ID, secondPage.url + "?sidebar-child", CHILD_TITLE, TabPlace.KEPT, createdAt = 4, folderId = FOLDER_ID),
                        BrowserTab("NEW_TAB|N|N", firstPage.url + "?pin", "Sidebar pin", TabPlace.PINNED, createdAt = 5),
                        BrowserTab("PINS|N|N", firstPage.url + "?today-one", "Sidebar today one", createdAt = 6),
                        BrowserTab("TODAY_CAPTION|N|N", firstPage.url + "?today-two", "Sidebar today two", createdAt = 7),
                    )
                    val snapshot = BrowserSnapshot(
                        spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = tabs,
                            currentTabId = FIRST_ID, folders = listOf(BrowserFolder(FOLDER_ID, FOLDER_TITLE, open = false)))),
                        selectedSpaceId = BrowserController.PERSONAL_SPACE, settings = BrowserSettings(welcomed = true))
                    // The ordinary launcher owns the loaded Controller before initial
                    // setup. ACTION_VIEW would create an unrelated external tab.
                    val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
                    ui.checkpoint("before_activity_launch")
                    val fixture = NativeMainActivityFixture.launch(intent, NativeMainActivityFixture.Kind.APP_WORKSPACE)
                    var activityFailure: Throwable? = null
                    try { fixture.use {
                        lateinit var model: BrowserSessionViewModel
                        fixture.onActivity { host ->
                            model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                            val original = model
                            ui.bind(original.browser, original.engine) { original.browser.workspaceWindow.value.generation }
                        }
                        val scene = Scene(fixture, model, ui, rootUrl, rows)
                        var bodyFailure: Throwable? = null
                        try {
                            await("original Main finishes its actual repository load") { !model.browser.state.value.loading }
                            scene.window(1280, 800)
                            fixture.onActivity {
                                check(model.browser.state.value.persistenceError == null)
                                initialDocument.put("beforeSetup", initialDocumentObservation(model.browser.state.value, firstPage.url))
                                // Initial public fixture setup belongs to this loaded owner,
                                // after its real full-window registration. No prelaunch writer.
                                model.browser.applySyncedSnapshot(snapshot)
                                model.browser.selectTab(FIRST_ID)
                                val original = model.browser.state.value
                                initialDocument.put("afterSetup", initialDocumentObservation(original, firstPage.url))
                                val tab = checkNotNull(original.tab)
                                val space = checkNotNull(original.space)
                                check(original.surface == BrowserSurface.PAGE && !original.loading &&
                                    tab.id == FIRST_ID && tab.url == firstPage.url && !space.isPrivate && !tab.isPrivate &&
                                    space.id == BrowserController.PERSONAL_SPACE && space.websiteProfile == snapshot.spaces.single().websiteProfile)
                                check(model.engine.hasLiveSession(tab.id))
                                // This fixture owns its synthetic initial document. Explicitly
                                // navigate its existing native session once, before tested UI.
                                model.engine.navigate(tab, firstPage.url, space.websiteProfile)
                                initialDocument.put("afterNavigate", initialDocumentObservation(model.browser.state.value, firstPage.url))
                            }
                            await("original Main owns the first real Gecko document") {
                                model.browser.state.value.also {
                                    initialDocument.put("lastPredicate", initialDocumentObservation(it, firstPage.url))
                                    initialDocument.put("lastFixtureUrl", it.tab?.url?.takeIf { url -> url.startsWith("http://127.0.0.1:") }?.take(240))
                                }.let { it.surface == BrowserSurface.PAGE && it.tab?.id == FIRST_ID &&
                                    it.tab?.url == firstPage.url && !it.page.loading && it.page.title == "Android flow article" }
                            }
                            scene.preparePair()
                            block(scene)
                            scene.record(Phase.COMPLETE)
                        } catch (error: Throwable) { bodyFailure = error; throw error }
                        finally { preserve(case, "owned-browser-app_workspace.json", "owned-ui", bodyFailure) }
                    } } catch (error: Throwable) { activityFailure = error; throw error }
                    finally { preserve(case, "native-main-activity-app_workspace.json", "activity", activityFailure) }
                } }
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
                attempt { receipt(case, completed, restored, rows, initialDocument) }
                cleanup?.let { if (failure != null) failure!!.addSuppressed(it) else throw it }
            }
        }
    }

    private suspend fun savedClick(tag: String): () -> Boolean {
        await("one original rendered sidebar control") { compose.onAllNodesWithTag(tag).fetchSemanticsNodes().size == 1 }
        return dev.yab.browser.originalRenderedClick(compose.onNodeWithTag(tag).fetchSemanticsNode())
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

    private fun visibleFrame(view: GeckoView): Rect? = Rect().takeIf { view.getGlobalVisibleRect(it) && it.width() > 0 && it.height() > 0 }
    private fun near(a: Int, b: Int): Boolean = abs(a - b) <= 1

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

    private fun preserve(case: Case, source: String, suffix: String, originalFailure: Throwable?) {
        try {
            val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
            val bytes = File(folder, source).inputStream().use { input ->
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
            File(folder, "${case.file}-$suffix.json").writeBytes(bytes)
        } catch (error: Throwable) { if (originalFailure != null) originalFailure.addSuppressed(error) else throw error }
    }

    private fun initialDocumentObservation(state: BrowserState, expectedUrl: String): JSONObject = JSONObject()
        .put("loading", state.loading).put("persistenceErrorPresent", state.persistenceError != null)
        .put("pageSurface", state.surface == BrowserSurface.PAGE).put("tabPresent", state.tab != null)
        .put("firstIdMatches", state.tab?.id == FIRST_ID).put("firstUrlMatches", state.tab?.url == expectedUrl)
        .put("pageLoading", state.page.loading).put("pageTitleMatches", state.page.title == "Android flow article")
        .put("personalSpaceMatches", state.space?.id == BrowserController.PERSONAL_SPACE)
        .put("publicSpace", state.space?.isPrivate == false).put("workspacePresent", state.workspace != null)

    private fun receipt(case: Case, completed: Boolean, restored: Boolean, rows: JSONArray, initialDocument: JSONObject) {
        val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation").apply { check(isDirectory || mkdirs()) }
        val text = JSONObject().put("schema", 1).put("case", case.name).put("completed", completed && restored)
            .put("wmOverridesRestored", restored).put("samples", rows).put("initialDocument", initialDocument)
            .put("actualMainAndGecko", rows.length() > 0)
            .put("localConfigurationInjected", false).put("forcedResume", false).put("physicalDeviceVerified", false)
            .put("providerAccepted", false).put("frameParityVerified", false).put("wholeTabletAccepted", false).toString(2)
        check(text.toByteArray().size <= 16_384)
        File(folder, "${case.file}.json").writeText(text)
    }

    private enum class Case(val file: String) {
        PROJECTION("app-workspace-sidebar-projection"), BOUNDARY_ACTIONS("app-workspace-sidebar-boundary")
    }
    private enum class Phase { ORIGINAL_PAIR, HIDDEN, OLD_CALLBACKS_REFUSED, FRESH_ROW, COMPACT_REFUSED,
        PORTRAIT_ABA_REFUSED, FOLDER_AND_CHILD, CLEAR_TODAY, NEW_TAB_REAL_FIELD, COMPLETE }

    private companion object {
        const val FIRST_ID = "sidebar-first"
        const val SECOND_ID = "sidebar-second"
        const val ROOT_ID = "shared"
        const val FOLDER_ID = "shared"
        const val CHILD_ID = "sidebar-child"
        const val ROOT_TITLE = "Sidebar root kept"
        const val FOLDER_TITLE = "Sidebar folder"
        const val CHILD_TITLE = "Sidebar child"
        const val ROOT_TAG = "browser.tablet.sidebar.tab.shared"
        const val CHILD_TAG = "browser.tablet.sidebar.tab.sidebar-child"
        const val TOGGLE_TAG = "browser.tablet.sidebar.toggle"
        const val WORKSPACE_TAG = "browser.tablet.workspace"
        const val PAGE_TAG = "browser.tablet.workspace.page"
    }
}

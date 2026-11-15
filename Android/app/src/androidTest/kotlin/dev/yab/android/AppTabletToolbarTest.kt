package dev.yab.android

import android.content.Intent
import android.content.res.Configuration
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

/** Actual Main toolbar consumers. Saved callbacks are negative checks only;
 * every successful toolbar, Gallery and Field action uses the owned native adapter. */
class AppTabletToolbarTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun originalToolbarCallbacksCannotReviveAcrossActualWindowAbaAndFreshReloadWorks(): Unit = runBlocking {
        scene(Case.COMMANDS) { scene ->
            val original = scene.original()
            val oldReload = savedClick(RELOAD_TAG)
            val oldNewTab = savedClick(NEW_TAB_TAG)
            val oldTabs = savedClick(ALL_TABS_TAG)
            val initialConfiguration = scene.browser.workspaceWindow.value.configuration

            shell("wm size 600x1000")
            val compact = scene.window(600, 1000, initialConfiguration)
            await("actual compact Main has no tablet toolbar") {
                compose.onAllNodesWithTag(TOOLBAR_TAG).fetchSemanticsNodes().isEmpty()
            }
            scene.fixture.onActivity { oldReload(); oldNewTab(); oldTabs() }
            compose.waitForIdle()
            scene.assertOriginal(original)
            scene.record(Phase.COMPACT_REFUSED)

            shell("wm size 900x768")
            scene.window(900, 768, compact)
            scene.toolbarReady()
            val before = scene.browser.state.value
            val requests = scene.articleRequests()
            scene.fixture.onActivity { oldReload(); oldNewTab(); oldTabs() }
            compose.waitForIdle()
            scene.fixture.onActivity { assertEquals(before, scene.browser.state.value) }
            scene.assertOriginal(original)
            assertEquals(requests, scene.articleRequests())
            scene.record(Phase.ORIGINAL_CALLBACKS_REFUSED)

            scene.nativeClick("Reload")
            await("fresh native Reload requests the original real HTTP article") {
                scene.articleRequests() > requests && scene.documentReady()
            }
            scene.assertOriginal(original)
            scene.record(Phase.FRESH_RELOAD, scene.articleRequests())
        }
    }

    @Test(timeout = 240_000)
    fun actualToolbarAllTabsReturnsToItsSinglePageAndNewTabOpensOneRealField(): Unit = runBlocking {
        scene(Case.GALLERY_AND_FIELD) { scene ->
            val original = scene.original()
            scene.fixture.onActivity {
                assertEquals(1, scene.browser.state.value.space!!.tabs.size)
                assertEquals(listOf(scene.firstId), scene.browser.state.value.galleryTabs.map { it.id })
            }
            scene.nativeClick("All Tabs")
            await("native All Tabs opens the actual one-card Gallery") {
                scene.browser.state.value.surface == BrowserSurface.GALLERY &&
                    compose.onAllNodesWithTag("browser.gallery.card.${scene.firstId}").fetchSemanticsNodes().size == 1 &&
                    compose.onAllNodesWithTag(INPUT_TAG).fetchSemanticsNodes().isEmpty()
            }
            scene.record(Phase.ONE_CARD_GALLERY)
            scene.nativeGalleryCard(scene.firstId, "Android flow article")
            await("native Gallery card returns to the exact original page") { scene.documentReady() }
            scene.toolbarReady()
            scene.assertOriginal(original, sameEpoch = false)

            // Both Sidebar and toolbar legitimately say New Tab. This case targets
            // the toolbar, so hide Sidebar through its real control before native input.
            assertEquals(264f, compose.onNodeWithTag(SIDEBAR_FRAME_TAG).fetchSemanticsNode().boundsInRoot.width, 1f)
            val sidebarSource = scene.captureSidebarPage(original)
            scene.nativeClick("Sidebar")
            scene.hiddenSidebar(sidebarSource)
            val beforeField = scene.browser.state.value
            scene.nativeClick("New Tab")
            scene.realField(beforeField)
            scene.record(Phase.FRESH_NEW_TAB_FIELD)
        }
    }

    @Test(timeout = 240_000)
    fun actualBlankGallerySurvivesActivityReplacementAndOnlyItsFreshNativeCardCanReturn(): Unit = runBlocking {
        scene(Case.GALLERY_RECREATION) { scene ->
            val setupConfiguration = scene.browser.workspaceWindow.value.configuration
            shell("wm size 1280x800")
            scene.window(1280, 800, setupConfiguration)
            val blank = BrowserTab("toolbar-empty-front", "about:blank", "Tablet empty front", createdAt = 1)
            fun blankFront(state: BrowserState) = state.tab?.let {
                it.id == blank.id && it.url == blank.url && it.title == blank.title && !it.isPrivate
            } == true
            lateinit var profile: WebsiteProfile
            lateinit var blankSession: GeckoSession
            lateinit var articleSession: GeckoSession
            lateinit var originalActivity: MainActivity
            var originalStore: Any? = null
            scene.fixture.onActivity { host ->
                val saved = checkNotNull(scene.browser.publicSnapshot())
                val original = checkNotNull(scene.browser.state.value.space)
                scene.browser.applySyncedSnapshot(saved.copy(spaces = saved.spaces.map {
                    if (it.id == original.id) it.copy(tabs = it.tabs + blank) else it
                }))
                scene.browser.selectTab(blank.id)
                scene.browser.openBeside(scene.firstId)
                scene.browser.selectTab(blank.id)
                val state = scene.browser.state.value
                profile = checkNotNull(state.space).websiteProfile
                check(blankFront(state) && state.workspace != null && scene.model.engine.hasLiveSession(blank.id) &&
                    scene.model.engine.hasLiveSession(scene.firstId))
                // A legitimate initial blank native document, not a renamed UI node.
                scene.model.engine.navigate(checkNotNull(state.tab), blank.url, profile)
                blankSession = scene.model.engine.session(checkNotNull(state.tab), profile)
                articleSession = scene.model.engine.session(state.space!!.tabs.single { it.id == scene.firstId }, profile)
                originalActivity = host; originalStore = host.viewModelStore
            }
            val initialAllTabs = GalleryCardNativeTarget.Readiness()
            await("the actual blank native front owns an enabled All Tabs control") {
                val frontReady = scene.browser.state.value.let { it.surface == BrowserSurface.PAGE && blankFront(it) && !it.page.loading }
                if (!frontReady) { initialAllTabs.reset(); false } else scene.allTabsReady(initialAllTabs)
            }
            compose.onNodeWithTag(ALL_TABS_TAG).assertIsDisplayed().assertIsEnabled()
            val pair = checkNotNull(scene.browser.state.value.workspace)
            scene.nativeClick("All Tabs")
            val epoch = scene.browser.state.value.surfaceEpoch
            val blankTag = "browser.gallery.card.${blank.id}"
            await("the actual Gallery shows the public blank front and real article") {
                scene.browser.state.value.surface == BrowserSurface.GALLERY &&
                    compose.onAllNodesWithTag(blankTag).fetchSemanticsNodes().size == 1 &&
                    compose.onAllNodesWithTag("browser.gallery.card.${scene.firstId}").fetchSemanticsNodes().size == 1
            }
            compose.onNodeWithTag(blankTag).assertIsDisplayed().assertIsEnabled()
            val oldBlank = savedClick(blankTag)
            scene.record(Phase.BLANK_GALLERY)
            val configuration = scene.browser.workspaceWindow.value.configuration
            shell("wm size 600x1000")
            val compact = scene.window(600, 1000, configuration)
            // Main now handles screenLayout for PiP. A resize can legitimately
            // keep this Activity, so request the real replacement this case proves.
            scene.fixture.recreate()
            await("a fresh compact Gallery render retains the real blank front") {
                scene.browser.state.value.let { it.surface == BrowserSurface.GALLERY && it.surfaceEpoch == epoch && blankFront(it) } &&
                    compose.onAllNodesWithTag(blankTag).fetchSemanticsNodes().size == 1
            }
            scene.fixture.onActivity { host ->
                assertNotSame(originalActivity, host)
                assertSame(originalStore, host.viewModelStore)
                assertSame(scene.model, ViewModelProvider(host)[BrowserSessionViewModel::class.java])
                assertEquals(pair, scene.browser.state.value.workspace)
            }
            compose.onNodeWithTag(blankTag).assertIsDisplayed().assertIsEnabled()
            scene.record(Phase.COMPACT_BLANK_GALLERY)
            shell("wm size 1280x800")
            scene.window(1280, 800, compact)
            await("a fresh returned tablet Gallery still has its original blank front") {
                compose.onAllNodesWithTag(blankTag).fetchSemanticsNodes().size == 1 &&
                    scene.browser.state.value.let { it.surface == BrowserSurface.GALLERY && it.surfaceEpoch == epoch && blankFront(it) }
            }
            val before = scene.browser.state.value
            scene.fixture.onActivity { oldBlank() }
            compose.waitForIdle()
            scene.fixture.onActivity { assertEquals(before, scene.browser.state.value) }
            scene.record(Phase.OLD_BLANK_REFUSED)
            scene.nativeGalleryCard(blank.id, "Tablet empty front")
            await("only the fresh native blank card returns to its actual selected page") {
                scene.browser.state.value.let { it.surface == BrowserSurface.PAGE && blankFront(it) }
            }
            scene.fixture.onActivity {
                val state = scene.browser.state.value
                assertEquals(pair, state.workspace)
                assertEquals(profile, state.space!!.websiteProfile)
                assertEquals(setOf(scene.firstId, blank.id), state.space!!.tabs.map { it.id }.toSet())
                check(scene.model.engine.hasLiveSession(blank.id) && scene.model.engine.hasLiveSession(scene.firstId))
                assertSame(blankSession, scene.model.engine.session(state.tab!!, profile))
                assertSame(articleSession, scene.model.engine.session(state.space!!.tabs.single { it.id == scene.firstId }, profile))
            }
            scene.record(Phase.FRESH_BLANK_RETURN)
        }
    }

    private data class Original(val tab: BrowserTab, val space: String, val profile: WebsiteProfile,
        val epoch: Long, val session: GeckoSession)

    /** Observation only: the Sidebar layout may change, the original PAGE owner may not. */
    private class SidebarPageSource(val root: View, val session: GeckoSession, val axWindow: Int,
        val axBounds: Rect, val beforePage: Rect, val beforeNative: Rect, val current: () -> Boolean)

    private inner class Scene(val fixture: NativeMainActivityFixture, val model: BrowserSessionViewModel,
        val ui: OwnedBrowserTestUi, val page: AppFlowTest.LocalPage, val firstId: String,
        private val rows: JSONArray) {
        val browser get() = model.browser

        fun articleRequests() = page.requests.count { it.startsWith("GET /article ") }

        fun documentReady() = browser.state.value.let { state ->
            state.surface == BrowserSurface.PAGE && state.tab?.id == firstId && state.tab?.url == page.url &&
                !state.page.loading && state.page.title == "Android flow article"
        }

        suspend fun loadInitialDocument() {
            await("the original Main Controller has finished loading") { !browser.state.value.loading }
            window(900, 768)
            fixture.onActivity {
                val initial = BrowserSnapshot(spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE,
                    "Personal", tabs = listOf(BrowserTab(firstId, page.url, "Toolbar original article", TabPlace.KEPT, createdAt = 1)),
                    currentTabId = firstId)), selectedSpaceId = BrowserController.PERSONAL_SPACE,
                    settings = BrowserSettings(welcomed = true))
                check(browser.state.value.persistenceError == null)
                browser.applySyncedSnapshot(initial)
                browser.selectTab(firstId)
                val state = browser.state.value
                val tab = checkNotNull(state.tab)
                val space = checkNotNull(state.space)
                check(!state.loading && state.surface == BrowserSurface.PAGE && tab.id == firstId && tab.url == page.url &&
                    space.id == BrowserController.PERSONAL_SPACE && !space.isPrivate && !tab.isPrivate &&
                    space.websiteProfile == initial.spaces.single().websiteProfile)
                check(model.engine.hasLiveSession(tab.id))
                // Initial disposable document setup only, never a tested UI action.
                model.engine.navigate(tab, page.url, space.websiteProfile)
            }
            await("original Main owns the exact loaded fixture document") { documentReady() }
            toolbarReady()
            record(Phase.ORIGINAL_REAL_PAGE, articleRequests())
        }

        suspend fun toolbarReady() {
            await("one enabled actual tablet toolbar owns its loaded original page") {
                documentReady() && compose.onAllNodesWithTag(TOOLBAR_TAG).fetchSemanticsNodes().size == 1 &&
                    compose.onAllNodesWithTag(RELOAD_TAG).fetchSemanticsNodes().size == 1 &&
                    compose.onAllNodesWithTag(NEW_TAB_TAG).fetchSemanticsNodes().size == 1 &&
                    compose.onAllNodesWithTag(ALL_TABS_TAG).fetchSemanticsNodes().size == 1
            }
            compose.onNodeWithTag(RELOAD_TAG).assertIsDisplayed().assertIsEnabled()
            compose.onNodeWithTag(NEW_TAB_TAG).assertIsDisplayed().assertIsEnabled()
            compose.onNodeWithTag(ALL_TABS_TAG).assertIsDisplayed().assertIsEnabled()
            ui.requireOwnCurrent()
        }

        fun original(): Original {
            lateinit var result: Original
            fixture.onActivity {
                val state = browser.state.value
                val tab = checkNotNull(state.tab)
                val space = checkNotNull(state.space)
                check(tab.id == firstId && tab.url == page.url && model.engine.hasLiveSession(tab.id))
                result = Original(tab, space.id, space.websiteProfile, state.surfaceEpoch,
                    model.engine.session(tab, space.websiteProfile))
            }
            return result
        }

        fun assertOriginal(original: Original, sameEpoch: Boolean = true) = fixture.onActivity {
            val state = browser.state.value
            assertEquals(BrowserSurface.PAGE, state.surface)
            assertEquals(original.tab.id, state.tab!!.id)
            assertEquals(original.tab.url, state.tab!!.url)
            assertEquals(original.space, state.selectedSpaceId)
            assertEquals(original.profile, state.space!!.websiteProfile)
            assertEquals(listOf(original.tab.id), state.space!!.tabs.map { it.id })
            assertNull(state.workspace)
            if (sameEpoch) assertEquals(original.epoch, state.surfaceEpoch)
            check(model.engine.hasLiveSession(original.tab.id))
            assertSame(original.session, model.engine.session(state.tab!!, original.profile))
        }

        suspend fun nativeClick(label: String) {
            compose.waitForIdle()
            ui.click(label)
            compose.waitForIdle()
        }

        fun captureSidebarPage(original: Original): SidebarPageSource {
            val page = compose.onNodeWithTag("browser.tablet.workspace.page").fetchSemanticsNode()
            val before = page.boundsInWindow
            check(kotlin.math.abs(before.width - 620f) <= 1f && kotlin.math.abs(before.left - 272f) <= 1f)
            val root = (page.root as? ViewRootForTest)?.view ?: error("Original page has no native Compose root")
            val ax = checkNotNull(instrumentation.uiAutomation.rootInActiveWindow)
            val axWindow: Int
            val axBounds = Rect()
            try {
                check(ax.packageName?.toString() == context.packageName)
                axWindow = ax.windowId
                ax.getBoundsInScreen(axBounds)
                check(!axBounds.isEmpty)
            } finally { ax.recycle() }
            lateinit var result: SidebarPageSource
            fixture.onActivity { host ->
                val state = browser.state.value
                val native = checkNotNull(model.engine.captureExternalActivityOwner())
                check(state.surface == BrowserSurface.PAGE && state.tab?.id == original.tab.id &&
                    state.tab?.url == original.tab.url && state.selectedSpaceId == original.space &&
                    state.space?.websiteProfile == original.profile && state.workspace == null &&
                    native.session === original.session && model.engine.ownsExternalActivity(native))
                val sync = (host.application as YabApplication).sync
                val account = sync.accountRecords.value
                val entrance = checkNotNull(host.intent)
                val configuration = Configuration(host.resources.configuration)
                val actual = Rect(host.windowManager.currentWindowMetrics.bounds)
                val registered = browser.workspaceWindow.value
                val lifetime = browser.settingsPresentationLifetime.value
                val history = browser.historyPresentationLifetime.value
                val ownWindow = host.window
                val store = host.viewModelStore
                val decor = ownWindow.decorView
                val token = checkNotNull(root.windowToken)
                check(registered.registered && registered.geometry == BrowserWorkspaceWindow(900.0, 768.0) &&
                    actual.width() == 900 && actual.height() == 768 &&
                    root.rootView === decor && decor.windowToken === token)
                val origin = IntArray(2).also(decor::getLocationOnScreen)
                val beforePage = Rect(before.left.toInt() + origin[0], before.top.toInt() + origin[1],
                    before.right.toInt() + origin[0], before.bottom.toInt() + origin[1])
                val visible = sidebarPageViews(host).mapNotNull { view -> sidebarVisibleFrame(view)?.let { view to it } }
                val beforeNative = checkNotNull(visible.singleOrNull()?.takeIf { it.first.session === original.session }?.second)
                check(sidebarNear(beforeNative.left, beforePage.left) && sidebarNear(beforeNative.top, beforePage.top) &&
                    sidebarNear(beforeNative.right, beforePage.right) && sidebarNear(beforeNative.bottom, beforePage.bottom))
                val current: () -> Boolean = {
                    val now = browser.state.value
                    val identity = sync.accountRecords.value
                    !host.isDestroyed && !host.isFinishing && host.hasWindowFocus() &&
                        host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                        host.window === ownWindow && host.viewModelStore === store && host.intent === entrance &&
                        host.resources.configuration == configuration && host.windowManager.currentWindowMetrics.bounds == actual &&
                        identity.account == account.account && identity.device == account.device &&
                        identity.epoch == account.epoch && identity.removed == account.removed &&
                        !account.removed && sync.nativeOwnerCurrent(account) &&
                        !now.loading && !now.privateContentBlocked && now.surface == BrowserSurface.PAGE && now.find == null &&
                        now.surfaceEpoch == state.surfaceEpoch && now.selectedSpaceId == state.selectedSpaceId &&
                        now.space?.isPrivate == false && now.space?.websiteProfile == original.profile &&
                        now.space?.tabs == state.space?.tabs && now.tab == state.tab && now.workspace == null &&
                        !now.page.loading && browser.workspaceWindow.value == registered &&
                        browser.settingsPresentationLifetime.value == lifetime && lifetime.active &&
                        browser.historyPresentationLifetime.value == history && model.engine.ownsExternalActivity(native) &&
                        native.session === original.session && native.session.settings.contextId == original.profile.id &&
                        !native.session.settings.usePrivateMode &&
                        root.isAttachedToWindow && root.isShown && root.rootView === decor && root.windowToken === token &&
                        decor.isAttachedToWindow && decor.isShown && decor.windowToken === token
                }
                check(current())
                result = SidebarPageSource(root, original.session, axWindow, axBounds, beforePage, beforeNative, current)
            }
            return result
        }

        suspend fun hiddenSidebar(source: SidebarPageSource) {
            var projection: JSONObject? = null
            await("native Sidebar toggle withholds its body and accessibility") {
                val pages = compose.onAllNodesWithTag("browser.tablet.workspace.page").fetchSemanticsNodes()
                val frameCount = compose.onAllNodesWithTag(SIDEBAR_FRAME_TAG).fetchSemanticsNodes().size
                val bodyCount = compose.onAllNodesWithTag("browser.tablet.sidebar").fetchSemanticsNodes().size
                val rowCount = compose.onAllNodesWithTag("browser.tablet.sidebar.tab.$firstId").fetchSemanticsNodes().size
                val sidebarNewCount = compose.onAllNodesWithTag("browser.tablet.sidebar.new-tab").fetchSemanticsNodes().size
                val newTabs = compose.onAllNodesWithTag(NEW_TAB_TAG).fetchSemanticsNodes()
                if (pages.size != 1 || frameCount != 0 || bodyCount != 0 || rowCount != 0 || sidebarNewCount != 0 ||
                    newTabs.size != 1 || newTabs.single().config.contains(androidx.compose.ui.semantics.SemanticsProperties.Disabled)) return@await false
                val page = pages.single()
                val bounds = page.boundsInWindow
                if (kotlin.math.abs(bounds.width - 900f) > 1f || kotlin.math.abs(bounds.left) > 1f || bounds.height <= 0 ||
                    (page.root as? ViewRootForTest)?.view !== source.root || !page.layoutInfo.isAttached || !page.layoutInfo.isPlaced) return@await false
                var ready = false
                fixture.onActivity { host ->
                    check(source.current()) { "Original PAGE changed while qualifying hidden Sidebar" }
                    val origin = IntArray(2).also(host.window.decorView::getLocationOnScreen)
                    val pageBounds = Rect(bounds.left.toInt() + origin[0], bounds.top.toInt() + origin[1],
                        bounds.right.toInt() + origin[0], bounds.bottom.toInt() + origin[1])
                    val visible = sidebarPageViews(host).mapNotNull { view -> sidebarVisibleFrame(view)?.let { view to it } }
                    val frame = visible.singleOrNull()?.takeIf { it.first.session === source.session }?.second
                    ready = frame != null && sidebarNear(pageBounds.left - origin[0], 0) && pageBounds.width() == 900 &&
                        sidebarNear(frame.left, pageBounds.left) && sidebarNear(frame.top, pageBounds.top) &&
                        sidebarNear(frame.right, pageBounds.right) && sidebarNear(frame.bottom, pageBounds.bottom) && source.current()
                    if (ready) projection = JSONObject().put("phase", "HIDDEN_SIDEBAR").put("passed", true)
                        .put("pageCount", pages.size).put("visibleNativePaneCount", visible.size)
                        .put("beforePageBounds", sidebarBounds(source.beforePage)).put("beforeNativePaneBounds", sidebarBounds(source.beforeNative))
                        .put("pageBounds", sidebarBounds(pageBounds)).put("nativePaneBounds", sidebarBounds(checkNotNull(frame)))
                        .put("sidebarFrameSemanticCount", frameCount).put("sidebarBodySemanticCount", bodyCount)
                        .put("sidebarRowSemanticCount", rowCount).put("sidebarNewTabSemanticCount", sidebarNewCount)
                        .put("toolbarNewTabSemanticCount", newTabs.size).put("originalSourceCurrent", true)
                }
                ready
            }
            fixture.onActivity { check(source.current()) }
            check(sidebarAxWindow(source))
            // These Sidebar-only captions do not occur in the real fixture document or toolbar.
            // The unchanged adapter requires a complete owned AX tree before absence can pass.
            ui.requireLabelAbsent("Kept")
            ui.requireLabelAbsent("Today")
            ui.requireLabelAbsent("Pages you open appear here.")
            check(sidebarAxWindow(source))
            fixture.onActivity { check(source.current()) }
            compose.onNodeWithTag(NEW_TAB_TAG).assertIsDisplayed().assertIsEnabled()
            check(rows.length() < 24)
            rows.put(checkNotNull(projection).put("keptCaptionAxAbsent", true).put("todayCaptionAxAbsent", true)
                .put("emptyCaptionAxAbsent", true).put("sourceCurrentAfterAx", true))
        }

        fun allTabsReady(readiness: GalleryCardNativeTarget.Readiness): Boolean {
            val node = compose.onAllNodesWithTag(ALL_TABS_TAG).fetchSemanticsNodes().singleOrNull()
            var ready = false
            fixture.onActivity { host -> ready = readiness.observe(node?.let { GalleryCardNativeTarget.observeAllTabs(host, model, it) }) }
            return ready
        }

        suspend fun nativeGalleryCard(id: String, title: String) {
            lateinit var selected: BrowserTab
            fixture.onActivity {
                selected = checkNotNull(browser.state.value.tab)
                check(selected.id == id && selected.title == title)
            }
            val readiness = GalleryCardNativeTarget.Readiness()
            await("the original selected Gallery card has settled in its own native window") {
                val node = compose.onAllNodesWithTag("browser.gallery.card.$id").fetchSemanticsNodes().singleOrNull()
                var ready = false
                fixture.onActivity { host ->
                    ready = readiness.observe(node?.let { GalleryCardNativeTarget.observeCard(host, model, it, selected) })
                }
                ready
            }
            lateinit var target: GalleryCardNativeTarget
            fixture.onActivity { target = readiness.captureCard() }
            target.tap(ui)
            compose.waitForIdle()
        }

        suspend fun window(width: Int, height: Int, newerThan: Long? = null): Long {
            var generation = -1L
            await("actual Main full-window registration follows its OS configuration") {
                var ready = false
                fixture.onActivity { host ->
                    val state = browser.workspaceWindow.value
                    if (newerThan != null && state.configuration <= newerThan) return@onActivity
                    val actual = host.windowManager.currentWindowMetrics.bounds
                    ready = state.registered && actual.width() == width && actual.height() == height &&
                        host.resources.displayMetrics.density == 1f &&
                        state.geometry == BrowserWorkspaceWindow(width.toDouble(), height.toDouble())
                    if (ready) {
                        assertEquals(width > height && width >= 641, state.geometry!!.canSplit)
                        generation = state.configuration
                    }
                }
                ready
            }
            ui.requireOwnCurrent()
            return generation
        }

        suspend fun realField(before: BrowserState) {
            await("native toolbar New Tab opens one focused Field with the real OS IME") {
                val editors = compose.onAllNodesWithTag(INPUT_TAG).fetchSemanticsNodes()
                if (editors.size != 1) return@await false
                var ready = false
                fixture.onActivity { host ->
                    val state = browser.state.value
                    ready = state.surface == BrowserSurface.FIELD && state.fieldIsNewTab && !state.fieldIsPrivate &&
                        !state.fieldResting && ViewCompat.getRootWindowInsets(host.window.decorView)
                            ?.isVisible(WindowInsetsCompat.Type.ime()) == true
                    if (ready) {
                        assertEquals(before.space!!.tabs, state.space!!.tabs)
                        assertEquals(before.space!!.websiteProfile, state.space!!.websiteProfile)
                        assertEquals(before.surfaceEpoch + 1, state.surfaceEpoch)
                        assertEquals(before.workspace, state.workspace)
                    }
                }
                ready
            }
            compose.onNodeWithTag(INPUT_TAG).assertIsDisplayed().assertIsEnabled().assertIsFocused()
        }

        fun record(phase: Phase, requests: Int? = null) {
            check(rows.length() < 24)
            rows.put(JSONObject().put("phase", phase.name).put("passed", true).also {
                if (requests != null) it.put("articleRequestsCapped", requests.coerceIn(0, 99))
            })
        }
    }

    private suspend fun scene(case: Case, action: suspend (Scene) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36)
        check(shell("getprop ro.kernel.qemu").trim() == "1")
        val originalSize = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}"))
        val originalDensity = overrideValue(shell("wm density"), Regex("[0-9]{2,4}"))
        val rows = JSONArray()
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
        var completed = false
        var restored = false
        var primary: Throwable? = null
        try {
            ui.run {
                shell("wm density 160")
                shell("wm size 900x768")
                AppFlowTest.LocalPage().use { page ->
                    val fixture = NativeMainActivityFixture.launch(
                        Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                        NativeMainActivityFixture.Kind.APP_WORKSPACE)
                    var fixtureFailure: Throwable? = null
                    try { fixture.use {
                        lateinit var model: BrowserSessionViewModel
                        fixture.onActivity { host ->
                            model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                            val original = model
                            ui.bind(original.browser, original.engine) { original.browser.workspaceWindow.value.generation }
                        }
                        val scene = Scene(fixture, model, ui, page, "toolbar-original-${case.file}", rows)
                        var failure: Throwable? = null
                        try {
                            scene.loadInitialDocument()
                            action(scene)
                            scene.record(Phase.COMPLETE)
                        } catch (error: Throwable) { failure = error; throw error }
                        finally { preserve(case, "owned-browser-app_workspace.json", "owned-ui", failure) }
                    } } catch (error: Throwable) { fixtureFailure = error; throw error }
                    finally { preserve(case, "native-main-activity-app_workspace.json", "activity", fixtureFailure) }
                }
            }
            completed = true
        } catch (error: Throwable) { primary = error; throw error }
        finally {
            withContext(NonCancellable) {
                var cleanup: Throwable? = null
                fun attempt(block: () -> Unit) {
                    try { block() } catch (error: Throwable) {
                        if (cleanup == null) cleanup = error else cleanup!!.addSuppressed(error)
                    }
                }
                attempt { shell("wm size ${originalSize ?: "reset"}") }
                attempt { shell("wm density ${originalDensity ?: "reset"}") }
                attempt {
                    restored = overrideValue(shell("wm size"), Regex("[0-9]{2,5}x[0-9]{2,5}")) == originalSize &&
                        overrideValue(shell("wm density"), Regex("[0-9]{2,4}")) == originalDensity
                    check(restored)
                }
                attempt { receipt(case, completed, restored, rows) }
                cleanup?.let { if (primary != null) primary!!.addSuppressed(it) else throw it }
            }
        }
    }

    private fun savedClick(tag: String): () -> Boolean = dev.yab.browser.originalRenderedClick(compose.onNodeWithTag(tag).fetchSemanticsNode())

    /** Same bounded real-Gecko observation as the existing Main Sidebar projection case. */
    private fun sidebarPageViews(host: MainActivity): List<GeckoView> {
        val views = mutableListOf<GeckoView>()
        var visited = 0
        fun visit(view: View) {
            check(++visited <= 512)
            if (view is GeckoView && view.isAttachedToWindow && view.isShown && view.width > 0 && view.height > 0 && view.session != null) views += view
            if (view is ViewGroup) {
                val count = view.childCount
                check(count <= 128)
                repeat(count) { visit(view.getChildAt(it)) }
            }
        }
        visit(host.window.decorView)
        return views
    }

    private fun sidebarVisibleFrame(view: GeckoView): Rect? = Rect().takeIf {
        view.getGlobalVisibleRect(it) && it.width() > 0 && it.height() > 0
    }
    private fun sidebarAxWindow(source: SidebarPageSource): Boolean {
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return false
        return try {
            root.packageName?.toString() == context.packageName && root.windowId == source.axWindow &&
                Rect().also(root::getBoundsInScreen) == source.axBounds
        } finally { root.recycle() }
    }
    private fun sidebarNear(a: Int, b: Int): Boolean = kotlin.math.abs(a - b) <= 1
    private fun sidebarBounds(bounds: Rect) = JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom))

    private suspend fun await(label: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (true) {
            compose.waitForIdle()
            if (predicate()) return
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out: $label" }
            delay(40)
        }
    }

    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }

    private fun overrideValue(text: String, pattern: Regex): String? = text.lineSequence()
        .firstOrNull { it.startsWith("Override ") }?.substringAfter(':')?.trim()?.also { check(pattern.matches(it)) }

    private fun preserve(case: Case, original: String, suffix: String, primary: Throwable?) {
        try {
            val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
            val source = File(folder, original)
            check(source.isFile && source.length() <= 65_536)
            val bytes = source.inputStream().use { input ->
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
            File(folder, "app-tablet-toolbar-${case.file}-$suffix.json").writeBytes(bytes)
        } catch (error: Throwable) { if (primary != null) primary.addSuppressed(error) else throw error }
    }

    private fun receipt(case: Case, completed: Boolean, restored: Boolean, rows: JSONArray) {
        val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation").apply { check(isDirectory || mkdirs()) }
        val text = JSONObject().put("schema", 1).put("case", case.name).put("completed", completed && restored)
            .put("wmOverridesRestored", restored).put("samples", rows).put("positiveInputsNative", true)
            .put("localConfigurationInjected", false).put("forcedResume", false).put("providerAccepted", false)
            .put("physicalDeviceVerified", false).put("frameParityVerified", false).put("wholeTabletAccepted", false).toString(2)
        check(text.toByteArray().size <= 16_384)
        File(folder, "app-tablet-toolbar-${case.file}.json").writeText(text)
    }

    private enum class Case(val file: String) { COMMANDS("commands"), GALLERY_AND_FIELD("gallery-field"), GALLERY_RECREATION("gallery-recreation") }
    private enum class Phase { ORIGINAL_REAL_PAGE, COMPACT_REFUSED, ORIGINAL_CALLBACKS_REFUSED, FRESH_RELOAD,
        ONE_CARD_GALLERY, FRESH_NEW_TAB_FIELD, BLANK_GALLERY, COMPACT_BLANK_GALLERY, OLD_BLANK_REFUSED, FRESH_BLANK_RETURN, COMPLETE }
    private companion object {
        const val TOOLBAR_TAG = "browser.tablet.toolbar"
        const val RELOAD_TAG = "browser.tablet.reload"
        const val NEW_TAB_TAG = "browser.tablet.new-tab"
        const val ALL_TABS_TAG = "browser.tablet.all-tabs"
        const val SIDEBAR_FRAME_TAG = "browser.tablet.workspace.sidebar"
        const val INPUT_TAG = "browser.field.input"
    }
}

package dev.yab.android

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.Lifecycle
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
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView

/** The same old-API fixture runs against the original products and the shortcut products. */
class BrowserHardwareKeysDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 300_000)
    fun actualMainHardwareKeysOwnFieldSplitUndoPagingFindAndCoveredRefusal(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36 && shell("getprop ro.kernel.qemu").trim() == "1")
        val file = File(context.filesDir, "browser.json")
        val saved = file.takeIf { it.isFile }?.readBytes()
        val size = overrideValue(shell("wm size"))
        val density = overrideValue(shell("wm density"))
        val phases = JSONArray()
        val undoSamples = JSONArray()
        val pagingSamples = JSONArray()
        val firstFieldSamples = JSONArray()
        var pagingInputAt: Long? = null
        var closeInputAt: Long? = null
        var completed = false
        var restored = false
        var firstCtrlTOpened = false
        var chords = 0
        var textEntries = 0
        var primary: Throwable? = null
        fun phase(value: String) { check(phases.length() < 12); phases.put(value) }
        try {
            shell("wm density 160"); shell("wm size 900x768")
            AppFlowTest.LocalPage().use { page ->
                val first = BrowserTab("keys-first", page.url + "?first", "Keys first", TabPlace.KEPT, createdAt = 1)
                val last = BrowserTab("keys-last", page.url + "?last", "Keys last", TabPlace.TODAY, createdAt = 2)
                val middle = BrowserTab("keys-middle", page.url + "?middle", "Keys middle", TabPlace.KEPT, createdAt = 3)
                val tabs = listOf(first, last, middle)
                val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = tabs, currentTabId = first.id)
                FileBrowserRepository(file).save(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                    settings = BrowserSettings(welcomed = true)))
                NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                    NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                    lateinit var model: BrowserSessionViewModel
                    lateinit var originalActivity: MainActivity
                    fixture.onActivity { host ->
                        originalActivity = host
                        model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                    }
                    val browser = model.browser
                    val sync = (context.applicationContext as YabApplication).sync
                    val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
                    fixture.onActivity { ui.bind(browser, model.engine) { browser.workspaceWindow.value.generation } }
                    ui.run {
                        check(bounded {
                            var ready = false
                            fixture.onActivity { host -> ready = !browser.state.value.loading && host === originalActivity &&
                                host.windowManager.currentWindowMetrics.bounds.let { it.width() == 900 && it.height() == 768 } &&
                                browser.workspaceWindow.value.let { it.registered && it.geometry == BrowserWorkspaceWindow(900.0, 768.0) } }
                            ready
                        }) { "The original Main did not load its own registered tablet window" }
                        fixture.onActivity {
                            val state = browser.state.value
                            check(state.tab?.id == first.id && state.tab?.url == first.url && state.space?.websiteProfile == space.websiteProfile &&
                                !state.privateContentBlocked && model.engine.hasLiveSession(first.id))
                            model.engine.navigate(checkNotNull(state.tab), first.url, space.websiteProfile)
                        }
                        fun shown(tag: String) = compose.onAllNodesWithTag(tag).fetchSemanticsNodes().size == 1
                        fun pageReady(id: String): Boolean {
                            var ready = false
                            fixture.onActivity { host ->
                                val state = browser.state.value
                                ready = state.surface == BrowserSurface.PAGE && state.tab?.id == id && !state.page.loading &&
                                    state.page.title == "Android flow article" && state.space?.websiteProfile == space.websiteProfile &&
                                    ViewCompat.getRootWindowInsets(host.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime()) == false
                            }
                            return ready && !shown(INPUT) && !shown("browser.field.popup")
                        }
                        fun fieldReady(newTab: Boolean): Boolean {
                            val nodes = compose.onAllNodesWithTag(INPUT).fetchSemanticsNodes()
                            val node = nodes.singleOrNull() ?: return false
                            val root = (node.root as? ViewRootForTest)?.view ?: return false
                            var ready = false
                            fixture.onActivity { host ->
                                val state = browser.state.value
                                val insets = ViewCompat.getRootWindowInsets(host.window.decorView)
                                ready = state.surface == BrowserSurface.FIELD && state.fieldIsNewTab == newTab &&
                                    !state.fieldIsPrivate && !state.fieldResting && state.tab?.id == first.id &&
                                    state.space?.websiteProfile == space.websiteProfile && node.layoutInfo.isAttached && node.layoutInfo.isPlaced &&
                                    node.config.getOrNull(SemanticsProperties.Focused) == true && !node.config.contains(SemanticsProperties.Disabled) &&
                                    root.isAttachedToWindow && root.isShown && root.rootView === host.window.decorView && root.windowToken != null &&
                                    root.windowToken === host.window.decorView.windowToken && insets?.isVisible(WindowInsetsCompat.Type.ime()) == true &&
                                    insets.getInsets(WindowInsetsCompat.Type.ime()).bottom > 0
                            }
                            return ready
                        }
                        fun focusNative() = fixture.onActivity { host ->
                            val state = browser.state.value
                            val tab = checkNotNull(state.tab)
                            check(state.surface == BrowserSurface.PAGE && !state.privateContentBlocked && model.engine.hasLiveSession(tab.id))
                            val native = checkNotNull(model.engine.captureExternalActivityOwner())
                            check(native.tab == tab.id && model.engine.ownsExternalActivity(native) &&
                                native.session.settings.contextId == space.websiteProfile.id && !native.session.settings.usePrivateMode)
                            val view = nativeViews(host.window.decorView).single { it.session === native.session && it.isShown && it.isAttachedToWindow }
                            check(view.requestFocus() && view.hasFocus()) { "The original native page did not take keyboard focus" }
                        }
                        // Diagnostic observations never report that Main admitted a command.
                        fun undoSample(point: String) {
                            check(point in setOf("CLOSE_BEFORE_DOWN", "CLOSE_AFTER_CHORD", "REOPEN_BEFORE_DOWN", "REOPEN_AFTER_CHORD"))
                            check(undoSamples.length() < 4)
                            fixture.onActivity {
                                val at = SystemClock.elapsedRealtime()
                                if (point == "CLOSE_BEFORE_DOWN") { check(closeInputAt == null); closeInputAt = at }
                                val relative = at - checkNotNull(closeInputAt)
                                check(relative in 0L..300_000L)
                                val current = browser.state.value
                                val tab = when (current.tab?.id) {
                                    first.id -> "FIRST"
                                    middle.id -> "MIDDLE"
                                    last.id -> "LAST"
                                    else -> "OTHER"
                                }
                                undoSamples.put(JSONObject().put("point", point).put("relativeMs", relative)
                                    .put("currentTab", tab).put("closedFirstPresent", current.spaces.any { owner -> owner.tabs.any { it.id == first.id } })
                                    .put("undoAvailable", current.undoAvailable).put("surface", current.surface.name)
                                    .put("loading", current.page.loading).put("titleMatches", current.page.title == "Android flow article"))
                            }
                        }
                        // These fixed observations do not inspect or alter Main's key registration.
                        // Never call session(): observation must not create or navigate a cold page.
                        fun pagingSample(point: String) {
                            check(point in setOf("CTRL9_BEFORE_CHORD", "CTRL9_AFTER_CHORD", "CTRL9_AFTER_WAIT"))
                            check(pagingSamples.length() < 3)
                            val row = JSONObject().put("point", point).put("observed", false)
                            try {
                                val fields = compose.onAllNodesWithTag(INPUT).fetchSemanticsNodes().size
                                val popups = compose.onAllNodesWithTag("browser.field.popup").fetchSemanticsNodes().size
                                fixture.onActivity { host ->
                                    val at = SystemClock.elapsedRealtime()
                                    if (pagingInputAt == null) pagingInputAt = at
                                    val relative = at - checkNotNull(pagingInputAt)
                                    check(relative in 0L..300_000L)
                                    fun tabName(id: String?) = when (id) {
                                        first.id -> "FIRST"; middle.id -> "MIDDLE"; last.id -> "LAST"; else -> "OTHER"
                                    }
                                    val current = browser.state.value
                                    val target = current.pageStates[last.id]
                                    val native = model.engine.captureExternalActivityOwner()
                                    val ime = ViewCompat.getRootWindowInsets(host.window.decorView)
                                        ?.isVisible(WindowInsetsCompat.Type.ime())
                                    val visible = nativeViews(host.window.decorView).filter { view ->
                                        val bounds = Rect()
                                        view.isAttachedToWindow && view.isShown && view.getGlobalVisibleRect(bounds) && !bounds.isEmpty
                                    }
                                    // Stored registration facts only; these reads never call a host or key action.
                                    val keyRegistration = runCatching {
                                        fun stored(type: Class<*>, target: Any, name: String): Any? =
                                            type.getDeclaredField(name).let { field -> field.isAccessible = true; field.get(target) }
                                        val owner = stored(MainActivity::class.java, host, "hardwareKeyOwner")
                                        val action = stored(MainActivity::class.java, host, "hardwareKeyAction")
                                        val down = stored(MainActivity::class.java, host, "hardwareKeysDown") as Set<*>
                                        val interrupted = stored(MainActivity::class.java, host, "interruptedHardwareKeys") as Set<*>
                                        check(owner == null || owner is BrowserHardwareKeyHost)
                                        val retired = owner?.let { stored(BrowserHardwareKeyHost::class.java, it, "retired") as Boolean }
                                        JSONObject().put("mainKeyOwnerPresent", owner != null).put("mainKeyActionPresent", action != null)
                                            .put("mainKeyOwnerRetired", retired ?: JSONObject.NULL)
                                            .put("ctrl9DownTracked", down.contains(KeyEvent.KEYCODE_9))
                                            .put("ctrl9InterruptedTracked", interrupted.contains(KeyEvent.KEYCODE_9))
                                    }.getOrNull()
                                    row.put("relativeMs", relative).put("originalActivity", host === originalActivity)
                                        .put("surface", current.surface.name).put("currentTab", tabName(current.tab?.id))
                                        .put("columnOrderMatchesFixture", current.pagingOrder().map { it.id } == listOf(first.id, middle.id, last.id))
                                        .put("selectedProfileMatches", current.space?.websiteProfile == space.websiteProfile)
                                        .put("lastUniqueInOriginalSpace", current.space?.tabs?.count { it.id == last.id && !it.isPrivate } == 1 &&
                                            current.spaces.sumOf { owner -> owner.tabs.count { it.id == last.id } } == 1)
                                        .put("lastLiveSession", model.engine.hasLiveSession(last.id))
                                        .put("lastPagePresent", target != null).put("lastPageLoading", target?.loading ?: JSONObject.NULL)
                                        .put("lastPageUrlMatches", target?.url == last.url)
                                        .put("lastPageTitleMatches", target?.title == "Android flow article")
                                        .put("lastPageHasError", target?.error != null)
                                        .put("selectedPageLoading", current.page.loading)
                                        .put("selectedPageTitleMatches", current.page.title == "Android flow article")
                                        .put("nativeOwnerPresent", native != null).put("nativeOwnerTab", tabName(native?.tab))
                                        .put("nativeOwnerCurrent", native?.let(model.engine::ownsExternalActivity) == true)
                                        .put("nativeOwnerInteractive", native?.let { model.engine.ownsInteractive(it.session) } ?: JSONObject.NULL)
                                        .put("interactiveSelectedMatches", current.tab?.id?.let { model.engine.interactiveSelected == it } ?: JSONObject.NULL)
                                        .put("mainKeyOwnerPresent", keyRegistration?.opt("mainKeyOwnerPresent") ?: JSONObject.NULL)
                                        .put("mainKeyActionPresent", keyRegistration?.opt("mainKeyActionPresent") ?: JSONObject.NULL)
                                        .put("mainKeyOwnerRetired", keyRegistration?.opt("mainKeyOwnerRetired") ?: JSONObject.NULL)
                                        .put("ctrl9DownTracked", keyRegistration?.opt("ctrl9DownTracked") ?: JSONObject.NULL)
                                        .put("ctrl9InterruptedTracked", keyRegistration?.opt("ctrl9InterruptedTracked") ?: JSONObject.NULL)
                                        .put("nativeProfileMatches", native?.session?.settings?.contextId == space.websiteProfile.id)
                                        .put("nativePrivate", native?.session?.settings?.usePrivateMode ?: JSONObject.NULL)
                                        .put("visibleLastViews", visible.count { view -> view.session?.let(model.engine::tabId) == last.id }.coerceAtMost(8))
                                        .put("ime", when (ime) { true -> "VISIBLE"; false -> "HIDDEN"; null -> "UNKNOWN" })
                                        .put("fieldInputs", fields.coerceAtMost(4)).put("fieldPopups", popups.coerceAtMost(4))
                                        .put("lastFixtureRequestSeen", page.requests.any { it.startsWith("GET /article?last ") })
                                        .put("observed", true)
                                }
                            } catch (_: Throwable) {
                                // Keep the original test failure and expose only a finite diagnostic refusal.
                                row.put("observationFailure", "OWNED_SAMPLE_UNAVAILABLE")
                            }
                            pagingSamples.put(row)
                        }
                        // Fixed first-Field observations are read-only and never qualify input delivery.
                        data class FirstFieldOrigin(val activity: MainActivity, val intent: Intent,
                            val window: android.view.Window, val decor: View, val token: android.os.IBinder?,
                            val configuration: Configuration, val bounds: Rect, val registered: WorkspaceWindowState,
                            val account: dev.yab.sync.AccountRecordsSnapshot, val lifetime: SettingsPresentationLifetime,
                            val state: BrowserState, val inputId: Int?, val inputRoot: View?)
                        var firstFieldOrigin: FirstFieldOrigin? = null
                        fun firstFieldSample(point: String) {
                            check(point in setOf("FIELD_BEFORE_TYPE", "FIELD_AFTER_TYPE", "FIELD_AFTER_WAIT"))
                            check(firstFieldSamples.length() < 3)
                            var row = JSONObject().put("point", point).put("observed", false)
                            try {
                                val nodes = compose.onAllNodesWithTag(INPUT).fetchSemanticsNodes()
                                val node = nodes.singleOrNull()
                                val root = (node?.root as? ViewRootForTest)?.view
                                val semanticText = node?.config?.getOrNull(SemanticsProperties.EditableText)?.text
                                fixture.onActivity { host ->
                                    val current = browser.state.value
                                    val window = host.window
                                    val decor = window.decorView
                                    if (point == "FIELD_BEFORE_TYPE") {
                                        check(firstFieldOrigin == null)
                                        firstFieldOrigin = FirstFieldOrigin(host, host.intent, window, decor, decor.windowToken,
                                            Configuration(host.resources.configuration), Rect(host.windowManager.currentWindowMetrics.bounds),
                                            browser.workspaceWindow.value, sync.accountRecords.value, browser.settingsPresentationLifetime.value,
                                            current, node?.id, root)
                                    }
                                    val origin = checkNotNull(firstFieldOrigin)
                                    val native = model.engine.captureExternalActivityOwner()
                                    val insets = ViewCompat.getRootWindowInsets(decor)
                                    fun count(value: Int): Any = if (value in 0..256) value else JSONObject.NULL
                                    val registration = run {
                                        fun stored(type: Class<*>, target: Any, name: String): Any? =
                                            type.getDeclaredField(name).let { field -> field.isAccessible = true; field.get(target) }
                                        val owner = stored(MainActivity::class.java, host, "hardwareKeyOwner")
                                        val action = stored(MainActivity::class.java, host, "hardwareKeyAction")
                                        val down = stored(MainActivity::class.java, host, "hardwareKeysDown") as Set<*>
                                        val interrupted = stored(MainActivity::class.java, host, "interruptedHardwareKeys") as Set<*>
                                        check(owner == null || owner is BrowserHardwareKeyHost)
                                        val retired = owner?.let { stored(BrowserHardwareKeyHost::class.java, it, "retired") as Boolean }
                                        JSONObject().put("mainKeyOwnerPresent", owner != null).put("mainKeyActionPresent", action != null)
                                            .put("mainKeyOwnerRetired", retired ?: JSONObject.NULL)
                                            .put("ctrl9DownTracked", down.contains(KeyEvent.KEYCODE_9))
                                            .put("ctrl9InterruptedTracked", interrupted.contains(KeyEvent.KEYCODE_9))
                                    }
                                    row.put("inputNodes", count(nodes.size))
                                        .put("inputFocused", node?.config?.getOrNull(SemanticsProperties.Focused) ?: JSONObject.NULL)
                                        .put("inputEnabled", node?.let { !it.config.contains(SemanticsProperties.Disabled) } ?: JSONObject.NULL)
                                        .put("inputAttached", node?.layoutInfo?.isAttached ?: JSONObject.NULL)
                                        .put("inputPlaced", node?.layoutInfo?.isPlaced ?: JSONObject.NULL)
                                        .put("sameInputNode", node?.let { origin.inputId != null && it.id == origin.inputId } ?: JSONObject.NULL)
                                        .put("sameInputRoot", root?.let { origin.inputRoot != null && it === origin.inputRoot } ?: JSONObject.NULL)
                                        .put("inputRootAttached", root?.isAttachedToWindow ?: JSONObject.NULL)
                                        .put("inputRootShown", root?.isShown ?: JSONObject.NULL)
                                        .put("inputRootHasFocus", root?.hasFocus() ?: JSONObject.NULL)
                                        .put("inputRootIsOriginalDecor", root?.let { it.rootView === origin.decor } ?: JSONObject.NULL)
                                        .put("inputRootTokenMatches", root?.let { origin.token != null && it.windowToken === origin.token } ?: JSONObject.NULL)
                                        .put("originalActivity", host === originalActivity && host === origin.activity)
                                        .put("activityResumed", host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
                                        .put("activityWindowFocused", host.hasWindowFocus())
                                        .put("activityAlive", !host.isFinishing && !host.isDestroyed)
                                        .put("sameIntent", host.intent === origin.intent).put("sameWindow", window === origin.window)
                                        .put("sameDecor", decor === origin.decor)
                                        .put("sameWindowToken", origin.token != null && decor.windowToken === origin.token)
                                        .put("sameConfiguration", host.resources.configuration == origin.configuration)
                                        .put("sameWindowBounds", host.windowManager.currentWindowMetrics.bounds == origin.bounds)
                                        .put("sameRegisteredWindow", browser.workspaceWindow.value == origin.registered)
                                        .put("originalAccountCurrent", sync.nativeOwnerCurrent(origin.account))
                                        .put("sameForegroundLifetime", browser.settingsPresentationLifetime.value == origin.lifetime && origin.lifetime.active)
                                        .put("fieldSurface", current.surface == BrowserSurface.FIELD)
                                        .put("fieldNewTab", current.fieldIsNewTab).put("fieldPrivate", current.fieldIsPrivate)
                                        .put("fieldResting", current.fieldResting)
                                        .put("sameFieldOwner", current.surface == origin.state.surface && current.surfaceEpoch == origin.state.surfaceEpoch &&
                                            current.selectedSpaceId == origin.state.selectedSpaceId && current.tab?.id == origin.state.tab?.id &&
                                            current.space?.websiteProfile == origin.state.space?.websiteProfile &&
                                            current.fieldIsNewTab == origin.state.fieldIsNewTab && current.fieldIsPrivate == origin.state.fieldIsPrivate)
                                        .put("modelTextLength", count(current.fieldText.length))
                                        .put("modelTextMatches", current.fieldText == "shortcut query")
                                        .put("semanticTextLength", semanticText?.let { count(it.length) } ?: JSONObject.NULL)
                                        .put("semanticTextMatches", semanticText?.let { it == "shortcut query" } ?: JSONObject.NULL)
                                        .put("imeVisible", insets?.isVisible(WindowInsetsCompat.Type.ime()) ?: JSONObject.NULL)
                                        .put("imeInsetPositive", insets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom?.let { it > 0 } ?: JSONObject.NULL)
                                        .put("focusedNativeViews", count(nativeViews(decor).count { it.hasFocus() }))
                                        .put("nativeOwnerPresent", native != null)
                                        .put("nativeOwnerCurrent", native?.let(model.engine::ownsExternalActivity) ?: JSONObject.NULL)
                                        .put("nativeOwnerInteractive", native?.let { model.engine.ownsInteractive(it.session) } ?: JSONObject.NULL)
                                        .put("interactiveSelectedMatches", current.tab?.id?.let { model.engine.interactiveSelected == it } ?: JSONObject.NULL)
                                        .put("mainKeyOwnerPresent", registration.opt("mainKeyOwnerPresent") ?: JSONObject.NULL)
                                        .put("mainKeyActionPresent", registration.opt("mainKeyActionPresent") ?: JSONObject.NULL)
                                        .put("mainKeyOwnerRetired", registration.opt("mainKeyOwnerRetired") ?: JSONObject.NULL)
                                        .put("ctrl9DownTracked", registration.opt("ctrl9DownTracked") ?: JSONObject.NULL)
                                        .put("ctrl9InterruptedTracked", registration.opt("ctrl9InterruptedTracked") ?: JSONObject.NULL)
                                        .put("observed", true)
                                }
                            } catch (_: Throwable) {
                                row = JSONObject().put("point", point).put("observed", false)
                                    .put("observationFailure", "OWNED_SAMPLE_UNAVAILABLE")
                            }
                            firstFieldSamples.put(row)
                        }
                        suspend fun chord(code: Int, shift: Boolean = false, undoPoint: String? = null) {
                            compose.waitForIdle()
                            lateinit var ownHost: () -> Boolean
                            lateinit var ownSource: () -> Boolean
                            fixture.onActivity { host ->
                                val state = browser.state.value
                                val account = sync.accountRecords.value
                                val configuration = Configuration(host.resources.configuration)
                                val intent = host.intent
                                val window = host.window
                                val decor = window.decorView
                                val token = decor.windowToken
                                val bounds = Rect(host.windowManager.currentWindowMetrics.bounds)
                                val registered = browser.workspaceWindow.value
                                val lifetime = browser.settingsPresentationLifetime.value
                                val native = model.engine.captureExternalActivityOwner()
                                val source: () -> Boolean = {
                                    val now = browser.state.value
                                    now.surface == state.surface && now.surfaceEpoch == state.surfaceEpoch && now.selectedSpaceId == state.selectedSpaceId &&
                                        now.tab?.id == state.tab?.id && now.tab?.url == state.tab?.url && now.space?.websiteProfile == space.websiteProfile &&
                                        now.fieldIsNewTab == state.fieldIsNewTab && !now.privateContentBlocked &&
                                        (state.surface == BrowserSurface.SETTINGS || native != null && model.engine.ownsExternalActivity(native))
                                }
                                val current: () -> Boolean = {
                                    host === originalActivity && !host.isFinishing && !host.isDestroyed && host.hasWindowFocus() &&
                                        host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && host.intent === intent && host.window === window &&
                                        window.decorView === decor && token != null && decor.windowToken === token && decor.isAttachedToWindow && decor.isShown &&
                                        host.resources.configuration == configuration && host.windowManager.currentWindowMetrics.bounds == bounds &&
                                        browser.workspaceWindow.value == registered && browser.settingsPresentationLifetime.value == lifetime && lifetime.active &&
                                        sync.nativeOwnerCurrent(account) && model === ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                                }
                                check(current() && source()) { "The original key source is no longer current" }
                                ownHost = current; ownSource = source
                            }
                            val downAt = SystemClock.uptimeMillis()
                            val modifiers = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON or
                                if (shift) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0
                            fun send(action: Int, keyCode: Int, originalSource: Boolean) {
                                if (undoPoint != null && action == KeyEvent.ACTION_DOWN && keyCode == code) undoSample(undoPoint + "_BEFORE_DOWN")
                                fixture.onActivity { check(ownHost() && (!originalSource || ownSource())) { "The original key window changed before native input" } }
                                instrumentation.sendKeySync(KeyEvent(downAt, SystemClock.uptimeMillis(), action, keyCode, 0, modifiers,
                                    KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD))
                            }
                            send(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_CTRL_LEFT, true)
                            send(KeyEvent.ACTION_DOWN, code, true)
                            // The command's DOWN may legitimately replace FIELD/tab/epoch. UP
                            // releases only that original window, never a newly acquired target.
                            send(KeyEvent.ACTION_UP, code, false)
                            send(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_CTRL_LEFT, false)
                            check(chords < 24); chords++
                            compose.waitForIdle()
                            if (undoPoint != null) undoSample(undoPoint + "_AFTER_CHORD")
                        }
                        suspend fun type(words: String, tag: String) {
                            val original = compose.onNodeWithTag(tag).fetchSemanticsNode()
                            fixture.onActivity {
                                check(original.layoutInfo.isAttached && original.layoutInfo.isPlaced &&
                                    original.config.getOrNull(SemanticsProperties.Focused) == true && !original.config.contains(SemanticsProperties.Disabled))
                            }
                            ui.requireOwnCurrent()
                            instrumentation.sendStringSync(words)
                            check(textEntries < 3); textEntries++
                        }
                        check(bounded { pageReady(first.id) }) { "The original HTTP page did not become ready" }
                        focusNative(); phase("ORIGINAL_NATIVE_PAGE")
                        chord(KeyEvent.KEYCODE_T)
                        firstCtrlTOpened = bounded { fieldReady(true) }
                        assertTrue("HARDWARE_CTRL_T_OPENS_ORIGINAL_NEW_TAB_FIELD", firstCtrlTOpened)
                        fixture.onActivity { assertEquals(tabs.map(BrowserTab::id), browser.state.value.space!!.tabs.map(BrowserTab::id)) }
                        firstFieldSample("FIELD_BEFORE_TYPE")
                        type("shortcut query", INPUT)
                        firstFieldSample("FIELD_AFTER_TYPE")
                        try {
                            assertTrue(bounded { browser.state.value.fieldText == "shortcut query" })
                        } finally { firstFieldSample("FIELD_AFTER_WAIT") }
                        phase("NEW_TAB_FIELD_REAL_TYPING")
                        chord(KeyEvent.KEYCODE_W)
                        assertTrue(bounded { pageReady(first.id) }); phase("FIELD_ONLY_CLOSE")
                        focusNative(); chord(KeyEvent.KEYCODE_L)
                        assertTrue(bounded { fieldReady(false) })
                        fixture.onActivity { assertEquals(first.url, browser.state.value.fieldText) }
                        chord(KeyEvent.KEYCODE_W); assertTrue(bounded { pageReady(first.id) }); phase("OPEN_LOCATION")
                        // The shown sidebar leaves only 564 pt at this exact 900 pt window.
                        // Hide it through its real control before requiring two drawn native panes.
                        ui.click("Sidebar")
                        assertTrue("HARDWARE_DRAWN_SPLIT_REQUIRES_OWN_FULL_WIDTH_PAGE", bounded {
                            val frame = compose.onAllNodesWithTag("browser.tablet.workspace.page").fetchSemanticsNodes().singleOrNull()
                            val toggle = compose.onAllNodesWithTag("browser.tablet.sidebar.toggle").fetchSemanticsNodes().singleOrNull()
                            val root = (frame?.root as? ViewRootForTest)?.view
                            var ownWindow = false
                            fixture.onActivity { host ->
                                ownWindow = host === originalActivity && root != null && root.isAttachedToWindow && root.isShown &&
                                    root.windowToken === host.window.decorView.windowToken &&
                                    host.windowManager.currentWindowMetrics.bounds.let { it.width() == 900 && it.height() == 768 } &&
                                    browser.workspaceWindow.value.let { it.registered && it.geometry == BrowserWorkspaceWindow(900.0, 768.0) }
                            }
                            ownWindow && frame != null && kotlin.math.abs(frame.boundsInWindow.width - 900f) <= 1f &&
                                frame.boundsInWindow.height > 0f &&
                                toggle?.config?.getOrNull(SemanticsProperties.StateDescription)?.equals("hidden", ignoreCase = true) == true
                        })
                        phase("SIDEBAR_HIDDEN_FOR_DRAWN_SPLIT")
                        fixture.onActivity { browser.openBeside(middle.id); browser.selectTab(first.id) }
                        assertTrue(bounded {
                            var pairReady = false
                            fixture.onActivity { host ->
                                val visible = nativeViews(host.window.decorView).filter { view ->
                                    val bounds = Rect()
                                    view.isAttachedToWindow && view.isShown && view.getGlobalVisibleRect(bounds) && !bounds.isEmpty
                                }
                                val current = browser.state.value
                                val companionPage = current.pageStates[middle.id]
                                val firstLive = model.engine.hasLiveSession(first.id)
                                val middleLive = model.engine.hasLiveSession(middle.id)
                                pairReady = current.workspace?.focused == first.id && firstLive && middleLive &&
                                    companionPage?.let { !it.loading && it.url == middle.url && it.title == "Android flow article" && it.error == null } == true &&
                                    visible.size == 2 && visible.count { it.session?.let(model.engine::tabId) == first.id } == 1 &&
                                    visible.count { it.session?.let(model.engine::tabId) == middle.id } == 1 &&
                                    visible.all { it.session?.settings?.contextId == space.websiteProfile.id && it.session?.settings?.usePrivateMode == false }
                            }
                            pageReady(first.id) && pairReady
                        })
                        lateinit var companionSession: GeckoSession
                        fixture.onActivity { companionSession = model.engine.session(middle, space.websiteProfile) }
                        focusNative(); chord(KeyEvent.KEYCODE_W, undoPoint = "CLOSE")
                        assertTrue(bounded { pageReady(middle.id) && browser.state.value.workspace == null })
                        fixture.onActivity { host ->
                            assertSame(originalActivity, host); assertFalse(host.isFinishing)
                            assertEquals(listOf(last.id, middle.id), browser.state.value.space!!.tabs.map(BrowserTab::id))
                            val current = checkNotNull(model.engine.captureExternalActivityOwner())
                            assertEquals(middle.id, current.tab); assertTrue(model.engine.ownsExternalActivity(current))
                            assertEquals(space.websiteProfile.id, current.session.settings.contextId)
                            assertFalse(current.session.settings.usePrivateMode); assertSame(companionSession, current.session)
                        }
                        phase("FOCUSED_SPLIT_TAB_CLOSED_WINDOW_KEPT")
                        focusNative(); chord(KeyEvent.KEYCODE_T, shift = true, undoPoint = "REOPEN")
                        assertTrue(bounded { pageReady(first.id) && !browser.state.value.undoAvailable })
                        fixture.onActivity { assertEquals(tabs.map(BrowserTab::id), browser.state.value.space!!.tabs.map(BrowserTab::id)) }
                        phase("ORIGINAL_TAB_REOPENED")
                        focusNative(); chord(KeyEvent.KEYCODE_TAB)
                        assertTrue(bounded { pageReady(middle.id) })
                        pagingSample("CTRL9_BEFORE_CHORD")
                        focusNative(); chord(KeyEvent.KEYCODE_9)
                        pagingSample("CTRL9_AFTER_CHORD")
                        try {
                            assertTrue(bounded { pageReady(last.id) })
                        } finally { pagingSample("CTRL9_AFTER_WAIT") }
                        focusNative(); chord(KeyEvent.KEYCODE_TAB)
                        assertTrue(bounded { pageReady(last.id) })
                        focusNative(); chord(KeyEvent.KEYCODE_1)
                        assertTrue(bounded { pageReady(first.id) }); phase("COLUMN_PAGING_AND_DIGITS")
                        focusNative(); chord(KeyEvent.KEYCODE_F)
                        assertTrue(bounded { compose.onAllNodesWithTag(FIND).fetchSemanticsNodes().singleOrNull()?.config?.getOrNull(SemanticsProperties.Focused) == true })
                        type("parcel", FIND)
                        assertTrue(bounded { browser.state.value.find?.query?.text == "parcel" })
                        focusNative()
                        assertTrue(bounded { compose.onNodeWithTag(FIND).fetchSemanticsNode().config.getOrNull(SemanticsProperties.Focused) != true })
                        chord(KeyEvent.KEYCODE_F)
                        assertTrue(bounded { compose.onAllNodesWithTag(FIND).fetchSemanticsNodes().singleOrNull()?.config?.getOrNull(SemanticsProperties.Focused) == true })
                        assertEquals("parcel", browser.state.value.find?.query?.text); phase("FIND_REFOCUSES_SAME_QUERY")
                        fixture.onActivity { browser.dismissFind(); browser.show(BrowserSurface.SETTINGS) }
                        assertTrue(bounded { browser.state.value.surface == BrowserSurface.SETTINGS && shown("settings.sheet") })
                        val covered = browser.state.value
                        chord(KeyEvent.KEYCODE_T); chord(KeyEvent.KEYCODE_W)
                        fixture.onActivity { host ->
                            assertSame(originalActivity, host); assertFalse(host.isFinishing)
                            val state = browser.state.value
                            assertEquals(covered.surface, state.surface); assertEquals(covered.surfaceEpoch, state.surfaceEpoch)
                            assertEquals(covered.tab?.id, state.tab?.id); assertEquals(covered.tab?.url, state.tab?.url)
                            assertEquals(tabs.map(BrowserTab::id), state.space!!.tabs.map(BrowserTab::id))
                        }
                        assertFalse(shown(INPUT)); phase("SETTINGS_KEYS_REFUSED")
                    }
                }
            }
            completed = true
        } catch (error: Throwable) { primary = error; throw error }
        finally {
            var cleanup: Throwable? = null
            fun attempt(block: () -> Unit) { try { block() } catch (error: Throwable) {
                if (cleanup == null) cleanup = error else cleanup!!.addSuppressed(error)
            } }
            attempt { shell("wm size ${size ?: "reset"}"); shell("wm density ${density ?: "reset"}") }
            attempt { if (saved == null) check(!file.exists() || file.delete()) else file.writeBytes(saved)
                restored = if (saved == null) !file.exists() else file.readBytes().contentEquals(saved); check(restored) }
            attempt {
                val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
                check(folder.isDirectory || folder.mkdirs())
                File(folder, "browser-hardware-keys.json").writeText(JSONObject().put("schema", 1).put("completed", completed)
                    .put("ownBrowserFileRestored", restored).put("firstCtrlTOpened", firstCtrlTOpened).put("phases", phases)
                    .put("nativeChords", chords).put("nativeTextEntries", textEntries)
                    .put("keyAdmissionKnown", false).put("undoSamples", undoSamples).put("pagingSamples", pagingSamples)
                    .put("firstFieldSamples", firstFieldSamples).toString(2))
            }
            cleanup?.let { if (primary != null) primary!!.addSuppressed(it) else throw it }
        }
    }

    @Test(timeout = 180_000)
    fun actualMainHardwareBackClosesOnlyTheScriptChildAndReturnsToItsNonfirstOpener(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Build.VERSION.SDK_INT == 36 && shell("getprop ro.kernel.qemu").trim() == "1")
        val file = File(context.filesDir, "browser.json")
        val saved = file.takeIf { it.isFile }?.readBytes()
        val size = overrideValue(shell("wm size"))
        val density = overrideValue(shell("wm density"))
        val samples = JSONArray()
        val childReadinessSamples = JSONArray()
        val coldReadySamples = JSONArray()
        var chords = 0
        var popupActivations = 0
        var completed = false
        var restored = false
        var primary: Throwable? = null
        try {
            shell("wm density 160"); shell("wm size 900x768")
            HardwareOpenerSite().use { site ->
                val decoy = BrowserTab("opener-back-decoy", site.url("decoy"), "Owned decoy", TabPlace.KEPT, createdAt = 1)
                val opener = BrowserTab("opener-back-source", site.url("opener"), "Owned opener source", TabPlace.KEPT, createdAt = 2)
                val tabs = listOf(decoy, opener)
                val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal", tabs = tabs, currentTabId = opener.id)
                FileBrowserRepository(file).save(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                    settings = BrowserSettings(welcomed = true)))
                NativeMainActivityFixture.launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
                    NativeMainActivityFixture.Kind.APP_WORKSPACE).use { fixture ->
                    lateinit var model: BrowserSessionViewModel
                    lateinit var originalActivity: MainActivity
                    fixture.onActivity { host ->
                        originalActivity = host
                        model = ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                    }
                    val browser = model.browser
                    val sync = (context.applicationContext as YabApplication).sync
                    val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.APP_WORKSPACE)
                    fixture.onActivity { ui.bind(browser, model.engine) { browser.workspaceWindow.value.generation } }
                    ui.run {
                        fun pageReady(id: String, url: String, title: String): Boolean {
                            var ready = false
                            fixture.onActivity { host ->
                                val state = browser.state.value
                                val native = model.engine.captureExternalActivityOwner()
                                ready = host === originalActivity && !state.loading && !state.privateContentBlocked &&
                                    state.surface == BrowserSurface.PAGE && state.tab?.id == id && state.tab?.url == url &&
                                    !state.page.loading && state.page.title == title && state.page.url == url &&
                                    state.page.error == null && state.page.progress >= 1f && state.space?.websiteProfile == space.websiteProfile &&
                                    state.workspace == null && model.engine.hasLiveSession(id) && native != null && native.tab == id &&
                                    model.engine.ownsExternalActivity(native) && model.engine.ownsInteractive(native.session) &&
                                    native.session.settings.contextId == space.websiteProfile.id && !native.session.settings.usePrivateMode &&
                                    ViewCompat.getRootWindowInsets(host.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime()) == false &&
                                    host.windowManager.currentWindowMetrics.bounds.let { it.width() == 900 && it.height() == 768 } &&
                                    browser.workspaceWindow.value.let { it.registered && it.geometry == BrowserWorkspaceWindow(900.0, 768.0) }
                            }
                            return ready && compose.onAllNodesWithTag(INPUT).fetchSemanticsNodes().isEmpty() &&
                                compose.onAllNodesWithTag("browser.field.popup").fetchSemanticsNodes().isEmpty()
                        }
                        fun focusNative() = fixture.onActivity { host ->
                            val state = browser.state.value
                            val tab = checkNotNull(state.tab)
                            check(state.surface == BrowserSurface.PAGE && !state.privateContentBlocked && model.engine.hasLiveSession(tab.id))
                            val native = checkNotNull(model.engine.captureExternalActivityOwner())
                            check(native.tab == tab.id && model.engine.ownsExternalActivity(native) &&
                                native.session.settings.contextId == space.websiteProfile.id && !native.session.settings.usePrivateMode)
                            val view = nativeViews(host.window.decorView).single { it.session === native.session && it.isShown && it.isAttachedToWindow }
                            check(view.requestFocus() && view.hasFocus()) { "The original native page did not take keyboard focus" }
                        }
                        // The existing hardware test's host/source guards and four-event chord are retained.
                        suspend fun chord(code: Int, shift: Boolean = false) {
                            compose.waitForIdle()
                            lateinit var ownHost: () -> Boolean
                            lateinit var ownSource: () -> Boolean
                            fixture.onActivity { host ->
                                val state = browser.state.value
                                val account = sync.accountRecords.value
                                val configuration = Configuration(host.resources.configuration)
                                val intent = host.intent
                                val window = host.window
                                val decor = window.decorView
                                val token = decor.windowToken
                                val bounds = Rect(host.windowManager.currentWindowMetrics.bounds)
                                val registered = browser.workspaceWindow.value
                                val lifetime = browser.settingsPresentationLifetime.value
                                val native = model.engine.captureExternalActivityOwner()
                                val source: () -> Boolean = {
                                    val now = browser.state.value
                                    now.surface == state.surface && now.surfaceEpoch == state.surfaceEpoch && now.selectedSpaceId == state.selectedSpaceId &&
                                        now.tab?.id == state.tab?.id && now.tab?.url == state.tab?.url && now.space?.websiteProfile == space.websiteProfile &&
                                        now.fieldIsNewTab == state.fieldIsNewTab && !now.privateContentBlocked &&
                                        (state.surface == BrowserSurface.SETTINGS || native != null && model.engine.ownsExternalActivity(native))
                                }
                                val current: () -> Boolean = {
                                    host === originalActivity && !host.isFinishing && !host.isDestroyed && host.hasWindowFocus() &&
                                        host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && host.intent === intent && host.window === window &&
                                        window.decorView === decor && token != null && decor.windowToken === token && decor.isAttachedToWindow && decor.isShown &&
                                        host.resources.configuration == configuration && host.windowManager.currentWindowMetrics.bounds == bounds &&
                                        browser.workspaceWindow.value == registered && browser.settingsPresentationLifetime.value == lifetime && lifetime.active &&
                                        sync.nativeOwnerCurrent(account) && model === ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                                }
                                check(current() && source()) { "The original key source is no longer current" }
                                ownHost = current; ownSource = source
                            }
                            val downAt = SystemClock.uptimeMillis()
                            val modifiers = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON or
                                if (shift) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0
                            fun send(action: Int, keyCode: Int, originalSource: Boolean) {
                                fixture.onActivity { check(ownHost() && (!originalSource || ownSource())) { "The original key window changed before native input" } }
                                instrumentation.sendKeySync(KeyEvent(downAt, SystemClock.uptimeMillis(), action, keyCode, 0, modifiers,
                                    KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD))
                            }
                            send(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_CTRL_LEFT, true)
                            send(KeyEvent.ACTION_DOWN, code, true)
                            // The command's DOWN may legitimately replace FIELD/tab/epoch. UP
                            // releases only that original window, never a newly acquired target.
                            send(KeyEvent.ACTION_UP, code, false)
                            send(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_CTRL_LEFT, false)
                            check(chords < 24); chords++
                            compose.waitForIdle()
                        }
                        assertTrue("HARDWARE_OPENER_BACK_REQUIRES_ORIGINAL_MAIN_SOURCE", bounded {
                            pageReady(opener.id, opener.url, "Owned opener source")
                        })
                        lateinit var openerNative: dev.yab.browser.engine.GeckoEngine.ExternalActivityOwner
                        lateinit var originalContext: () -> Boolean
                        lateinit var originalContextFacts: (MainActivity) -> JSONObject
                        fixture.onActivity { host ->
                            check(browser.state.value.spaces.size == 1 && browser.state.value.space?.tabs?.map(BrowserTab::id) == tabs.map(BrowserTab::id))
                            openerNative = checkNotNull(model.engine.captureExternalActivityOwner())
                            val window = host.window
                            val decor = window.decorView
                            val token = decor.windowToken
                            val intent = host.intent
                            val configuration = Configuration(host.resources.configuration)
                            val frame = Rect(host.windowManager.currentWindowMetrics.bounds)
                            val registered = browser.workspaceWindow.value
                            val lifetime = browser.settingsPresentationLifetime.value
                            val account = sync.accountRecords.value
                            originalContext = {
                                host === originalActivity && !host.isFinishing && !host.isDestroyed && host.hasWindowFocus() &&
                                    host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && host.window === window && window.decorView === decor &&
                                    token != null && decor.windowToken === token && decor.isAttachedToWindow && decor.isShown && host.intent === intent &&
                                    host.resources.configuration == configuration && host.windowManager.currentWindowMetrics.bounds == frame &&
                                    browser.workspaceWindow.value == registered && browser.settingsPresentationLifetime.value == lifetime && lifetime.active &&
                                    sync.nativeOwnerCurrent(account) && model === ViewModelProvider(host)[BrowserSessionViewModel::class.java]
                            }
                            check(originalContext() && openerNative.tab == opener.id && model.engine.ownsExternalActivity(openerNative))
                            // Read-only decomposition of the original context, never an input or readiness authority.
                            val originalStore = host.viewModelStore
                            originalContextFacts = { currentHost ->
                                JSONObject().put("originalActivity", currentHost === originalActivity)
                                    .put("hostNotFinishing", !currentHost.isFinishing).put("hostNotDestroyed", !currentHost.isDestroyed)
                                    .put("hostWindowFocused", currentHost.hasWindowFocus())
                                    .put("hostResumed", currentHost.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
                                    .put("sameWindow", currentHost.window === window).put("sameDecor", currentHost.window.decorView === decor)
                                    .put("originalTokenKnown", token != null).put("sameDecorToken", currentHost.window.decorView.windowToken === token)
                                    .put("decorAttached", currentHost.window.decorView.isAttachedToWindow).put("decorShown", currentHost.window.decorView.isShown)
                                    .put("sameIntent", currentHost.intent === intent).put("sameConfiguration", currentHost.resources.configuration == configuration)
                                    .put("sameWindowBounds", currentHost.windowManager.currentWindowMetrics.bounds == frame)
                                    .put("sameRegisteredWindow", browser.workspaceWindow.value == registered)
                                    .put("samePresentationLifetime", browser.settingsPresentationLifetime.value == lifetime)
                                    .put("originalPresentationActive", lifetime.active).put("sameAccountOwner", sync.nativeOwnerCurrent(account))
                                    .put("sameRetainedStore", currentHost.viewModelStore === originalStore)
                            }
                        }
                        var child: BrowserTab? = null
                        fun sample(point: String) {
                            check(point in setOf("OPENER_READY", "CHILD_BEFORE_BACK", "OPENER_AFTER_BACK") && samples.length() < 3)
                            fixture.onActivity {
                                val state = browser.state.value
                                val native = model.engine.captureExternalActivityOwner()
                                val rows = state.space?.tabs.orEmpty()
                                val childId = child?.id
                                samples.put(JSONObject().put("point", point).put("observed", true)
                                    .put("originalContextCurrent", originalContext()).put("originalSpace", state.selectedSpaceId == space.id)
                                    .put("originalProfile", state.space?.websiteProfile == space.websiteProfile).put("workspaceAbsent", state.workspace == null)
                                    .put("pageSurface", state.surface == BrowserSurface.PAGE).put("pageReady", !state.page.loading && state.page.error == null && state.page.progress >= 1f)
                                    .put("tabCount", rows.size.coerceAtMost(8)).put("decoyPresent", rows.count { it.id == decoy.id && it.url == decoy.url && it.place == decoy.place } == 1)
                                    .put("openerPresent", rows.count { it.id == opener.id && it.url == opener.url && it.place == opener.place } == 1)
                                    .put("openerIsNotFirst", rows.indexOfFirst { it.id == opener.id } > 0)
                                    .put("originalPairOrder", rows.filter { it.id != childId }.map(BrowserTab::id) == tabs.map(BrowserTab::id))
                                    .put("selectedOpener", state.tab?.id == opener.id).put("selectedChild", childId != null && state.tab?.id == childId)
                                    .put("childKnown", childId != null).put("childPresent", childId != null && rows.count { it.id == childId } == 1)
                                    .put("childNamesOriginalOpener", child?.openerId == opener.id)
                                    .put("childLive", childId != null && model.engine.hasLiveSession(childId))
                                    .put("selectedCanGoBack", state.page.canGoBack).put("selectedReaderEnabled", state.page.readerEnabled)
                                    .put("selectedNativeBackItems", state.tab?.id?.let { model.engine.backItems(it).size.coerceAtMost(8) } ?: 0)
                                    .put("nativeOwnerCurrent", native?.let(model.engine::ownsExternalActivity) == true)
                                    .put("nativeOwnerInteractive", native?.let { model.engine.ownsInteractive(it.session) } == true)
                                    .put("nativeProfileMatches", native != null && native.session.settings.contextId == space.websiteProfile.id && !native.session.settings.usePrivateMode)
                                    .put("openerLive", model.engine.hasLiveSession(opener.id))
                                    .put("originalOpenerSessionRetained", model.engine.tabId(openerNative.session) == opener.id)
                                    .put("originalOpenerOwnerCurrent", model.engine.ownsExternalActivity(openerNative))
                                    .put("openerRequestSeen", site.openerRequests.get() > 0).put("childRequestSeen", site.childRequests.get() > 0))
                            }
                        }
                        // Fixed snapshots only: do not write child, call pageReady(), create a session or run a callback.
                        fun childReadinessSample(point: String) {
                            check(point in setOf("CHILD_BEFORE_ACTIVATION", "CHILD_AFTER_ACTIVATION", "CHILD_AFTER_ORIGINAL_WAIT"))
                            check(childReadinessSamples.length() < 3)
                            var row = JSONObject().put("point", point).put("observed", false)
                            try {
                                val fields = compose.onAllNodesWithTag(INPUT).fetchSemanticsNodes().size
                                val popups = compose.onAllNodesWithTag("browser.field.popup").fetchSemanticsNodes().size
                                fixture.onActivity { host ->
                                    val state = browser.state.value
                                    val candidate = state.tab
                                    val rows = state.space?.tabs.orEmpty()
                                    val native = model.engine.captureExternalActivityOwner()
                                    val shield = model.shield.state.value
                                    fun role(id: String?) = when (id) {
                                        null -> "NONE"; decoy.id -> "DECOY"; opener.id -> "OPENER"; else -> "OTHER"
                                    }
                                    fun urlKind(url: String?) = when (url) {
                                        null -> "NONE"; opener.url -> "SOURCE"; decoy.url -> "DECOY"
                                        site.url("child") -> "CHILD"; "about:blank" -> "ABOUT_BLANK"; else -> "OTHER"
                                    }
                                    fun titleKind(title: String?) = when (title) {
                                        null -> "NONE"; "Owned opener source" -> "SOURCE"; "Owned decoy" -> "DECOY"
                                        "Owned child loading" -> "CHILD_LOADING"; "Owned opener child" -> "CHILD_WITH_OPENER"
                                        "Owned child without opener" -> "CHILD_WITHOUT_OPENER"; else -> "OTHER"
                                    }
                                    val contextFacts = originalContextFacts(host)
                                    for (key in contextFacts.keys()) row.put(key, contextFacts.getBoolean(key))
                                    val ime = ViewCompat.getRootWindowInsets(host.window.decorView)
                                        ?.isVisible(WindowInsetsCompat.Type.ime())
                                    val visible = nativeViews(host.window.decorView).filter { view ->
                                        val bounds = Rect()
                                        view.isAttachedToWindow && view.isShown && view.getGlobalVisibleRect(bounds) && !bounds.isEmpty
                                    }
                                    row.put("originalContextCurrent", originalContext()).put("modelLoading", state.loading)
                                        .put("privateContentBlocked", state.privateContentBlocked).put("surface", state.surface.name)
                                        .put("spaceCount", state.spaces.size.coerceAtMost(8)).put("originalSpace", state.selectedSpaceId == space.id)
                                        .put("originalProfile", state.space?.websiteProfile == space.websiteProfile).put("workspaceAbsent", state.workspace == null)
                                        .put("tabCount", rows.size.coerceAtMost(8)).put("candidatePresent", candidate != null)
                                        .put("candidateRole", role(candidate?.id))
                                        .put("candidateDistinctFromOriginalTabs", candidate != null && candidate.id !in tabs.map(BrowserTab::id))
                                        .put("candidateNamesOriginalOpener", candidate?.openerId == opener.id).put("candidateOpenerRole", role(candidate?.openerId))
                                        .put("candidateUrlKind", urlKind(candidate?.url)).put("candidateTitleKind", titleKind(candidate?.title))
                                        .put("candidateUrlMatchesChild", candidate?.url == site.url("child"))
                                        .put("candidatePrivate", candidate?.isPrivate ?: JSONObject.NULL)
                                        .put("candidateDecoyOpenerOrder", candidate != null && rows.map(BrowserTab::id) == listOf(candidate.id, decoy.id, opener.id))
                                        .put("originalPairOrder", rows.filter { it.id in tabs.map(BrowserTab::id) }.map(BrowserTab::id) == tabs.map(BrowserTab::id))
                                        .put("originalOpenerRelationCount", rows.count { it.openerId == opener.id }.coerceAtMost(8))
                                        .put("nonfixtureTabCount", rows.count { it.id !in tabs.map(BrowserTab::id) }.coerceAtMost(8))
                                        .put("pageUrlKind", urlKind(state.page.url)).put("pageTitleKind", titleKind(state.page.title))
                                        .put("pageUrlMatchesChild", state.page.url == site.url("child"))
                                        .put("pageTitleMatchesChild", state.page.title == "Owned opener child")
                                        .put("pageLoading", state.page.loading).put("pageHasError", state.page.error != null)
                                        .put("pageProgressComplete", state.page.progress >= 1f)
                                        .put("canGoBack", state.page.canGoBack).put("readerEnabled", state.page.readerEnabled)
                                        .put("nativeBackItems", candidate?.id?.let { model.engine.backItems(it).size.coerceAtMost(8) } ?: JSONObject.NULL)
                                        .put("candidateLive", candidate?.id?.let(model.engine::hasLiveSession) ?: JSONObject.NULL)
                                        .put("openerLive", model.engine.hasLiveSession(opener.id))
                                        .put("originalOpenerSessionRetained", model.engine.tabId(openerNative.session) == opener.id)
                                        .put("originalOpenerOwnerCurrent", model.engine.ownsExternalActivity(openerNative))
                                        .put("nativeOwnerPresent", native != null).put("nativeOwnerRole", role(native?.tab))
                                        .put("nativeOwnerMatchesCandidate", native != null && native.tab == candidate?.id)
                                        .put("nativeOwnerCurrent", native?.let(model.engine::ownsExternalActivity) ?: JSONObject.NULL)
                                        .put("nativeOwnerInteractive", native?.let { model.engine.ownsInteractive(it.session) } ?: JSONObject.NULL)
                                        .put("interactiveSelectedMatchesCandidate", candidate != null && model.engine.interactiveSelected == candidate.id)
                                        .put("nativeProfileMatchesOriginal", native?.session?.settings?.contextId == space.websiteProfile.id)
                                        .put("nativePrivate", native?.session?.settings?.usePrivateMode ?: JSONObject.NULL)
                                        .put("visibleNativeViews", visible.size.coerceAtMost(8))
                                        .put("visibleCandidateViews", visible.count { view -> candidate != null && view.session?.let(model.engine::tabId) == candidate.id }.coerceAtMost(8))
                                        .put("window900x768", host.windowManager.currentWindowMetrics.bounds.let { it.width() == 900 && it.height() == 768 })
                                        .put("workspaceWindowRegistered", browser.workspaceWindow.value.registered)
                                        .put("workspaceGeometryMatches", browser.workspaceWindow.value.geometry == BrowserWorkspaceWindow(900.0, 768.0))
                                        .put("ime", when (ime) { true -> "VISIBLE"; false -> "HIDDEN"; null -> "UNKNOWN" })
                                        .put("fieldInputs", fields.coerceAtMost(4)).put("fieldPopups", popups.coerceAtMost(4))
                                        .put("nativePromptPending", model.engine.prompts?.pending?.value ?: JSONObject.NULL)
                                        .put("openerRequestSeen", site.openerRequests.get() > 0).put("childRequestSeen", site.childRequests.get() > 0)
                                        .put("shieldReady", shield.ready).put("shieldRefreshing", shield.refreshing).put("shieldErrorPresent", shield.error != null)
                                        .put("observed", true)
                                    val markers = site.markerSnapshot()
                                    for (key in markers.keys()) row.put(key, markers.get(key))
                                }
                            } catch (_: Throwable) {
                                // Observation failure cannot swallow or replace the original child-readiness assertion.
                                row = JSONObject().put("point", point).put("observed", false)
                                    .put("observationFailure", "OWNED_SAMPLE_UNAVAILABLE")
                            }
                            childReadinessSamples.put(row)
                        }
                        sample("OPENER_READY")
                        // A production configure acknowledgement is a milestone, not a current native port lease.
                        val coldReadyStarted = SystemClock.elapsedRealtime()
                        fun coldReadySample(point: String, premiseSatisfied: Boolean) {
                            check(point in setOf("COLD_READY_BEFORE_WAIT", "COLD_READY_AFTER_WAIT"))
                            check(coldReadySamples.length() < 2)
                            var row = JSONObject().put("point", point).put("observed", false)
                            try {
                                val samePage = pageReady(opener.id, opener.url, "Owned opener source")
                                fixture.onActivity { host ->
                                    val state = browser.state.value
                                    val shield = model.shield.state.value
                                    row.put("elapsedMs", (SystemClock.elapsedRealtime() - coldReadyStarted).coerceIn(0L, 65_000L))
                                        .put("premiseSatisfied", premiseSatisfied).put("originalActivity", host === originalActivity)
                                        .put("originalContextCurrent", originalContext()).put("openerSelected", state.tab?.id == opener.id)
                                        .put("originalSpace", state.selectedSpaceId == space.id).put("originalProfile", state.space?.websiteProfile == space.websiteProfile)
                                        .put("workspaceAbsent", state.workspace == null).put("pageSurface", state.surface == BrowserSurface.PAGE)
                                        .put("pageReady", samePage).put("openerLive", model.engine.hasLiveSession(opener.id))
                                        .put("originalOpenerSessionRetained", model.engine.tabId(openerNative.session) == opener.id)
                                        .put("originalOpenerOwnerCurrent", model.engine.ownsExternalActivity(openerNative))
                                        .put("originalOpenerInteractive", model.engine.ownsInteractive(openerNative.session))
                                        .put("interactiveSelectedMatchesOpener", model.engine.interactiveSelected == opener.id)
                                        .put("nativeProfileMatchesOriginal", openerNative.session.settings.contextId == space.websiteProfile.id)
                                        .put("nativePrivate", openerNative.session.settings.usePrivateMode)
                                        .put("shieldReady", shield.ready).put("shieldRefreshing", shield.refreshing).put("shieldErrorPresent", shield.error != null)
                                        .put("shieldRules", shield.rules.coerceIn(0, 1_000_000)).put("shieldSkipped", shield.skipped.coerceIn(0, 1_000_000))
                                        .put("shieldLeft", shield.left.coerceIn(0, 1_000_000)).put("shieldUnsupportedPopupRules", shield.unsupportedPopupRules.coerceIn(0, 1_000_000))
                                        .put("shieldSourceCount", shield.sources.size.coerceAtMost(8)).put("observed", true)
                                }
                            } catch (_: Throwable) {
                                row = JSONObject().put("point", point).put("observed", false)
                                    .put("observationFailure", "OWNED_SAMPLE_UNAVAILABLE")
                            }
                            coldReadySamples.put(row)
                        }
                        suspend fun awaitProductionColdReady(): Boolean {
                            val deadline = coldReadyStarted + 60_000L
                            while (SystemClock.elapsedRealtime() <= deadline) {
                                val samePage = pageReady(opener.id, opener.url, "Owned opener source")
                                var sameOwner = false
                                var ready = false
                                fixture.onActivity {
                                    val state = browser.state.value
                                    sameOwner = originalContext() && state.tab?.id == opener.id && state.tab?.url == opener.url &&
                                        state.selectedSpaceId == space.id && state.space?.websiteProfile == space.websiteProfile && state.workspace == null &&
                                        model.engine.hasLiveSession(opener.id) && model.engine.tabId(openerNative.session) == opener.id &&
                                        model.engine.ownsExternalActivity(openerNative) && model.engine.ownsInteractive(openerNative.session) &&
                                        model.engine.interactiveSelected == opener.id && openerNative.session.settings.contextId == space.websiteProfile.id &&
                                        !openerNative.session.settings.usePrivateMode
                                    ready = model.shield.state.value.ready
                                }
                                if (!samePage || !sameOwner || SystemClock.elapsedRealtime() > deadline) return false
                                if (ready) return true
                                delay(40)
                            }
                            return false
                        }
                        var productionColdReady = false
                        coldReadySample("COLD_READY_BEFORE_WAIT", false)
                        try {
                            productionColdReady = awaitProductionColdReady()
                            assertTrue("HARDWARE_OPENER_BACK_REQUIRES_PRODUCTION_COLD_READY", productionColdReady)
                        } finally { coldReadySample("COLD_READY_AFTER_WAIT", productionColdReady) }
                        childReadinessSample("CHILD_BEFORE_ACTIVATION")
                        ui.click("Open owned child"); popupActivations++
                        childReadinessSample("CHILD_AFTER_ACTIVATION")
                        try {
                        assertTrue("HARDWARE_OPENER_BACK_REQUIRES_GENUINE_CHILD_WITHOUT_NATIVE_BACK_HISTORY", bounded {
                            var ready = false
                            fixture.onActivity {
                                val state = browser.state.value
                                val candidate = state.tab
                                ready = originalContext() && candidate != null && candidate.id !in tabs.map(BrowserTab::id) &&
                                    candidate.openerId == opener.id && candidate.url == site.url("child") && !candidate.isPrivate &&
                                    state.space?.tabs?.map(BrowserTab::id) == listOf(candidate.id, decoy.id, opener.id) &&
                                    state.spaces.size == 1 && !state.page.canGoBack && !state.page.readerEnabled &&
                                    model.engine.backItems(candidate.id).isEmpty() && model.engine.hasLiveSession(opener.id) &&
                                    model.engine.tabId(openerNative.session) == opener.id && site.childRequests.get() > 0
                                if (ready) child = candidate
                            }
                            ready && pageReady(checkNotNull(child).id, site.url("child"), "Owned opener child")
                        })
                        } finally { childReadinessSample("CHILD_AFTER_ORIGINAL_WAIT") }
                        val originalChild = checkNotNull(child)
                        sample("CHILD_BEFORE_BACK")
                        focusNative(); chord(KeyEvent.KEYCODE_LEFT_BRACKET)
                        try {
                            assertTrue("HARDWARE_BACK_RETURNS_TO_ORIGINAL_NONFIRST_OPENER", bounded {
                                var returned = false
                                fixture.onActivity {
                                    val state = browser.state.value
                                    val native = model.engine.captureExternalActivityOwner()
                                    returned = originalContext() && state.spaces.size == 1 && state.space?.tabs?.map(BrowserTab::id) == tabs.map(BrowserTab::id) &&
                                        state.spaces.none { owner -> owner.tabs.any { it.id == originalChild.id } } &&
                                        !model.engine.hasLiveSession(originalChild.id) && model.engine.hasLiveSession(opener.id) &&
                                        model.engine.ownsExternalActivity(openerNative) && native != null && native.session === openerNative.session &&
                                        native.document == openerNative.document && native.tab == opener.id
                                }
                                returned && pageReady(opener.id, opener.url, "Owned opener source")
                            })
                        } finally { sample("OPENER_AFTER_BACK") }
                        assertEquals(1, chords); assertEquals(1, popupActivations); assertEquals(3, samples.length())
                    }
                }
            }
            completed = true
        } catch (error: Throwable) { primary = error; throw error }
        finally {
            var cleanup: Throwable? = null
            fun attempt(block: () -> Unit) { try { block() } catch (error: Throwable) {
                if (cleanup == null) cleanup = error else cleanup!!.addSuppressed(error)
            } }
            attempt { shell("wm size ${size ?: "reset"}"); shell("wm density ${density ?: "reset"}") }
            attempt { if (saved == null) check(!file.exists() || file.delete()) else file.writeBytes(saved)
                restored = if (saved == null) !file.exists() else file.readBytes().contentEquals(saved); check(restored) }
            attempt {
                val folder = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
                check(folder.isDirectory || folder.mkdirs())
                File(folder, "browser-hardware-opener-back.json").writeText(JSONObject().put("schema", 1).put("completed", completed)
                    .put("ownBrowserFileRestored", restored).put("nativeChords", chords).put("popupActivations", popupActivations)
                    .put("keyAdmissionKnown", false).put("samples", samples)
                    .put("childReadinessSamples", childReadinessSamples).put("coldReadySamples", coldReadySamples).toString(2))
            }
            cleanup?.let { if (primary != null) primary!!.addSuppressed(it) else throw it }
        }
    }

    private suspend fun bounded(ready: () -> Boolean): Boolean {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (true) { compose.waitForIdle(); if (ready()) return true
            if (SystemClock.elapsedRealtime() >= deadline) return false; delay(40) }
    }
    private fun nativeViews(root: View): List<GeckoView> = buildList {
        if (root is GeckoView) add(root)
        if (root is ViewGroup) for (i in 0 until root.childCount) addAll(nativeViews(root.getChildAt(i)))
    }
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(
        instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun overrideValue(value: String) = value.lineSequence().firstOrNull { it.startsWith("Override ") }?.substringAfter(": ")?.trim()
    companion object { private const val INPUT = "browser.field.input"; private const val FIND = "browser.find.query" }
}

/** This private HTTP fixture supplies a real script opener. It never sets history or invokes browser commands. */
private class HardwareOpenerSite : java.io.Closeable {
    private val socket = java.net.ServerSocket(0, 8, java.net.InetAddress.getByName("127.0.0.1"))
    private val alive = java.util.concurrent.atomic.AtomicBoolean(true)
    val openerRequests = java.util.concurrent.atomic.AtomicInteger()
    val childRequests = java.util.concurrent.atomic.AtomicInteger()
    private val handlerMarkers = java.util.concurrent.atomic.AtomicInteger()
    private val returnedNullMarkers = java.util.concurrent.atomic.AtomicInteger()
    private val returnedObjectMarkers = java.util.concurrent.atomic.AtomicInteger()
    private val returnedOtherMarkers = java.util.concurrent.atomic.AtomicInteger()
    private val threwMarkers = java.util.concurrent.atomic.AtomicInteger()
    @Volatile private var accepted: java.net.Socket? = null
    private val listener = Thread({
        while (alive.get()) try {
            socket.accept().use { client ->
                accepted = client
                if (!alive.get()) return@use
                try {
                    client.soTimeout = 5000
                    val reader = client.getInputStream().bufferedReader()
                    val first = try {
                        val request = reader.readLine().orEmpty()
                        var bytes = request.length
                        while (true) {
                            val header = reader.readLine() ?: break
                            bytes += header.length; check(bytes <= 8192)
                            if (header.isEmpty()) break
                        }
                        request
                    } catch (_: java.net.SocketTimeoutException) { return@use }
                    if (!first.startsWith("GET ")) return@use
                    val route = first.split(' ').getOrNull(1)?.substringBefore('?')
                    val content = when (route) {
                        "/owned-marker/handler" -> { handlerMarkers.updateAndGet { (it + 1).coerceAtMost(2) }; "" }
                        "/owned-marker/returned-null" -> { returnedNullMarkers.updateAndGet { (it + 1).coerceAtMost(2) }; "" }
                        "/owned-marker/returned-object" -> { returnedObjectMarkers.updateAndGet { (it + 1).coerceAtMost(2) }; "" }
                        "/owned-marker/returned-other" -> { returnedOtherMarkers.updateAndGet { (it + 1).coerceAtMost(2) }; "" }
                        "/owned-marker/threw" -> { threwMarkers.updateAndGet { (it + 1).coerceAtMost(2) }; "" }
                        "/opener" -> {
                            openerRequests.incrementAndGet()
                            """<title>Owned opener source</title><h1>Owned opener source</h1>
                                <button onclick="ownedOpenChild()">Open owned child</button>
                                <script>
                                window.ownedPopupDiagnostic={entered:0,result:'NOT_CALLED',markers:[]};
                                function ownedPopupMarker(kind){
                                  try{
                                    const paths={handler:'/owned-marker/handler',returnedNull:'/owned-marker/returned-null',returnedObject:'/owned-marker/returned-object',returnedOther:'/owned-marker/returned-other',threw:'/owned-marker/threw'};
                                    const state=window.ownedPopupDiagnostic;
                                    if(!Object.prototype.hasOwnProperty.call(paths,kind)||state.markers.length>=8)return;
                                    const marker=new Image();state.markers.push(marker);marker.src=paths[kind];
                                  }catch(ignored){}
                                }
                                function ownedOpenChild(){
                                  const state=window.ownedPopupDiagnostic;
                                  state.entered=Math.min(2,state.entered+1);state.result='CALLING';
                                  try{window.ownedChild=window.open('/child','_blank')}
                                  catch(error){state.result='THREW';ownedPopupMarker('handler');ownedPopupMarker('threw');throw error}
                                  state.result=window.ownedChild===null?'RETURNED_NULL':typeof window.ownedChild==='object'?'RETURNED_OBJECT':'RETURNED_OTHER';
                                  ownedPopupMarker('handler');
                                  ownedPopupMarker(state.result==='RETURNED_NULL'?'returnedNull':state.result==='RETURNED_OBJECT'?'returnedObject':'returnedOther');
                                }
                                </script>"""
                        }
                        "/child" -> {
                            childRequests.incrementAndGet()
                            """<title>Owned child loading</title><h1>Owned child</h1>
                                <script>document.title=window.opener?'Owned opener child':'Owned child without opener'</script>"""
                        }
                        else -> "<title>Owned unused page</title><p>Owned unused page</p>"
                    }
                    val body = ("<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'></head><body>" +
                        content + "</body></html>").toByteArray()
                    val header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray()
                    val output = client.getOutputStream()
                    try {
                        output.write(header); output.write(body); output.flush()
                    } catch (error: java.net.SocketException) {
                        if (error.message != "Broken pipe") throw error
                    }
                } finally { accepted = null }
            }
        } catch (error: java.io.IOException) { if (alive.get()) throw error }
    }, "hardware-opener-site").apply { isDaemon = true; start() }
    /** Received positive markers only. Missing transport never proves that the DOM point did not execute. */
    fun markerSnapshot(): JSONObject {
        val handler = handlerMarkers.get()
        val counts = listOf(returnedNullMarkers.get(), returnedObjectMarkers.get(), returnedOtherMarkers.get(), threwMarkers.get())
        val kinds = listOf("RETURNED_NULL", "RETURNED_OBJECT", "RETURNED_OTHER", "THREW")
        val positive = counts.indices.filter { counts[it] > 0 }
        val result = when (positive.size) { 0 -> "UNKNOWN"; 1 -> kinds[positive.single()]; else -> "CONFLICT" }
        return JSONObject().put("domHandlerMarkersReceived", handler)
            .put("domHandlerObservation", if (handler > 0) "OBSERVED" else "UNKNOWN")
            .put("windowOpenReturnedNullMarkersReceived", counts[0]).put("windowOpenReturnedObjectMarkersReceived", counts[1])
            .put("windowOpenReturnedOtherMarkersReceived", counts[2]).put("windowOpenThrewMarkersReceived", counts[3])
            .put("windowOpenResultObservation", result)
    }
    fun url(route: String) = "http://127.0.0.1:${socket.localPort}/$route"
    override fun close() { alive.set(false); socket.close(); accepted?.close(); listener.join(3_000); check(!listener.isAlive) }
}

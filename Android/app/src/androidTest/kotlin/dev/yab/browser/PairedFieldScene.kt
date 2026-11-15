package dev.yab.browser

import android.view.View
import android.graphics.Rect
import android.animation.ValueAnimator
import android.provider.Settings
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.background
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import kotlin.math.roundToInt
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.Lifecycle
import dev.yab.android.EngineTestActivity
import dev.yab.android.YabApplication
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserAccessibility
import dev.yab.browser.ui.BrowserScreen
import dev.yab.browser.ui.BrowserTheme
import dev.yab.browser.ui.FieldProgressKey
import dev.yab.browser.ui.FieldKeyboardKey
import dev.yab.browser.ui.FieldClosingKey
import java.io.Closeable
import java.lang.ref.WeakReference
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.GeckoSession

/** Independent test scene. The complete Field is production UI, including its actual OS IME.
 * The selected synthetic page is rewritten to one owned loopback document. Nothing here
 * certifies identical Phone typography, keyboard, icons, Chats content, pixels or cadence. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
internal class PairedFieldScene private constructor(private val nonce: String) {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val alive = AtomicBoolean(true)
    private var scenario: ActivityScenario<EngineTestActivity>? = null
    private lateinit var server: Page
    lateinit var activity: EngineTestActivity; private set
    lateinit var controller: BrowserController; private set
    lateinit var engine: GeckoEngine; private set
    lateinit var field: FieldPresentationLease; private set
    lateinit var native: GeckoEngine.ExternalActivityOwner; private set
    private var initialTab: BrowserTab? = null
    private var initialProfile: WebsiteProfile? = null
    private var initialToken: android.os.IBinder? = null
    private var engineCreated = false
    private var controllerCreated = false
    private var composeRoot: ViewRootForTest? = null
    private val observedViews = mutableMapOf<String, WeakReference<GeckoView>>()
    private var initialNativeView: WeakReference<GeckoView>? = null
    private var initialNativeSession: GeckoSession? = null
    var marker by mutableStateOf(false)

    internal data class RootPreflight(val composeRootPresent: Boolean = false,
        val viewAttached: Boolean = false, val originalWindowToken: Boolean = false,
        val originalDecorRoot: Boolean = false, val viewWindowFocused: Boolean = false,
        val nativeNodePresent: Boolean = false, val nativePackageMatches: Boolean = false,
        val nativeWindowIdKnown: Boolean = false, val nativeRootBoundsNonempty: Boolean = false)

    internal data class TraversalProbe(val visited: Int = 0, val foreignRoots: Int = 0,
        val unplaced: Int = 0, val fixedTagsFound: Int = 0, val capped: Boolean = false)

    internal data class GeometryProbe(val source: Boolean, val rootOwned: Boolean = false,
        val lifecycleResumed: Boolean = false, val pendingLayout: Boolean = false, val complete: Boolean = false,
        val progress: Float? = null, val keyboard: Float? = null, val closing: Boolean? = null,
        val focusedNodes: Int = 0, val editableNodes: Int = 0, val window: Int? = null, val rootBounds: Rect? = null,
        val bounds: Map<String, Rect> = emptyMap(), val preflight: RootPreflight = RootPreflight(),
        val traversal: TraversalProbe = TraversalProbe()) {
        val settled get() = source && rootOwned && lifecycleResumed && !pendingLayout && complete && progress == 1f && closing == false
    }

    /** Public Compose1.9.3 test-root API; Main only, read-only, never forces layout or a frame.
     * Values are fixed production tags and finite geometry. No text/actions/account are read. */
    fun geometry(): GeometryProbe {
        check(android.os.Looper.myLooper() === android.os.Looper.getMainLooper())
        if (!current()) return GeometryProbe(false)
        val root = composeRoot ?: return GeometryProbe(true)
        val view = root.view
        var preflight = RootPreflight(composeRootPresent = true, viewAttached = view.isAttachedToWindow,
            originalWindowToken = view.windowToken === initialToken,
            originalDecorRoot = view.rootView === activity.window.decorView, viewWindowFocused = view.hasWindowFocus())
        val owned = preflight.viewAttached && preflight.originalWindowToken &&
            preflight.originalDecorRoot && preflight.viewWindowFocused
        if (!owned) return GeometryProbe(true, preflight = preflight)
        // Create only this original View's root node locally, not a UiAutomation/Binder tree.
        val native = view.createAccessibilityNodeInfo() ?: return GeometryProbe(true, preflight = preflight)
        val window: Int; val rootBounds = Rect()
        try {
            preflight = preflight.copy(nativeNodePresent = true,
                nativePackageMatches = native.packageName?.toString() == instrumentation.targetContext.packageName)
            if (!preflight.nativePackageMatches) return GeometryProbe(true, preflight = preflight)
            window = native.windowId; native.getBoundsInScreen(rootBounds)
            preflight = preflight.copy(nativeWindowIdKnown = window >= 0, nativeRootBoundsNonempty = !rootBounds.isEmpty)
            if (window < 0 || rootBounds.isEmpty) return GeometryProbe(true, preflight = preflight)
        } finally { native.recycle() }
        val resumed = root.isLifecycleInResumedState
        val pending = root.hasPendingMeasureOrLayout
        val offset = IntArray(2); view.getLocationOnScreen(offset)
        val tags = setOf("browser.field.eyes", "browser.field.pill", "browser.field.close", "browser.field.pages", "browser.field.motion")
        val found = mutableMapOf<String, MutableList<SemanticsNode>>()
        var count = 0; var complete = true; var focused = 0; var editable = 0
        var foreignRoots = 0; var unplaced = 0; var capped = false
        fun visit(node: SemanticsNode, depth: Int) {
            if (count >= 512 || depth > 64) { complete = false; capped = true; return }; count++
            if (node.root !== root) { complete = false; foreignRoots++; return }
            if (!node.layoutInfo.isPlaced) { complete = false; unplaced++; return }
            val config = node.config
            if (config.getOrNull(SemanticsProperties.Focused) == true) focused++
            if (config.contains(SemanticsProperties.EditableText)) editable++
            config.getOrNull(SemanticsProperties.TestTag)?.takeIf { it in tags }?.let { found.getOrPut(it) { mutableListOf() }.add(node) }
            val children = node.children
            if (children.size > 128) { complete = false; capped = true }
            children.take(128).forEach { visit(it, depth + 1) }
        }
        visit(root.semanticsOwner.unmergedRootSemanticsNode, 0)
        if (tags.any { found[it]?.size != 1 }) complete = false
        val bounds = mutableMapOf<String, Rect>()
        found.forEach { (tag, nodes) -> if (nodes.size == 1) {
            // This is also the geometry used by SemanticsOwner's Android accessibility region.
            val r = nodes.single().touchBoundsInRoot
            if (listOf(r.left, r.top, r.right, r.bottom).all(Float::isFinite) && r.width > 0 && r.height > 0)
                bounds[tag] = Rect(r.left.roundToInt() + offset[0], r.top.roundToInt() + offset[1],
                    r.right.roundToInt() + offset[0], r.bottom.roundToInt() + offset[1])
            else complete = false
        } }
        val motion = found["browser.field.motion"]?.singleOrNull()?.config
        val progress = motion?.getOrNull(FieldProgressKey)?.takeIf(Float::isFinite)
        val keyboard = motion?.getOrNull(FieldKeyboardKey)?.takeIf(Float::isFinite)
        return GeometryProbe(true, true, resumed, pending, complete, progress, keyboard,
            motion?.getOrNull(FieldClosingKey), focused.coerceAtMost(8), editable.coerceAtMost(8), window, rootBounds, bounds, preflight,
            TraversalProbe(count, foreignRoots, unplaced, tags.count { found[it]?.size == 1 }, capped))
    }

    suspend fun start(initiallyPrivate: Boolean) {
        check(nonce.matches(Regex("[a-f0-9]{32}")))
        server = Page(asset("figma.html", FIGMA_SHA, 16_384), nonce)
        val snapshot = publicSnapshot(asset("mira-public.json", MIRA_ASSET_SHA, 32_768), server.url)
        try {
            scenario = ActivityScenario.launch(EngineTestActivity::class.java).also { host ->
                host.onActivity { target ->
                    activity = target
                    engine = GeckoEngine(target, (target.application as YabApplication).runtime, maxLiveSessions = 1)
                    engineCreated = true
                    controller = BrowserController(object : BrowserRepository {
                        override suspend fun load() = snapshot
                        override suspend fun save(snapshot: BrowserSnapshot) = Unit // RAM fixture, no real profile.
                    }, engine, scope)
                    controllerCreated = true
                    engine.onState = controller::pageChanged
                    target.setContent {
                        BrowserTheme(BrowserAppearance.LIGHT) { BrowserAccessibility {
                            val view = LocalView.current
                            SideEffect { composeRoot = view as? ViewRootForTest }
                            var covered by remember { mutableStateOf(false) }
                            Box(Modifier.fillMaxSize()) {
                            BrowserScreen(controller, modifier = Modifier.semantics { testTagsAsResourceId = true },
                                onOpenChats = {}, onUnlockPrivate = { it(false) }, onOverlayChange = { covered = it },
                                pageContent = { tab, profile, modifier ->
                                    AndroidView(modifier = modifier.fillMaxSize(), factory = { context ->
                                        GeckoView(context).apply {
                                            setSession(engine.session(tab, profile)); tag = tab.id; engine.bindView(tab.id, this)
                                            observedViews[tab.id] = WeakReference(this)
                                            importantForAccessibility = if (covered) View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS else View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
                                        }
                                    }, update = { view ->
                                        val session = engine.session(tab, profile)
                                        if (view.session !== session) {
                                            (view.tag as? String)?.let { engine.unbindView(it, view); forgetObservedView(it, view) }
                                            view.releaseSession(); view.setSession(session); view.tag = tab.id
                                        }
                                        engine.bindView(tab.id, view)
                                        observedViews[tab.id] = WeakReference(view)
                                        view.importantForAccessibility = if (covered) View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS else View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
                                    }, onReset = null, onRelease = { view ->
                                        (view.tag as? String)?.let { engine.unbindView(it, view); forgetObservedView(it, view) }; view.releaseSession()
                                    })
                                })
                            if (marker) Box(Modifier.offset(8.dp, 32.dp).size(4.dp).background(Color.Blue))
                            }
                        } }
                    }
                }
            }
            await("owned public fixture document") { main {
                !controller.state.value.loading && controller.state.value.page.let {
                    !it.loading && it.progress >= 1f && it.title == "Onboarding v3 · Welcome screens"
                } && engine.captureExternalActivityOwner() != null
            } }
            main {
                val state = controller.state.value
                initialTab = checkNotNull(state.tab)
                initialProfile = checkNotNull(state.space).websiteProfile
                native = checkNotNull(engine.captureExternalActivityOwner())
                initialNativeView = observedViews[checkNotNull(state.tab).id]?.get()?.let { WeakReference(it) }
                initialNativeSession = initialNativeView?.get()?.session
                initialToken = checkNotNull(activity.window.decorView.windowToken)
                controller.openField(newTab = true, privately = initiallyPrivate)
                field = checkNotNull(controller.captureFieldPresentation())
            }
        } catch (error: Throwable) { runCatching { close() }.exceptionOrNull()?.let(error::addSuppressed); throw error }
    }

    /** Main only. The privacy target may change, but the original public page/Field owner cannot. */
    fun current(): Boolean = alive.get() && !activity.isDestroyed && !activity.isFinishing && activity.hasWindowFocus() &&
        activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && ValueAnimator.areAnimatorsEnabled() &&
        listOf(Settings.Global.ANIMATOR_DURATION_SCALE, Settings.Global.TRANSITION_ANIMATION_SCALE, Settings.Global.WINDOW_ANIMATION_SCALE)
            .all { Settings.Global.getFloat(activity.contentResolver, it, 1f) == 1f } &&
        activity.window.decorView.isAttachedToWindow && activity.window.decorView.windowToken === initialToken &&
        controller.fieldPresentationCurrent(field) && engine.ownsExternalActivity(native) && controller.state.value.let {
            it.surface == BrowserSurface.FIELD && it.fieldIsNewTab && it.fieldText.isEmpty() &&
                it.selectedSpaceId == "work" && it.tab?.id == initialTab?.id && it.tab?.url == initialTab?.url &&
                it.space?.websiteProfile == initialProfile && !it.privateContentBlocked && it.find == null && !it.loading
        }

    /** Observer only. Acceptance continues to use current(), unchanged above.
     * Read only public Engine APIs and original fixture View/session equality. Never exports identities. */
    fun sourceComponents(): Map<String, Boolean> {
        check(android.os.Looper.myLooper() === android.os.Looper.getMainLooper())
        val values = linkedMapOf("fixtureAlive" to alive.get(), "activityCreated" to ::activity.isInitialized,
            "controllerCreated" to controllerCreated, "engineCreated" to engineCreated,
            "fieldLeaseCaptured" to ::field.isInitialized, "nativeOwnerCaptured" to ::native.isInitialized)
        if (!::activity.isInitialized || !controllerCreated || !engineCreated || !::field.isInitialized || !::native.isInitialized) return values
        val state = controller.state.value
        values["activityNotDestroyed"] = !activity.isDestroyed
        values["activityNotFinishing"] = !activity.isFinishing
        values["windowFocused"] = activity.hasWindowFocus()
        values["lifecycleResumed"] = activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
        values["nativeAnimatorsEnabled"] = ValueAnimator.areAnimatorsEnabled()
        values["animationScalesOne"] = listOf(Settings.Global.ANIMATOR_DURATION_SCALE, Settings.Global.TRANSITION_ANIMATION_SCALE,
            Settings.Global.WINDOW_ANIMATION_SCALE).all { Settings.Global.getFloat(activity.contentResolver, it, 1f) == 1f }
        values["decorAttached"] = activity.window.decorView.isAttachedToWindow
        values["originalWindowToken"] = activity.window.decorView.windowToken === initialToken
        values["fieldPresentationCurrent"] = controller.fieldPresentationCurrent(field)
        values["capturedNativeOwnerCurrent"] = engine.ownsExternalActivity(native)
        values["capturedNativeOwnerAlive"] = engine.externalActivityAlive(native)
        values["currentNativeOwnerAvailable"] = engine.captureExternalActivityOwner() != null
        values["surfaceIsField"] = state.surface == BrowserSurface.FIELD
        values["fieldIsNewTab"] = state.fieldIsNewTab
        values["fieldDraftEmpty"] = state.fieldText.isEmpty()
        values["selectedSpaceOriginal"] = state.selectedSpaceId == "work"
        values["selectedTabOriginal"] = state.tab?.id == initialTab?.id
        values["selectedUrlOriginal"] = state.tab?.url == initialTab?.url
        values["selectedProfileOriginal"] = state.space?.websiteProfile == initialProfile
        values["privateContentUnblocked"] = !state.privateContentBlocked
        values["findAbsent"] = state.find == null
        values["snapshotNotLoading"] = !state.loading
        val originalView = initialNativeView?.get()
        val originalSession = initialNativeSession
        values["originalNativeViewCaptured"] = originalView != null
        values["originalNativeSessionCaptured"] = originalSession != null
        values["originalNativeViewStillBound"] = originalView != null && initialTab?.id?.let { observedViews[it]?.get() } === originalView
        values["originalNativeSessionStillBound"] = originalView != null && originalSession != null && originalView.session === originalSession
        values["originalNativeSessionOwned"] = originalSession != null && engine.owns(originalSession)
        values["originalNativeSessionTabOriginal"] = originalSession != null && engine.tabId(originalSession) == initialTab?.id
        return values
    }

    private fun forgetObservedView(id: String, view: GeckoView) {
        if (observedViews[id]?.get() === view) observedViews.remove(id)
    }

    suspend fun close() = withContext(NonCancellable) {
        if (!alive.getAndSet(false)) return@withContext
        try { scenario?.close() } finally {
            try { main {
                composeRoot = null
                observedViews.clear(); initialNativeView = null; initialNativeSession = null
                scope.cancel()
                if (engineCreated) {
                    if (controllerCreated) controller.state.value.spaces.flatMap { it.tabs }.forEach { engine.close(it.id) }
                    engine.dispose()
                }
            } } finally { if (::server.isInitialized) server.close() }
        }
    }

    private fun asset(name: String, expectedSha: String, limit: Int): ByteArray {
        check(name in setOf("mira-public.json", "figma.html"))
        val bytes = instrumentation.context.assets.open("paired-field/$name").use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                val read = input.read(buffer, 0, minOf(buffer.size, limit + 1 - output.size()))
                if (read < 0) break
                check(read > 0); output.write(buffer, 0, read); check(output.size() <= limit)
            }
            output.toByteArray()
        }
        check(bytes.size in 1..limit && sha(bytes) == expectedSha)
        return bytes
    }

    private fun publicSnapshot(bytes: ByteArray, selectedUrl: String): BrowserSnapshot {
        val root = JSONObject(bytes.toString(Charsets.UTF_8))
        check(root.keys().asSequence().toSet() == setOf("schema", "phoneWorldSha256", "selectedSpace", "spaces"))
        check(root.getInt("schema") == 1 && root.getString("phoneWorldSha256") == PHONE_WORLD_SHA && root.getString("selectedSpace") == "work")
        val rows = root.getJSONArray("spaces")
        check(rows.length() == 3)
        val spaces = (0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            check(row.keys().asSequence().toSet() == setOf("id", "name", "emoji", "tint", "pins", "kept", "today", "current"))
            val id = row.getString("id"); check(id in setOf("personal", "work", "lisbon"))
            val tabs = mutableListOf<BrowserTab>(); val folders = mutableListOf<BrowserFolder>()
            fun tab(value: JSONObject, place: TabPlace, folder: String? = null) {
                check(tabs.size < 64)
                val tabId = value.getString("id"); val raw = value.optString("url")
                val url = if (tabId == "work-figma-onb") selectedUrl else when {
                    raw.isBlank() -> "about:blank"
                    raw.startsWith("localhost:") -> "http://$raw"
                    raw.startsWith("https://") || raw.startsWith("http://") -> raw
                    else -> "https://$raw"
                }
                tabs += BrowserTab(tabId, url, value.getString("title"), place, createdAt = tabs.size.toLong() + 1, folderId = folder)
            }
            fun list(values: JSONArray, action: (JSONObject) -> Unit) {
                check(values.length() <= 64); for (i in 0 until values.length()) action(values.getJSONObject(i))
            }
            list(row.getJSONArray("pins")) { tab(it, TabPlace.PINNED) }
            list(row.getJSONArray("kept")) { entry ->
                check(entry.length() == 1)
                if (entry.has("folder")) {
                    val folder = entry.getJSONObject("folder"); val key = folder.getString("id")
                    folders += BrowserFolder(key, folder.getString("name"), open = folder.getBoolean("open"))
                    list(folder.getJSONArray("tabs")) { tab(it, TabPlace.KEPT, key) }
                } else tab(entry.getJSONObject("tab"), TabPlace.KEPT)
            }
            list(row.getJSONArray("today")) { tab(it, TabPlace.TODAY) }
            check(tabs.map { it.id }.toSet().size == tabs.size)
            val tint = row.getJSONArray("tint"); check(tint.length() == 3)
            val rgb = (0..2).map { tint.getInt(it).also { value -> check(value in 0..255) } }
            val color = 0xFF000000L or (rgb[0].toLong() shl 16) or (rgb[1].toLong() shl 8) or rgb[2].toLong()
            BrowserSpace(id, row.getString("name"), row.getString("emoji"), color, ownSignIns = true,
                tabs = tabs, currentTabId = row.getString("current"), folders = folders).also { check(it.currentTab != null) }
        }
        check(spaces.map { it.id } == listOf("personal", "work", "lisbon"))
        return BrowserSnapshot(spaces = spaces, selectedSpaceId = "work", settings = BrowserSettings(appearance = BrowserAppearance.LIGHT, welcomed = true))
    }

    /** Exact one immutable HTML route. No wildcard proxy, cookies, grants, auth or request logs. */
    private class Page(private val html: ByteArray, nonce: String) : Closeable {
        private val running = AtomicBoolean(true)
        private val active = AtomicReference<Socket?>(null)
        private val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).apply { soTimeout = 250 }
        private val path = "/paired-field-$nonce"
        val url = "http://127.0.0.1:${server.localPort}$path"
        private val worker = Thread({
            try {
                while (running.get()) {
                    val socket = try { server.accept() } catch (_: java.net.SocketTimeoutException) { continue }
                    active.set(socket)
                    try { socket.use {
                        it.soTimeout = 600
                        val input = it.getInputStream()
                        val request = StringBuilder()
                        while (request.length < 4096 && !request.endsWith("\r\n\r\n")) {
                            val value = input.read(); if (value < 0) break; request.append(value.toChar())
                        }
                        check(request.endsWith("\r\n\r\n"))
                        val accepted = request.lineSequence().first() == "GET $path HTTP/1.1"
                        val bytes = if (accepted) html else ByteArray(0)
                        it.getOutputStream().apply {
                            write(("HTTP/1.1 ${if (accepted) "200 OK" else "404 Not Found"}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Security-Policy: default-src 'none'; img-src data:; style-src 'unsafe-inline'\r\nCache-Control: no-store\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n").toByteArray())
                            write(bytes); flush()
                        }
                    } } catch (_: Exception) { /* Fixed test route refusal; no request/error content retained. */ }
                    finally { active.compareAndSet(socket, null) }
                }
            } catch (_: Exception) { /* Closing the original server releases accept. */ }
        }, "OwnedPairedFieldPage").apply { isDaemon = true; start() }
        override fun close() {
            running.set(false); runCatching { server.close() }; active.getAndSet(null)?.let { runCatching { it.close() } }
            worker.interrupt(); worker.join(1500); check(!worker.isAlive)
        }
    }

    companion object {
        const val PHONE_WORLD_SHA = "27c661ccf86cae2bfc93116db919f95297f6a21f0089d81a2240668610737fa7"
        const val MIRA_ASSET_SHA = "8cf16db3ac0d827d8409729bf09f2dfcc560d342fc4b56dcf1310b905b3993ad"
        const val FIGMA_SHA = "d5e3a27c99d188f250e90e635ea5fca5d163df315aca9c67cd9498f2ba1f0d9c"
        fun create(nonce: String) = PairedFieldScene(nonce)
        private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
        private suspend fun await(reason: String, current: suspend () -> Boolean) {
            val end = android.os.SystemClock.elapsedRealtime() + 30_000
            while (!current()) { check(android.os.SystemClock.elapsedRealtime() < end) { "Timed out: $reason" }; delay(16) }
        }
    }
}

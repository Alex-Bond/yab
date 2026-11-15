package dev.yab.android

import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.ReaderPreferencesStore
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.model.BrowserWorkspaceWindow
import dev.yab.browser.model.ReaderTheme
import dev.yab.browser.ui.BrowserReaderCard
import dev.yab.browser.ui.BrowserReaderPresentation
import dev.yab.browser.ui.BrowserTheme
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real owned FINGER events on three controlled product components. No Main, Gecko or Sync result. */
class ModalBackdropGestureTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val underlay = AtomicInteger()
    private val events = JSONArray()

    @Test(timeout = 90_000)
    fun firstRunOriginalChoiceAcceptsSmallMoveWithoutTouchingItsPageUnderlay(): Unit = proof("first-run") {
        val scene = scene()
        val host = FirstRunPresentation.RenderedHost(scene::current)
        val original = TabletJoinPresentation.Source(null, 1, true)
        val flow = main {
            FirstRunPresentation({ original }, { null }).also {
                check(it.begin(it.control(host)))
                check(it.advance(checkNotNull(it.timer(host, false)), FirstRunPresentation.DefaultBrowser(false, false), finish = { false }))
            }
        }
        val haptics = AtomicInteger()
        try {
            mount { FirstRunScreen(flow, host, (compose.activity.application as YabApplication).sync,
                tablet = false, window = scene.geometry, spaces = emptyList(),
                role = FirstRunPresentation.DefaultBrowser(false, false), macName = "Mac",
                requestDefault = { error("This component gesture must not request a role") }, finish = { false },
                copy = { error("This component gesture must not copy") }, haptic = { haptics.incrementAndGet() }) }
            background(scene, "welcome")
            assertEquals(0, underlay.get())
            assertEquals(FirstRunPresentation.Step.CHOOSE, flow.state.value.step)
            val node = compose.onNodeWithTag("welcome.noMac").assertIsDisplayed().assertIsEnabled().fetchSemanticsNode()
            val old = dev.yab.browser.originalRenderedClick(node)
            move(scene, node)
            compose.waitForIdle()
            assertEquals(FirstRunPresentation.Step.NO_MAC, flow.state.value.step)
            assertEquals(1, haptics.get()); assertEquals(0, underlay.get())
            main { old() }
            assertEquals(FirstRunPresentation.Step.NO_MAC, flow.state.value.step)
            assertEquals(1, haptics.get())
        } finally { main { host.retire(); flow.close() } }
    }

    @Test(timeout = 90_000)
    fun preparationOriginalRetryAcceptsSmallMoveWithoutTouchingItsPageUnderlay(): Unit = proof("preparation") {
        val scene = scene()
        val host = FirstRunPresentation.RenderedHost(scene::current)
        val source = FirstRunPreparation.Source(true, false, false, null, 1, false)
        val owner = FirstRunPreparation { source }
        val accepted = AtomicInteger()
        try {
            mount { FirstRunPreparationScreen(owner, host, tablet = false, retry = { control ->
                owner.begin(control)?.let { ticket ->
                    if (owner.beforeCall(ticket)) accepted.incrementAndGet()
                    owner.complete(ticket, failed = false)
                }
            }) }
            background(scene, "welcome.preparation")
            assertEquals(0, underlay.get()); assertEquals(0, accepted.get())
            val node = compose.onNodeWithTag("welcome.preparation.retry").assertIsDisplayed().assertIsEnabled().fetchSemanticsNode()
            val old = dev.yab.browser.originalRenderedClick(node)
            move(scene, node)
            compose.waitForIdle()
            assertEquals(1, accepted.get()); assertEquals(0, underlay.get())
            main { old() }
            assertEquals(1, accepted.get())
            assertEquals(FirstRunPreparation.Phase.PENDING, owner.state.value.phase)
        } finally { main { host.retire(); owner.retireHost(host) } }
    }

    @Test(timeout = 90_000)
    fun readerOriginalThemeAndClosingBackdropAcceptSmallMoveWithoutTouchingItsPageUnderlay(): Unit = proof("reader") {
        val scene = scene()
        val store = ReaderPreferencesStore()
        val presentation = BrowserReaderPresentation(store, scene::current)
        try {
            mount { BrowserReaderCard(presentation) }
            val node = compose.onNodeWithTag("reader.card.theme.paper").assertIsDisplayed().assertIsEnabled().fetchSemanticsNode()
            val old = dev.yab.browser.originalRenderedClick(node)
            assertEquals(ReaderTheme.ORIGINAL, store.snapshot().theme)
            move(scene, node)
            compose.waitForIdle()
            assertEquals(ReaderTheme.PAPER, store.snapshot().theme)
            assertEquals(1L, store.themeRevision); assertEquals(0, underlay.get())
            main { old() }
            assertEquals(1L, store.themeRevision)
            background(scene, "reader.layer")
            compose.waitForIdle()
            assertFalse(presentation.state.value.shown)
            assertEquals(0, underlay.get())
        } finally { main { presentation.drop() } }
    }

    private fun mount(content: @Composable () -> Unit) {
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
            Box(Modifier.fillMaxSize()) {
                Box(Modifier.matchParentSize().testTag("gesture.underlay").clickable { underlay.incrementAndGet() })
                content()
            }
        } }
        compose.waitForIdle()
    }

    /** Original Activity/window owner, unrelated to any Main/browser/Sync capability. */
    private inner class Scene {
        val host = compose.activity
        private val entrance = checkNotNull(host.intent)
        private val configuration = Configuration(host.resources.configuration)
        val window = host.window
        val decor = window.decorView
        val token = checkNotNull(decor.windowToken)
        val frame = Rect(host.windowManager.currentWindowMetrics.bounds)
        private val density = host.resources.displayMetrics.density
        val geometry = BrowserWorkspaceWindow(frame.width() / density.toDouble(), frame.height() / density.toDouble())
        val slop = ViewConfiguration.get(host).scaledTouchSlop.toFloat()
        init { check(!frame.isEmpty && density.isFinite() && density > 0f && slop > 1f) }
        fun current(): Boolean = !host.isFinishing && !host.isDestroyed && host.intent === entrance &&
            host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && host.hasWindowFocus() &&
            host.resources.configuration == configuration && host.window === window && window.decorView === decor &&
            Rect(host.windowManager.currentWindowMetrics.bounds) == frame && decor.isAttachedToWindow && decor.isShown &&
            decor.hasWindowFocus() && decor.windowToken === token
    }

    private suspend fun scene(): Scene {
        compose.waitUntil(10_000) { compose.activity.hasWindowFocus() }
        return main { Scene().also { check(it.current()) } }
    }

    private suspend fun background(scene: Scene, tag: String) {
        val node = compose.onNodeWithTag(tag).fetchSemanticsNode()
        val frame = node.boundsInWindow
        // Genuine empty background above the compact card, not any child/control fallback.
        move(scene, node, Offset(frame.center.x, frame.top + frame.height * .06f))
    }

    /** One original target, one real stream, no replacement lookup or input retry. */
    private suspend fun move(scene: Scene, node: SemanticsNode, position: Offset? = null) {
        val original = main {
            check(scene.current())
            val root = checkNotNull(node.root)
            val view = (root as? ViewRootForTest)?.view ?: error("Original component has no native root")
            check(view.rootView === scene.decor && view.windowToken === scene.token)
            Target(scene, node, root, view, position)
        }
        val root = checkNotNull(instrumentation.uiAutomation.rootInActiveWindow)
        val nativeWindow: Int
        val nativeBounds = Rect()
        try {
            check(root.packageName?.toString() == instrumentation.targetContext.packageName)
            nativeWindow = root.windowId; root.getBoundsInScreen(nativeBounds)
            check(!nativeBounds.isEmpty && nativeBounds.contains(original.start.x.toInt(), original.start.y.toInt()) &&
                nativeBounds.contains(original.end.x.toInt(), original.end.y.toInt()))
        } finally { root.recycle() }
        suspend fun current(target: Boolean): Boolean {
            if (!main { if (target) original.current() else scene.current() }) return false
            val active = instrumentation.uiAutomation.rootInActiveWindow
            return try { active != null && active.packageName?.toString() == instrumentation.targetContext.packageName &&
                active.windowId == nativeWindow && Rect().also(active::getBoundsInScreen) == nativeBounds }
            finally { active?.recycle() }
        }
        val began = SystemClock.uptimeMillis()
        var down = false
        var primary: Throwable? = null
        fun send(action: Int, point: Offset) {
            val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
            val coords = MotionEvent.PointerCoords().apply {
                x = point.x; y = point.y; size = 1f; pressure = if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) 0f else 1f
            }
            val event = MotionEvent.obtain(began, SystemClock.uptimeMillis(), action, 1, arrayOf(properties), arrayOf(coords),
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { check(instrumentation.uiAutomation.injectInputEvent(event, true)) }
            finally { event.recycle() }
        }
        try {
            check(current(true)); send(MotionEvent.ACTION_DOWN, original.start); down = true; events.put("DOWN")
            delay(24)
            check(current(true)); send(MotionEvent.ACTION_MOVE, original.end); events.put("SMALL_MOVE")
            delay(24)
            check(current(true)); send(MotionEvent.ACTION_UP, original.end); down = false; events.put("UP")
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            if (down) {
                val cleanup = runCatching {
                    if (current(false)) { send(MotionEvent.ACTION_CANCEL, original.end); events.put("CANCEL") }
                    else events.put("CANCEL_OMITTED_OWNER_CHANGED")
                }.exceptionOrNull()
                if (cleanup != null) { if (primary != null) primary.addSuppressed(cleanup) else throw cleanup }
            }
        }
    }

    private class Target(val scene: ModalBackdropGestureTest.Scene, val node: SemanticsNode,
        private val root: Any, private val view: View, position: Offset?) {
        private val info = node.layoutInfo
        private val id = node.id
        private val frame = node.boundsInWindow
        private val origin = origin(view)
        private val sourcePoint = position ?: frame.center
        private val delta = minOf(scene.slop * .25f, frame.width * .1f, frame.height * .1f)
        val start = sourcePoint + Offset(origin.first.toFloat(), origin.second.toFloat())
        val end = start + Offset(delta, 0f)
        init { check(delta >= 1f && delta < scene.slop && frame.contains(sourcePoint) && frame.contains(sourcePoint + Offset(delta, 0f))) }
        fun current(): Boolean = scene.current() && view.isAttachedToWindow && view.isShown && view.hasWindowFocus() &&
            view.rootView === scene.decor && view.windowToken === scene.token && origin(view) == origin &&
            node.root === root && node.layoutInfo === info && info.isAttached && info.isPlaced && info.semanticsId == id &&
            node.boundsInWindow == frame
        companion object {
            private fun origin(view: View): Pair<Int, Int> {
                val screen = IntArray(2); val window = IntArray(2)
                view.getLocationOnScreen(screen); view.getLocationInWindow(window)
                return screen[0] - window[0] to screen[1] - window[1]
            }
        }
    }

    private fun proof(name: String, body: suspend () -> Unit): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true" && Build.VERSION.SDK_INT == 36)
        check(ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand("getprop ro.kernel.qemu"))
            .bufferedReader().use { it.readText() }.trim() == "1")
        var complete = false
        try { body(); complete = true }
        finally {
            val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation")
            check(folder.isDirectory || folder.mkdirs())
            File(folder, "modal-gesture-$name.json").writeText(JSONObject().put("schema", 1).put("completed", complete)
                .put("events", events).put("underlayActivations", underlay.get()).put("componentOnly", true)
                .put("mainOrBridgeProof", false).put("screenshotsCaptured", false).toString(2))
        }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
}

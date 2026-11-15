package dev.yab.browser

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dev.yab.android.EngineTestActivity
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import java.io.File
import java.util.IdentityHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView

/** Fixture-only compositor observation; the production content delegate is never replaced. */
internal class RecoveryPaintObservation {
    private val paints = IdentityHashMap<GeckoSession, Long>()
    private val callbacks = IdentityHashMap<GeckoSession, Runnable>()
    private var capped = false
    fun watchBound(view: GeckoView) {
        val session = checkNotNull(view.session)
        if (!paints.containsKey(session) && paints.size >= 16) { capped = true; return }
        val compositor = session.compositorController
        // GeckoView.setSession installs its own uncover callback. Observe only
        // after binding, and preserve that actual callback on every replacement.
        if (compositor.firstPaintCallback === callbacks[session]) return
        if (!paints.containsKey(session)) paints[session] = 0
        val original = compositor.firstPaintCallback
        val callback = Runnable {
            original?.run()
            paints[session] = System.nanoTime()
        }
        callbacks[session] = callback
        compositor.firstPaintCallback = callback
    }
    fun receipt(session: GeckoSession, after: Long): JSONObject {
        return JSONObject().put("firstCompositeAfterBoundary", (paints[session] ?: 0) > after)
            .put("observationCapped", capped).put("contentVerifiedByCallback", false)
    }
}

/** Positive native/screen pixels and fixed UI enums, never a general accessibility dump. */
internal class RecoveryViewportProof(private val paints: RecoveryPaintObservation) {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val output get() = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/recovery-viewport").apply { check(isDirectory || mkdirs()) }
    private data class Target(val view: GeckoView, val session: GeckoSession, val bounds: Rect, val tab: String, val url: String?)
    private data class UiProjection(val ownActive: Boolean, val otherForeground: Boolean, val crash: Boolean, val anr: Boolean, val complete: Boolean) {
        val accepted get() = ownActive && !otherForeground && !crash && !anr && complete
        fun json() = JSONObject().put("ownApplicationWindowActive", ownActive).put("appErrorDialog", crash)
            .put("nonApplicationWindowForeground", otherForeground).put("appNotRespondingDialog", anr).put("enumerationComplete", complete)
    }
    private data class Pixels(val samples: Int, val dark: Int, val difference: Double) {
        val fraction get() = dark.toDouble() / samples
        fun json() = JSONObject().put("sampleCount", samples).put("darkPixelCount", dark)
            .put("darkFraction", fraction).put("meanNativeScreenChannelDifference", difference)
    }

    /** Before-fault control must pass the same rendering gate as the recovered page. */
    suspend fun requireVisible(label: String, browser: BrowserController, engine: GeckoEngine,
        after: Long = 0, controlInk: Double? = null): Double {
        require(label in setOf("foreground-before", "foreground-recovered", "deferred-before", "deferred-recovered"))
        val attempts = JSONArray()
        val deadline = SystemClock.elapsedRealtime() + 15_000
        var answer: Double? = null
        var failure = "NO_VISIBLE_NATIVE_CONTENT"
        try {
            while (SystemClock.elapsedRealtime() < deadline) {
                val ui = projectUi()
                val row = JSONObject().put("ui", ui.json())
                if (attempts.length() < 40) attempts.put(row)
                if (!ui.accepted) {
                    failure = "SYSTEM_OBSTRUCTION_OR_INCOMPLETE_UI_PROJECTION"
                    if (ui.crash || ui.anr || ui.otherForeground) break
                    // A fresh own Activity can precede its accessibility root.
                    // Keep the same gate and deadline; capture no rejected UI.
                    delay(400)
                    continue
                }
                val screen = requireNotNull(instrumentation.uiAutomation.takeScreenshot()) { "Owned viewport screenshot unavailable" }
                try {
                    val afterCapture = projectUi()
                    row.put("uiAfterCapture", afterCapture.json())
                    if (!afterCapture.accepted) { failure = "WINDOW_CHANGED_DURING_CAPTURE"; break }
                    // Only a verified own foreground screen is persisted. A rejected
                    // system/foreign/incomplete projection retains fixed JSON only.
                    save(screen, "$label-screen.png")
                    val target = main { target(browser, engine) }
                    val paint = main { paints.receipt(target.session, after) }
                    row.put("paint", paint)
                    if (!paint.getBoolean("firstCompositeAfterBoundary") || paint.getBoolean("observationCapped")) {
                        failure = "CURRENT_NATIVE_PAINT_NOT_READY"
                    } else {
                        val native = capture(target.view)
                        try {
                            save(native, "$label-native.png")
                            val unchanged = main { current(target, browser, engine) }
                            row.put("sameVisibleOwner", unchanged).put("nativeWidthPx", native.width).put("nativeHeightPx", native.height)
                            if (!unchanged) { failure = "VISIBLE_OWNER_CHANGED"; break }
                            val nativePixels = pixels(native, screen, target.bounds, true)
                            val screenPixels = pixels(native, screen, target.bounds, false)
                            row.put("native", nativePixels.json()).put("screen", screenPixels.json())
                            val minimum = maxOf(.008, (controlInk ?: .008) * .5)
                            if (nativePixels.fraction >= minimum && screenPixels.fraction >= minimum &&
                                nativePixels.difference <= 20.0 && screenPixels.fraction / nativePixels.fraction in .5..2.0) {
                                row.put("contentPixelsVerified", true)
                                answer = screenPixels.fraction; failure = "NONE"; break
                            }
                            failure = "BLANK_OR_DIFFERENT_DRAWN_VIEWPORT"
                        } finally { native.recycle() }
                    }
                } finally { screen.recycle() }
                delay(400)
            }
        } finally {
            File(output, "$label.json").writeText(JSONObject().put("passed", answer != null).put("failure", failure)
                .put("firstPaintSource", "pinned Gecko158 CompositorController.firstPaintCallback; composition only, not content or a presentation fence")
                .put("pixelRegion", "native view interior x10..90 percent y15..65 percent, 128x96 native pixel samples")
                .put("positiveControlInkFraction", controlInk ?: JSONObject.NULL).put("minimumInkFraction", maxOf(.008, (controlInk ?: .008) * .5))
                .put("fault", "exact normal-UID APK Gecko child Process.killProcess")
                .put("rawOsDataCollected", false).put("systemDialogsDismissed", false)
                .put("physicalDeviceSmoothnessVerified", false).put("attempts", attempts).toString(2))
        }
        return checkNotNull(answer) { "Native recovery was not visibly accepted: $failure" }
    }

    private fun target(browser: BrowserController, engine: GeckoEngine): Target {
        val state = browser.state.value
        val tab = checkNotNull(state.tab)
        check(!state.page.loading && state.page.error == null && engine.hasLiveSession(tab.id))
        val session = engine.session(tab, checkNotNull(state.space).websiteProfile)
        val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<EngineTestActivity>().single()
        val found = mutableListOf<GeckoView>()
        fun visit(view: View) {
            if (view is GeckoView && view.session === session && view.isAttachedToWindow && view.isShown && view.tag == tab.id) found.add(view)
            if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(activity.window.decorView)
        val view = found.single()
        val position = IntArray(2).also(view::getLocationOnScreen)
        val rect = Rect(position[0], position[1], position[0] + view.width, position[1] + view.height)
        check(rect.width() >= 200 && rect.height() >= 200)
        return Target(view, session, rect, tab.id, tab.url)
    }
    private fun current(target: Target, browser: BrowserController, engine: GeckoEngine): Boolean {
        val state = browser.state.value
        return state.tab?.id == target.tab && state.tab?.url == target.url && !state.page.loading && state.page.error == null &&
            target.view.isAttachedToWindow && target.view.isShown && target.view.session === target.session && engine.ownsInteractive(target.session)
    }
    private suspend fun capture(view: GeckoView): Bitmap = main {
        val pending = CompletableDeferred<Bitmap>()
        view.capturePixels().accept({ bitmap ->
            if (bitmap == null) pending.completeExceptionally(IllegalStateException("Native pixel capture returned no bitmap"))
            else if (!pending.complete(bitmap)) bitmap.recycle()
        }, { pending.completeExceptionally(IllegalStateException("Native pixel capture failed")) })
        try { withTimeout(5_000) { pending.await() } } finally { if (!pending.isCompleted) pending.cancel() }
    }
    private fun pixels(native: Bitmap, screen: Bitmap, rect: Rect, nativeValues: Boolean): Pixels {
        check(rect.left >= 0 && rect.top >= 0 && rect.right <= screen.width && rect.bottom <= screen.height)
        var dark = 0; var difference = 0.0; var count = 0
        repeat(96) { y -> repeat(128) { x ->
            val fx = .1 + .8 * (x + .5) / 128; val fy = .15 + .5 * (y + .5) / 96
            val a = native.getPixel((fx * native.width).toInt().coerceIn(0, native.width - 1), (fy * native.height).toInt().coerceIn(0, native.height - 1))
            val b = screen.getPixel(rect.left + (fx * rect.width()).toInt(), rect.top + (fy * rect.height()).toInt())
            val value = if (nativeValues) a else b
            val r = value ushr 16 and 255; val g = value ushr 8 and 255; val blue = value and 255
            if (maxOf(r, g, blue) < 160 && value ushr 24 >= 200) dark++
            difference += (kotlin.math.abs((a ushr 16 and 255) - (b ushr 16 and 255)) +
                kotlin.math.abs((a ushr 8 and 255) - (b ushr 8 and 255)) + kotlin.math.abs((a and 255) - (b and 255))) / 3.0
            count++
        } }
        return Pixels(count, dark, difference / count)
    }
    private fun projectUi(): UiProjection {
        val own = instrumentation.targetContext.packageName
        val errorIds = setOf("android:id/aerr_close", "android:id/aerr_restart", "android:id/aerr_report", "android:id/aerr_mute")
        var seen = 0; var complete = true; var crash = false; var anr = false; var active = false; var other = false
        fun visit(node: AccessibilityNodeInfo) {
            if (++seen > 512) { complete = false; return }
            val system = node.packageName?.toString() in setOf("android", "com.android.systemui")
            if (system && node.viewIdResourceName in errorIds) crash = true
            if (system && node.viewIdResourceName == "android:id/aerr_wait") anr = true
            if (node.childCount > 128) { complete = false; return }
            repeat(node.childCount) { index -> node.getChild(index)?.let { child -> try { visit(child) } finally { child.recycle() } } }
        }
        val windows = instrumentation.uiAutomation.windows
        if (windows.size > 32) complete = false
        windows.take(32).forEach { window ->
            val root = window.root
            if (root == null) { if (window.isActive || window.isFocused) complete = false }
            else try {
                if (window.isActive || window.isFocused) {
                    if (root.packageName?.toString() == own) active = true else other = true
                }
                visit(root)
            } finally { root.recycle() }
        }
        val foreground = instrumentation.uiAutomation.rootInActiveWindow
        if (foreground == null) complete = false
        else try {
            if (foreground.packageName?.toString() == own) active = true else other = true
            visit(foreground)
        } finally { foreground.recycle() }
        return UiProjection(active, other, crash, anr, complete)
    }
    private fun save(bitmap: Bitmap, name: String) {
        File(output, name).outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
    }
    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }
}

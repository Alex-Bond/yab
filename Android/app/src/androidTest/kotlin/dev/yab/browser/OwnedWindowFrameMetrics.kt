package dev.yab.browser

import android.animation.ValueAnimator
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.view.Choreographer
import android.view.FrameMetrics
import android.view.View
import android.view.ViewTreeObserver
import android.view.Window
import androidx.activity.ComponentActivity
import androidx.annotation.RequiresApi
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Test-only reported HWUI work for one original Window. No presentation or pixel capture API. */
@RequiresApi(36)
internal class OwnedWindowFrameMetrics private constructor(
    private val activity: ComponentActivity,
    private val nonce: String,
    private val scenario: String,
    private val sourceCurrent: () -> Boolean,
) {
    private val revoked = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val lock = Any()
    private val data = LongArray(MAX_ROWS * COLUMNS.size)
    private val worker = Worker()
    private lateinit var originalWindow: Window
    private lateinit var originalDecor: View
    private lateinit var originalToken: IBinder
    private var focusObserver: ViewTreeObserver? = null
    private var choreographer: Choreographer? = null
    private var rowCount = 0
    private var reports = 0L
    private var dropped = 0L
    private var foreignWindowReports = 0L
    private var rejectedAfterRevocation = 0L
    private var metricReadFailed = false
    private var capped = false
    @Volatile private var expired = false
    @Volatile private var sourceCheckFailed = false
    @Volatile private var activeStart = 0L
    @Volatile private var activeEnd = 0L
    private var explicitEnd = false
    private var sourceAtBegin = false
    private var sourceAtEnd = false
    private var registered = false
    private var listenerRemoved = false
    private var mainDetached = false
    private var barrierReached = false
    private var workerStopped = false
    private var cleanupWaitFailed = false
    private var width = 0
    private var height = 0
    private var density = 0f
    private var fontScale = 0f
    private var refreshHz = 0f
    private var scalesBefore: List<Float> = emptyList()
    private var scalesAfter: List<Float> = emptyList()
    private var nativeAnimatorsBefore = false
    private var nativeAnimatorsAfter = false

    private val lifecycleObserver = LifecycleEventObserver { _, _ ->
        if (activity.lifecycle.currentState != Lifecycle.State.RESUMED) revoked.set(true)
    }
    private val focusListener = ViewTreeObserver.OnWindowFocusChangeListener { focused ->
        if (!focused) revoked.set(true)
    }
    private val heartbeat = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (closed.get()) return
            current()
            if (activeStart != 0L && activeEnd == 0L && System.nanoTime() - activeStart > MAX_ACTIVE_NANOS) {
                expired = true
            }
            if (!revoked.get() && !expired) choreographer?.postFrameCallback(this)
        }
    }
    private val listener = Window.OnFrameMetricsAvailableListener { window, metrics, lost ->
        // FrameMetrics is reused by the framework. Copy primitive fields here, never retain it.
        synchronized(lock) {
            if (closed.get() || activeStart == 0L) return@synchronized
            if (window !== originalWindow) {
                foreignWindowReports++
                revoked.set(true)
                return@synchronized
            }
            if (revoked.get()) { rejectedAfterRevocation++; return@synchronized }
            val now = System.nanoTime()
            if (activeEnd == 0L && now - activeStart > MAX_ACTIVE_NANOS) expired = true
            if (expired) return@synchronized
            reports++
            if (lost < 0) { metricReadFailed = true; return@synchronized }
            dropped += lost.toLong()
            if (rowCount == MAX_ROWS) { capped = true; return@synchronized }
            val offset = rowCount * COLUMNS.size
            try {
                for (index in METRICS.indices) data[offset + index] = metrics.getMetric(METRICS[index])
                data[offset + 12] = now
                data[offset + 13] = lost.toLong()
                rowCount++
            } catch (_: RuntimeException) {
                metricReadFailed = true
            }
        }
    }

    /** Main only. A lost source or Window can never become current again in this take. */
    private fun current(): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (revoked.get() || closed.get()) return false
        val source = try { sourceCurrent() } catch (_: Exception) { sourceCheckFailed = true; false }
        val display = activity.resources.displayMetrics
        val result = source && activity.window === originalWindow && originalWindow.decorView === originalDecor &&
            !activity.isFinishing && !activity.isDestroyed && activity.lifecycle.currentState == Lifecycle.State.RESUMED &&
            activity.hasWindowFocus() && originalDecor.hasWindowFocus() && originalDecor.isAttachedToWindow &&
            originalDecor.windowToken === originalToken && originalDecor.isHardwareAccelerated &&
            originalDecor.width == width && originalDecor.height == height &&
            display.density == density && activity.resources.configuration.fontScale == fontScale
        if (!result) revoked.set(true)
        return result
    }

    private fun scales(): List<Float> = listOf(
        Settings.Global.ANIMATOR_DURATION_SCALE,
        Settings.Global.TRANSITION_ANIMATION_SCALE,
        Settings.Global.WINDOW_ANIMATION_SCALE,
    ).map { Settings.Global.getFloat(activity.contentResolver, it, 1f) }

    private suspend fun arm() {
        check(Build.VERSION.SDK_INT == 36)
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(Looper.myLooper() != Looper.getMainLooper())
        worker.start()
        check(withContext(Dispatchers.IO) { worker.ready.await(2, TimeUnit.SECONDS) }) { "metrics_worker_not_ready" }
        val handler = checkNotNull(worker.handler)
        withContext(Dispatchers.Main.immediate) {
            check(activity.packageName == InstrumentationRegistry.getInstrumentation().targetContext.packageName)
            originalWindow = activity.window
            originalDecor = originalWindow.decorView
            originalToken = checkNotNull(originalDecor.windowToken)
            width = originalDecor.width
            height = originalDecor.height
            density = activity.resources.displayMetrics.density
            fontScale = activity.resources.configuration.fontScale
            refreshHz = checkNotNull(originalDecor.display).refreshRate
            check(width == 1206 && height == 2622 && density == 3f && fontScale == 1f)
            check(refreshHz.isFinite() && refreshHz in 30f..240f)
            check(current()) { "metrics_original_owner_refused" }
            scalesBefore = scales()
            nativeAnimatorsBefore = ValueAnimator.areAnimatorsEnabled()
            check(scalesBefore.all { it == 1f } && nativeAnimatorsBefore) { "metrics_original_animators_refused" }
            activity.lifecycle.addObserver(lifecycleObserver)
            focusObserver = originalDecor.viewTreeObserver.also { it.addOnWindowFocusChangeListener(focusListener) }
            choreographer = Choreographer.getInstance().also { it.postFrameCallback(heartbeat) }
            originalWindow.addOnFrameMetricsAvailableListener(listener, handler)
            registered = true
        }
    }

    /** Call after recorder ACK, immediately before the existing input sequence. Uses System.nanoTime. */
    suspend fun begin() = withContext(Dispatchers.Main.immediate) {
        check(registered && activeStart == 0L && activeEnd == 0L && !closed.get())
        sourceAtBegin = current()
        check(sourceAtBegin && scales() == scalesBefore && ValueAnimator.areAnimatorsEnabled()) { "metrics_begin_refused" }
        activeStart = System.nanoTime()
    }

    /** Call after the existing settle tail, without changing input or animation timing. */
    suspend fun end() = withContext(Dispatchers.Main.immediate) {
        check(activeStart != 0L && activeEnd == 0L && !closed.get())
        activeEnd = System.nanoTime()
        explicitEnd = true
        if (activeEnd - activeStart > MAX_ACTIVE_NANOS) expired = true
        sourceAtEnd = current()
        scalesAfter = scales()
        nativeAnimatorsAfter = ValueAnimator.areAnimatorsEnabled()
        check(sourceAtEnd && !expired && scalesAfter == scalesBefore && nativeAnimatorsAfter) { "metrics_end_refused" }
    }

    private suspend fun finish(actionCompleted: Boolean): JSONObject = withContext(Dispatchers.IO) {
        // Post non-cancellable cleanup, so a stalled Main cannot leave an input-active token.
        val detached = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            try {
                if (registered && activeEnd == 0L) activeEnd = System.nanoTime()
                if (registered && !current()) sourceAtEnd = false
                choreographer?.removeFrameCallback(heartbeat)
                activity.lifecycle.removeObserver(lifecycleObserver)
                focusObserver?.takeIf { it.isAlive }?.removeOnWindowFocusChangeListener(focusListener)
                if (registered) {
                    originalWindow.removeOnFrameMetricsAvailableListener(listener)
                    listenerRemoved = true
                }
                mainDetached = true
            } catch (_: Exception) {
                // Fixed booleans describe failure. No exception text or OS data is exported.
            } finally { detached.countDown() }
        }
        fun await(latch: CountDownLatch): Boolean = try {
            latch.await(2, TimeUnit.SECONDS).also { reached ->
                if (!reached) cleanupWaitFailed = true
            }
        } catch (_: InterruptedException) {
            cleanupWaitFailed = true
            false
        }
        try {
            await(detached)
            val barrier = CountDownLatch(1)
            if (worker.handler?.post { barrier.countDown() } == true) barrierReached = await(barrier)
        } catch (_: RuntimeException) {
            cleanupWaitFailed = true
        } finally {
            try {
                worker.requestStop()
                try { worker.join(2_000) } catch (_: InterruptedException) { cleanupWaitFailed = true }
                workerStopped = !worker.isAlive
            } finally {
                // Also closes publication if a cleanup operation itself failed.
                closed.set(true)
            }
        }
        val copied = synchronized(lock) { data.copyOf(rowCount * COLUMNS.size) }
        val rows = JSONArray()
        for (offset in copied.indices step COLUMNS.size) {
            rows.put(JSONArray().apply { for (column in COLUMNS.indices) put(copied[offset + column]) })
        }
        JSONObject().put("schema", 1).put("kind", "owned-window-frame-metrics")
            .put("nonce", nonce).put("scenario", scenario).put("clock", "System.nanoTime")
            .put("widthPx", width).put("heightPx", height).put("density", density).put("fontScale", fontScale)
            .put("refreshHz", refreshHz).put("maxActiveNanos", MAX_ACTIVE_NANOS).put("maxRows", MAX_ROWS)
            .put("primitiveBufferBytes", data.size * 8).put("maxJsonBytes", MAX_JSON_BYTES)
            .put("actionCompleted", actionCompleted).put("explicitBegin", activeStart != 0L).put("explicitEnd", explicitEnd)
            .put("activeStartNanos", activeStart).put("activeEndNanos", activeEnd)
            .put("sourceAtBegin", sourceAtBegin).put("sourceAtEnd", sourceAtEnd)
            .put("permanentlyRevoked", revoked.get()).put("sourceCheckFailed", sourceCheckFailed)
            .put("listenerRegistered", registered).put("listenerRemoved", listenerRemoved).put("mainDetached", mainDetached)
            .put("barrierReached", barrierReached).put("workerStopped", workerStopped)
            .put("cleanupWaitFailed", cleanupWaitFailed)
            .put("scalesBefore", JSONArray(scalesBefore)).put("scalesAfter", JSONArray(scalesAfter))
            .put("nativeAnimatorsBefore", nativeAnimatorsBefore).put("nativeAnimatorsAfter", nativeAnimatorsAfter)
            .put("reportsReceived", reports).put("droppedReports", dropped).put("foreignWindowReports", foreignWindowReports)
            .put("rejectedAfterRevocation", rejectedAfterRevocation).put("bufferCapped", capped).put("sliceExpired", expired)
            .put("metricReadFailed", metricReadFailed).put("columns", JSONArray(COLUMNS)).put("rows", rows)
            .put("choreographerUsedOnlyForLeaseChecks", true).put("presentationFenceMeasured", false)
            .put("completePhysicalFrameCensusVerified", false).put("wholeSceneTimingCoverageVerified", false)
            .put("pairedFrameParityVerified", false).put("physicalDeviceSmoothnessVerified", false)
    }

    private class Worker : HandlerThread("owned-window-metrics") {
        val ready = CountDownLatch(1)
        @Volatile var handler: Handler? = null
        private val stopRequested = AtomicBoolean(false)
        override fun onLooperPrepared() {
            handler = Handler(looper)
            if (stopRequested.get()) looper.quitSafely()
            ready.countDown()
        }
        fun requestStop() {
            stopRequested.set(true)
            handler?.post { Looper.myLooper()?.quitSafely() }
        }
    }

    companion object {
        const val MAX_ROWS = 1024
        const val MAX_ACTIVE_NANOS = 4_000_000_000L
        const val MAX_JSON_BYTES = 524_288
        val COLUMNS = listOf("intendedVsyncNanos", "vsyncNanos", "totalNanos", "deadlineNanos", "gpuNanos",
            "layoutNanos", "drawNanos", "syncNanos", "commandNanos", "swapNanos", "firstDraw", "timelineId",
            "callbackNanos", "reportsDropped")
        private val METRICS = intArrayOf(FrameMetrics.INTENDED_VSYNC_TIMESTAMP, FrameMetrics.VSYNC_TIMESTAMP,
            FrameMetrics.TOTAL_DURATION, FrameMetrics.DEADLINE, FrameMetrics.GPU_DURATION,
            FrameMetrics.LAYOUT_MEASURE_DURATION, FrameMetrics.DRAW_DURATION, FrameMetrics.SYNC_DURATION,
            FrameMetrics.COMMAND_ISSUE_DURATION, FrameMetrics.SWAP_BUFFERS_DURATION, FrameMetrics.FIRST_DRAW_FRAME,
            FrameMetrics.FRAME_TIMELINE_VSYNC_ID)

        /** Call off Main. Always detach and join before publishing; preserve the original block failure. */
        suspend fun <T> collect(
            activity: ComponentActivity,
            nonce: String,
            scenario: String,
            sourceCurrent: () -> Boolean,
            publish: (JSONObject) -> Unit,
            block: suspend (OwnedWindowFrameMetrics) -> T,
        ): T {
            require(nonce.matches(Regex("[a-f0-9]{32}")))
            require(scenario in setOf("pairEyesClose", "pairEyesOpen", "pairEyesReverse80", "pairEyesReverse160"))
            check(Looper.myLooper() != Looper.getMainLooper())
            val collector = OwnedWindowFrameMetrics(activity, nonce, scenario, sourceCurrent)
            var original: Throwable? = null
            var completed = false
            try {
                collector.arm()
                return block(collector).also { completed = true }
            } catch (error: Throwable) {
                original = error
                throw error
            } finally {
                withContext(NonCancellable) {
                    try {
                        val receipt = collector.finish(completed)
                        check(receipt.toString().toByteArray(Charsets.UTF_8).size <= MAX_JSON_BYTES) { "metrics_json_capped" }
                        publish(receipt)
                        check(collector.mainDetached && collector.listenerRemoved && collector.barrierReached && collector.workerStopped &&
                            !collector.cleanupWaitFailed) {
                            "metrics_cleanup_unconfirmed"
                        }
                        check(collector.activeStart != 0L && collector.explicitEnd && collector.sourceAtBegin && collector.sourceAtEnd &&
                            !collector.revoked.get() && !collector.expired && !collector.capped && !collector.metricReadFailed &&
                            !collector.sourceCheckFailed && collector.dropped == 0L && collector.foreignWindowReports == 0L &&
                            collector.rowCount > 0) { "metrics_report_slice_refused" }
                    } catch (error: Throwable) {
                        val prior = original
                        if (prior != null) prior.addSuppressed(error) else throw error
                    }
                }
            }
        }
    }
}

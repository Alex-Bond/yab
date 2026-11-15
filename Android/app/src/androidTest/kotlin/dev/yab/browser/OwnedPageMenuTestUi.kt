package dev.yab.browser

import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Fixed Menu controls only. Native input has no Compose test clock or ancestor-action fallback. */
internal class OwnedPageMenuTestUi(private val case: Case) {
    enum class Case { COMPONENT_REVERSAL, COMPONENT_REVOCATION, INTEGRATION_FUNCTIONAL, INTEGRATION_REVOCATION, HANDOFF }
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val own = instrumentation.targetContext.packageName
    private var capture: (() -> (() -> Boolean)?)? = null
    private var activeOwner: (() -> Boolean)? = null
    private val samples = ArrayDeque<JSONObject>()
    private var last = ""
    private var lastAt = 0L
    private data class Frame(val phase: String = "NONE", val running: Boolean = false, val interactive: Boolean = false, val count: Int = 0)
    @Volatile private var lastFrame = Frame()
    private var completed = false
    private var ownerBeforeCleanup: Boolean? = null
    private var cancelAttempted = false
    private var cancelConfirmed = false
    private var cancelRefused = false

    init { check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") }

    /** Captured before any await, and checked on Main before DOWN and before UP. */
    fun bind(owner: () -> (() -> Boolean)?) { capture = owner }
    fun frame(phase: String, running: Boolean, interactive: Boolean) {
        require(phase in setOf("MOUNTED", "OPENING", "OPEN", "DRAGGING", "CLOSING", "CLOSED", "HANDING_OFF", "HANDED_OFF", "REVOKED"))
        lastFrame = Frame(phase, running, interactive, (lastFrame.count + 1).coerceAtMost(100000))
    }

    private data class Hit(val bounds: Rect, val rootBounds: Rect, val window: Int, val enabled: Boolean)
    private data class Projection(val hit: Hit?, val complete: Boolean, val visible: Int, val foreign: Boolean,
        val hosts: Int, val window: Int?, val rootBounds: Rect?)

    private fun project(label: String): Projection {
        require(label in setOf("Page menu", "Keep", "Kept", "Copy", "Copy Link", "Share", "Find on Page", "Close Find", "Queue Fixture Action", "Edit address"))
        val root = instrumentation.uiAutomation.rootInActiveWindow
        var visited = 0; var capped = false; var truncated = false; var missing = false; var unowned = false
        var exactText = 0; var exactDescription = 0; var visible = 0; var actionable = 0
        var hosts = 0
        var nestedTextMatches = 0; var unrelatedVisibleLabels = 0
        var first: Hit? = null; var action: Hit? = null
        val descriptions = mutableListOf<Hit>()
        val states = JSONArray()
        val owned = root?.packageName?.toString() == own
        var rootWindow: Int? = null
        var capturedRootBounds: Rect? = null
        if (root != null) try {
            val window = root.windowId
            val rootBounds = Rect().also(root::getBoundsInScreen)
            if (owned) { rootWindow = window; capturedRootBounds = Rect(rootBounds) }
            if (rootBounds.isEmpty) missing = true
            fun visit(node: AccessibilityNodeInfo, describedAncestor: Hit? = null,
                withinMenu: Boolean = false, disabledAncestors: List<Rect> = emptyList()) {
                if (visited >= 512) { capped = true; return }; visited++
                if (node.packageName?.toString() != own || node.windowId != window) { unowned = true; return }
                val menuHost = node.isVisibleToUser && node.paneTitle?.toString() == "Page Menu"
                if (menuHost) hosts++
                val inMenu = withinMenu || menuHost
                val nodeBounds = Rect().also(node::getBoundsInScreen)
                val inheritedDisabled = disabledAncestors.any { it.contains(nodeBounds) }
                val effectiveEnabled = node.isEnabled && !inheritedDisabled
                var ownDescription: Hit? = null
                val text = node.text?.toString() == label
                val description = node.contentDescription?.toString() == label
                if (text) exactText++
                if (description) exactDescription++
                if (text || description) {
                    val bounds = nodeBounds
                    val shown = node.isVisibleToUser && !bounds.isEmpty && rootBounds.contains(bounds)
                    val click = node.isClickable || node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }
                    if (shown) {
                        visible++
                        val value = Hit(Rect(bounds), Rect(rootBounds), window, effectiveEnabled)
                        if (first == null) first = value
                        if (click) { actionable++; if (action == null) action = value }
                        if (description) { descriptions += value; ownDescription = value }
                        else if (text && node.className?.toString() == "android.widget.TextView" && !click &&
                            describedAncestor != null && describedAncestor.bounds.contains(bounds)) nestedTextMatches++
                        else unrelatedVisibleLabels++
                    }
                    if (states.length() < 4) states.put(JSONObject().put("visible", shown).put("enabled", node.isEnabled)
                        .put("textExact", text).put("descriptionExact", description)
                        .put("effectiveEnabled", effectiveEnabled).put("disabledAncestorWithinMenu", inheritedDisabled)
                        .put("exactDescriptionAncestor", describedAncestor != null && describedAncestor.bounds.contains(bounds))
                        .put("knownTextClass", node.className?.toString() == "android.widget.TextView")
                        .put("clickable", node.isClickable).put("actionClick", click)
                        .put("bounds", JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).map { it.coerceIn(-1000000, 1000000) })))
                }
                val count = node.childCount
                if (count > 128) truncated = true
                val disabled = if (inMenu && !node.isEnabled && !nodeBounds.isEmpty && rootBounds.contains(nodeBounds)) {
                    if (disabledAncestors.size >= 32) { truncated = true; disabledAncestors }
                    else disabledAncestors + Rect(nodeBounds)
                } else disabledAncestors
                for (i in 0 until count.coerceAtMost(128)) {
                    if (visited >= 512) { capped = true; break }
                    val child = node.getChild(i)
                    if (child == null) missing = true else try { visit(child, ownDescription ?: describedAncestor, inMenu, disabled) } finally { child.recycle() }
                }
            }
            if (owned) visit(root) else unowned = true
        } finally { root.recycle() }
        val complete = owned && !capped && !truncated && !missing && !unowned
        // An exact labelled control plus its nonactionable text child is unambiguous.
        // No actionable ancestor or arbitrary parent is selected.
        val exactDescriptionWithText = descriptions.singleOrNull()?.takeIf {
            visible == 1 + nestedTextMatches && unrelatedVisibleLabels == 0
        }
        val hit = if (!complete || actionable > 1) null else if (actionable == 1) action
            else (first.takeIf { visible == 1 } ?: exactDescriptionWithText)
        val row = JSONObject().put("label", label).put("rootPresent", root != null).put("rootOwned", owned)
            .put("complete", complete).put("visited", visited).put("capped", capped).put("childrenTruncated", truncated)
            .put("missingChild", missing).put("unownedNode", unowned)
            .put("textMatches", exactText.coerceAtMost(999)).put("descriptionMatches", exactDescription.coerceAtMost(999))
            .put("visibleMatches", visible.coerceAtMost(999)).put("directActionMatches", actionable.coerceAtMost(999))
            .put("directDescriptionMatches", descriptions.size.coerceAtMost(999))
            .put("nestedExactTextMatches", nestedTextMatches.coerceAtMost(999))
            .put("unrelatedVisibleLabels", unrelatedVisibleLabels.coerceAtMost(999))
            .put("menuHosts", hosts.coerceAtMost(999))
            .put("uniqueControl", hit != null).put("knownControlStates", states)
        val signature = row.toString(); val now = SystemClock.elapsedRealtime()
        if (signature != last || now - lastAt >= 1000) {
            last = signature; lastAt = now
            if (samples.size == 32) samples.removeFirst()
            samples.addLast(row); save()
        }
        return Projection(hit, complete, visible, root != null && !owned, hosts, rootWindow, capturedRootBounds)
    }

    suspend fun visible(label: String) {
        await("visible exact Menu control") { val value = project(label); check(!value.foreign); value.complete && value.visible > 0 }
    }
    suspend fun absent(label: String) {
        await("complete owned absence") { val value = project(label); check(!value.foreign); value.complete && value.visible == 0 }
    }
    suspend fun disabled(label: String) {
        await("disabled exact Menu control") { val value = project(label); check(!value.foreign); value.hit?.enabled == false }
    }
    suspend fun menuAbsent() {
        await("original Menu host absent") { val value = project("Page menu"); check(!value.foreign); value.complete && value.hosts == 0 }
    }
    suspend fun click(label: String) {
        val owner = withContext(Dispatchers.Main.immediate) { capture?.invoke() }
        check(owner != null) { "Original Menu fixture owner unavailable" }
        activeOwner = owner
        var hit: Hit? = null
        var originalWindow: Pair<Int, Rect>? = null
        await("unique exact Menu action") {
            check(withContext(Dispatchers.Main.immediate) { owner() }) { "Original Menu source replaced before input" }
            val value = project(label); check(!value.foreign) { "Foreign active root refused" }
            val window = value.window
            val bounds = value.rootBounds
            if (window != null && bounds != null && !bounds.isEmpty) {
                val current = window to bounds
                if (originalWindow == null) originalWindow = current
                else check(originalWindow == current) { "Original owned Menu window changed before input" }
            }
            hit = value.hit?.takeIf { it.enabled }; hit != null
        }
        val first = checkNotNull(hit)
        check(withContext(Dispatchers.Main.immediate) { owner() })
        delay(96)
        fun same() = project(label).let { !it.foreign && it.complete && it.hit == first }
        check(same()) { "Original Menu control moved before DOWN" }
        check(withContext(Dispatchers.Main.immediate) { owner() })
        val down = SystemClock.uptimeMillis()
        var sentDown = false; var sentUp = false
        fun originalWindowCurrent(): Boolean {
            val root = instrumentation.uiAutomation.rootInActiveWindow ?: return false
            return try {
                root.packageName?.toString() == own && root.windowId == first.window &&
                    Rect().also(root::getBoundsInScreen) == first.rootBounds
            } finally { root.recycle() }
        }
        fun event(action: Int) {
            val properties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
            val coordinates = arrayOf(MotionEvent.PointerCoords().apply {
                x = first.bounds.exactCenterX(); y = first.bounds.exactCenterY(); pressure = 1f; size = 1f
            })
            val input = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, properties, coordinates,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { check(instrumentation.uiAutomation.injectInputEvent(input, true)) { "Native owned Menu input refused" } }
            finally { input.recycle() }
        }
        try {
            event(MotionEvent.ACTION_DOWN); sentDown = true
            delay(32)
            check(withContext(Dispatchers.Main.immediate) { owner() })
            check(same()) { "Original Menu control changed during press" }
            event(MotionEvent.ACTION_UP); sentUp = true
        } catch (error: Throwable) {
            if (sentDown && !sentUp) withContext(NonCancellable) {
                cancelAttempted = true
                try {
                    check(withContext(Dispatchers.Main.immediate) { owner() } && originalWindowCurrent()) {
                        "Original Menu cancellation owner unavailable"
                    }
                    event(MotionEvent.ACTION_CANCEL); cancelConfirmed = true
                } catch (cancel: Throwable) { cancelRefused = true; error.addSuppressed(cancel) }
            }
            throw error
        } finally { save() }
    }

    suspend fun finish(passed: Boolean) {
        completed = passed
        if (ownerBeforeCleanup == null) ownerBeforeCleanup = withContext(NonCancellable + Dispatchers.Main.immediate) {
            runCatching { activeOwner?.invoke() == true }.getOrDefault(false)
        }
        save(ownerBeforeCleanup)
    }
    private suspend fun await(name: String, condition: suspend () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 15000
        while (!condition()) { check(SystemClock.elapsedRealtime() < end) { "Timed out: $name" }; delay(16) }
    }
    private fun save(ownerCurrent: Boolean? = null) {
        val frame = lastFrame
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        File(folder, "page-menu-ui-${case.name.lowercase()}.json").writeText(JSONObject()
            .put("case", case.name).put("completed", completed).put("ownerCurrent", ownerCurrent ?: JSONObject.NULL)
            .put("phase", frame.phase).put("running", frame.running).put("interactive", frame.interactive).put("drawCallbacks", frame.count)
            .put("cancelAttempted", cancelAttempted).put("cancelConfirmed", cancelConfirmed).put("cancelRefused", cancelRefused)
            .put("realNativeUi", true).put("composeTestClockInstalled", false).put("pairedIosPresentedFrames", false)
            .put("samples", JSONArray(samples.toList())).toString())
    }
}

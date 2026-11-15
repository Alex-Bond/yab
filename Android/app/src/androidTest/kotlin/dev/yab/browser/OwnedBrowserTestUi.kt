package dev.yab.browser

import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dev.yab.android.EngineTestActivity
import dev.yab.android.MainActivity
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

/** Native fixture input only. No permission changes, parent-action fallback or foreign window input. */
internal class OwnedBrowserTestUi(private val case: Case) {
    enum class Case { ACTIONS_FIND, ACTIONS_PIN, BACK_HISTORY, LINK_PREVIEW, DOWNLOAD_PUBLIC, DOWNLOAD_PRIVATE, WORKSPACE, APP_WORKSPACE, AUTOFILL }
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val own = instrumentation.targetContext.packageName
    private val samples = JSONArray()
    private val started = SystemClock.elapsedRealtime()
    private var lastProjection = ""
    private var lastSample = 0L
    private var completeOwnedProjection = false
    private var labelMatches = 0
    private var visibleLabelMatches = 0
    private var captureOwner: (() -> (() -> Boolean)?)? = null
    private var boundBrowser: BrowserController? = null

    init {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        save()
    }

    /** Called on Main; every input captures this source once, rather than retargeting after an await. */
    fun bind(browser: BrowserController, engine: GeckoEngine, operation: () -> Any? = { null }) {
        boundBrowser = browser
        captureOwner = factory@ {
            val state = browser.state.value
            val tab = state.tab ?: return@factory null
            val profile = state.space?.websiteProfile ?: return@factory null
            val space = state.selectedSpaceId
            val native = engine.captureExternalActivityOwner() ?: return@factory null
            val value = operation()
            val captured: () -> Boolean = {
                val current = browser.state.value
                val currentTab = current.tab
                !current.loading && !current.privateContentBlocked && current.selectedSpaceId == space &&
                    current.surface == state.surface && current.surfaceEpoch == state.surfaceEpoch &&
                    current.space?.websiteProfile == profile && currentTab != null && currentTab.id == tab.id && currentTab.url == tab.url &&
                    engine.ownsExternalActivity(native) && operation() == value
            }
            captured
        }
    }

    suspend fun <T> run(block: suspend () -> T): T {
        try {
            checkpoint("start")
            val result = block()
            checkpoint("completed")
            return result
        } catch (error: Throwable) {
            withContext(NonCancellable) { runCatching { checkpoint("failed") } }
            throw error
        } finally {
            withContext(NonCancellable) { runCatching { checkpoint("finished") } }
            save()
        }
    }

    suspend fun checkpoint(phase: String) {
        require(phase.matches(Regex("[a-z_]{1,40}")))
        val row = JSONObject().put("phase", phase)
        withTimeoutOrNull(2_000) {
            withContext(Dispatchers.Main) {
                val stages = JSONObject()
                for (stage in Stage.values()) {
                    val activities = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(stage)
                        .filter { it.packageName == own && (it is MainActivity || it is EngineTestActivity) }
                    stages.put(stage.name, activities.size.coerceAtMost(8))
                    if (stage == Stage.RESUMED) row.put("ownResumedWindowFocused", activities.any { it.hasWindowFocus() })
                }
                row.put("ownActivityStages", stages)
                boundBrowser?.state?.value?.let { state ->
                    row.put("browserLoading", state.loading).put("pageLoading", state.page.loading)
                        .put("privateBlocked", state.privateContentBlocked).put("tabPresent", state.tab != null)
                        .put("surface", state.surface.name).put("pageError", state.page.error != null)
                    state.find?.let { find -> row.put("findSearching", find.searching).put("findFailed", find.failed)
                        .put("findCurrent", find.result.current.coerceIn(0, 100_000)).put("findTotal", find.result.total.coerceIn(0, 100_000)) }
                }
            }
        }
        val root = instrumentation.uiAutomation.rootInActiveWindow
        try { row.put("activeRootPresent", root != null).put("activeRootOwned", root?.packageName?.toString() == own) }
        finally { root?.recycle() }
        record(row)
    }

    private data class Hit(val bounds: Rect, val window: Int, val rootBounds: Rect,
        val node: AccessibilityNodeInfo) : AutoCloseable {
        override fun close() { node.recycle() }
    }

    /** Exact text OR description, unique visible owned node, no indexed-query dependency. */
    private fun find(label: String): Hit? {
        require(label.length in 1..256)
        if (android.os.Build.VERSION.SDK_INT >= 34) check(instrumentation.uiAutomation.clearCache())
        val root = instrumentation.uiAutomation.rootInActiveWindow
        val row = JSONObject().put("phase", "label_projection").put("activeRootPresent", root != null)
        completeOwnedProjection = false; labelMatches = 0; visibleLabelMatches = 0
        var ownedTree = false
        var visited = 0; var capped = false; var truncated = false; var missingChild = false
        var unownedNode = false
        var exact = 0; var exactText = 0; var exactDescription = 0
        val states = JSONArray()
        var found: Hit? = null
        var actionable: Hit? = null
        var actionMatches = 0
        if (root != null) try {
            val owned = root.packageName?.toString() == own
            row.put("activeRootOwned", owned)
            val rootBounds = Rect().also(root::getBoundsInScreen)
            fun visit(node: AccessibilityNodeInfo) {
                if (visited >= 512) { capped = true; return }
                visited++
                if (node.packageName?.toString() != own || node.windowId != root.windowId) { unownedNode = true; return }
                val text = node.text?.toString() == label
                val description = node.contentDescription?.toString() == label
                if (text) exactText++
                if (description) exactDescription++
                if (text || description) {
                    val bounds = Rect().also(node::getBoundsInScreen)
                    val inside = !bounds.isEmpty && rootBounds.contains(bounds)
                    val visible = node.isVisibleToUser && inside
                    if (visible) {
                        exact++
                        if (node.isEnabled && found == null) found = Hit(bounds, node.windowId, Rect(rootBounds), AccessibilityNodeInfo.obtain(node))
                        val directAction = node.isClickable || node.isLongClickable || node.actionList.any {
                            it.id == AccessibilityNodeInfo.ACTION_CLICK || it.id == AccessibilityNodeInfo.ACTION_LONG_CLICK
                        }
                        if (node.isEnabled && directAction) {
                            actionMatches++
                            if (actionable == null) actionable = Hit(bounds, node.windowId, Rect(rootBounds), AccessibilityNodeInfo.obtain(node))
                        }
                    }
                    if (states.length() < 4) states.put(JSONObject().put("text", text).put("description", description)
                        .put("visible", node.isVisibleToUser).put("enabled", node.isEnabled).put("insideRoot", inside)
                        .put("clickable", node.isClickable).put("longClickable", node.isLongClickable)
                        .put("clickAction", node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK })
                        .put("longAction", node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_LONG_CLICK })
                        .put("bounds", boundsJson(bounds)))
                }
                val children = node.childCount
                if (children > 128) truncated = true
                for (index in 0 until children.coerceAtMost(128)) {
                    if (visited >= 512) { capped = true; break }
                    val child = node.getChild(index)
                    if (child == null) { missingChild = true; continue }
                    try { visit(child) } finally { child.recycle() }
                }
            }
            if (owned && !rootBounds.isEmpty) { ownedTree = true; visit(root) }
        } catch (error: Throwable) {
            found?.close(); found = null; actionable?.close(); actionable = null
            throw error
        } finally { root.recycle() }
        completeOwnedProjection = ownedTree && !capped && !truncated && !missingChild && !unownedNode
        labelMatches = exactText + exactDescription
        visibleLabelMatches = exact
        // Gecko exposes one exact-labelled link control plus a non-actionable text child.
        // Select the unique directly labelled control, never search for an actionable ancestor.
        // Two independently actionable exact matches remain ambiguous and cannot receive input.
        if (completeOwnedProjection && actionMatches == 1) {
            found?.close(); found = actionable; actionable = null
        } else if (exact != 1 || actionMatches > 1 || !completeOwnedProjection) { found?.close(); found = null }
        actionable?.close()
        row.put("visited", visited).put("capped", capped).put("childrenTruncated", truncated)
            .put("childUnavailable", missingChild).put("unownedNode", unownedNode).put("visibleExactMatches", exact.coerceAtMost(999))
            .put("textMatches", exactText.coerceAtMost(999)).put("descriptionMatches", exactDescription.coerceAtMost(999))
            .put("directActionMatches", actionMatches.coerceAtMost(999))
            .put("uniqueEnabledOwnedMatch", found != null).put("knownLabelStates", states)
        val signature = row.toString()
        if (signature != lastProjection || SystemClock.elapsedRealtime() - lastSample >= 1_000) {
            lastProjection = signature; lastSample = SystemClock.elapsedRealtime(); record(row)
        }
        return found
    }

    fun hasLabel(label: String): Boolean {
        find(label)?.close()
        return completeOwnedProjection && visibleLabelMatches > 0
    }

    /** Absence cannot pass because a foreign, unavailable or truncated tree was unreadable. */
    fun requireLabelAbsent(label: String) {
        find(label)?.close()
        check(completeOwnedProjection) { "Cannot prove absence outside the complete owned window" }
        check(labelMatches == 0) { "The protected fixture label remained in its owned accessibility tree" }
    }

    suspend fun requireOwnCurrent() {
        val owner = withContext(Dispatchers.Main) { captureOwner?.invoke() }
        check(owner != null && withContext(Dispatchers.Main) { owner() }) { "Owned native fixture source is no longer current" }
        val root = instrumentation.uiAutomation.rootInActiveWindow
        try { check(root?.packageName?.toString() == own) { "Owned fixture window is not active" } }
        finally { root?.recycle() }
    }

    suspend fun click(label: String) = act(label, longPress = false)
    suspend fun tap(label: String) = act(label, longPress = false, physical = true)
    suspend fun longPress(label: String, activated: (() -> Boolean)? = null) = act(label, longPress = true, activated = activated)

    private suspend fun act(label: String, longPress: Boolean, activated: (() -> Boolean)? = null, physical: Boolean = false) {
        val source = withContext(Dispatchers.Main) { captureOwner?.invoke() }
        check(source != null) { "Cannot capture the original owned fixture source" }
        val deadline = SystemClock.elapsedRealtime() + 30_000
        var captured: Hit? = null
        var stableSince = SystemClock.elapsedRealtime()
        // Prepare within this one captured source, before committing any DOWN.
        // Dialog entrance animation may still be moving its exact labelled control.
        // Once stable, the original window/bounds remain mandatory through UP.
        while (true) {
            check(withContext(Dispatchers.Main) { source() }) { "Fixture source changed before native control" }
            val next = find(label)
            val now = SystemClock.elapsedRealtime()
            val same = next != null && captured?.let {
                next.window == it.window && next.bounds == it.bounds && next.rootBounds == it.rootBounds
            } == true
            captured?.close(); captured = next
            if (!same) stableSince = now
            if (next != null && now - stableSince >= 128) break
            if (now >= deadline) {
                captured?.close()
                error("Exact owned native label did not become stable")
            }
            delay(32)
        }
        checkNotNull(captured).use { first ->
            delay(96)
            val same = find(label)
            same.use {
                check(it != null && it.window == first.window && it.bounds == first.bounds && it.rootBounds == first.rootBounds &&
                    withContext(Dispatchers.Main) { source() }) { "Owned control moved before native input" }
                val action = if (longPress) AccessibilityNodeInfo.ACTION_LONG_CLICK else AccessibilityNodeInfo.ACTION_CLICK
                val actionAvailable = (if (longPress) it.node.isLongClickable else it.node.isClickable) && it.node.actionList.any { item -> item.id == action }
                // A context-menu case must prove the real sustained touch. Gecko may
                // acknowledge ACTION_LONG_CLICK before any menu is actually opened.
                if (actionAvailable && !physical && !(longPress && activated != null)) {
                    check(it.node.performAction(action)) { "Same-node native action was refused" }
                    record(JSONObject().put("phase", "same_node_action").put("longPress", longPress).put("performed", true))
                } else {
                    pointer(first.bounds, first.window, source, if (longPress) ViewConfiguration.getLongPressTimeout().toLong() + 200 else 32, activated) {
                        find(label)?.use { hit -> hit.bounds == first.bounds && hit.window == first.window && hit.rootBounds == first.rootBounds } == true
                    }
                }
            }
        }
    }

    /** Workspace calls this with a captured target-session/view guard instead of a selected-tab lease. */
    suspend fun tapBounds(bounds: Rect, source: () -> Boolean) {
        val root = instrumentation.uiAutomation.rootInActiveWindow
        val window: Int
        try {
            check(root?.packageName?.toString() == own) { "Owned pane window is not active" }
            val currentRoot = checkNotNull(root)
            val rootBounds = Rect().also(currentRoot::getBoundsInScreen)
            check(!bounds.isEmpty && rootBounds.contains(bounds)) { "Pane bounds escaped the owned window" }
            window = currentRoot.windowId
        } finally { root?.recycle() }
        pointer(bounds, window, source, 32, null) { true }
    }

    private suspend fun pointer(bounds: Rect, window: Int, source: () -> Boolean, hold: Long,
        activated: (() -> Boolean)?, labelCurrent: () -> Boolean) {
        suspend fun current(): Boolean {
            if (!withContext(Dispatchers.Main) { source() }) return false
            val root = instrumentation.uiAutomation.rootInActiveWindow
            return try {
                root != null && root.packageName?.toString() == own && root.windowId == window &&
                    Rect().also(root::getBoundsInScreen).contains(bounds) && labelCurrent()
            } finally { root?.recycle() }
        }
        check(current()) { "Captured native target is stale before DOWN" }
        val began = SystemClock.uptimeMillis()
        var down = false
        var failure: Throwable? = null
        fun send(action: Int) {
            val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
            val point = MotionEvent.PointerCoords().apply {
                x = bounds.exactCenterX(); y = bounds.exactCenterY(); size = 1f
                pressure = if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) 0f else 1f
            }
            val event = MotionEvent.obtain(began, SystemClock.uptimeMillis(), action, 1, arrayOf(properties), arrayOf(point),
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { check(instrumentation.uiAutomation.injectInputEvent(event, true)) { "Owned native pointer event was refused" } }
            finally { event.recycle() }
        }
        try {
            send(MotionEvent.ACTION_DOWN); down = true
            delay(hold)
            if (!current()) {
                val root = instrumentation.uiAutomation.rootInActiveWindow
                val expectedModal = try {
                    root?.packageName?.toString() == own && hold > 32 && activated != null &&
                        withContext(Dispatchers.Main) { source() } && activated()
                } finally { root?.recycle() }
                check(expectedModal) { "Captured native target changed during the press" }
                // The real long press opened its expected own modal. Never send UP
                // into that new window; release the original stream with CANCEL.
                send(MotionEvent.ACTION_CANCEL); down = false
                record(JSONObject().put("phase", "long_press_opened_owned_modal").put("cancelConfirmed", true))
                return
            }
            send(MotionEvent.ACTION_UP); down = false
            record(JSONObject().put("phase", "native_pointer").put("longPress", hold > 32).put("upSent", true).put("bounds", boundsJson(bounds)))
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (down) {
                val cancelled = runCatching { send(MotionEvent.ACTION_CANCEL) }
                record(JSONObject().put("phase", "native_cancel").put("confirmed", cancelled.isSuccess))
                cancelled.exceptionOrNull()?.let { error -> failure?.addSuppressed(error) ?: throw error }
            }
        }
    }

    private fun boundsJson(bounds: Rect) = JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).map { it.coerceIn(-1_000_000, 1_000_000) })
    private fun record(row: JSONObject) {
        if (samples.length() >= 32) samples.remove(0)
        samples.put(row.put("elapsedMs", (SystemClock.elapsedRealtime() - started).coerceIn(0, 300_000)))
        save()
    }
    private fun save() = runCatching {
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
        val target = File(folder, "owned-browser-${case.name.lowercase()}.json")
        val pending = File(folder, target.name + ".tmp")
        pending.writeText(JSONObject().put("schema", 1).put("case", case.name).put("samples", samples).toString(2))
        check(pending.renameTo(target))
    }.let { Unit }
}

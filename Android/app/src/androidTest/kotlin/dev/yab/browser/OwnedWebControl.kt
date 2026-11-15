package dev.yab.browser

import android.graphics.Rect
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import java.util.ArrayDeque

/** Gecko's virtual document nodes are exposed by getChild even when Android's
 * findAccessibilityNodeInfosByText returns no result. Walk the actual owned
 * window; this still clicks the real accessibility node, never injected DOM. */
internal object OwnedWebControl {
    fun find(text: String, ignoreCase: Boolean = false, visible: Boolean = true, className: String? = null): AccessibilityNodeInfo? {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        // Gecko can publish new virtual nodes while Android retains their old
        // geometry. Read the current tree before targeting actual native input.
        if (Build.VERSION.SDK_INT >= 34) check(instrumentation.uiAutomation.clearCache())
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return null
        val own = instrumentation.targetContext.packageName
        if (root.packageName?.toString() != own) { root.recycle(); return null }
        val window = root.windowId
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var result: AccessibilityNodeInfo? = null
        var visited = 0
        var complete = true
        try {
            while (queue.isNotEmpty()) {
                val node = queue.removeFirst()
                try {
                    if (++visited > 3000 || node.packageName?.toString() != own || node.windowId != window) {
                        complete = false; break
                    }
                    val bounds = Rect().also(node::getBoundsInScreen)
                    if (result == null && (className == null || node.className?.toString() == className) &&
                        (!visible || node.isVisibleToUser && !bounds.isEmpty) &&
                        // Native optgroup rows indent their labels ("  Oslo").
                        // Match the exact words, retaining case/visibility/window
                        // checks, rather than failing on presentation whitespace.
                        (node.text?.toString()?.trim()?.equals(text.trim(), ignoreCase) == true ||
                         node.contentDescription?.toString()?.trim()?.equals(text.trim(), ignoreCase) == true)) {
                        result = AccessibilityNodeInfo.obtain(node)
                    }
                    if (node.childCount > 256) { complete = false; break }
                    repeat(node.childCount) { index ->
                        val child = node.getChild(index)
                        if (child == null) complete = false else queue.add(child)
                    }
                } finally { node.recycle() }
            }
        } finally {
            while (queue.isNotEmpty()) queue.removeFirst().recycle()
        }
        if (!complete) { result?.recycle(); return null }
        return result
    }
}

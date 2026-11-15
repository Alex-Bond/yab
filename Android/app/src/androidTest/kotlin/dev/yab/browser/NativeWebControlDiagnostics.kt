package dev.yab.browser

import android.graphics.Bitmap
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/** Failure evidence from this runner's own fictional page and app window only. */
internal object NativeWebControlDiagnostics {
    fun capture(label: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (InstrumentationRegistry.getArguments().getString("ownedEmulator") != "true") return
        runCatching {
            val context = instrumentation.targetContext
            val root = instrumentation.uiAutomation.rootInActiveWindow
            val owned = root?.packageName?.toString() == context.packageName
            val nodes = JSONArray()
            fun visit(node: AccessibilityNodeInfo) {
                try {
                    if (nodes.length() >= 256 || node.packageName?.toString() != context.packageName) return
                    val bounds = Rect().also(node::getBoundsInScreen)
                    nodes.put(JSONObject().put("class", node.className).put("text", node.text?.toString()?.take(240))
                        .put("description", node.contentDescription?.toString()?.take(240)).put("visible", node.isVisibleToUser)
                        .put("enabled", node.isEnabled).put("clickable", node.isClickable).put("bounds", bounds.toShortString()))
                    repeat(node.childCount.coerceAtMost(128)) { index -> node.getChild(index)?.let(::visit) }
                } finally { node.recycle() }
            }
            if (root != null) { if (owned) visit(root) else root.recycle() }
            val directory = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
            val name = "web-control-${System.currentTimeMillis()}"
            File(directory, "$name.json").writeText(JSONObject().put("label", label.take(120)).put("owned", owned)
                .put("nodes", nodes).put("nativeAcceptance", false).toString(2))
            if (owned) instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
                File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
        }
    }
}

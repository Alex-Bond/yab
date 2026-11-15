package dev.yab.browser

import android.os.Looper
import androidx.compose.ui.platform.InspectableValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.getOrNull
import androidx.test.platform.app.InstrumentationRegistry

/** Capture the app's original immutable onClick, while its rendered node is attached.
 * Compose 1.12's semantics wrapper reads LocalSoundEffect before calling onClick;
 * invoking that wrapper after node disposal throws before exercising app authority.
 * Tooling exposes the exact callback stored on the original ClickableElement.
 * No exception is swallowed, owner is reacquired, or replacement node searched.
 * Fresh clicks still use native input in the corresponding device scenarios. */
internal fun originalRenderedClick(node: SemanticsNode): () -> Boolean {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
    var captured: (() -> Boolean)? = null
    fun capture() {
        check(node.layoutInfo.isAttached)
        val semantic = checkNotNull(node.config.getOrNull(SemanticsActions.OnClick)?.action)
        val callbacks = node.layoutInfo.getModifierInfo().mapNotNull { info ->
            val value = info.modifier as? InspectableValue ?: return@mapNotNull null
            if (value.nameFallback !in setOf("clickable", "combinedClickable", "selectable")) return@mapNotNull null
            val callback = value.inspectableElements.singleOrNull { it.name == "onClick" }?.value
            @Suppress("UNCHECKED_CAST")
            callback as? (() -> Unit)
        }
        check(callbacks.size <= 1) { "Ambiguous original rendered click callback" }
        // Explicit app semantics without a ClickableElement already contain the
        // app action itself. A missing framework projection still fails normally.
        captured = callbacks.singleOrNull()?.let { action -> { action(); true } } ?: semantic
    }
    if (Looper.myLooper() == Looper.getMainLooper()) capture() else instrumentation.runOnMainSync { capture() }
    return checkNotNull(captured)
}

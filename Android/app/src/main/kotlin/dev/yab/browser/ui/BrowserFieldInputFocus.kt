package dev.yab.browser.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Focus ownership of the one movable Field editor, independent of its action lease.
 * A retired placement may clean up its own focus, but cannot clear a successor. */
internal class BrowserFieldInputFocus {
    private var focused by mutableStateOf<Binding?>(null)
    private var revision = 0L

    fun bind(): Binding = Binding(this)

    internal class Binding internal constructor(private val focus: BrowserFieldInputFocus) {
        private var sawKeyboard = false
        val ownsFocus: Boolean get() = focus.focused === this

        /** The actual editor calls this only after its original input is current. */
        fun acquired() {
            if (!ownsFocus) { sawKeyboard = false; focus.focused = this; focus.revision++ }
        }

        /** Blur/disposal still releases the original token after its action is revoked. */
        fun released() {
            if (ownsFocus) { sawKeyboard = false; focus.focused = null; focus.revision++ }
        }

        fun clear(clearFocus: () -> Unit, hideKeyboard: () -> Unit): Boolean {
            if (!ownsFocus) return false
            sawKeyboard = false
            focus.focused = null
            val release = ++focus.revision
            clearFocus()
            // clearFocus dispatches synchronous focus callbacks. A newly acquired
            // editor, even one blurred again, must never receive this old hide.
            if (focus.focused == null && focus.revision == release) hideKeyboard()
            return true
        }

        fun keyboardShown() { if (ownsFocus) sawKeyboard = true }

        /** A first hidden sample in a replacement placement is not a dismissal. */
        fun takeKeyboardDismissal(): Boolean {
            if (!ownsFocus || !sawKeyboard) return false
            sawKeyboard = false
            return true
        }
    }
}

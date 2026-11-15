package dev.yab.browser.ui

/** Callback lifetime of the actual keyed Field input, not a new input capability.
 * Binding a replacement retires the old callbacks before Compose removes the
 * old CoreTextField, whose blur can otherwise publish a collapsed selection. */
internal class BrowserFieldEditorNode {
    private var node: Binding? = null
    private var focused: Binding? = null

    fun bind(): Binding {
        node?.retire()
        return Binding(this).also { node = it }
    }

    fun retire() { node?.retire() }

    internal class Binding internal constructor(private val editor: BrowserFieldEditorNode) {
        private var retired = false

        fun current(): Boolean = !retired && editor.node === this

        fun retire() {
            retired = true
            if (editor.node === this) editor.node = null
        }

        /** Fresh unfocused accessibility selection and IME composition remain valid. */
        fun change(inputCurrent: () -> Boolean, apply: () -> Unit): Boolean {
            if (!current() || !inputCurrent() || !current()) return false
            apply()
            return true
        }

        fun acquired(): Boolean {
            if (!current()) return false
            editor.focused = this
            return true
        }

        /** Old blur may release its own claim, even retired, but never a new node's. */
        fun released(release: () -> Unit): Boolean {
            if (editor.focused !== this) return false
            editor.focused = null
            release()
            return true
        }
    }
}

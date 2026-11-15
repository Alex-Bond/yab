package dev.yab.browser.ui

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import dev.yab.browser.model.BrowserState
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.WebsiteProfile

/** A delayed composition echo must never roll a newer native IME edit back. */
internal fun reconcileFieldEditorValue(value: TextFieldValue, renderedText: String,
    currentText: String, sourceCurrent: Boolean): TextFieldValue =
    if (!sourceCurrent || renderedText != currentText || value.text == renderedText) value
    else TextFieldValue(renderedText, TextRange(renderedText.length))

/** Logical UI value domain. Full-window placement and foreground control generations
 * do not erase an ordinary draft; account invalidation already advances surfaceEpoch. */
internal data class BrowserFieldEditorOwner(
    val epoch: Long,
    val space: String,
    val tab: String?,
    val newTab: Boolean,
    val privately: Boolean,
    val profile: WebsiteProfile?,
    val privateBoundary: Long,
    val blocked: Boolean,
) {
    companion object {
        fun from(state: BrowserState, privateBoundary: Long) = BrowserFieldEditorOwner(
            state.surfaceEpoch, state.selectedSpaceId, state.tab?.id, state.fieldIsNewTab,
            state.fieldIsPrivate, state.space?.websiteProfile, privateBoundary, state.privateContentBlocked)
    }
}

/** One Screen-owned value and actual-node callback owner, outside movable-content
 * invocation sites. A remounted input retires old callbacks through these same nodes. */
internal class BrowserFieldEditorValue(initial: TextFieldValue) {
    val value = mutableStateOf(initial)
    val nodes = BrowserFieldEditorNode()
}

/** Retained-session UI cache, with no View, focus requester, input lease or disk state.
 * Public only for BrowserScreen's optional host parameter; all operations stay internal. */
class BrowserFieldEditorValues internal constructor() {
    private var controller: BrowserController? = null
    private var owner: BrowserFieldEditorOwner? = null
    private var value: BrowserFieldEditorValue? = null
    private var closed = false

    internal fun retain(controller: BrowserController, owner: BrowserFieldEditorOwner,
        initial: () -> TextFieldValue): BrowserFieldEditorValue? {
        if (closed) return null
        if (this.controller !== controller || this.owner != owner) {
            value?.nodes?.retire()
            this.controller = controller; this.owner = owner
            value = BrowserFieldEditorValue(initial())
        }
        return value
    }

    internal fun close() {
        closed = true
        value?.nodes?.retire()
        value = null; owner = null; controller = null
    }
}

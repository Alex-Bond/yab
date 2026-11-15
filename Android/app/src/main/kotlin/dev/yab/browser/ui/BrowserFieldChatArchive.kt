package dev.yab.browser.ui

import androidx.compose.runtime.*

/** UI-only bridge from the existing inline chat source to the field's archive button.
 * Every bound action keeps its original Field/account predicate and is consumed once. */
internal class BrowserFieldChatArchiveAction(val archived: Boolean, private val originalCurrent: () -> Boolean,
    private val originalToggle: () -> Unit) {
    private var retired = false
    fun current() = !retired && originalCurrent()
    fun retire() { retired = true }
    fun perform(): Boolean {
        if (!current()) return false
        retired = true
        originalToggle()
        return true
    }
}

internal class BrowserFieldChatArchiveBinding {
    var action by mutableStateOf<BrowserFieldChatArchiveAction?>(null)
        private set
    private var closed = false
    fun bind(original: BrowserFieldChatArchiveAction) { if (!closed) action = original }
    fun release(original: BrowserFieldChatArchiveAction) { if (action === original) action = null }
    fun close() { closed = true; action?.retire(); action = null }
}

internal val LocalBrowserFieldChatArchive = staticCompositionLocalOf<BrowserFieldChatArchiveBinding?> { null }

@Composable
internal fun BindBrowserFieldChatArchive(source: Any, archived: Boolean, current: () -> Boolean, toggle: () -> Unit) {
    val binding = LocalBrowserFieldChatArchive.current ?: return
    // Keep the original callbacks. A retained button must never adopt a replacement source.
    val action = remember(binding, source) { BrowserFieldChatArchiveAction(archived, current, toggle) }
    DisposableEffect(binding, action) { onDispose { action.retire(); binding.release(action) } }
    SideEffect { binding.bind(action) }
}

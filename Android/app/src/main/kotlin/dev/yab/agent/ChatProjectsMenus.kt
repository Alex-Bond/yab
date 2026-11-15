package dev.yab.agent

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp

/** Same-root presentation only. Native popup focus must not retire the captured window owner. */
internal class ProjectMenuPortal {
    class Entry(val current: () -> Boolean, val dismiss: () -> Unit, val dialog: Boolean,
        val content: @Composable ColumnScope.() -> Unit)
    var entry by mutableStateOf<Entry?>(null)
        private set
    fun show(value: Entry) { entry = value }
    fun hide(value: Entry) { if (entry === value) entry = null }
}
internal val LocalProjectMenuPortal = staticCompositionLocalOf<ProjectMenuPortal?> { null }

@Composable
internal fun ProjectMenuRoot(enabled: Boolean, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    if (!enabled) { Box(modifier) { content() }; return }
    val portal = remember { ProjectMenuPortal() }
    CompositionLocalProvider(LocalProjectMenuPortal provides portal) {
        Box(modifier.fillMaxSize()) {
            Box(if (portal.entry == null) Modifier.fillMaxSize() else Modifier.fillMaxSize().clearAndSetSemantics { }) { content() }
            portal.entry?.let { original ->
                if (original.current()) {
                    BackHandler { if (portal.entry === original && original.current()) original.dismiss() }
                    Box(Modifier.fillMaxSize()) {
                        Box(Modifier.matchParentSize().background(if (original.dialog) Color.Black.copy(alpha = .28f) else Color.Transparent)
                            .clickable(indication = null, interactionSource = remember(original) { MutableInteractionSource() }) {
                                if (portal.entry === original && original.current()) original.dismiss()
                            }.clearAndSetSemantics { })
                        Surface(Modifier.align(if (original.dialog) Alignment.Center else Alignment.TopEnd)
                            .padding(horizontal = 16.dp, vertical = 56.dp).widthIn(min = 220.dp, max = 360.dp)
                            .heightIn(max = 620.dp), shape = MaterialTheme.shapes.extraLarge,
                            tonalElevation = 6.dp, shadowElevation = 8.dp) {
                            Column(Modifier.padding(if (original.dialog) 20.dp else 8.dp), content = original.content)
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun ProjectDropdownMenu(expanded: Boolean, onDismissRequest: () -> Unit, modifier: Modifier = Modifier,
    owned: Boolean, current: () -> Boolean, sourceKey: Any?, content: @Composable ColumnScope.() -> Unit) {
    if (!owned) { DropdownMenu(expanded, onDismissRequest, modifier, content = content); return }
    val portal = LocalProjectMenuPortal.current ?: return
    if (expanded) {
        val entry = remember(sourceKey) { ProjectMenuPortal.Entry(current, onDismissRequest, false, content) }
        DisposableEffect(entry, portal) { portal.show(entry); onDispose { portal.hide(entry) } }
    }
}

@Composable
internal fun ProjectAlertDialog(onDismissRequest: () -> Unit, confirmButton: @Composable () -> Unit,
    modifier: Modifier = Modifier, dismissButton: (@Composable () -> Unit)? = null,
    title: (@Composable () -> Unit)? = null, text: (@Composable () -> Unit)? = null,
    owned: Boolean, current: () -> Boolean, sourceKey: Any?) {
    if (!owned) {
        AlertDialog(onDismissRequest, confirmButton, modifier, dismissButton = dismissButton, title = title, text = text)
        return
    }
    val portal = LocalProjectMenuPortal.current ?: return
    val entry = remember(sourceKey) { ProjectMenuPortal.Entry(current, onDismissRequest, true) {
        title?.invoke(); Spacer(Modifier.height(16.dp))
        Box(Modifier.weight(1f, fill = false)) { text?.invoke() }
        Spacer(Modifier.height(16.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { dismissButton?.invoke(); confirmButton() }
    } }
    DisposableEffect(entry, portal) { portal.show(entry); onDispose { portal.hide(entry) } }
}

/** Only logical modal phases use this delegate. Text drafts intentionally use ordinary state. */
internal class ProjectLocalState<T>(initial: T, private val changed: () -> Unit) : MutableState<T> {
    private val state = mutableStateOf(initial)
    override var value: T
        get() = state.value
        set(next) { if (state.value != next) { changed(); state.value = next } }
    override fun component1(): T = value
    override fun component2(): (T) -> Unit = { value = it }
}

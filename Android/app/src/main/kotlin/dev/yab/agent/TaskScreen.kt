package dev.yab.agent

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.BrowserState
import dev.yab.browser.model.BrowserSurface
import dev.yab.core.sync.TaskRecords
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Capture the displayed public source. The bridge independently checks its journal before writing. */
fun taskOrigin(state: BrowserState): AgentTaskOrigin? {
    val space = state.space ?: return null
    if (state.loading || space.isPrivate || state.privateContentBlocked || state.surface == BrowserSurface.FIELD && state.fieldPrivate) return null
    if (state.surface == BrowserSurface.FIELD && state.fieldIsNewTab) return AgentTaskOrigin(space.id)
    val tab = state.tab?.takeUnless { it.isPrivate || it.isBlank } ?: return null
    return TaskRecords.web(tab.url)?.let { AgentTaskOrigin(space.id, tab.id, tab.url, tab.title) }
}

@Composable
fun TaskScreen(port: AgentTaskPort, origin: AgentTaskOrigin?, initialTaskId: String? = null,
               onOpenWebsite: (String) -> Unit, onBack: () -> Unit) {
    val all by port.tasks.collectAsState()
    val macs by port.taskMacs.collectAsState()
    val visible = all.filter { origin != null && !origin.isPrivate && it.request.space == origin.space }
    var selected by remember(origin?.space, initialTaskId) { mutableStateOf(initialTaskId) }
    var chosen by remember(origin?.space) { mutableStateOf<String?>(null) }
    var words by remember(origin) { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var error by remember(origin) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val current = visible.firstOrNull { it.id == selected }
    val mac = if (chosen != null) macs.firstOrNull { it.id == chosen } else macs.singleOrNull()
    BackHandler { if (selected != null) selected = null else onBack() }
    Column(Modifier.fillMaxSize().imePadding().padding(16.dp).testTag("tasks.screen")) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = { if (selected != null) selected = null else onBack() }) { Text("Back") }
            Text("Read-only tasks", style = MaterialTheme.typography.titleLarge)
        }
        if (selected != null) {
            if (current == null) Text("This task is not available in this public space", Modifier.testTag("tasks.unavailable"))
            else {
                Text(current.title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.testTag("tasks.title"))
                Text(current.progress, Modifier.testTag("tasks.progress"))
                Text(current.macName, style = MaterialTheme.typography.labelMedium)
                val open: (String) -> Unit = { url -> scope.launch {
                    try {
                        val target = port.openTaskResult(current, url)
                        if (target == null) error = "This task or public source changed" else onOpenWebsite(target)
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) { error = failure.message ?: "This result could not be opened" }
                } }
                SelectionContainer(Modifier.weight(1f).verticalScroll(rememberScrollState()).testTag("tasks.body")) {
                    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text(current.request.words, Modifier.testTag("tasks.request"))
                        current.observation?.takeIf { it.status == TaskRecords.Status.done }?.let { observed ->
                            observed.result?.let { AgentMarkdownText(it, open, Modifier.testTag("tasks.result")) }
                            observed.resultURL?.let { url -> TextButton(onClick = { open(url) }, modifier = Modifier.testTag("tasks.result-url")) { Text(url) } }
                        }
                    }
                }
            }
        } else {
            if (origin == null || origin.isPrivate) Text("Choose a public page or a new public tab to send a task")
            else {
                Text("Your Mac reads pages in this space. Requests cannot make changes or approve actions.")
                for (item in macs) FilterChip(selected = mac?.id == item.id, onClick = { chosen = item.id }, label = { Text(item.name) })
                if (macs.isEmpty()) Text("No ready Mac is available for a read-only task")
                OutlinedTextField(words, { words = it }, label = { Text("What should your Mac read?") }, modifier = Modifier.fillMaxWidth().testTag("tasks.words"))
                Button(enabled = !sending && mac != null && words.isNotBlank(), modifier = Modifier.testTag("tasks.send"), onClick = {
                    val owner = mac ?: return@Button
                    val captured = origin
                    sending = true; error = null
                    scope.launch {
                        try { selected = port.sendTask(words, captured, owner.id, owner.epoch).id; words = "" }
                        catch (cancelled: CancellationException) { throw cancelled }
                        catch (failure: Exception) { error = failure.message ?: "The task could not be queued for your Mac" }
                        finally { sending = false }
                    }
                }) { Text(if (sending) "Saving request…" else "Send to Mac") }
            }
            LazyColumn(Modifier.weight(1f)) {
                items(visible, key = { it.id }) { task -> Column(Modifier.fillMaxWidth().clickable { selected = task.id }.padding(vertical = 12.dp).testTag("tasks.row.${task.id}")) {
                    Text(task.title, style = MaterialTheme.typography.titleMedium); Text(task.progress); Text(task.macName, style = MaterialTheme.typography.labelSmall)
                } }
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("tasks.error")) }
    }
}

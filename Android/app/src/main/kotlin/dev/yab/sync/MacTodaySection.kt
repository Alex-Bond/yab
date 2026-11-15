package dev.yab.sync

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.yab.agent.MacPhase
import dev.yab.agent.MacRouting
import java.net.URI

/** Place under this device's Today. The controller owns every row and action's account lease. */
@Composable
fun MacTodaySection(controller: MacTodayController) {
    val state by controller.state.collectAsState(); val busy by controller.busy.collectAsState(); val error by controller.error.collectAsState()
    if (!state.enabled) return
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (group in state.groups) key(state.account, state.space, group.mac.id) {
            var folded by remember { mutableStateOf(false) }; var all by remember { mutableStateOf(false) }
            Row(Modifier.fillMaxWidth().clickable { folded = !folded }.padding(vertical = 8.dp)) {
                Text(group.mac.name, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                Text(if (group.mac.availability.phase != MacPhase.UP) MacRouting.state(group.mac) else if (folded) "${group.rows.size} tabs" else "", style = MaterialTheme.typography.labelSmall)
            }
            if (!folded) {
                for (row in group.rows.let { if (all) it else it.take(5) }) Row(Modifier.fillMaxWidth().clickable(enabled = !row.closing) { controller.open(row) }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                        Text(row.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(when { row.closing -> "Closes when your Mac wakes"; row.front -> if (group.mac.awake) "In front on Mac" else "Was in front on Mac"; else -> runCatching { URI(row.url).host.removePrefix("www.") }.getOrDefault(row.url) }, style = MaterialTheme.typography.labelSmall, maxLines = 1)
                    }
                    TextButton(enabled = !row.closing && row.id !in busy, onClick = { controller.close(row) }) { Text("Close on Mac") }
                }
                if (!all && group.rows.size > 5) TextButton(onClick = { all = true }) { Text("Show all ${group.rows.size}") }
            }
        }
        error?.let { TextButton(onClick = controller::clearError) { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}

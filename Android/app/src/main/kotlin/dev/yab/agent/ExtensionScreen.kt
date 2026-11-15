package dev.yab.agent

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import dev.yab.browser.engine.ExtensionActionRow

@Composable
fun ExtensionScreen(manager: GeckoSignedExtensionManager, onOpenOptions: (String) -> Unit, onBack: () -> Unit, modifier: Modifier = Modifier,
    actions: List<ExtensionActionRow> = emptyList(), onAction: (String) -> Unit = {}) {
    val state by manager.state.collectAsState()
    val scope = rememberCoroutineScope()
    var address by remember { mutableStateOf("") }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) scope.launch { manager.install(uri) } }
    Column(modifier.fillMaxSize().padding(16.dp)) {
        TextButton(onClick = onBack) { Text("Back") }
        Text("Extensions", style = MaterialTheme.typography.headlineMedium)
        Text("This build runs Mozilla-signed Firefox extensions. Chrome Web Store CRX packages require a different engine and cannot be installed here.", modifier = Modifier.padding(vertical = 12.dp))
        Button(enabled = !state.busy, onClick = { picker.launch(arrayOf("application/x-xpinstall", "application/octet-stream", "*/*")) }) { Text(if (state.busy) "Installing…" else "Install signed .xpi file") }
        OutlinedTextField(address, { address = it }, singleLine = true, label = { Text("Direct HTTPS .xpi link") }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp))
        TextButton(enabled = !state.busy, onClick = { manager.installHttps(address.trim()) }) { Text("Install from link") }
        LazyColumn {
            items(state.installed, key = { it.id }) { item ->
                Row(Modifier.padding(vertical = 12.dp)) {
                    Column(Modifier.weight(1f)) { Text(item.name); Text(item.version, style = MaterialTheme.typography.bodySmall) }
                    Switch(checked = item.enabled, onCheckedChange = { manager.setEnabled(item.id, it) })
                }
                Row {
                    for (action in actions.filter { it.extensionId == item.id }) TextButton(enabled = action.enabled, onClick = { onAction(action.id) }) { Text(action.title + if (action.badge.isBlank()) "" else " · ${action.badge}") }
                    item.optionsUrl?.let { url -> TextButton(onClick = { onOpenOptions(url) }) { Text("Options") } }
                    TextButton(onClick = { manager.remove(item.id) }) { Text("Remove") }
                }
                HorizontalDivider()
            }
        }
    }
    state.consent?.let { consent -> AlertDialog(onDismissRequest = { manager.resolveConsent(consent.token, false) }, title = { Text("Add ${consent.name}?") }, text = {
        LazyColumn {
            item { Text("Permissions") }
            items(consent.permissions) { Text(it) }
            item { Text("Website access") }
            items(consent.origins) { Text(it) }
            if (consent.dataCollection.isNotEmpty()) { item { Text("Requested data collection") }; items(consent.dataCollection) { Text(it) } }
            item { Text("Access in Private is disabled. Technical and interaction data collection is declined.") }
        }
    }, confirmButton = { TextButton(onClick = { manager.resolveConsent(consent.token, true) }) { Text("Add") } }, dismissButton = { TextButton(onClick = { manager.resolveConsent(consent.token, false) }) { Text("Cancel") } }) }
    state.error?.let { error -> AlertDialog(onDismissRequest = manager::clearError, title = { Text("Extension not installed") }, text = { Text(error) }, confirmButton = { TextButton(onClick = manager::clearError) { Text("OK") } }) }
}

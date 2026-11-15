package dev.yab.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.yab.agent.ApprovalAuthentication
import dev.yab.sync.AndroidSyncBridge
import dev.yab.sync.RecoveryKeyReveal
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import java.util.concurrent.atomic.AtomicReference
import dev.yab.browser.ui.LocalBrowserAccessibility
import kotlinx.coroutines.delay

@Composable
fun SyncSettingsScreen(sync: AndroidSyncBridge, authentication: ApprovalAuthentication, onBack: () -> Unit,
    joinPresentation: TabletJoinPresentation? = null) {
    val state by sync.ui.collectAsState()
    val connection by sync.connection.collectAsState()
    val records by sync.accountRecords.collectAsState()
    val identity = sync.identityLease()?.takeIf { it.account == records.account && it.device == records.device && it.epoch == records.epoch }
    val exportIdentity = sync.recoveryLease()?.takeIf { it == identity && !records.removed }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val lifecycleState by lifecycle.currentStateAsState()
    val scope = rememberCoroutineScope()
    var recovery by remember(sync, identity) { mutableStateOf("") }
    var confirmOff by remember(sync, identity) { mutableStateOf(false) }
    val revealer = remember(sync, exportIdentity, lifecycle) { RecoveryKeyReveal(
        source = { sync.recoveryLease()?.takeIf { it == exportIdentity && lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) } },
        export = sync::recoveryKey) }
    val reveal by revealer.state.collectAsState()
    val revealJob = remember(revealer) { AtomicReference<Job?>(null) }
    fun clearReveal() { revealJob.getAndSet(null)?.cancel(); revealer.clear(); recovery = "" }
    val back = { joinPresentation?.close(); clearReveal(); onBack() }
    DisposableEffect(lifecycle, revealer) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) clearReveal() }
        lifecycle.addObserver(observer)
        onDispose { revealJob.getAndSet(null)?.cancel(); revealer.close(); lifecycle.removeObserver(observer) }
    }
    DisposableEffect(lifecycle, joinPresentation) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) joinPresentation?.close() }
        lifecycle.addObserver(observer)
        onDispose { joinPresentation?.close(); lifecycle.removeObserver(observer) }
    }
    val joinedState = joinPresentation?.state?.collectAsState()?.value
    val presentation = joinPresentation?.takeIf { joinedState?.finished != true && it.available() }
    val controls = remember(presentation, joinedState?.revision, state.phase, state.code, identity,
        records.account, records.device, records.epoch, records.removed) { presentation?.control() }
    DisposableEffect(controls) { onDispose { controls?.retire() } }
    val success = joinedState?.success?.takeIf { presentation?.current(it) == true }
    val reducedMotion = LocalBrowserAccessibility.current.reduceMotion
    LaunchedEffect(presentation, success, reducedMotion) {
        if (success != null && presentation != null) {
            if (!reducedMotion) delay(1_400)
            presentation.finish(success)
        }
    }
    if (success != null) {
        val name = connection.macs.firstOrNull()?.name.takeIf { connection.account == success.identity.account &&
            connection.epoch == success.identity.epoch && identity == success.identity && !records.removed } ?: "your Mac"
        TabletJoinSuccessScreen(name)
        return
    }
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(20.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            TextButton(onClick = back) { Text("Back") }
            Text("Sync with your Mac", style = MaterialTheme.typography.headlineMedium)
            Text("${state.phase.replaceFirstChar(Char::uppercase)}", style = MaterialTheme.typography.titleMedium)
            Text("Your account is your encryption key. Pair with a Mac or restore your Recovery Key.")
            if (state.account == null) {
                if (state.code != null) {
                    Text(state.code!!, style = MaterialTheme.typography.headlineLarge)
                    Text("In Yab on your Mac, open Settings › Sync › Add a Device and enter this code.")
                    state.check?.let { Text("Confirm these digits on your Mac: $it", style = MaterialTheme.typography.titleLarge) }
                    val code = state.code!!
                    key(controls, code) {
                        OutlinedButton(onClick = {
                            if (presentation == null || controls?.let(presentation::cancel) == true) sync.cancelJoin(code)
                        }) { Text("Cancel joining") }
                    }
                } else {
                    key(controls) {
                        Button(onClick = {
                            if (presentation == null) sync.join()
                            else controls?.let(presentation::begin)?.let { attempt -> sync.join(onJoined = { presentation.joined(attempt, it) }) }
                        }) { Text("Join your Mac") }
                    }
                    OutlinedTextField(recovery, { recovery = it }, label = { Text("Recovery Key") }, modifier = Modifier.fillMaxWidth())
                    val originalRecovery = recovery
                    val recoveryControls = remember(presentation, joinedState?.revision, controls, originalRecovery) { presentation?.control() }
                    DisposableEffect(recoveryControls) { onDispose { recoveryControls?.retire() } }
                    key(recoveryControls, originalRecovery) {
                        OutlinedButton(onClick = restore@ {
                            if (originalRecovery.isNotBlank()) {
                                if (presentation == null) sync.joinRecovery(originalRecovery)
                                else {
                                    if (recovery != originalRecovery) return@restore
                                    val attempt = recoveryControls?.let(presentation::begin) ?: return@restore
                                    sync.joinRecovery(originalRecovery, onJoined = { presentation.joined(attempt, it) })
                                }
                                recovery = ""
                            }
                        }, enabled = originalRecovery.isNotBlank()) { Text("Restore Sync") }
                    }
                }
            } else {
                Text("Devices", style = MaterialTheme.typography.titleLarge)
                state.devices.filterNot { it.revoked }.forEach { device ->
                    ListItem(headlineContent = { Text(device.name) }, supportingContent = { Text("${device.platform ?: device.model} · ${device.id.take(8)}") })
                }
                if (connection.macs.size > 1) {
                    Text("Mac for new work")
                    Row { RadioButton(connection.selectedMac == null, onClick = { identity?.let { sync.selectMac(null, it) } }); TextButton(onClick = { identity?.let { sync.selectMac(null, it) } }) { Text("Auto") } }
                    connection.macs.forEach { mac ->
                        Row { RadioButton(connection.selectedMac == mac.id, onClick = { identity?.let { sync.selectMac(mac.id, it) } }); TextButton(onClick = { identity?.let { sync.selectMac(mac.id, it) } }) { Text("${mac.name} · ${dev.yab.agent.MacRouting.state(mac)}") } }
                    }
                }
                OutlinedButton(onClick = { revealJob.set(scope.launch { revealer.reveal(authentication) }) }, enabled = exportIdentity != null && !reveal.busy) { Text("Show Recovery Key") }
                TextButton(onClick = { confirmOff = true }) { Text("Turn off Sync on this device", color = MaterialTheme.colorScheme.error) }
            }
            (state.error ?: reveal.error)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
    if (confirmOff && identity != null) AlertDialog(onDismissRequest = { confirmOff = false }, title = { Text("Turn off Sync?") },
        text = { Text("This device will be removed from the sync account. Your other devices keep syncing.") },
        confirmButton = { TextButton(onClick = { confirmOff = false; clearReveal(); sync.disconnect(identity) }) { Text("Turn off") } },
        dismissButton = { TextButton(onClick = { confirmOff = false }) { Text("Cancel") } })
    reveal.revealed?.takeIf { it.source == exportIdentity && sync.recoveryLease() == it.source && lifecycleState.isAtLeast(Lifecycle.State.STARTED) }?.let { shown -> AlertDialog(onDismissRequest = { clearReveal() }, title = { Text("Recovery Key") },
        text = { Text("${shown.key}\n\nKeep it safe. This key allows another device to join your account.") },
        confirmButton = { TextButton(onClick = { clearReveal() }) { Text("Done") } }) }
}

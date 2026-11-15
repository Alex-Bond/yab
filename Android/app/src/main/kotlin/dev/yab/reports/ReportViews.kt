package dev.yab.reports

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

@Composable
fun ReportPreferences(controller: ReportsController, actionCurrent: () -> Boolean = { true }) {
    val state by controller.state.collectAsState()
    if (!state.available) {
        Text(state.storageError ?: "This build has nowhere to send reports. Nothing is collected or sent.", style = MaterialTheme.typography.bodySmall)
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ReportToggle("Automatically send crash reports", state.automaticCrashes, { if (actionCurrent()) controller.automaticCrashes(it) })
        Text("Why Android ended Yab, saved code locations when available, Yab and Android versions and the device model. No pages or anything you typed. When off, Yab asks after a new crash.", style = MaterialTheme.typography.bodySmall)
        ReportToggle("Share daily activity", state.dailyActivity, { if (actionCurrent()) controller.dailyActivity(it) })
        Text("A random ID for this installation counts the UTC days Yab is active. A random person ID is included if your Mac shares one through Sync. No pages, searches or browsing history.", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
fun CrashReportQuestion(controller: ReportsController) {
    val state by controller.state.collectAsState()
    val question = state.question ?: return
    AlertDialog(onDismissRequest = { controller.answer(question.token, false) }, title = { Text("Share saved crash reports?") },
        text = { Text("Android saved information about an earlier Yab session that ended unexpectedly. It includes the failure kind, saved code locations when available, versions and device model. Never pages or anything you typed. This choice applies only to these saved reports. You can enable automatic sending in About.") },
        confirmButton = { TextButton(onClick = { controller.answer(question.token, true) }) { Text("Send") } },
        dismissButton = { TextButton(onClick = { controller.answer(question.token, false) }) { Text("Don't Send") } })
}

@Composable
fun FeedbackForm(controller: ReportsController, actionCurrent: () -> Boolean = { true }) {
    val state by controller.state.collectAsState()
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        OutlinedTextField(state.draft, { if (actionCurrent()) controller.draft(it) }, Modifier.fillMaxWidth().heightIn(min = 160.dp),
            label = { Text("What happened?") }, minLines = 5, maxLines = 12)
        OutlinedTextField(state.email, { if (actionCurrent()) controller.email(it) }, Modifier.fillMaxWidth(), label = { Text("Email for a reply (optional)") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), singleLine = true)
        Button(onClick = { if (actionCurrent()) controller.sendFeedback() }, enabled = state.draft.isNotBlank() && state.feedback != FeedbackStatus.SENDING,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(if (state.feedback == FeedbackStatus.SENDING) "Sending…" else "Send Feedback") }
        val message = if (state.feedback == FeedbackStatus.SENT) "Sent. Thank you." else state.feedbackError
        message?.let { Text(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun ReportToggle(title: String, checked: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(title, Modifier.weight(1f).padding(end = 12.dp), style = MaterialTheme.typography.bodyLarge)
        Switch(checked, change, modifier = Modifier.semantics { contentDescription = title })
    }
}

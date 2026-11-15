package dev.yab.browser.download

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue

/** A cancellable pending request is separate from the original stream's real download progress. */
@Composable
fun OwnedImageDownloadDialog(runtime: OwnedImageDownloadRuntime, mayPresent: Boolean) {
    val value by runtime.preparation.collectAsState()
    val preparing = value ?: return
    if (!mayPresent || !runtime.preparationCurrent(preparing)) return
    AlertDialog(onDismissRequest = { runtime.cancel(preparing.token) }, title = { Text("Save Image") },
        text = { Text("Waiting for this webpage to send the image.") },
        confirmButton = {}, dismissButton = {
            TextButton(onClick = { runtime.cancel(preparing.token) }) { Text("Cancel") }
        })
}

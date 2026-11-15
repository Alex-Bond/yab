package dev.yab.android

import android.app.Activity
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.withResumed
import kotlinx.coroutines.launch

/** Activity launchers own only system UI; the controller and source bytes outlive recreation. */
@Composable
fun PageDownloadDialog(controller: PageDownloadController, mayPresent: Boolean) {
    val state by controller.state.collectAsState()
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    var saveToken by rememberSaveable { mutableStateOf<String?>(null) }
    var shareToken by rememberSaveable { mutableStateOf<String?>(null) }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { returned ->
        val token = saveToken; saveToken = null
        if (token != null) controller.saveTo(token, returned.data?.data.takeIf { returned.resultCode == Activity.RESULT_OK })
    }
    val share = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        val token = shareToken; shareToken = null
        if (token != null) lifecycle.lifecycleScope.launch { lifecycle.lifecycle.withResumed { }; controller.shareReturned(token) }
    }
    if (!mayPresent || !controller.isSourceAlive() || state.id == null || state.owner == null || state.phase !in setOf(
            PageDownloadPhase.TRANSFERRING, PageDownloadPhase.READY, PageDownloadPhase.FAILED, PageDownloadPhase.CANCELLING, PageDownloadPhase.EXPORTING)) return
    val mayCancel = state.phase != PageDownloadPhase.EXPORTING || state.exportKind == PageDownloadExportKind.PICTURES
    AlertDialog(onDismissRequest = { if (mayCancel) controller.cancel(state.id) },
        title = { Text(when (state.phase) {
            PageDownloadPhase.READY -> "Download Ready"
            PageDownloadPhase.FAILED -> "Couldn't Download"
            PageDownloadPhase.CANCELLING -> "Cancelling Download"
            PageDownloadPhase.EXPORTING -> "Saving File"
            else -> "Downloading"
        }) },
        text = { Column {
            when (state.phase) {
                PageDownloadPhase.TRANSFERRING -> {
                    val total = state.total?.takeIf { it > 0 }
                    if (total == null) { Text("This webpage is sending a file."); LinearProgressIndicator(Modifier.padding(top = 12.dp)) }
                    else {
                        val progress = (state.received.toDouble() / total).toFloat().coerceIn(0f, 1f)
                        Text("Downloading ${(progress * 100).toInt()}%")
                        LinearProgressIndicator(progress = { progress }, modifier = Modifier.padding(top = 12.dp))
                    }
                }
                PageDownloadPhase.READY -> { Text(state.name); state.error?.let { Text(it) } }
                PageDownloadPhase.FAILED -> Text(state.error ?: "The file didn't finish. Try again from this webpage.")
                PageDownloadPhase.EXPORTING -> { Text("Saving your file…"); LinearProgressIndicator(Modifier.padding(top = 12.dp)) }
                else -> Text("Closing the webpage's transfer…")
            }
        } },
        confirmButton = {
            if (state.phase == PageDownloadPhase.READY) {
                if (PicturesExport.supports(state.mime)) TextButton(onClick = {
                    if (mayPresent && controller.isSourceAlive()) controller.savePictures(state.id!!)
                }) { Text("Save to Pictures") }
                TextButton(onClick = {
                    if (!mayPresent || !controller.isSourceAlive()) return@TextButton
                    controller.beginExport(state.id!!, PageDownloadExportKind.SAVE)?.let { export ->
                        saveToken = export.token
                        try { save.launch(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(export.mime).putExtra(Intent.EXTRA_TITLE, export.name)) }
                        catch (_: RuntimeException) { saveToken = null; controller.exportCancelled(export.token) }
                    }
                }) { Text("Save…") }
                TextButton(onClick = {
                    if (!mayPresent || !controller.isSourceAlive()) return@TextButton
                    controller.beginExport(state.id!!, PageDownloadExportKind.SHARE)?.let { export ->
                        shareToken = export.token
                        try {
                            val uri = FileProvider.getUriForFile(context, context.packageName + ".files", export.file)
                            val send = Intent(Intent.ACTION_SEND).setType(export.mime).putExtra(Intent.EXTRA_STREAM, uri)
                                .apply { clipData = android.content.ClipData.newRawUri(export.name, uri) }
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            share.launch(Intent.createChooser(send, "Share file"))
                            controller.shareLaunched(export.token)
                        } catch (_: RuntimeException) { shareToken = null; controller.exportCancelled(export.token) }
                    }
                }) { Text("Share…") }
            }
        },
        dismissButton = { if (mayCancel) TextButton(onClick = { controller.cancel(state.id) }, enabled = state.phase != PageDownloadPhase.CANCELLING) { Text("Cancel") } })
}

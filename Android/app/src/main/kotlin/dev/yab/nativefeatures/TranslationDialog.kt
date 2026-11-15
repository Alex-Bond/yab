package dev.yab.nativefeatures

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalConfiguration
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

@Composable
fun TranslationDialog(controller: PageTranslationController, scope: CoroutineScope, onDismiss: () -> Unit) {
    val state by controller.state.collectAsState()
    val locale = LocalConfiguration.current.locales[0]
    val target = locale.toLanguageTag()
    val source = state.source
    val host = state.host
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Translate page") }, text = {
        Column {
            Text(when (state.phase) {
                TranslationPhase.ORIGINAL -> "Translate this page to ${Locale.forLanguageTag(target).getDisplayLanguage(locale)}?"
                TranslationPhase.READING -> "Reading this page…"
                TranslationPhase.NEED_MODEL -> "Download the ${state.source} and ${state.target} language models over Wi-Fi? Translation runs on this phone."
                TranslationPhase.DOWNLOADING -> "Downloading language models over Wi-Fi…"
                TranslationPhase.TRANSLATING -> "Translating…"
                TranslationPhase.TRANSLATED -> "Translated on this phone"
                TranslationPhase.FAILED -> state.error ?: "The page could not be translated"
            })
            if (host != null && source != null && source != state.target &&
                (state.always || state.phase in setOf(TranslationPhase.TRANSLATING, TranslationPhase.TRANSLATED, TranslationPhase.DOWNLOADING))) {
                androidx.compose.foundation.layout.Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Checkbox(checked = state.always, onCheckedChange = { enabled -> scope.launch { controller.setAlways(enabled) } })
                    Text("Always translate ${Locale.forLanguageTag(source).getDisplayLanguage(locale)} on $host")
                }
            }
            if (state.phase != TranslationPhase.FAILED) state.error?.let { Text(it) }
        }
    }, confirmButton = {
        when (state.phase) {
            TranslationPhase.NEED_MODEL -> TextButton(onClick = { scope.launch { controller.confirmDownload() } }) { Text("Download languages") }
            TranslationPhase.TRANSLATED, TranslationPhase.TRANSLATING, TranslationPhase.DOWNLOADING -> TextButton(onClick = { scope.launch { controller.showOriginal() } }) { Text("Show original") }
            TranslationPhase.ORIGINAL, TranslationPhase.FAILED -> TextButton(onClick = { scope.launch { controller.translate(target) } }) { Text("Translate") }
            else -> Unit
        }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } })
}

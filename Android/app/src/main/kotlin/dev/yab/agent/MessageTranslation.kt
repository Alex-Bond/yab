package dev.yab.agent

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import com.google.mlkit.nl.translate.TranslateLanguage
import dev.yab.nativefeatures.MlKitTranslationRuntime
import dev.yab.nativefeatures.TranslationBatching
import dev.yab.nativefeatures.TranslationSegment
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Local message translation. Model downloads receive language identifiers, never message text. */
@Composable
fun MessageTranslation(text: String, close: () -> Unit) = MessageTranslation(text, close, null, null)

@Composable
fun MessageTranslation(text: String, close: () -> Unit, projectCurrent: (() -> Boolean)?, projectSourceKey: Any?) {
    val runtime = remember { MlKitTranslationRuntime() }
    val target = TranslateLanguage.fromLanguageTag(LocalConfiguration.current.locales[0].toLanguageTag()) ?: "en"
    val scope = rememberCoroutineScope()
    var source by remember(text) { mutableStateOf<String?>(null) }
    var translated by remember(text) { mutableStateOf<String?>(null) }
    var needsModel by remember(text) { mutableStateOf(false) }
    var busy by remember(text) { mutableStateOf(true) }
    var error by remember(text) { mutableStateOf<String?>(null) }
    suspend fun perform() {
        val from = source ?: return
        if (from == target) { translated = text; return }
        val pieces = TranslationBatching.pieces(listOf(TranslationSegment("message", text)))
        val outputs = pieces.chunked(24).flatMap { runtime.translate(from, target, it.map { piece -> piece.text }) }
        translated = TranslationBatching.combine(pieces, outputs).single().text
    }
    LaunchedEffect(text, target) {
        try {
            source = runtime.identify(text)?.let(TranslateLanguage::fromLanguageTag) ?: throw IllegalArgumentException("The message language could not be identified")
            needsModel = source != target && !runtime.modelsReady(source!!, target)
            if (!needsModel) perform()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.message ?: "The message could not be translated on this device" }
        finally { busy = false }
    }
    ProjectAlertDialog(owned = projectCurrent != null, current = projectCurrent ?: { true }, sourceKey = projectSourceKey,
        onDismissRequest = close, title = { Text("Translate message") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            if (busy) Text("Translating on this device…")
            if (needsModel) Text("Download the $source and $target language models over Wi-Fi? Your message stays on this device.")
            translated?.let { SelectionContainer { Text(it) } }
            error?.let { Text(it) }
        }
    }, confirmButton = { TextButton(onClick = close) { Text("Close") } }, dismissButton = {
        if (needsModel && !busy) TextButton(onClick = { if (projectCurrent?.invoke() != false) scope.launch {
            if (projectCurrent?.invoke() == false) return@launch
            busy = true; error = null
            try { runtime.download(source!!, target); needsModel = false; perform() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { error = failure.message ?: "The language models could not be downloaded" }
            finally { busy = false }
        } }) { Text("Download languages") }
    })
}

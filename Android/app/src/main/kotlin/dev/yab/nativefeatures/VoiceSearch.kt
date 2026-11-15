package dev.yab.nativefeatures

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import java.util.Locale

object VoicePrivacy {
    fun canStart(privateContext: Boolean, sdk: Int, hasOnDeviceService: Boolean): Boolean = !privateContext || (sdk >= 31 && hasOnDeviceService)
}

class VoiceSearchSession(private val context: Context) {
    private val lease = CaptureLease()
    private var recognizer: SpeechRecognizer? = null
    fun start(owner: String, privateContext: Boolean, onPartial: (String) -> Unit, onResult: (String) -> Unit, onError: (String) -> Unit) {
        close()
        val onDevice = Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        if (!VoicePrivacy.canStart(privateContext, Build.VERSION.SDK_INT, onDevice)) {
            onError("Private voice search requires on-device speech recognition, which is not available on this phone.")
            return
        }
        if (!onDevice && !SpeechRecognizer.isRecognitionAvailable(context)) { onError("Speech recognition is not available on this phone"); return }
        val token = lease.begin(owner)
        try {
            val speech = if (onDevice && Build.VERSION.SDK_INT >= 31) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
            recognizer = speech
            speech.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onPartialResults(partialResults: Bundle?) {
                    if (lease.current(token, owner)) onPartial(partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty())
                }
                override fun onResults(results: Bundle?) {
                    if (!lease.current(token, owner)) return
                    val words = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim()
                    close()
                    if (!words.isNullOrBlank()) onResult(words) else onError("No speech was recognized. Try again.")
                }
                override fun onError(error: Int) {
                    if (!lease.current(token, owner)) return
                    close()
                    onError(when (error) {
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Allow microphone access to search by voice"
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was recognized. Try again."
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Speech recognition for this language is not installed on this phone"
                        else -> "Voice search could not finish (code $error). Try again."
                    })
                }
            })
            speech.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, onDevice)
            })
        } catch (error: Exception) { close(); onError(error.message ?: "Speech recognition could not start") }
    }
    fun close() { lease.retire(); recognizer?.cancel(); recognizer?.destroy(); recognizer = null }
}

@Composable
fun VoiceSearchDialog(privateContext: Boolean, onResult: (String) -> Unit, onDismiss: () -> Unit, ownerKey: String = "voice") {
    val context = LocalContext.current
    val session = remember(context, ownerKey, privateContext) { VoiceSearchSession(context) }
    var words by remember(session) { mutableStateOf("") }
    var error by remember(session) { mutableStateOf<String?>(null) }
    var started by remember(session) { mutableStateOf(false) }
    fun start() {
        error = null; started = true
        session.start(ownerKey, privateContext, { words = it }, { session.close(); onResult(it); onDismiss() }, { error = it; started = false })
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) start() else error = "Microphone permission was declined"
    }
    LaunchedEffect(session) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) start()
        else permission.launch(Manifest.permission.RECORD_AUDIO)
    }
    DisposableEffect(session) { onDispose { session.close() } }
    AlertDialog(onDismissRequest = { session.close(); onDismiss() }, title = { Text(if (started) "Listening…" else "Voice search") }, text = {
        Column { Text(error ?: words.ifBlank { "Say what you want to search for" }); if (privateContext) Text("Recognition stays on this device") }
    }, confirmButton = { if (!started) TextButton(onClick = { permission.launch(Manifest.permission.RECORD_AUDIO) }) { Text("Try again") } },
        dismissButton = { TextButton(onClick = { session.close(); onDismiss() }) { Text("Cancel") } })
}

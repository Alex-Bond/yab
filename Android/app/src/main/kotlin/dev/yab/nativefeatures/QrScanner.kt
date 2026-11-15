package dev.yab.nativefeatures

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

@Composable
fun QrScannerDialog(onResult: (String) -> Unit, onDismiss: () -> Unit, ownerKey: String = "scanner") {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var error by remember { mutableStateOf<String?>(null) }
    val active = remember(ownerKey) { AtomicBoolean(true) }
    fun dismiss() { active.set(false); onDismiss() }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed -> granted = allowed; if (!allowed) error = "Camera permission was declined" }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }
    AlertDialog(onDismissRequest = ::dismiss, title = { Text("Scan QR code") }, text = {
        Column {
            if (granted) QrCamera(ownerKey, { if (active.compareAndSet(true, false)) { onResult(it); onDismiss() } }, { if (active.get()) error = it }, Modifier.fillMaxWidth().height(360.dp))
            Text(error ?: "Point the camera at a QR code")
        }
    }, confirmButton = { if (!granted) TextButton(onClick = { permission.launch(Manifest.permission.CAMERA) }) { Text("Allow camera") } },
        dismissButton = { TextButton(onClick = ::dismiss) { Text("Cancel") } })
    DisposableEffect(active) { onDispose { active.set(false) } }
}

@androidx.annotation.OptIn(ExperimentalGetImage::class)
@Composable
private fun QrCamera(owner: String, onResult: (String) -> Unit, onError: (String) -> Unit, modifier: Modifier) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context) }
    AndroidView(factory = { previewView }, modifier = modifier)
    DisposableEffect(context, lifecycle, owner) {
        val lease = CaptureLease()
        val token = lease.begin(owner)
        val delivered = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        val main = ContextCompat.getMainExecutor(context)
        val scanner = BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
        val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
        val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
        var provider: ProcessCameraProvider? = null
        analysis.setAnalyzer(executor) { proxy ->
            val image = proxy.image
            if (image == null || !lease.current(token, owner) || delivered.get()) { proxy.close(); return@setAnalyzer }
            scanner.process(InputImage.fromMediaImage(image, proxy.imageInfo.rotationDegrees))
                .addOnSuccessListener(main) { barcodes ->
                    if (lease.current(token, owner)) {
                        val payload = barcodes.firstNotNullOfOrNull { it.rawValue?.takeIf(String::isNotBlank) }
                        if (payload != null && delivered.compareAndSet(false, true)) { lease.retire(); onResult(payload) }
                    }
                }
                .addOnFailureListener(main) { if (lease.current(token, owner)) onError(it.message ?: "The code could not be scanned") }
                .addOnCompleteListener { proxy.close() }
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (lease.current(token, owner)) try {
                provider = future.get()
                provider?.bindToLifecycle(lifecycle, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (error: Exception) { onError(error.message ?: "The camera could not start") }
        }, main)
        onDispose {
            lease.retire()
            analysis.clearAnalyzer()
            provider?.unbind(preview, analysis)
            scanner.close()
            executor.shutdown()
        }
    }
}

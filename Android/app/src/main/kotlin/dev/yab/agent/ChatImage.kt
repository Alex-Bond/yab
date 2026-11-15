package dev.yab.agent

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest

/** Only a photo actually kept by the public attachment picker is available, by verified digest. */
@Composable
fun ChatImage(file: ChatFile, modifier: Modifier = Modifier, crop: Boolean = false) {
    val context = LocalContext.current.applicationContext
    val image by produceState<Bitmap?>(null, file.digest, file.mime) {
        value = withContext(Dispatchers.IO) { runCatching {
            require(file.mime.startsWith("image/") && file.digest.matches(Regex("[0-9a-f]{64}")))
            val path = File(context.noBackupFilesDir, "chat-photos/${file.digest}")
            require(path.length() in 1..AttachmentLimits.EACH.toLong())
            val bytes = path.readBytes()
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
            require(digest == file.digest)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            require(bounds.outWidth in 1..65_536 && bounds.outHeight in 1..65_536)
            var sample = 1; while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 1024) sample *= 2
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
        }.getOrNull() }
    }
    var opened by remember(file.digest) { mutableStateOf(false) }
    image?.let { bitmap ->
        Image(bitmap.asImageBitmap(), file.name, modifier.fillMaxWidth().sizeIn(maxHeight = 260.dp).clickable { opened = true }, contentScale = if (crop) androidx.compose.ui.layout.ContentScale.Crop else androidx.compose.ui.layout.ContentScale.Fit)
        if (opened) AlertDialog(onDismissRequest = { opened = false }, title = { Text(file.name) }, text = {
            Image(bitmap.asImageBitmap(), file.name, Modifier.fillMaxWidth())
        }, confirmButton = { TextButton(onClick = { opened = false }) { Text("Close") } })
    }
}

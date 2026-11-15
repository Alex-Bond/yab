package dev.yab.android

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Fixed local status only. No phase, server response, saved identifier or key is rendered. */
@Composable
internal fun FirstRunPreparationScreen(owner: FirstRunPreparation, host: FirstRunPresentation.Host,
    tablet: Boolean, retry: (FirstRunPreparation.Control?) -> Unit) {
    val state by owner.state.collectAsState()
    val source = owner.snapshot()
    SideEffect { owner.observe(host) }
    val control = remember(owner, host, state.revision, source) { owner.control(host, expected = source) }
    DisposableEffect(control) { onDispose { control?.retire() } }
    DisposableEffect(owner, host) { onDispose { owner.retireHost(host) } }
    val savedUnavailable = source.identity != null && source.nativeAvailable && !source.entryAvailable
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    BoxWithConstraints(Modifier.fillMaxSize().background(Brush.verticalGradient(
        0f to (if (dark) Color(0xFF1B1826) else Color(0xFFF1EEFB)),
        .62f to (if (dark) Color.Black else Color.White), 1f to (if (dark) Color.Black else Color.White)))
        .testTag("welcome.preparation").semantics { paneTitle = "Yab setup" }) {
        Box(Modifier.matchParentSize().pointerInput(owner, host) { awaitPointerEventScope {
            while (true) awaitPointerEvent(PointerEventPass.Final).changes.forEach { it.consume() }
        } })
        val width = if (tablet) (maxWidth.value - 48).coerceIn(1f, 520f) else (maxWidth.value - 16).coerceAtLeast(1f)
        Surface(Modifier.width(width.dp).align(if (tablet) Alignment.Center else Alignment.BottomCenter)
            .padding(bottom = if (tablet) 0.dp else 8.dp).navigationBarsPadding(), shape = RoundedCornerShape(38.dp),
            color = if (dark) Color(0xFF1C1C1E) else Color.White) {
            Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Image(painterResource(R.drawable.spaces_yab_mark), null, Modifier.size(76.dp))
                Text(if (savedUnavailable) "Saved connection unavailable"
                    else if (state.phase == FirstRunPreparation.Phase.FAILED) "Setup unavailable" else "Getting Yab ready",
                    Modifier.semantics { heading() }.testTag("welcome.preparation.title"),
                    fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                Text(if (savedUnavailable) "The saved connection isn’t live. Try Again checks this device’s local setup; it doesn’t reconnect."
                    else if (state.phase == FirstRunPreparation.Phase.FAILED)
                    "Yab couldn’t read the saved setup. Try again."
                    else "Your saved setup isn’t ready yet. Try again to read this device’s saved connection.",
                    Modifier.testTag("welcome.preparation.status"), fontSize = 17.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                if (state.phase == FirstRunPreparation.Phase.PREPARING) {
                    CircularProgressIndicator(Modifier.size(28.dp))
                    Text("Checking saved setup…", fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else key(control) {
                    Button(onClick = { retry(control) }, enabled = control != null,
                        modifier = Modifier.fillMaxWidth().height(50.dp).testTag("welcome.preparation.retry"),
                        shape = RoundedCornerShape(50), colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.onSurface, contentColor = MaterialTheme.colorScheme.surface)) {
                        Text("Try Again", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}

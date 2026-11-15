package dev.yab.android

import android.animation.ValueAnimator
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.ui.LocalBrowserAccessibility
import kotlin.math.hypot

/** The tablet's successful first-run join replaces the code/recovery body, with no actions. */
@Composable
internal fun TabletJoinSuccessScreen(macName: String, modifier: Modifier = Modifier) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    val ground = Brush.verticalGradient(0f to if (dark) Color(0xFF1B1826) else Color(0xFFF1EEFB),
        .62f to if (dark) Color.Black else Color.White)
    BoxWithConstraints(modifier.fillMaxSize().background(ground).testTag("welcome.tabletJoined"), contentAlignment = Alignment.Center) {
        val width = TabletJoinSuccessGeometry.width(maxWidth.value.toDouble()).dp
        Column(Modifier.width(width)
            .verticalScroll(rememberScrollState()).padding(vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(32.dp)) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Image(painterResource(R.drawable.spaces_yab_mark), null, Modifier.size(76.dp))
                Text("Yab", Modifier.padding(top = 20.dp).testTag("welcome.title"),
                    style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
                Text("Your Mac’s tabs, on your tablet", Modifier.padding(top = 10.dp).testTag("welcome.words"),
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center)
            }
            val shape = RoundedCornerShape(38.dp)
            Surface(Modifier.fillMaxWidth().shadow(15.dp, shape, ambientColor = Color.Black.copy(alpha = .14f),
                spotColor = Color.Black.copy(alpha = .14f)).testTag("welcome.tray"), shape = shape,
                color = if (dark) Color(0xFF1C1C1E) else Color.White) {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    TabletJoinedCheck()
                    Text("In sync with $macName", Modifier.semantics { heading() }.testTag("welcome.joinedTitle"),
                        style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                        letterSpacing = (-.48).sp, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

@Composable
private fun TabletJoinedCheck() {
    var drawn by remember { mutableStateOf(false) }
    val animationsDisabled = LocalBrowserAccessibility.current.let { !ValueAnimator.areAnimatorsEnabled() }
    val progress by animateFloatAsState(if (drawn) 1f else 0f,
        tween(if (animationsDisabled) 0 else 560, easing = LinearEasing), label = "joined check")
    LaunchedEffect(Unit) { drawn = true }
    Canvas(Modifier.size(52.dp).clearAndSetSemantics { }) {
        val scale = size.width / 52f
        fun part(start: Float, end: Float): Float {
            val p = ((progress - start) / (end - start)).coerceIn(0f, 1f)
            return 1f - (1f - p) * (1f - p) * (1f - p)
        }
        val color = Color(0xFF34C759)
        drawArc(color, -90f, 360f * part(0f, .6f), false, Offset(3f * scale, 3f * scale),
            Size(46f * scale, 46f * scale), style = Stroke(3.5f * scale, cap = StrokeCap.Round))
        val a = Offset(15f, 27f) * scale
        val b = Offset(22.5f, 34.5f) * scale
        val c = Offset(37.5f, 19f) * scale
        val first = hypot(b.x - a.x, b.y - a.y)
        val second = hypot(c.x - b.x, c.y - b.y)
        val length = part(.45f, 1f) * (first + second)
        if (length > 0f) drawLine(color, a, a + (b - a) * (length / first).coerceAtMost(1f),
            4f * scale, StrokeCap.Round)
        if (length > first) drawLine(color, b, b + (c - b) * ((length - first) / second).coerceAtMost(1f),
            4f * scale, StrokeCap.Round)
    }
}

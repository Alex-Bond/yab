package dev.yab.browser.ui

import android.animation.ValueAnimator
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.material3.Text
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.ceil

internal val BrowserEyesPoseKey = SemanticsPropertyKey<List<Float>>("BrowserEyesPose")

/** Current Phone Eyes.swift grid and independent lid/word timelines. */
@Composable
internal fun BrowserEyesButton(shut: Boolean, enabled: Boolean, color: Color, onToggle: () -> Unit,
    modifier: Modifier = Modifier, animationsEnabled: Boolean = ValueAnimator.areAnimatorsEnabled(), owner: Any? = null) {
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val lid = animateFloatAsState(if (shut) 1f else 0f,
        if (!animationsEnabled) snap() else tween(200, easing = if (reduced)
            CubicBezierEasing(.42f, 0f, .58f, 1f) else CubicBezierEasing(.4f, 0f, .6f, 1f)), label = "private lids").value
    // Phone's word has its own explicit eyesWord animation, including during Reduce Motion.
    val word = animateFloatAsState(if (shut) 1f else 0f,
        if (!animationsEnabled) snap() else tween(260, easing = CubicBezierEasing(.2f, .8f, .2f, 1f)), label = "private word").value
    val density = LocalDensity.current
    val style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium)
    val measured = rememberTextMeasurer().measure(AnnotatedString("Incognito"), style).size.width
    val wordWidth = with(density) { ceil(measured / this.density).toFloat().coerceAtMost(90f * fontScale).dp }
    key(owner) {
    Row(modifier.widthIn(min = 40.dp).heightIn(min = 36.dp).testTag("browser.field.eyes")
        .toggleable(shut, interactionSource = remember { MutableInteractionSource() }, indication = null,
            enabled = enabled, role = Role.Switch, onValueChange = { onToggle() })
        .semantics {
            contentDescription = if (shut) "Turn off private input" else "Search privately"
            stateDescription = if (shut) "on" else "off"
            this[BrowserEyesPoseKey] = listOf(lid, word)
        }.padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.width(wordWidth * word).clipToBounds()) {
            // Like Phone, the off label has no retained text layer during its exit.
            if (shut) Text("Incognito", Modifier.wrapContentWidth(Alignment.Start, unbounded = true).clearAndSetSemantics {},
                style = style, color = color.copy(alpha = color.alpha * .85f), maxLines = 1, softWrap = false)
        }
        Canvas(Modifier.size(26.dp, 20.dp)) {
            val k = size.width / 26f
            val clip = if (lid > .001f) Path().apply {
                val rx = size.width * .75f
                val ry = size.height * .84f * lid
                addOval(Rect(size.width / 2 - rx, -ry, size.width / 2 + rx, ry))
            } else null
            for (cx in listOf(7f, 19f)) {
                val top = Offset((cx - 5.2f) * k, 2.4f * k)
                val eyeSize = Size(10.4f * k, 15.2f * k)
                if (clip != null) clipPath(clip) { drawOval(color, top, eyeSize) }
                drawOval(color, top, eyeSize, style = Stroke(1.8f * k))
                val pupil = (1 - lid * 2).coerceAtLeast(0f)
                if (pupil > .001f) drawCircle(color.copy(alpha = color.alpha * pupil), 2.5f * k,
                    Offset((cx - 1.4f) * k, 13f * k))
            }
        }
    }
    }
}

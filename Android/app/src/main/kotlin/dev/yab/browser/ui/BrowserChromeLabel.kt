package dev.yab.browser.ui

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.SemanticsPropertyReceiver
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

internal val ChromeLabelPoseKey = SemanticsPropertyKey<List<Float>>("ChromeLabelPose")
private var SemanticsPropertyReceiver.chromeLabelPose by ChromeLabelPoseKey

internal fun browserChromeLabelStyle(base: TextStyle, pointSize: Float) = base.copy(
    fontSize = pointSize.sp, fontWeight = FontWeight.Normal,
    letterSpacing = (-0.02f * pointSize).sp, lineHeight = TextUnit.Unspecified,
    textDirection = TextDirection.Ltr,
)

/** The native text remains whole: only its viewport clips and fades the beginning. */
@Composable
internal fun BrowserChromeLabel(words: String, pointSize: Float, modifier: Modifier = Modifier) {
    val density = LocalDensity.current
    val style = browserChromeLabelStyle(LocalTextStyle.current, pointSize).copy(color = LocalContentColor.current)
    val measurer = rememberTextMeasurer()
    val measured = remember(words, style, density, measurer) {
        measurer.measure(words, style = style, softWrap = false, maxLines = 1, overflow = TextOverflow.Clip)
    }
    BoxWithConstraints(modifier.clipToBounds()) {
        val room = with(density) { maxWidth.toPx() }
        val pose = BrowserChromeLabelPose(measured.size.width.toDouble(), room.toDouble(), density.density.toDouble())
        Layout(content = {
            BasicText(words, style = style, maxLines = 1, softWrap = false, overflow = TextOverflow.Clip,
                modifier = Modifier.testTag("browser.chrome.label"))
        }, modifier = Modifier.fillMaxWidth().testTag("browser.chrome.label.viewport").semantics {
            chromeLabelPose = listOf(pose.natural.toFloat(), pose.width.toFloat(), pose.left.toFloat(), pose.fade.toFloat())
        }.drawWithCache {
            val paint = Paint()
            val rect = Rect(0f, 0f, size.width, size.height)
            val mask = if (pose.fade > 0) Brush.horizontalGradient(listOf(Color.Transparent, Color.Black),
                startX = 0f, endX = pose.fade.toFloat()) else null
            onDrawWithContent {
                if (mask == null) drawContent() else {
                    drawContext.canvas.saveLayer(rect, paint)
                    try { drawContent(); drawRect(mask, blendMode = BlendMode.DstIn) }
                    finally { drawContext.canvas.restore() }
                }
            }
        }) { children, constraints ->
            val child = children.single().measure(Constraints.fixedWidth(pose.natural.roundToInt()))
            layout(constraints.maxWidth, constraints.constrainHeight(child.height)) {
                child.placeWithLayer(0, 0) { translationX = pose.left.toFloat() }
            }
        }
    }
}

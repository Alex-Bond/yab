package dev.yab.browser.field

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.window.PopupProperties

val LocalFieldRateSource = staticCompositionLocalOf<FieldRateSource?> { null }

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun FieldAnswerPlate(answer: FieldAnswer, copied: Boolean, canSwap: Boolean,
    canPaste: Boolean, showPaste: Boolean, onCopy: () -> Unit, onQuestion: () -> Unit,
    onSwap: () -> Unit, onPaste: () -> Unit, modifier: Modifier = Modifier, actionable: Boolean = true, dark: Boolean = false,
    bestFill: Color? = null, current: () -> Boolean = { true }) {
    val context = LocalContext.current
    var menu by remember(answer) { mutableStateOf(false) }
    LaunchedEffect(actionable) { if (!actionable) menu = false }
    BackHandler(menu && actionable && current()) { menu = false }
    Box(modifier) {
        val lit = bestFill.takeIf { answer.takesReturn }
        Surface(shape = RoundedCornerShape(20.dp), color = lit ?: if (dark) androidx.compose.ui.graphics.Color(0xFF303138) else if (answer.takesReturn) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
            contentColor = if (lit != null || dark) androidx.compose.ui.graphics.Color.White else if (answer.takesReturn) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.fillMaxWidth().height(100.dp).testTag("browser.field.answer")
                .combinedClickable(enabled = actionable && answer.copy.isNotEmpty(), onClick = onCopy,
                    onLongClick = { if (actionable && current()) menu = true })
                .semantics {
                    contentDescription = "${answer.question} is ${answer.result}"
                    stateDescription = if (copied) "Copied" else answer.resultNote
                }) {
            Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                AnswerSide(answer.question, answer.questionNote, false, Modifier.weight(1f))
                if (canSwap) IconButton(onClick = onSwap, enabled = actionable, modifier = Modifier.size(44.dp).testTag("browser.field.answer.swap")) {
                    Text("⇄", style = MaterialTheme.typography.titleMedium)
                } else Text("→", Modifier.width(44.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                AnswerSide(answer.result, if (copied) "Copied" else answer.resultNote, true, Modifier.weight(1f))
            }
        }
        // The answer's menu keeps the field and its keyboard focused. It has
        // no text input of its own; Back dismisses it before the field.
        DropdownMenu(menu && actionable && current(), { menu = false }, properties = PopupProperties(focusable = false)) {
            DropdownMenuItem(text = { Text("Copy Answer") }, enabled = answer.copy.isNotEmpty(), onClick = { menu = false; onCopy() })
            DropdownMenuItem(text = { Text("Copy Question") }, onClick = { menu = false; onQuestion() })
            if (canSwap) DropdownMenuItem(text = { Text("Swap") }, onClick = { menu = false; onSwap() })
            if (showPaste) DropdownMenuItem(text = { Text("Paste into Page") }, enabled = canPaste && answer.copy.isNotEmpty(), onClick = { menu = false; onPaste() })
            DropdownMenuItem(text = { Text("Share") }, enabled = answer.copy.isNotEmpty(), onClick = {
                menu = false
                if (!actionable || !current()) return@DropdownMenuItem
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"; putExtra(Intent.EXTRA_TEXT, answer.copy)
                }, null))
            })
        }
    }
}

@Composable
private fun AnswerSide(words: String, note: String, strong: Boolean, modifier: Modifier) {
    BoxWithConstraints(modifier.padding(horizontal = 6.dp), contentAlignment = Alignment.Center) {
        val density = LocalDensity.current
        val measurer = rememberTextMeasurer()
        val style = LocalTextStyle.current.merge(TextStyle(fontSize = 22.sp,
            fontWeight = if (strong) FontWeight.SemiBold else FontWeight.Normal))
        val available = with(density) { maxWidth.roundToPx() }
        val fitted = remember(words, strong, style, available, density.density, density.fontScale, measurer) {
            fun at(scale: Float) = style.copy(fontSize = (22f * scale).sp)
            fun fits(scale: Float) = measurer.measure(words, style = at(scale), softWrap = false,
                maxLines = 1, overflow = TextOverflow.Ellipsis, constraints = Constraints()).size.width <= available
            if (fits(1f)) style else {
                // Fixed inherited letter spacing does not scale with fontSize. Measure each
                // candidate's actual style instead of scaling a differently styled width.
                var low = 0.6f
                var high = 1f
                repeat(10) {
                    val middle = (low + high) / 2f
                    if (fits(middle)) low = middle else high = middle
                }
                at(low)
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(words, modifier = Modifier.fillMaxWidth(), style = fitted, textAlign = TextAlign.Center,
            softWrap = false, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(note.ifEmpty { " " }, Modifier.padding(top = 3.dp), maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelSmall, color = LocalContentColor.current.copy(alpha = 0.72f))
        }
    }
}

@Composable
internal fun FieldMathKeys(onKey: (String) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        for (symbol in listOf("+", "−", "×", "÷", "(", ")", "%")) {
            FilledTonalButton(onClick = { onKey(if (symbol == "−") "-" else symbol) },
                modifier = Modifier.weight(1f).fillMaxHeight().testTag("browser.field.math.$symbol"),
                shape = RoundedCornerShape(8.dp), contentPadding = PaddingValues(0.dp)) { Text(symbol) }
        }
    }
}

internal fun copyFieldValue(context: Context, value: String) {
    require(value.length <= 4096)
    requireNotNull(context.getSystemService(ClipboardManager::class.java)).setPrimaryClip(ClipData.newPlainText("Answer", value))
}

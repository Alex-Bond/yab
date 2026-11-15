package dev.yab.agent

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.runtime.remember
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.ClickableText
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import java.net.URI

/** Local text rendering only. HTML, script, file and app-command URLs never execute. */
object AgentMarkdown {
    data class Block(val text: String, val kind: Kind, val cells: List<List<String>> = emptyList())
    enum class Kind { PARAGRAPH, HEADING, ITEM, CODE, TABLE }
    fun blocks(source: String, streaming: Boolean = false): List<Block> {
        val output = mutableListOf<Block>()
        val paragraph = mutableListOf<String>()
        val code = mutableListOf<String>()
        var fence: String? = null
        val table = mutableListOf<List<String>>(); var ruled = false
        fun endTable() { if (table.isNotEmpty() && (ruled || !streaming)) output += Block(table.joinToString("\n") { it.joinToString(" | ") }, Kind.TABLE, table.toList()); table.clear(); ruled = false }
        fun flush() { if (paragraph.isNotEmpty()) { output += Block(paragraph.joinToString("\n"), Kind.PARAGRAPH); paragraph.clear() }; endTable() }
        var literalFence: String? = null
        val lines = source.lineSequence().map { raw ->
            val line = raw.trim()
            when {
                literalFence != null -> { if (line.startsWith(literalFence!!)) literalFence = null; raw }
                line.startsWith("```") || line.startsWith("~~~") -> { literalFence = line.take(3); raw }
                else -> raw.replace("<b>", "**").replace("</b>", "**").replace("<strong>", "**").replace("</strong>", "**").replace("<br>", "\n").replace("<br/>", "\n")
            }
        }.joinToString("\n").lines().let { if (streaming && it.lastOrNull()?.trim()?.startsWith('|') == true) it.dropLast(1) else it }
        for (raw in lines) {
            val line = raw.trim()
            if (fence != null) {
                if (line.startsWith(fence!!)) { output += Block(code.joinToString("\n"), Kind.CODE); code.clear(); fence = null }
                else code += raw
            } else if (line.startsWith('|')) {
                if (paragraph.isNotEmpty()) { output += Block(paragraph.joinToString("\n"), Kind.PARAGRAPH); paragraph.clear() }
                val cells = line.trim('|').split('|').map(String::trim)
                if (cells.all { cell -> cell.isNotEmpty() && cell.all { it in "-: " } }) ruled = true else table.add(cells)
            } else {
                endTable()
                when {
                line.startsWith("```") || line.startsWith("~~~") -> { flush(); fence = line.take(3) }
                line.isBlank() -> flush()
                Regex("^#{1,6}\\s+").containsMatchIn(line) -> { flush(); output += Block(line.replaceFirst(Regex("^#{1,6}\\s+"), ""), Kind.HEADING) }
                Regex("^([-*•]|\\d+[.)])\\s+").containsMatchIn(line) -> { flush(); output += Block(line.replaceFirst(Regex("^[-*]\\s+"), "• "), Kind.ITEM) }
                else -> paragraph += raw
                }
            }
        }
        flush()
        if (fence != null) output += Block(code.joinToString("\n"), Kind.CODE)
        if (streaming && output.isNotEmpty() && output.last().kind !in setOf(Kind.TABLE, Kind.CODE)) {
            val last = output.removeAt(output.lastIndex); output += last.copy(text = settled(last.text))
        }
        return output
    }
    /** Phone ChatMarkdown.parts: consecutive items and their short lead-in share a bubble. */
    fun parts(blocks: List<Block>): List<List<Int>> {
        val parts = mutableListOf<MutableList<Int>>()
        blocks.forEachIndexed { index, block ->
            val previous = parts.lastOrNull()?.lastOrNull()?.let(blocks::get)
            if (block.kind == Kind.ITEM && previous != null &&
                (previous.kind == Kind.ITEM || previous.kind == Kind.PARAGRAPH && previous.text.length < 60 && parts.last().size == 1)) {
                parts.last().add(index)
            } else parts.add(mutableListOf(index))
        }
        return parts
    }
    fun settled(words: String): String {
        var text = words
        if (text.split("**").size % 2 == 0) text = text.substringBeforeLast("**")
        val open = text.lastIndexOf('[')
        if (open >= 0) { val tail = text.substring(open + 1); if (!tail.contains("]") || tail.contains("](") && !tail.substringAfter("](").contains(')')) text = text.take(open) }
        return text
    }
    fun safeUrl(value: String): Boolean = try {
        val uri = URI(value)
        value.toByteArray().size <= 8192 && value.none(Char::isISOControl) && uri.rawUserInfo == null && uri.scheme?.lowercase() in listOf("https", "http") && !uri.host.isNullOrBlank()
    } catch (_: Exception) { false }

    fun inline(source: String, linkColor: Color): AnnotatedString = buildAnnotatedString {
        val token = Regex("\\[([^]\\n]+)]\\(([^)\\s]+)\\)|\\*\\*([^*]+)\\*\\*|`([^`]+)`|(?<!\\*)\\*([^*]+)\\*(?!\\*)|~~([^~]+)~~|https?://[^\\s<>()\\[\\]\"']+")
        var cursor = 0
        for (match in token.findAll(source)) {
            append(source.substring(cursor, match.range.first))
            val label = match.groups[1]?.value
            val url = match.groups[2]?.value
            when {
                label != null && url != null -> {
                    if (safeUrl(url)) { pushStringAnnotation("website", url); withStyle(SpanStyle(color = linkColor)) { append(label) }; pop() }
                    else append(label)
                }
                match.groups[3] != null -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(match.groups[3]!!.value) }
                match.groups[4] != null -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(match.groups[4]!!.value) }
                match.groups[5] != null -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(match.groups[5]!!.value) }
                match.groups[6] != null -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { append(match.groups[6]!!.value) }
                safeUrl(match.value.trimEnd('.', ',', ';', ':', '!', '?')) -> {
                    val urlValue = match.value.trimEnd('.', ',', ';', ':', '!', '?')
                    pushStringAnnotation("website", urlValue); withStyle(SpanStyle(color = linkColor)) { append(urlValue) }; pop(); append(match.value.removePrefix(urlValue))
                }
                else -> append(match.value)
            }
            cursor = match.range.last + 1
        }
        append(source.substring(cursor))
    }
}

@Composable
fun AgentMarkdownText(text: String, onOpenWebsite: (String) -> Unit, modifier: Modifier = Modifier, streaming: Boolean = false) {
    Column(modifier) {
        for (block in AgentMarkdown.blocks(text, streaming)) {
            Column(Modifier.padding(vertical = 4.dp)) { AgentMarkdownBlockText(block, onOpenWebsite) }
        }
    }
}

/** Render parsed blocks without losing heading, code or table semantics between bubbles. */
@Composable
internal fun AgentMarkdownBlockText(block: AgentMarkdown.Block, onOpenWebsite: (String) -> Unit,
    onHeld: (() -> Unit)? = null, selecting: Boolean = false) {
    val clipboard = LocalClipboardManager.current
    val style = when (block.kind) {
        AgentMarkdown.Kind.HEADING -> MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold)
        AgentMarkdown.Kind.CODE -> MaterialTheme.typography.bodyLarge.copy(fontSize = androidx.compose.ui.unit.TextUnit(15.5f, androidx.compose.ui.unit.TextUnitType.Sp), lineHeight = androidx.compose.ui.unit.TextUnit(20f, androidx.compose.ui.unit.TextUnitType.Sp), fontFamily = FontFamily.Monospace)
        AgentMarkdown.Kind.TABLE -> MaterialTheme.typography.bodyLarge
        else -> MaterialTheme.typography.bodyLarge
    }
    val content = AgentMarkdown.inline(block.text, MaterialTheme.colorScheme.primary)
    when (block.kind) {
        AgentMarkdown.Kind.CODE -> {
            val dark = MaterialTheme.colorScheme.background.luminance() < .2f
            Text(block.text, style = style, modifier = Modifier.fillMaxWidth()
                .background(if (dark) Color(0xFF1C1C1E) else Color(0xFFF2F2F4), androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                .horizontalScroll(rememberScrollState()).padding(12.dp))
        }
        AgentMarkdown.Kind.TABLE -> ChatTable(block.cells, onOpenWebsite)
        else -> {
            val layout = remember(block.text) { arrayOfNulls<TextLayoutResult>(1) }
            val links = content.getStringAnnotations("website", 0, content.length).isNotEmpty()
            // Plain paragraphs own no tap recognizer: the message receives its hold.
            // Linked text handles both gestures in one recognizer, so links cannot steal the hold.
            val gestures = if (!links || selecting) Modifier else Modifier.pointerInput(content, onOpenWebsite, onHeld) {
                detectTapGestures(onLongPress = onHeld?.let { held -> { _: androidx.compose.ui.geometry.Offset -> held() } }, onTap = { position ->
                    layout[0]?.getOffsetForPosition(position)?.let { offset ->
                        content.getStringAnnotations("website", offset, offset).firstOrNull()?.let {
                            if (AgentMarkdown.safeUrl(it.item)) onOpenWebsite(it.item)
                        }
                    }
                })
            }
            Text(content, style = style.copy(color = MaterialTheme.colorScheme.onSurface), modifier = gestures,
                onTextLayout = { layout[0] = it })
        }
    }
}

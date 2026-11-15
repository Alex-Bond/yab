package dev.yab.agent

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.ui.BrowserFavicon

@Composable
internal fun ChatSiteMark(url: String, size: androidx.compose.ui.unit.Dp, privateOrigin: Boolean = false) {
    BrowserFavicon(BrowserTab("chat-site", url = url, isPrivate = privateOrigin, createdAt = 0), size)
}

/** Four columns become row cards; compact tables retain their ruled, proportional grid. */
@Composable
internal fun ChatTable(rows: List<List<String>>, open: (String) -> Unit) {
    val header = rows.firstOrNull().orEmpty()
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    val fill = if (dark) Color(0xFF262628) else Color(0xFFE9E9EB)
    if (header.size > 3) {
        val layout = remember(rows) { ChatTableLayout.read(rows) }
        Column(Modifier.fillMaxWidth().testTag("chat.table.cards"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            rows.drop(1).forEachIndexed { index, row ->
                Surface(shape = RoundedCornerShape(18.dp), color = fill, modifier = Modifier.fillMaxWidth().testTag("chat.table.card.$index")) {
                    Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
                        layout.cell(row, layout.kicker).takeIf(String::isNotEmpty)?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 3.dp)) }
                        Text(AgentMarkdown.inline(layout.cell(row, layout.title), ChatVisuals.blue), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                        layout.words.forEach { i -> layout.cell(row, i).takeIf(String::isNotEmpty)?.let {
                            Text(AgentMarkdown.inline(it, ChatVisuals.blue), Modifier.padding(top = 5.dp), fontSize = 15.sp, lineHeight = 20.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .82f))
                        } }
                        val foot = layout.footLine(row, header); val source = layout.cell(row, layout.source)
                        if (foot.isNotEmpty() || source.isNotEmpty()) Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(AgentMarkdown.inline(foot, ChatVisuals.blue), Modifier.weight(1f), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (source.isNotEmpty()) {
                                val url = ChatTableLayout.sourceUrl(source)
                                Row(Modifier.clickable(enabled = url != null) { url?.let(open) }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                    url?.let { ChatSiteMark(it, 14.dp) }
                                    Text(AgentMarkdown.inline(source, ChatVisuals.blue).text.let { if (it.contains("://")) it.substringAfter("://").substringBefore('/') else it }, fontSize = 14.sp, color = ChatVisuals.blue, maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }
        }
    } else if (header.isNotEmpty()) Surface(Modifier.fillMaxWidth().testTag("chat.table.grid"), shape = RoundedCornerShape(8.dp),
        color = Color.Transparent, border = BorderStroke(.5.dp, Color(0xFF767680).copy(alpha = if (dark) .24f else .12f))) {
        val numbers = header.indices.map { i -> rows.size > 1 && rows.drop(1).all { ChatTableLayout.numeric(it.getOrNull(i).orEmpty()) } }
        Column {
            rows.forEachIndexed { index, row ->
                if (index > 0) HorizontalDivider(thickness = .5.dp, color = Color(0xFF767680).copy(alpha = .1f))
                Surface(color = if (index == 0) Color(0xFF767680).copy(alpha = .05f) else Color.Transparent) {
                    Row(Modifier.fillMaxWidth()) {
                        header.indices.forEach { column -> Text(AgentMarkdown.inline(ChatTableLayout.bare(row.getOrNull(column).orEmpty()), ChatVisuals.blue),
                            Modifier.weight(1f).padding(horizontal = 12.dp, vertical = if (index == 0) 7.dp else 9.dp), fontSize = if (index == 0) 13.sp else 15.sp,
                            color = if (index == 0) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                            fontWeight = if (index == 0 || column == 0) FontWeight.Medium else FontWeight.Normal,
                            textAlign = if (numbers[column]) TextAlign.End else TextAlign.Start)
                        }
                    }
                }
            }
        }
    }
}

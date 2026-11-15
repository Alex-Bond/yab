package dev.yab.agent

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Phone ResultCardsView: the existing accepted result payload, presented without new actions. */
@Composable fun ChatResultCards(cards: List<ChatResultCard>, open: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        cards.forEach { card ->
            val rows = card.kind in setOf("links", "folder", "table")
            val dark = MaterialTheme.colorScheme.background.luminance() < .2f
            Surface(Modifier.widthIn(max = 356.dp).fillMaxWidth().testTag("chat.card.${card.kind}"),
                shape = RoundedCornerShape(20.dp), color = if (dark) Color(0xFF2C2C2E) else Color.White,
                border = BorderStroke(.5.dp, (if (dark) Color.White else Color.Black).copy(alpha = .08f)), shadowElevation = if (dark) 0.dp else 2.dp) {
                Column(Modifier.padding(if (rows) 6.dp else 12.dp)) {
                    when (card.kind) {
                        "links", "folder", "table" -> {
                            if (card.kind == "folder") ResultRow(null, open) {
                                Text(card.title, Modifier.weight(1f), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                                Text("on your Mac", fontSize = 13.sp, color = chatGray(.5f))
                            }
                            card.rows.orEmpty().forEachIndexed { index, row ->
                                val url = row.url?.takeIf(AgentMarkdown::safeUrl)
                                val lit = card.kind == "table" && index == card.lit
                                ResultRow(url, open, lit) {
                                    val site = url ?: row.site?.let(ChatTableLayout::sourceUrl)
                                    site?.let { ChatSiteMark(it, 20.dp) }
                                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                                        Text(row.title, fontSize = 15.sp, fontWeight = if (card.kind == "links") FontWeight.Medium else FontWeight.Normal,
                                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        if (card.kind == "links") {
                                            val host = row.site ?: url?.let { runCatching { java.net.URI(it).host?.removePrefix("www.") }.getOrNull() }
                                            val under = listOfNotNull(host, row.minutes?.let { "$it min" }).joinToString(" · ")
                                            if (under.isNotEmpty()) Text(under, fontSize = 13.sp, color = chatGray(.5f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        }
                                    }
                                    if (card.kind == "table") Text(row.cells.orEmpty().joinToString(" · "), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                                }
                            }
                        }
                        "event" -> Row(Modifier.resultLink(card.url, open), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            val at = resultDate(card.at)
                            Surface(Modifier.size(34.dp, 36.dp), shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surface,
                                border = BorderStroke(.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = .1f))) {
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    Box(Modifier.fillMaxWidth().height(11.dp).background(Color(0xFFE6484D)), contentAlignment = Alignment.Center) {
                                        Text(at?.format(DateTimeFormatter.ofPattern("EEE", Locale.US))?.uppercase(Locale.US).orEmpty(), fontSize = 8.sp, lineHeight = 9.sp, fontWeight = FontWeight.Bold, color = Color.White)
                                    }
                                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { Text(at?.dayOfMonth?.toString().orEmpty(), fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
                                }
                            }
                            ResultTwo(card.title, listOfNotNull(resultHours(card), card.detail).joinToString(" · "))
                        }
                        "promise" -> Text(resultPromise(card), fontSize = 15.sp)
                        "watch" -> Box(Modifier.resultLink(card.url, open)) {
                            ResultTwo("Watching: ${card.title}", card.value?.let { "Now $it" + card.site?.let { site -> " on $site" }.orEmpty() }.orEmpty())
                        }
                        "routine" -> ResultTwo(card.title, card.detail.orEmpty())
                    }
                }
            }
        }
    }
}

private fun Modifier.resultLink(address: String?, open: (String) -> Unit): Modifier {
    val url = address?.takeIf(AgentMarkdown::safeUrl)
    return clickable(enabled = url != null) { url?.let(open) }
}
@Composable private fun ResultRow(url: String?, open: (String) -> Unit, lit: Boolean = false, content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 36.dp).background(if (lit) MaterialTheme.colorScheme.onSurface.copy(alpha = .05f) else Color.Transparent, RoundedCornerShape(10.dp))
        .resultLink(url, open).padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp), content = content)
}
@Composable private fun ResultTwo(title: String, detail: String) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (detail.isNotEmpty()) Text(detail, fontSize = 13.sp, color = chatGray(.5f), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
private fun resultDate(seconds: Double?): ZonedDateTime? = seconds?.takeIf { it.isFinite() && it in -62_135_596_800.0..253_402_300_799.0 }
    ?.let { runCatching { Instant.ofEpochSecond(it.toLong()).atZone(ZoneId.systemDefault()) }.getOrNull() }
private fun resultHours(card: ChatResultCard): String? {
    val start = resultDate(card.at) ?: return null
    val format = DateTimeFormatter.ofPattern("h:mm a", Locale.US)
    val first = start.format(format)
    val end = resultDate(card.end) ?: return first
    return (if ((start.hour < 12) == (end.hour < 12)) first.dropLast(3) else first) + " – " + end.format(format)
}
private fun resultPromise(card: ChatResultCard): String {
    val who = card.title.ifBlank { "nobody" }
    val at = resultDate(card.at) ?: return "Tells you when " + if (card.title.isBlank()) "they answer" else "$who answers"
    val day = when (java.time.temporal.ChronoUnit.DAYS.between(LocalDate.now(), at.toLocalDate())) {
        0L -> "today"; 1L -> "tomorrow"
        in 2L..6L -> at.format(DateTimeFormatter.ofPattern("EEEE", Locale.US))
        else -> at.format(DateTimeFormatter.ofPattern("MMM d", Locale.US))
    }
    return "Back in your inbox $day if $who hasn’t answered"
}

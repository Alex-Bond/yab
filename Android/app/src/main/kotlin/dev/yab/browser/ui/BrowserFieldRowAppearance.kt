package dev.yab.browser.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserSpaceLook
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.BrowserVisit
import dev.yab.browser.model.SpaceLookColor

/** TypedRows uses the picked primary, not the readable wash/ground behind the card. */
internal fun browserFieldBestFill(space: BrowserSpace?, privately: Boolean): Color {
    if (privately || space?.isPrivate == true) return Color.White.copy(alpha = .18f)
    val primary = space?.let { browserSurfaceLook(it)?.primary ?: unwash(it.color) } ?: 0xFF808080L
    return Color(SpaceLookColor.filled(primary))
}

/** The space's own picked color, or its wash with the white taken back out. */
internal fun browserSpaceOwnColor(space: BrowserSpace?): Color =
    Color(space?.let { browserSurfaceLook(it)?.primary ?: unwash(it.color) } ?: 0xFF808080L)

/** The sheet's first rows: a page from history, its icon on the row's column. */
@Composable
internal fun BrowserRecentRow(visit: BrowserVisit, ink: Color, action: () -> Unit) {
    val page = remember(visit.url) { BrowserTab(id = "recent:" + visit.url, url = visit.url, title = visit.title, createdAt = 0) }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(onClick = action).heightIn(min = 46.dp)
        .padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        BrowserFavicon(page, 22.dp, loads = true)
        Text(buildAnnotatedString {
            append(visit.title.ifBlank { page.host })
            withStyle(SpanStyle(color = ink.copy(alpha = .62f))) { append("  ${page.host}") }
        }, color = ink, fontSize = 16.sp, fontWeight = FontWeight.Medium, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
    }
}

/** Phone WordRowView: one line, 46 high, no trailing disclosure or keyboard word. */
@Composable
internal fun BrowserTypedRow(title: String, icon: ImageVector, detail: String? = null, action: () -> Unit) {
    val ink = LocalBrowserRowInk.current ?: MaterialTheme.colorScheme.onSurface
    Row(Modifier.fillMaxWidth().clickable(onClick = action).heightIn(min = 46.dp)
        .padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, null, Modifier.size(22.dp), tint = ink)
        Text(buildAnnotatedString {
            append(title)
            if (!detail.isNullOrEmpty()) withStyle(SpanStyle(color = ink.copy(alpha = .62f))) { append("  $detail") }
        }, color = ink, fontSize = 16.sp, fontWeight = FontWeight.Medium, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
    }
}

/** Inverse of the legacy SyncMapping.tint wash, before the source OKLCH filled transform. */
private fun unwash(tint: Long): Long = BrowserSpaceLook.rgb(
    BrowserSpaceLook.roundComponent((BrowserSpaceLook.component(tint, 16) - 255 * .82) / .18),
    BrowserSpaceLook.roundComponent((BrowserSpaceLook.component(tint, 8) - 255 * .82) / .18),
    BrowserSpaceLook.roundComponent((BrowserSpaceLook.component(tint, 0) - 255 * .82) / .18),
)

/** Decoration only. The original ActionRow keeps its own layout, semantics and action. */
@Composable
internal fun BrowserFieldBestRow(fill: Color?, content: @Composable () -> Unit) {
    if (fill == null) content()
    else CompositionLocalProvider(LocalBrowserRowInk provides Color.White) {
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(fill)) { content() }
    }
}

/** Words.question on Phone, used only to order the existing search/ask controls. */
internal fun browserFieldQuestion(text: String): Boolean {
    val trimmed = text.trim()
    val words = trimmed.lowercase(java.util.Locale.ROOT).split(Regex("\\s+")).filter(String::isNotEmpty)
    if (words.size < 2 || "://" in trimmed) return false
    if (trimmed.endsWith('?')) return true
    return words.size >= 3 && words.first().trim { !it.isLetter() && it != '\'' } in setOf(
        "how", "what", "why", "who", "whom", "whose", "which", "when", "where", "is", "are", "was", "were",
        "can", "could", "does", "do", "did", "should", "would", "will", "whats", "what's", "how's")
}

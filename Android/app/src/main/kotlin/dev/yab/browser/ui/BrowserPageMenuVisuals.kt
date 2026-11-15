package dev.yab.browser.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Phone MenuRowLabel/SiteSettingsPage geometry; this layer owns no actions or page state. */
@Composable internal fun PageMenuCard(modifier: Modifier = Modifier, site: Boolean = false,
    content: @Composable ColumnScope.() -> Unit) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    val color = if (site) Color.White.copy(alpha = if (dark) .08f else .62f)
        else (if (dark) Color.White else Color.Black).copy(alpha = if (dark) .08f else .06f)
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(color), content = content)
}

@Composable internal fun PageMenuDivider(site: Boolean = false) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    HorizontalDivider(Modifier.padding(start = if (site) 54.dp else 0.dp), thickness = .5.dp,
        color = if (dark) Color.White.copy(alpha = .1f) else Color(0xFF3C3C43).copy(alpha = .18f))
}

@Composable internal fun PageMenuLine(title: String, icon: ImageVector, action: (() -> Unit)? = null,
    subtitle: String? = null, chevron: Boolean = false, grayed: Boolean = false,
    tile: Color? = null, modifier: Modifier = Modifier, destructive: Boolean = false,
    trailing: (@Composable () -> Unit)? = null) {
    val ink = MaterialTheme.colorScheme.onSurface
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    val red = if (MaterialTheme.colorScheme.background.luminance() < .2f) Color(0xFFFF453A) else Color(0xFFFF3B30)
    Row(modifier.fillMaxWidth().heightIn(min = if (tile == null) 54.dp else 52.dp)
        .then(if (grayed) Modifier.semantics { disabled() } else Modifier)
        .then(if (action != null) Modifier.clickable(onClick = action) else Modifier)
        .padding(start = 16.dp, end = if (tile == null) 10.dp else 14.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(if (tile == null) 24.dp else 28.dp)
            .then(if (tile == null) Modifier else Modifier.background(tile, RoundedCornerShape(7.dp))),
            contentAlignment = Alignment.Center) {
            Icon(icon, null, Modifier.size(if (tile == null) 20.dp else 18.dp),
                tint = if (tile != null) Color.White else if (grayed) secondary.copy(alpha = .45f) else ink)
        }
        Spacer(Modifier.width(if (tile == null) 14.dp else 10.dp))
        Column(Modifier.weight(1f).padding(end = 8.dp)) {
            Text(title, fontSize = 17.sp, lineHeight = 20.3.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                color = if (grayed) secondary.copy(alpha = .45f) else if (destructive) red else ink)
            subtitle?.let { Text(it, fontSize = 13.sp, lineHeight = 16.sp, color = secondary, maxLines = 2) }
        }
        trailing?.invoke()
        if (chevron) Icon(YabGlyphs.ChevronRight, null, Modifier.size(16.dp), tint = secondary)
    }
}

@Composable internal fun PageMenuTile(title: String, icon: ImageVector, enabled: Boolean,
    selected: Boolean = false, modifier: Modifier = Modifier, action: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    Column(modifier.clickable(enabled = enabled, onClick = action).testTag("page.menu.tile.$title"),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().height(78.dp).clip(RoundedCornerShape(20.dp))
            .background(if (selected) ink else (if (dark) Color.White else Color.Black).copy(alpha = if (dark) .08f else .06f)),
            contentAlignment = Alignment.Center) {
            Icon(icon, null, Modifier.size(24.dp), tint = when {
                selected -> MaterialTheme.colorScheme.surface
                enabled -> ink
                else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .45f)
            })
        }
        Text(title, Modifier.padding(top = 8.dp), fontSize = 12.5.sp, lineHeight = 15.sp, maxLines = 2,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

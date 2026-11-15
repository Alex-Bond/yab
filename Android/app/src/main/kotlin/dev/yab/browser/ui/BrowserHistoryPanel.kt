package dev.yab.browser.ui

import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.*
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.util.Date
import java.util.Locale

@Composable
internal fun BrowserHistoryPanel(state: BrowserState, controller: BrowserController) {
    val lifetime by controller.settingsPresentationLifetime.collectAsState()
    val historyLifetime by controller.historyPresentationLifetime.collectAsState()
    val rowSources by controller.historyRowPresentationSources.collectAsState()
    val lease = remember(controller, lifetime, historyLifetime, state.surfaceEpoch, state.selectedSpaceId, state.tab?.id, state.space?.websiteProfile) {
        controller.captureHistoryPresentation()
    }
    var query by remember(controller, state.surfaceEpoch) { mutableStateOf("") }
    var clearLease by remember(controller, state.surfaceEpoch) { mutableStateOf<HistoryPresentationLease?>(null) }
    LaunchedEffect(lease) { if (lease == null || clearLease?.let(controller::historyActionsCurrent) == false) clearLease = null }
    val keyboard = LocalSoftwareKeyboardController.current
    val view = LocalView.current
    val rows = remember(controller, lease, view, keyboard) {
        BrowserHistoryRows(current = { lease?.let(controller::historyActionsCurrent) == true },
            accepts = controller::historyRowActionsCurrent,
            open = { original -> controller.openHistoryRow(original).also { if (it) keyboard?.hide() } },
            delete = { original -> controller.deleteHistoryRow(original).also { if (it) view.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY) } })
    }
    HistoryRowsClock(rows)
    val locale = LocalConfiguration.current.locales[0] ?: Locale.ROOT
    val zone = ZoneId.systemDefault()
    val now = System.currentTimeMillis()
    val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val days = remember(state.history, query, today, zone) {
        HistoryPresentation.days(HistoryPresentation.matching(state.history, query), now, zone)
    }
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val leave = tween<Float>(if (reduced) 200 else 130,
        easing = if (reduced) androidx.compose.animation.core.CubicBezierEasing(.42f, 0f, .58f, 1f) else BrowserMotion.easeIn)
    val placement = tween<androidx.compose.ui.unit.IntOffset>(if (reduced) 200 else 130,
        easing = if (reduced) androidx.compose.animation.core.CubicBezierEasing(.42f, 0f, .58f, 1f) else BrowserMotion.easeIn)
    val time = remember(locale) { DateFormat.getTimeInstance(DateFormat.SHORT, locale) }
    val dayFormat = remember(locale, today.year) {
        fun format(skeleton: String) = SimpleDateFormat(android.text.format.DateFormat.getBestDateTimePattern(locale, skeleton), locale)
        format("EEEEMMMMd") to format("yEEEEMMMMd")
    }
    MaterialTheme(colorScheme = settingsColors()) {
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding().navigationBarsPadding().imePadding()) {
        val top = with(LocalDensity.current) { WindowInsets.statusBars.getTop(this).toDp() }
        Spacer(Modifier.height((60.dp - top).coerceAtLeast(0.dp)))
        Box(Modifier.fillMaxWidth().height(54.dp)) {
            Surface(Modifier.align(Alignment.CenterStart).padding(start = 12.dp).size(44.dp), shape = CircleShape,
                color = MaterialTheme.colorScheme.surface, shadowElevation = 6.dp) {
                IconButton(onClick = { lease?.let(controller::dismissHistory) }) { Icon(YabGlyphs.ChevronLeft, "Back", Modifier.size(22.dp)) }
            }
            Text("History", Modifier.align(Alignment.Center), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        LazyColumn(Modifier.weight(1f).testTag("history.page"),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 40.dp)) {
            item(key = "search") {
            Row(Modifier.padding(bottom = 16.dp)
                .fillMaxWidth().heightIn(min = 44.dp).background(MaterialTheme.colorScheme.surface, CircleShape)
                .padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(YabGlyphs.MagnifyingGlass, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                BasicTextField(query, { query = it }, Modifier.weight(1f).padding(start = 10.dp, top = 10.dp, bottom = 10.dp).testTag("history.search").semantics { contentDescription = "Search History" },
                    singleLine = true, textStyle = androidx.compose.ui.text.TextStyle(fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.onSurface), decorationBox = { editor ->
                        Box { if (query.isEmpty()) Text("Search History", fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant); editor() }
                    })
                if (query.isNotEmpty()) IconButton(onClick = { query = "" }, modifier = Modifier.size(28.dp).testTag("history.search.clear")) {
                    Icon(YabGlyphs.CircleX, "Clear Search", Modifier.size(18.dp))
                }
            }
            }
            if (state.history.isNotEmpty() && query.isEmpty()) item(key = "clear") {
                SettingsGroup {
                    Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).testTag("history.clear").clickable {
                        lease?.takeIf(controller::historyActionsCurrent)?.let { clearLease = it }
                    }.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("Clear History…", fontSize = 17.sp, color = MaterialTheme.colorScheme.error)
                    }
                }
            }
            if (days.isEmpty()) item(key = "empty") {
                if (state.history.isEmpty()) {
                    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 60.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(YabGlyphs.History, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text("No History", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                        Text("Pages you open on this device and synced history show here.",
                            fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    }
                } else Box(Modifier.fillMaxWidth().heightIn(min = 44.dp), contentAlignment = Alignment.Center) {
                    Text("No pages found", color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag("history.search.empty"))
                }
            } else {
                for (day in days) {
                    item(key = "day:${day.date}") {
                        val title = when (day.date) {
                            today -> "Today"
                            today.minusDays(1) -> "Yesterday"
                            else -> (if (day.date.year == today.year) dayFormat.first else dayFormat.second)
                                .format(Date(day.date.atStartOfDay(zone).toInstant().toEpochMilli()))
                        }
                        Text(title.uppercase(locale), Modifier.padding(start = 8.dp, end = 8.dp, top = 22.dp, bottom = 6.dp).semantics { heading() },
                            fontSize = 12.sp, letterSpacing = .36.sp, fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    itemsIndexed(day.visits, key = { _, visit -> visit.identity }) { index, visit ->
                        val captured = remember(controller, lease, visit, rowSources[visit.identity]) {
                            lease?.let { controller.captureHistoryRow(it, visit) }
                        }
                        val original = remember(captured) { captured }
                        if (original != null) BrowserHistoryRow(original, rows, index == 0, index == day.visits.lastIndex, time,
                            Modifier.animateItem(fadeInSpec = null,
                                fadeOutSpec = leave, placementSpec = placement))
                    }
                }
            }
        }
    }
    clearLease?.let { original ->
        AlertDialog(onDismissRequest = { clearLease = null }, title = { Text("Clear History?") }, text = {
            Column {
                Text("Pages go from History on this device. History on your Mac stays as it is.")
                for (range in HistoryRange.entries) TextButton(onClick = {
                    if (controller.historyActionsCurrent(original)) rows.motion.close()
                    controller.clearHistory(original, range)
                    clearLease = null
                }, modifier = Modifier.testTag("history.clear.${range.name}")) { Text(range.title, color = MaterialTheme.colorScheme.error) }
            }
        }, confirmButton = { TextButton(onClick = { clearLease = null }) { Text("Cancel") } })
    }
    }
}

package dev.yab.browser.model

import java.net.URI
import java.text.Normalizer
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

/** An old row/dialog cannot borrow a reopened History screen or a new account. */
data class HistoryPresentationLease internal constructor(
    internal val ownership: Long,
    internal val foreground: Long,
    internal val privateBoundary: Long,
    internal val sourceGeneration: Long,
    internal val epoch: Long,
    internal val space: String,
    internal val front: String?,
    internal val profile: WebsiteProfile?,
)

enum class HistoryRange(val title: String) {
    LAST_HOUR("Last Hour"), TODAY("Today"), TODAY_AND_YESTERDAY("Today and Yesterday"), ALL_TIME("All Time");

    fun start(now: Long, zone: ZoneId): Long = when (this) {
        LAST_HOUR -> now - 3_600_000L
        TODAY -> Instant.ofEpochMilli(now).atZone(zone).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli()
        TODAY_AND_YESTERDAY -> Instant.ofEpochMilli(now).atZone(zone).toLocalDate().minusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        ALL_TIME -> 0L
    }
}

data class HistoryDay(val date: LocalDate, val visits: List<BrowserVisit>)

/** The Phone HistoryList's display rules, independent of its sync projection. */
object HistoryPresentation {
    fun pretty(address: String): String = runCatching {
        val url = URI(address)
        val host = requireNotNull(url.host).removePrefix("www.")
        val bare = host + if (url.port >= 0) ":${url.port}" else ""
        bare + url.rawPath.orEmpty().takeUnless { it == "/" }.orEmpty() +
            url.rawQuery?.takeIf(String::isNotEmpty)?.let { "?$it" }.orEmpty() +
            url.rawFragment?.takeIf(String::isNotEmpty)?.let { "#$it" }.orEmpty()
    }.getOrDefault(address)

    fun matching(visits: List<BrowserVisit>, query: String): List<BrowserVisit> {
        val words = fold(query).split(Regex("[\\s\\p{Z}]+")).filter(String::isNotEmpty)
        if (words.isEmpty()) return visits
        return visits.filter { visit ->
            val haystack = fold(visit.title + " " + pretty(visit.url))
            words.all(haystack::contains)
        }
    }

    fun days(visits: List<BrowserVisit>, now: Long, zone: ZoneId): List<HistoryDay> {
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        return visits.sortedWith(compareByDescending<BrowserVisit> { it.visitedAt }.thenBy { it.identity })
            .groupBy { Instant.ofEpochMilli(it.visitedAt).atZone(zone).toLocalDate().coerceAtMost(today) }
            .map { (day, rows) -> HistoryDay(day, rows) }
    }

    private fun fold(text: String): String = Normalizer.normalize(text, Normalizer.Form.NFKD)
        .replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT)
}

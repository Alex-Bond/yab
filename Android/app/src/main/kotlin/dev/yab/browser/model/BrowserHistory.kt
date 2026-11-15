package dev.yab.browser.model

import java.net.URI
import java.net.URLDecoder
import kotlinx.serialization.Serializable

/** Local hides never delete another device's shared history. Dates retain wire precision. */
@Serializable
data class HistoryForgetting(val places: Map<String, Double> = emptyMap(), val spans: List<HistorySpan> = emptyList()) {
    fun hides(key: String, last: Double): Boolean = places[key]?.let { last <= it } == true || spans.any { last >= it.from && last <= it.to }
    fun forget(key: String, last: Double): HistoryForgetting {
        require(last.isFinite())
        return copy(places = places + (key to maxOf(places[key] ?: 0.0, last)))
    }
    fun clear(from: Double, to: Double): HistoryForgetting {
        require(from.isFinite() && to.isFinite() && from <= to)
        val merged = mutableListOf<HistorySpan>()
        for (span in (spans + HistorySpan(from, to)).sortedBy { it.from }) {
            val previous = merged.lastOrNull()
            if (previous != null && span.from <= previous.to) merged[merged.lastIndex] = previous.copy(to = maxOf(previous.to, span.to))
            else merged += span
        }
        return copy(spans = merged)
    }
    fun prune(now: Long): HistoryForgetting {
        val floor = now / 1000.0 - 15 * 86_400
        return copy(places = places.filterValues { it >= floor }, spans = spans.filter { it.to >= floor })
    }
    fun merged(other: HistoryForgetting): HistoryForgetting {
        var combined = this
        for ((key, at) in other.places) combined = combined.forget(key, at)
        for (span in other.spans) combined = combined.clear(span.from, span.to)
        return combined
    }
}

@Serializable data class HistorySpan(val from: Double, val to: Double)

object BrowserHistory {
    fun key(text: String): String = runCatching { URI(text).let { uri ->
        val host = requireNotNull(uri.host).removePrefix("www.")
        val bare = if (':' in host && !host.startsWith('[')) "[$host]" else host
        (bare + uri.path.takeUnless { it.isNullOrBlank() || it == "/" }.orEmpty()).lowercase()
    } }.getOrDefault(text.lowercase())

    /** The iOS rule excludes sign-in handoffs and credentials, while local History is independent. */
    fun exportable(visit: BrowserVisit, now: Long): Boolean = runCatching {
        if (visit.syncedKey != null || now - visit.visitedAt > 14L * 86_400_000) return false
        val uri = URI(visit.url)
        if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrEmpty() || uri.rawUserInfo != null) return false
        val names = uri.rawQuery?.split('&').orEmpty().map { URLDecoder.decode(it.substringBefore('='), "UTF-8").lowercase() }.toSet()
        "login_hint" !in names && !names.containsAll(setOf("client_id", "redirect_uri")) && !names.containsAll(setOf("code", "state"))
    }.getOrDefault(false)
}

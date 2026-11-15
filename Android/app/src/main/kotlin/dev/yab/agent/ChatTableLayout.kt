package dev.yab.agent

/** The presentation roles used by Sources/Fast/TableCards.swift and Phone ChatMarkdown. */
internal data class ChatTableLayout(val title: Int, val kicker: Int?, val words: List<Int>, val foot: List<Int>, val source: Int?) {
    fun cell(row: List<String>, index: Int?) = index?.let { bare(row.getOrNull(it).orEmpty()) }.orEmpty()
    fun footLine(row: List<String>, header: List<String>) = foot.mapNotNull { index ->
        cell(row, index).takeIf(String::isNotEmpty)?.let { if (numeric(it)) "${header.getOrNull(index).orEmpty()} $it" else it }
    }.joinToString(" · ")
    companion object {
        fun read(rows: List<List<String>>): ChatTableLayout {
            val header = rows.firstOrNull().orEmpty(); val body = rows.drop(1)
            fun cells(index: Int) = body.map { bare(it.getOrNull(index).orEmpty()) }.filter(String::isNotEmpty)
            val source = header.indices.firstOrNull { i ->
                header[i].lowercase() in setOf("source", "sources", "link", "links", "url") || cells(i).let { it.isNotEmpty() && it.all(::linkOnly) }
            }
            val columns = header.indices.filter { it != source }
            val dated = columns.filter { cells(it).let { values -> values.isNotEmpty() && values.all(::dated) } }
            val first = columns.firstOrNull() ?: 0
            val kicker = if (first in dated && columns.size > 1) first else dated.firstOrNull { it != first }
            val title = if (first == kicker && columns.size > 1) columns[1] else first
            val rest = columns.filter { it != title && it != kicker }
            val words = rest.filter { cells(it).let { values -> values.isNotEmpty() && values.sumOf(String::length) / values.size > 36 } }
            return ChatTableLayout(title, kicker, words, rest.filter { it !in words }, source)
        }
        fun bare(value: String) = value.trim().takeUnless { it in setOf("-", "–", "—") }.orEmpty()
        fun numeric(value: String) = Regex("""^[~≈]?[-+]?[$€£¥]?\d[\d,.\s]*(%|k|m|min|h)?$""").matches(value.trim())
        private fun linkOnly(value: String) = Regex("""^(\[[^\]]+]\([^)\s]+\)|<?https?://\S+?>?)$""").matches(value)
        private fun dated(value: String) = value.length <= 40 && Regex("""\d{1,2}:\d{2}|\d{4}-\d{2}-\d{2}|\d\s*\.?\s*\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\.?\s+\d|\b(mon|tue|wed|thu|fri|sat|sun|today|tomorrow|tonight)\b""", RegexOption.IGNORE_CASE).containsMatchIn(value)
        fun sourceUrl(value: String): String? {
            Regex("""\[[^]]+]\((https?://[^\s)]+)\)""").find(value)?.groupValues?.get(1)?.let { return it.takeIf(AgentMarkdown::safeUrl) }
            val address = value.trim().trim('<', '>').let { if (it.startsWith("http")) it else "https://$it" }
            return address.takeIf(AgentMarkdown::safeUrl)
        }
    }
}

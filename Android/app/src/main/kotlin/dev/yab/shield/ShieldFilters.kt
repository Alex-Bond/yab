package dev.yab.shield

import kotlinx.serialization.Serializable
import java.util.Locale

/** Port of Sources/Fast/Filters.swift schema 13. Unsupported uBO syntax stays unsupported. */
@Serializable
data class ShieldRule(val action: String, val filter: String, val selector: String? = null,
    val caseSensitive: Boolean = false, val types: List<String> = emptyList(), val party: String? = null,
    val context: String? = null, val ifDomain: List<String> = emptyList(), val unlessDomain: List<String> = emptyList())

@Serializable
data class ShieldRules(val blocks: List<ShieldRule> = emptyList(), val exceptions: List<ShieldRule> = emptyList(),
    val important: List<ShieldRule> = emptyList(), val generic: List<ShieldRule> = emptyList(),
    val unhide: List<ShieldRule> = emptyList(), val skipped: Int = 0, val hidingSites: List<String> = emptyList()) {
    val count get() = blocks.size + exceptions.size + important.size + generic.size + unhide.size
}

object ShieldFilters {
    const val SCHEMA = 13
    private val everything = listOf("script", "image", "svg-document", "style-sheet", "font", "media", "fetch", "websocket", "ping", "other")
    private val kinds = mapOf("script" to setOf("script"), "image" to setOf("image", "svg-document"),
        "stylesheet" to setOf("style-sheet"), "css" to setOf("style-sheet"), "font" to setOf("font"),
        "media" to setOf("media"), "xmlhttprequest" to setOf("fetch"), "xhr" to setOf("fetch"),
        "websocket" to setOf("websocket"), "ping" to setOf("ping"), "beacon" to setOf("ping"),
        "other" to setOf("other"), "object" to setOf("other"))
    private data class Made(val rule: ShieldRule, val place: String = "plain")
    private data class PlacedRule(val rule: ShieldRule, val place: String)
    fun convert(texts: List<String>): ShieldRules {
        val lines = texts.flatMap { it.split('\n').map { line -> line.trim(' ', '\t', '\r') }.filter(String::isNotEmpty) }
        val taken = lines.filter { "badfilter" in it }.mapNotNull(::unbadfilter).toSet()
        val blocks = mutableListOf<ShieldRule>(); val exceptions = mutableListOf<ShieldRule>(); val important = mutableListOf<ShieldRule>()
        val generic = mutableListOf<ShieldRule>(); val unhide = mutableListOf<ShieldRule>(); val seen = mutableSetOf<PlacedRule>(); val hides = Hides()
        var skipped = 0
        for (line in lines) {
            if (line.startsWith('!') || line.startsWith('[')) continue
            if (line in taken || "badfilter" in line) { skipped++; continue }
            val host = hostsLine(line)
            if (host != null) {
                if ("||${host.lowercase(Locale.ROOT)}^" in taken) { skipped++; continue }
                plainDomain(host)?.takeUnless { it == "localhost.localdomain" }?.let { ShieldRule("block", onSite(it)) }?.let { if (seen.add(PlacedRule(it, "plain"))) blocks += it }
                continue
            }
            if (line.startsWith('#') && listOf("##", "#@#", "#?#", "#$#").none(line::startsWith)) continue
            val marker = cosmeticMarker(line)
            if (marker != null) { if (!hides.take(line, marker)) skipped++; continue }
            val made = network(line)
            if (made == null) { skipped++; continue }
            for ((rule, place) in made) {
                if (place == "unhideAll") hides.unhidden += rule.ifDomain
                val group = if (place == "unhideAll") "unhide" else place
                if (!seen.add(PlacedRule(rule, group))) continue
                when (place) {
                    "unhide", "unhideAll" -> unhide += rule
                    "important" -> important += rule
                    else -> if (rule.action == "allow") exceptions += rule else blocks += rule
                }
            }
        }
        val hidden = hides.rules(); skipped += hidden.dropped
        hidden.generic.forEach { if (seen.add(PlacedRule(it, "plain"))) generic += it }; hidden.own.forEach { if (seen.add(PlacedRule(it, "plain"))) blocks += it }
        return ShieldRules(blocks, exceptions, important, generic, unhide, skipped, hidden.sites.sorted())
    }
    private fun network(line: String): List<Made>? {
        var pattern = line; val exception = pattern.startsWith("@@"); if (exception) pattern = pattern.drop(2)
        if (pattern.startsWith('/') && pattern.length > 2 && (pattern.endsWith('/') || "/$" in pattern)) return null
        val options = mutableListOf<Pair<String, String?>>()
        optionsStart(pattern)?.let { index ->
            for (token in pattern.substring(index + 1).split(',')) {
                if (token.isEmpty()) return null
                val equals = token.indexOf('='); options += if (equals >= 0) token.substring(0, equals).lowercase(Locale.ROOT) to token.substring(equals + 1) else token.lowercase(Locale.ROOT) to null
            }
            pattern = pattern.substring(0, index)
        }
        var rule = ShieldRule(if (exception) "allow" else "block", "")
        var important = false; val wanted = mutableSetOf<String>(); val unwanted = mutableSetOf<String>()
        var frames: String? = null; var whole = false; val includes = mutableListOf<String>(); val excludes = mutableListOf<String>()
        var documentOnly = false; var webrtc = false; var hiding: String? = null; var odd = 0
        for ((name, value) in options) when (name) {
            "third-party", "3p", "~first-party", "~1p" -> { if (rule.party == "first-party") return null; rule = rule.copy(party = "third-party") }
            "first-party", "1p", "~third-party", "~3p" -> { if (rule.party == "third-party") return null; rule = rule.copy(party = "first-party") }
            "match-case" -> rule = rule.copy(caseSensitive = true)
            "important" -> important = true
            "all" -> whole = true
            "reason" -> Unit
            "domain", "from" -> {
                if (value == null) return null
                for (domain in value.split('|').filter(String::isNotEmpty)) if (domain.startsWith('~')) {
                    excludes += plainDomain(domain.drop(1)) ?: return null
                } else { val clean = plainDomain(domain); if (clean != null) includes += clean else odd++ }
            }
            "doc", "document" -> if (exception) documentOnly = true else frames = if (frames == "child-frame") "any" else "top-frame"
            "subdocument", "frame" -> frames = if (frames == "top-frame") "any" else "child-frame"
            "popup" -> wanted += "popup"
            "generichide", "ghide" -> { if (!exception) return null; if (hiding == null) hiding = "unhide" }
            "elemhide", "ehide" -> { if (!exception) return null; hiding = "unhideAll" }
            else -> when {
                name.startsWith('~') && kinds[name.drop(1)] != null -> unwanted += kinds.getValue(name.drop(1))
                kinds[name] != null -> wanted += kinds.getValue(name)
                name == "webrtc" -> webrtc = true
                name == "~webrtc" -> Unit
                else -> return null
            }
        }
        if (webrtc && wanted.isEmpty() && frames == null || includes.isNotEmpty() && excludes.isNotEmpty() || wanted.isNotEmpty() && unwanted.isNotEmpty()) return null
        rule = rule.copy(ifDomain = includes.distinct().sorted(), unlessDomain = excludes.distinct().sorted())
        if (hiding != null) {
            if (options.any { it.first !in setOf("generichide", "ghide", "elemhide", "ehide", "domain", "from") } || excludes.isNotEmpty()) return null
            val host = pureHost(pattern)
            rule = when {
                host != null && rule.ifDomain.isEmpty() -> rule.copy(filter = ".*", ifDomain = listOf(host))
                pattern.isEmpty() || pattern == "*" -> { if (rule.ifDomain.isEmpty()) return null; rule.copy(filter = ".*") }
                else -> { val filter = urlFilter(pattern) ?: return null; if (everywhere(pattern) && rule.ifDomain.isEmpty()) return null; rule.copy(filter = filter) }
            }
            if (hiding == "unhideAll" && (rule.ifDomain.isEmpty() || rule.filter != ".*")) return null
            return listOf(Made(rule, hiding))
        }
        if (odd != 0) return null
        if (documentOnly) {
            val host = pureHost(pattern) ?: return null
            if (options.size != 1 || rule.ifDomain.isNotEmpty() || rule.unlessDomain.isNotEmpty()) return null
            return listOf(Made(rule.copy(filter = ".*", ifDomain = listOf(host))))
        }
        if (pattern.isEmpty() || pattern == "*" || everywhere(pattern)) {
            if (rule.ifDomain.isEmpty()) return null
            rule = rule.copy(filter = if (pattern.isEmpty() || pattern == "*") ".*" else urlFilter(pattern) ?: ".*")
        } else rule = rule.copy(filter = urlFilter(pattern) ?: return null)
        if (unwanted.isNotEmpty()) { wanted.clear(); wanted += everything.filterNot { it in unwanted } }
        if (whole) { wanted.clear(); frames = null }
        val place = if (important && !exception) "important" else "plain"
        val made = mutableListOf<Made>()
        if (wanted.isNotEmpty()) made += Made(rule.copy(types = wanted.sorted()), place)
        if (frames != null) made += Made(rule.copy(types = listOf("document"), context = frames.takeUnless { it == "any" }), place)
        if (made.isEmpty()) {
            if (whole || !exception && pureHost(pattern) != null) made += Made(rule, place)
            else {
                made += Made(rule.copy(types = (everything + "popup").sorted()), place)
                made += Made(rule.copy(types = listOf("document"), context = "child-frame"), place)
            }
        }
        return made
    }
    fun everywhere(source: String): Boolean {
        var rest = source.lowercase(Locale.ROOT); val anchored = rest.startsWith('|') && !rest.startsWith("||")
        if (anchored) rest = rest.drop(1)
        rest = rest.trimEnd('*', '^'); if (rest.isEmpty()) return true
        return listOf("https://", "http://", "wss://", "ws://").any { if (anchored) it.startsWith(rest) else it.contains(rest) }
    }
    private fun optionsStart(pattern: String): Int? = pattern.lastIndexOf('$').takeIf { it >= 0 && it + 1 < pattern.length && pattern[it + 1].let { c -> c.isLetterOrDigit() || c == '~' } }
    fun urlFilter(source: String): String? {
        if (source.any { it.code >= 128 || it == ' ' }) return null
        var pattern = source; val out = StringBuilder(); var endAnchor = false
        if (pattern.startsWith("||")) {
            pattern = pattern.drop(2)
            val end = pattern.indexOfFirst { it in "/^?*|:" }.takeIf { it >= 0 } ?: pattern.length
            val host = pattern.take(end).lowercase(Locale.ROOT)
            if ('.' !in host || host.any { !hostByte(it) }) return null
            out.append("^[a-z-]+://([^/]*\\.)?").append(escape(host)); pattern = pattern.drop(end)
            if (pattern.startsWith('^')) { out.append("[/:]"); pattern = pattern.drop(1) }
        } else if (pattern.startsWith('|')) { out.append('^'); pattern = pattern.drop(1) }
        if (pattern.endsWith('|')) { endAnchor = true; pattern = pattern.dropLast(1) }
        if (!endAnchor) pattern = pattern.trimEnd('*')
        if (out.isEmpty()) pattern = pattern.trimStart('*')
        if (out.isEmpty() && pattern.length < 3) return null
        pattern.forEachIndexed { index, c -> when (c) {
            '*' -> out.append(".*")
            '^' -> if (index == pattern.lastIndex) { out.append(if (endAnchor) "[^a-zA-Z0-9_.%-]?" else "([^a-zA-Z0-9_.%-].*)?"); endAnchor = true } else out.append("[^a-zA-Z0-9_.%-]")
            else -> out.append(escape(c.toString()))
        } }
        if (endAnchor) out.append('$')
        return out.toString().takeIf { it.length <= 1024 }
    }
    private fun hostByte(c: Char) = c in 'a'..'z' || c in '0'..'9' || c in ".-_"
    fun escape(text: String) = buildString { text.forEach { if (it in ".?+()[]{}$|\\^*") append('\\'); append(it) } }
    fun onSite(site: String) = "^[a-z-]+://([^/]*\\.)?" + escape(site) + "[/:]"
    private fun pureHost(pattern: String) = if (pattern.startsWith("||") && pattern.endsWith('^')) plainDomain(pattern.drop(2).dropLast(1)) else null
    fun plainDomain(value: String): String? = value.lowercase(Locale.ROOT).takeIf {
        '.' in it && !it.startsWith('.') && !it.endsWith('.') && it.all(::hostByte)
    }
    private fun unbadfilter(line: String): String? {
        val dollar = line.lastIndexOf('$'); if (dollar < 0) return null
        val options = line.substring(dollar + 1).split(',').filter { it.isNotEmpty() && it != "badfilter" }
        return line.take(dollar) + if (options.isEmpty()) "" else "$" + options.joinToString(",")
    }
    private fun hostsLine(line: String): String? {
        if (line.firstOrNull() !in listOf('0', '1', ':')) return null
        val parts = line.split(' ', '\t').filter(String::isNotEmpty)
        return parts.getOrNull(1)?.takeIf { parts.firstOrNull() in setOf("127.0.0.1", "0.0.0.0", "::1", "::") }
    }
    private fun cosmeticMarker(line: String): String? {
        val hash = line.indexOf('#'); if (hash < 0 || line.indexOf('[').let { it >= 0 && it < hash }) return null
        return listOf("##", "#@#", "#?#", "#@?#", "#$#", "#@$#", "#%#").firstOrNull { line.startsWith(it, hash) }
    }
    private class Hides {
        val everywhere = mutableSetOf<String>(); val sparing = mutableMapOf<String, MutableSet<String>>()
        val only = mutableMapOf<String, MutableSet<String>>(); val order = mutableListOf<String>()
        val spared = mutableMapOf<String, MutableSet<String>>(); val anywhereSpared = mutableSetOf<String>(); val unhidden = mutableSetOf<String>()
        fun take(line: String, marker: String): Boolean {
            if (marker !in setOf("##", "#@#")) return false
            val index = line.indexOf(marker); val selector = line.substring(index + marker.length).trim(::whiteSpace)
            if (!ShieldFilters.selector(selector)) return false
            val includes = mutableListOf<String>(); val excludes = mutableListOf<String>()
            for (piece in line.take(index).split(',').filter(String::isNotEmpty)) {
                val part = piece.trim(::whiteSpace); if (part.startsWith('~')) excludes += plainDomain(part.drop(1)) ?: return false else includes += plainDomain(part) ?: return false
            }
            if (marker == "#@#") {
                if (excludes.isNotEmpty()) return false
                if (includes.isEmpty()) anywhereSpared += selector else spared.getOrPut(selector) { mutableSetOf() } += includes
                return true
            }
            if (includes.isNotEmpty() && excludes.isNotEmpty()) return false
            if (selector !in everywhere && selector !in sparing && selector !in only) order += selector
            when { includes.isNotEmpty() -> only.getOrPut(selector) { mutableSetOf() } += includes
                excludes.isNotEmpty() -> sparing.getOrPut(selector) { mutableSetOf() } += excludes
                else -> everywhere += selector }
            return true
        }
        data class Hidden(val generic: List<ShieldRule>, val own: List<ShieldRule>, val dropped: Int, val sites: Set<String>)
        fun rules(): Hidden {
            val generic = mutableListOf<ShieldRule>(); val own = mutableListOf<ShieldRule>(); val named = mutableSetOf<String>(); var dropped = 0
            for (selector in order.filterNot { it in anywhereSpared }) {
                val spare = spared[selector].orEmpty()
                if (selector in everywhere || selector in sparing) {
                    val unless = if (selector in everywhere) spare else spare + sparing[selector].orEmpty()
                    generic += ShieldRule("hide", ".*", selector, unlessDomain = unless.sorted())
                } else only[selector]?.let { sites ->
                    val off = spare + unhidden
                    val left = sites.filterNot { site -> off.any { site == it || site.endsWith(".$it") || it.endsWith(".$site") } }
                    if (left.isEmpty()) dropped++
                    left.sorted().forEach { own += ShieldRule("hide", onSite(it), selector) }; named += left
                }
            }
            return Hidden(generic, own, dropped, named)
        }
    }
    private fun whiteSpace(c: Char) = c == '\t' || Character.getType(c) == Character.SPACE_SEPARATOR.toInt()
    fun selector(selector: String): Boolean {
        if (selector.isEmpty() || selector.length > 1024 || selector.any { it.code >= 128 }) return false
        if (selector.startsWith("+js(") || selector.startsWith('^') || selector.startsWith('{')) return false
        return listOf(":has-text(", ":contains(", ":xpath(", ":upward(", ":nth-ancestor(", ":-abp-", ":matches-css", ":matches-attr", ":matches-path", ":matches-prop", ":matches-media", ":min-text-length(", ":watch-attr(", ":remove", ":style(", ":others(", ":if(", ":if-not(", "{", "}").none(selector::contains)
    }
}

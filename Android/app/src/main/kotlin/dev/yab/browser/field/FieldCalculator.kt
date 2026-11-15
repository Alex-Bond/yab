package dev.yab.browser.field

import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.time.*
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.temporal.ChronoUnit
import java.util.Currency
import java.util.Locale
import kotlin.math.*

data class FieldAnswer(val question: String, val questionNote: String, val result: String,
    val resultNote: String, val copy: String, val kind: Kind) {
    enum class Kind { MATH, PERCENT, UNIT, BASE, MONEY, TIME, DATE, COLOR }
    val takesReturn: Boolean get() = copy.isNotEmpty() && kind !in setOf(Kind.TIME, Kind.DATE)
}

data class FieldRatesSnapshot(val perDollar: Map<String, Double> = emptyMap(), val fetchedAt: Instant? = null,
    val failed: Boolean = false, val retryAt: Instant? = null) {
    fun knows(code: String) = code == "USD" || (if (code == "SAT") perDollar["BTC"] else perDollar[code]) != null
    fun convert(value: Double, from: String, to: String): Double? {
        // A satoshi is a Bitcoin unit, never a separate market quote or USD peg.
        fun rate(code: String): Double? = when (code) {
            "USD" -> 1.0
            "SAT" -> perDollar["BTC"]?.times(100_000_000)
            else -> perDollar[code]
        }
        val a = rate(from) ?: return null
        val b = rate(to) ?: return null
        if (!a.isFinite() || !b.isFinite() || a <= 0 || b <= 0) return null
        return (value / a * b).takeIf(Double::isFinite)
    }
    fun age(now: Instant): String {
        val hours = fetchedAt?.let { Duration.between(it, now).toHours() } ?: return ""
        return if (hours < 6) "" else " · ${if (hours < 48) "${hours}h" else "${hours / 24}d"} ago"
    }
}

/** The current iPhone Calc/Sum grammar. Typed words never enter a network request. */
object FieldCalculator {
    private val locale = Locale.US
    private val signs = "$€£¥₽₴₸₹₩₺₪"
    private val timeLeads = listOf("time in ", "now in ", "time at ", "current time in ", "what time is it in ")
    private val dayLeads = listOf("days until ", "days till ", "days to ", "how many days until ", "weeks until ", "weeks till ")

    fun answer(text: String, now: Instant = Instant.now(), rates: FieldRatesSnapshot = FieldRatesSnapshot(),
        zone: ZoneId = ZoneId.systemDefault(), homeCurrency: String = homeCurrency()): FieldAnswer? {
        val words = text.trim()
        if (words.length !in 2..120 || isAddress(words)) return null
        // Color alone uses Foundation's horizontal .whitespaces normalization.
        // Keep the existing broader normalization for all previous readings.
        if (words.startsWith('#')) return color(text.trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() })
        val lower = words.lowercase(Locale.ROOT)
        if (words.none { it.isDigit() || it in signs } && !lower.contains("pi") && 'π' !in lower && '√' !in lower &&
            !lower.endsWith(" time") && timeLeads.none(lower::startsWith) && dayLeads.none(lower::startsWith)) return null
        return percent(words) ?: math(words) ?: base(words) ?: units(words) ?: money(words, rates, now, homeCurrency)
            ?: time(words, now, zone) ?: date(words, now, zone)
    }

    private fun color(words: String): FieldAnswer? {
        if (!words.startsWith('#')) return null
        var digits = words.drop(1)
        if (digits.length !in setOf(3, 6) || digits.any { it !in '0'..'9' && it !in 'a'..'f' && it !in 'A'..'F' }) return null
        if (digits.length == 3) digits = buildString(6) { digits.forEach { append(it); append(it) } }
        val value = digits.toIntOrNull(16) ?: return null
        val hex = "#" + digits.uppercase(Locale.ROOT)
        val rgb = "RGB ${(value ushr 16) and 255}, ${(value ushr 8) and 255}, ${value and 255}"
        return FieldAnswer(hex, "HEX", rgb, "RGB", hex, FieldAnswer.Kind.COLOR)
    }

    fun mathKeys(text: String): Boolean = text.trim().let { words ->
        words.firstOrNull()?.let { it.isDigit() || it in "(.-−" } == true && words.none(Char::isLetter)
    }

    fun keepsLocal(text: String, now: Instant = Instant.now(), rates: FieldRatesSnapshot = FieldRatesSnapshot()): Boolean {
        if (isAddress(text.trim())) return false
        if (answer(text, now, rates) != null) return true
        val words = text.trim().lowercase(Locale.ROOT).replace("sqrt", "√").replace("pi", "π")
        return words.firstOrNull()?.let { it.isDigit() || it in "(.-−√π" } == true &&
            words.all { it in "0123456789.,+-−*/×÷x^%()√π " }
    }

    fun reverse(answer: FieldAnswer, words: String, rates: FieldRatesSnapshot): FieldAnswer? {
        if (answer.copy.isEmpty()) return null
        val copy = when (answer.kind) {
            FieldAnswer.Kind.UNIT, FieldAnswer.Kind.BASE -> answer.question.replace(",", "")
            FieldAnswer.Kind.MONEY -> moneyAmount(answer.question, rates, true)?.first?.let { shown(it, 8).replace(",", "") }
            else -> null
        } ?: return null
        return answer.copy(question = answer.result, questionNote = answer.resultNote, result = answer.question,
            resultNote = answer.questionNote, copy = copy)
    }

    fun isAddress(words: String): Boolean {
        if (words.startsWith('/') || words == "~" || words.startsWith("~/")) return true
        if (words.any(Char::isWhitespace)) return false
        val lower = words.lowercase(Locale.ROOT)
        if (lower.startsWith("about:") || lower.startsWith("data:")) return true
        if ("://" in lower) return lower.substringBefore("://") in setOf("http", "https", "file", "about", "data", "yab-diary", "yab-artifact")
        val head = lower.takeWhile { it !in "/?#" }
        if ('@' in head) return false
        if (head.startsWith('[')) return Regex("\\[[a-f0-9:.]+](?::[0-9]{1,5})?").matches(head)
        val host = head.substringBefore(':')
        val port = head.substringAfter(':', "").toIntOrNull()
        if (':' in head && (port == null || port !in 1..65535)) return false
        if (host == "localhost") return true
        val labels = host.split('.')
        if (labels.size == 4 && labels.all { label -> label.toIntOrNull()?.let { it in 0..255 } == true }) return true
        if (labels.size >= 2 && labels.last().length >= 2 && labels.last().all(Char::isLetter) &&
            labels.all { it.isNotEmpty() && !it.startsWith('-') && !it.endsWith('-') && it.all { c -> c.isLetterOrDigit() || c == '-' } }) return true
        return labels.size == 1 && host.any(Char::isLetter) && host.all { it.isLetterOrDigit() || it == '-' } &&
            !host.startsWith('-') && !host.endsWith('-') && port != null && (port >= 1024 || port in setOf(80, 443)) &&
            host !in setOf("javascript", "mailto", "tel", "sms", "ftp", "ws", "wss", "blob", "view-source", "ssh", "git")
    }

    fun shown(value: Double, places: Int? = null): String {
        val digits = places ?: if (value == 0.0 || abs(value) >= 1000) 2 else if (abs(value) >= 1) 4 else 8
        return DecimalFormat("#,##0" + if (digits > 0) "." + "#".repeat(digits.coerceIn(0, 10)) else "", DecimalFormatSymbols(locale)).format(value)
    }

    private fun number(text: String): Double? {
        var words = text.lowercase(Locale.ROOT).replace(",", "").replace(" ", "")
        var scale = 1.0
        if (words.length > 1 && words.last() in "km" && words[words.lastIndex - 1].isDigit()) {
            scale = if (words.last() == 'k') 1000.0 else 1_000_000.0
            words = words.dropLast(1)
        }
        return if (words.isNotEmpty() && words.all { it.isDigit() || it == '.' }) words.toDoubleOrNull()?.times(scale)?.takeIf(Double::isFinite) else null
    }

    private fun split(words: String): List<Pair<String, String>> = buildList {
        for (join in listOf(" to ", " in ", " into ", " as ", " -> ", " → ", " = ")) {
            // Search backwards before consuming a join. "5 in in cm" shares
            // the middle space; a forwards non-overlapping regex loses the valid join.
            var before = words.length
            while (before >= join.length) {
                val index = words.lastIndexOf(join, before - join.length, ignoreCase = true)
                if (index < 0) break
                val left = words.substring(0, index).trim(); val right = words.substring(index + join.length).trim()
                if (left.isNotEmpty() && right.isNotEmpty()) add(left to right)
                before = index
            }
        }
    }

    private fun math(input: String): FieldAnswer? {
        val words = input.trim().lowercase(Locale.ROOT).replace("sqrt", "√").replace("pi", "π")
        if (words.length !in 2..120 || words.any { it !in "0123456789.,+-*/×÷x^%()√π " } || words.none { it.isDigit() || it == 'π' }) return null
        if (!Regex("[0-9)%π]\\s*[-+*/×÷x^]\\s*[-(0-9√π]").containsMatchIn(words) &&
            !Regex("^√\\s*[(0-9π]").containsMatchIn(words) && !Regex("^[0-9.]+\\s*π$").matches(words)) return null
        val parser = SumParser(words.replace(" ", ""))
        val value = parser.expression()?.takeIf { parser.done && it.isFinite() } ?: return null
        val result = shown(value, if (abs(value) < 1) 10 else 6)
        return FieldAnswer(input.replace("*", " × ").replace("/", " ÷ ").replace("  ", " ").trim(), "Sum",
            result, spelled(value), result.replace(",", ""), FieldAnswer.Kind.MATH)
    }

    private class SumParser(private val text: String) {
        private var at = 0
        val done get() = at == text.length
        private fun peek() = text.getOrNull(at)
        private fun eat(options: String): Char? = peek()?.takeIf { it in options }?.also { at++ }
        fun expression(): Double? {
            var value = term() ?: return null
            while (true) { val op = eat("+-") ?: return value; val right = term() ?: return null; value = if (op == '+') value + right else value - right }
        }
        private fun term(): Double? {
            var value = power() ?: return null
            while (true) {
                val op = eat("*/×÷x")
                if (op != null) { val right = power() ?: return null; value = if (op in "/÷") value / right else value * right }
                else if (peek() == 'π' || peek() == '√') value *= power() ?: return null
                else return value
            }
        }
        private fun power(): Double? { val value = unary() ?: return null; return if (eat("^") != null) value.pow(power() ?: return null) else value }
        private fun unary(): Double? {
            if (eat("-") != null) return unary()?.unaryMinus()
            if (eat("+") != null) return unary()
            if (eat("√") != null) return unary()?.takeIf { it >= 0 }?.let(::sqrt)
            var value = primary() ?: return null
            while (eat("%") != null) value /= 100
            return value
        }
        private fun primary(): Double? {
            if (eat("π") != null) return PI
            if (eat("(") != null) { val value = expression() ?: return null; return if (eat(")") != null) value else null }
            val start = at
            while (peek()?.let { it.isDigit() || it in ".," } == true) at++
            return text.substring(start, at).replace(",", "").toDoubleOrNull()
        }
    }

    private fun percent(words: String): FieldAnswer? {
        if ('%' !in words) return null
        val n = "([0-9][0-9,]*\\.?[0-9]*)"
        val lower = words.lowercase(Locale.ROOT)
        fun result(question: String, value: Double) = FieldAnswer(question, "Percentage", shown(value), spelled(value), shown(value).replace(",", ""), FieldAnswer.Kind.PERCENT)
        Regex("^$n\\s*%\\s*of\\s*$n$").matchEntire(lower)?.let { m ->
            val a = number(m.groupValues[1]) ?: return null; val b = number(m.groupValues[2]) ?: return null
            return result("${shown(a)}% of ${shown(b)}", a / 100 * b)
        }
        Regex("^$n\\s*%\\s*off\\s*$n$").matchEntire(lower)?.let { m ->
            val a = number(m.groupValues[1]) ?: return null; val b = number(m.groupValues[2]) ?: return null
            return result("${shown(b)} − ${shown(a)}%", b * (1 - a / 100))
        }
        Regex("^$n\\s*([+-])\\s*$n\\s*%$").matchEntire(lower)?.let { m ->
            val a = number(m.groupValues[1]) ?: return null; val b = number(m.groupValues[3]) ?: return null; val adding = m.groupValues[2] == "+"
            return result("${shown(a)} ${if (adding) "+" else "−"} ${shown(b)}%", a * (1 + (if (adding) 1 else -1) * b / 100))
        }
        return null
    }

    private fun base(words: String): FieldAnswer? {
        val names = mapOf("hex" to 16, "hexadecimal" to 16, "decimal" to 10, "dec" to 10, "binary" to 2, "bin" to 2, "octal" to 8, "oct" to 8)
        val titles = mapOf(16 to "Hexadecimal", 10 to "Decimal", 2 to "Binary", 8 to "Octal")
        fun read(text: String): Pair<Long, Int>? {
            val radix = when { text.startsWith("0x") -> 16; text.startsWith("0b") -> 2; text.startsWith("0o") -> 8; else -> 10 }
            val digits = if (radix == 10) text else text.drop(2)
            if (radix == 10 && !digits.all(Char::isDigit)) return null
            return digits.toLongOrNull(radix)?.let { it to radix }
        }
        fun said(value: Long, radix: Int) = when (radix) { 16 -> "0x" + value.toString(16).uppercase(locale); 2 -> "0b" + value.toString(2); 8 -> "0o" + value.toString(8); else -> shown(value.toDouble(), 0) }
        val lower = words.lowercase(Locale.ROOT)
        for ((left, right) in split(lower)) {
            val (value, from) = read(left) ?: continue; val to = names[right] ?: continue
            if (to != from) return FieldAnswer(said(value, from), titles.getValue(from), said(value, to), titles.getValue(to), said(value, to), FieldAnswer.Kind.BASE)
        }
        if (lower.startsWith("0x") || lower.startsWith("0b")) read(lower)?.let { (value, from) ->
            return FieldAnswer(said(value, from), titles.getValue(from), said(value, 10), "Decimal", said(value, 10).replace(",", ""), FieldAnswer.Kind.BASE)
        }
        return null
    }

    data class UnitName(val words: List<String>, val symbol: String, val name: String, val group: String, val coefficient: Double, val offset: Double = 0.0)
    private fun unit(words: String): UnitName? {
        val key = words.lowercase(Locale.ROOT).replace("degrees ", "").trim()
        return FieldUnits.all.firstOrNull { key in it.words } ?: FieldUnits.all.firstOrNull { words.lowercase(Locale.ROOT).trim() in it.words }
    }
    private fun units(words: String): FieldAnswer? {
        for ((left, right) in split(words)) {
            val to = unit(right) ?: continue
            val match = Regex("^([0-9.,]+)(.+)$").matchEntire(left.trim()) ?: continue
            val value = number(match.groupValues[1]) ?: continue; val from = unit(match.groupValues[2]) ?: continue
            if (from.group != to.group || from.symbol == to.symbol) continue
            val converted = ((value * from.coefficient + from.offset) - to.offset) / to.coefficient
            if (!converted.isFinite()) continue
            fun display(value: Double, unit: UnitName) = shown(value) + (if (unit.symbol.startsWith('°')) "" else " ") + unit.symbol
            return FieldAnswer(display(value, from), from.name, display(converted, to), to.name, display(converted, to).replace(",", ""), FieldAnswer.Kind.UNIT)
        }
        return null
    }

    private val currencyNames = mapOf("dollar" to "USD", "buck" to "USD", "euro" to "EUR", "pound" to "GBP", "quid" to "GBP", "sterling" to "GBP", "yen" to "JPY", "yuan" to "CNY", "renminbi" to "CNY", "rmb" to "CNY", "rupee" to "INR", "ruble" to "RUB", "rouble" to "RUB", "franc" to "CHF", "won" to "KRW", "lira" to "TRY", "hryvnia" to "UAH", "hryvna" to "UAH", "tenge" to "KZT", "shekel" to "ILS", "zloty" to "PLN", "dirham" to "AED", "bitcoin" to "BTC", "ether" to "ETH", "ethereum" to "ETH", "solana" to "SOL", "tether" to "USDT", "usd coin" to "USDC", "satoshi" to "SAT", "sat" to "SAT", "sri lankan rupee" to "LKR")
    private val askedCurrencies = "USD EUR GBP JPY CNY CHF CAD AUD NZD SEK NOK DKK PLN CZK HUF RON TRY RUB UAH KZT BYN INR KRW HKD SGD THB IDR MYR VND AED SAR ILS BRL MXN ARS ZAR EGP LKR BTC ETH SOL USDT USDC SAT".split(' ').toSet()
    private val cryptos = mapOf("BTC" to "Bitcoin", "ETH" to "Ethereum", "SOL" to "Solana", "USDT" to "Tether", "USDC" to "USD Coin", "XRP" to "XRP", "DOGE" to "Dogecoin", "TON" to "Toncoin", "LTC" to "Litecoin", "SAT" to "Bitcoin satoshis")
    private val currencySigns = mapOf("$" to "USD", "€" to "EUR", "£" to "GBP", "¥" to "JPY", "₽" to "RUB", "₴" to "UAH", "₸" to "KZT", "₹" to "INR", "₩" to "KRW", "₺" to "TRY")
    private fun currency(input: String, rates: FieldRatesSnapshot, tickers: Boolean): String? {
        val words = input.trim { it.isWhitespace() || (!it.isLetterOrDigit() && it !in signs) }
        val key = words.lowercase(Locale.ROOT)
        currencySigns[key]?.let { return it }
        (currencyNames[key] ?: if (key.endsWith('s')) currencyNames[key.dropLast(1)] else null)?.let { return it }
        val code = key.uppercase(Locale.ROOT)
        if (code.length !in 3..5 || !code.all(Char::isLetter) || !rates.knows(code)) return null
        return code.takeIf { it in askedCurrencies || (tickers && words == code) }
    }
    private fun moneyAmount(input: String, rates: FieldRatesSnapshot, tickers: Boolean): Pair<Double, String>? {
        val words = input.trim()
        val firstDigit = words.indexOfFirst(Char::isDigit)
        if (words.firstOrNull()?.isDigit() == false && firstDigit >= 0) {
            val code = currency(words.substring(0, firstDigit), rates, tickers)
            val value = number(words.substring(firstDigit))
            if (code != null && value != null) return value to code
        }
        val end = words.indexOfLast { it.isDigit() || it in ".," }
        if (end < 0) return null
        var cut = end + 1
        if (words.getOrNull(cut) in listOf('k', 'K', 'm', 'M') && (cut + 1 == words.length || words.getOrNull(cut + 1) == ' ')) cut++
        val value = number(words.substring(0, cut)) ?: return null
        val code = currency(words.substring(cut), rates, tickers) ?: return null
        return value to code
    }
    private fun money(words: String, rates: FieldRatesSnapshot, now: Instant, home: String): FieldAnswer? {
        var question: Triple<Double, String, String>? = null
        for ((left, right) in split(words)) {
            val from = moneyAmount(left, rates, true) ?: continue; val to = currency(right, rates, true) ?: continue
            if (to != from.second) { question = Triple(from.first, from.second, to); break }
        }
        if (question == null) moneyAmount(words, rates, false)?.let { (value, from) -> question = Triple(value, from, if (from == home) if (home == "USD") "EUR" else "USD" else home) }
        val (value, from, to) = question ?: return null
        val converted = rates.convert(value, from, to)
        if (converted == null) return FieldAnswer(said(value, from), currencyName(from), "…", if (rates.failed) "Rates unavailable" else "Getting rates", "", FieldAnswer.Kind.MONEY)
        return FieldAnswer(said(value, from), currencyName(from), said(converted, to), currencyName(to) + rates.age(now),
            shown(converted, if (to in cryptos) 8 else 2).replace(",", ""), FieldAnswer.Kind.MONEY)
    }
    private fun currencyName(code: String) = cryptos[code] ?: (if (code == "GBP") "British Pound" else null)
        ?: runCatching { Currency.getInstance(code).getDisplayName(locale) }.getOrDefault(code)
    private fun said(value: Double, code: String): String {
        if (code == "SAT") return shown(value, 8) + " sats"
        if (code in cryptos) return shown(value, if (value >= 1) 4 else 8) + " " + code
        val symbol = mapOf("RUB" to "₽", "UAH" to "₴", "KZT" to "₸", "TRY" to "₺", "ILS" to "₪", "INR" to "₹", "KRW" to "₩", "CNY" to "¥", "AED" to "AED ", "CHF" to "CHF ", "LKR" to "LKR ")[code]
            ?: runCatching { Currency.getInstance(code).getSymbol(locale) }.getOrDefault(code.take(3) + " ")
        val digits = if (code in setOf("JPY", "KRW")) 0 else 2
        val format = DecimalFormat("#,##0" + if (digits == 2) ".00" else "", DecimalFormatSymbols(locale))
        return symbol + format.format(value)
    }
    private fun homeCurrency() = runCatching { Currency.getInstance(Locale.getDefault()).currencyCode }.getOrDefault("USD")

    private fun zone(input: String, local: ZoneId): Pair<ZoneId, String>? {
        val key = input.lowercase(Locale.ROOT).trim()
        if (key in setOf("local", "here", "me")) return local to "Here"
        FieldZones.aliases[key]?.let { return ZoneId.of(it.first) to it.second }
        val id = ZoneId.getAvailableZoneIds().sorted().lastOrNull { it.substringAfterLast('/').lowercase(Locale.ROOT) == key.replace(' ', '_') } ?: return null
        return ZoneId.of(id) to id.substringAfterLast('/').replace('_', ' ')
    }
    private fun clock(input: String): Pair<Int, Int>? {
        val match = Regex("^(\\d{1,2})(?::(\\d{2}))?(am|pm|a|p)?$").matchEntire(input.lowercase(locale).replace(" ", "")) ?: return null
        var hour = match.groupValues[1].toInt(); val minutes = match.groupValues[2].toIntOrNull() ?: 0; val half = match.groupValues[3]
        if (minutes >= 60) return null
        if (half.isNotEmpty()) { if (hour !in 1..12) return null; if (half.startsWith('p') && hour != 12) hour += 12; if (half.startsWith('a') && hour == 12) hour = 0 }
        else if (match.groupValues[2].isEmpty() || hour >= 24) return null
        return hour to minutes
    }
    private fun time(words: String, now: Instant, local: ZoneId): FieldAnswer? {
        val lower = words.lowercase(locale).trim()
        fun said(moment: Instant, zone: ZoneId) = DateTimeFormatter.ofPattern("h:mm a", locale).withZone(zone).format(moment)
        fun note(moment: Instant, place: Pair<ZoneId, String>): String {
            val seconds = place.first.rules.getOffset(moment).totalSeconds
            val offset = "UTC" + (if (seconds >= 0) "+" else "−") + abs(seconds / 3600) + (if (abs(seconds % 3600) / 60 > 0) ":%02d".format(locale, abs(seconds % 3600) / 60) else "")
            return place.second + " · " + DateTimeFormatter.ofPattern("EEE, MMM d", locale).withZone(place.first).format(moment) + " · " + offset
        }
        fun result(moment: Instant, from: Pair<ZoneId, String>, to: Pair<ZoneId, String>) = FieldAnswer(said(moment, from.first), note(moment, from), said(moment, to.first), note(moment, to), said(moment, to.first), FieldAnswer.Kind.TIME)
        for (lead in timeLeads) if (lower.startsWith(lead)) zone(lower.removePrefix(lead), local)?.let { return result(now, local to "Here", it) }
        if (lower.endsWith(" time")) zone(lower.dropLast(5), local)?.let { return result(now, local to "Here", it) }
        for ((left, right) in split(lower)) {
            val to = zone(right, local) ?: continue
            var from = local to "Here"; var clockWords = left
            for (space in left.indices.filter { left[it] == ' ' }) {
                val place = zone(left.substring(space + 1), local) ?: continue
                if (clock(left.substring(0, space)) != null) { from = place; clockWords = left.substring(0, space); break }
            }
            val (hour, minute) = clock(clockWords) ?: continue
            val moment = now.atZone(from.first).toLocalDate().atTime(hour, minute).atZone(from.first).toInstant()
            return result(moment, from, to)
        }
        return null
    }

    private fun date(words: String, now: Instant, zone: ZoneId): FieldAnswer? {
        val lower = words.lowercase(locale).trim(); val today = now.atZone(zone).toLocalDate()
        fun shown(day: LocalDate, year: Boolean = false) = day.format(DateTimeFormatter.ofPattern(if (year) "MMM d, yyyy" else "EEE, MMM d", locale))
        for (lead in dayLeads) if (lower.startsWith(lead)) {
            val target = FieldDates.day(lower.removePrefix(lead), today) ?: return null
            val days = ChronoUnit.DAYS.between(today, target); val weeks = "week" in lead
            val result = if (weeks) FieldCalculator.shown(days.toDouble() / 7, 1) + (if (days == 7L) " week" else " weeks")
                else FieldCalculator.shown(days.toDouble(), 0) + (if (abs(days) == 1L) " day" else " days")
            return FieldAnswer("Today", shown(today), result, "Until " + shown(target), if (weeks) FieldCalculator.shown(days.toDouble() / 7, 1) else days.toString(), FieldAnswer.Kind.DATE)
        }
        val patterns = listOf("^in (\\d+) ([a-z]+)$" to 1, "^(\\d+) ([a-z]+) (?:from now|from today|later)$" to 1, "^(\\d+) ([a-z]+) ago$" to -1, "^(?:today|now) \\+ (\\d+) ([a-z]+)$" to 1, "^(?:today|now) - (\\d+) ([a-z]+)$" to -1)
        for ((pattern, sign) in patterns) {
            val match = Regex(pattern).matchEntire(lower) ?: continue; val count = match.groupValues[1].toLongOrNull() ?: continue
            val unit = listOf("day", "week", "month", "year").firstOrNull { match.groupValues[2].startsWith(it) } ?: continue
            val target = runCatching { when (unit) { "day" -> today.plusDays(sign * count); "week" -> today.plusWeeks(sign * count); "month" -> today.plusMonths(sign * count); else -> today.plusYears(sign * count) } }.getOrNull() ?: continue
            val label = "$count $unit" + if (count == 1L) "" else "s"
            return FieldAnswer("Today ${if (sign > 0) "+" else "−"} $label", shown(today), shown(target, true),
                target.format(DateTimeFormatter.ofPattern("EEEE", locale)), shown(target, true), FieldAnswer.Kind.DATE)
        }
        return null
    }

    private fun spelled(value: Double): String {
        if (abs(value) >= 1e15) return ""
        // Android and Foundation both use the platform's ICU English spell-out.
        val native = runCatching {
            val type = Class.forName("android.icu.text.RuleBasedNumberFormat")
            val formatter = type.getConstructor(Locale::class.java, Int::class.javaPrimitiveType).newInstance(locale, type.getField("SPELLOUT").getInt(null))
            type.getMethod("setMaximumFractionDigits", Int::class.javaPrimitiveType).invoke(formatter, 4)
            type.getMethod("format", Double::class.javaPrimitiveType).invoke(formatter, value) as String
        }.getOrNull()
        return (native ?: FieldNumberWords.spell(value)).replaceFirstChar { it.titlecase(locale) }
    }
}

internal object FieldDates {
    fun day(words: String, today: LocalDate): LocalDate? {
        val holidays = mapOf("christmas" to MonthDay.of(12, 25), "xmas" to MonthDay.of(12, 25), "new year" to MonthDay.of(1, 1), "new years" to MonthDay.of(1, 1), "new year's" to MonthDay.of(1, 1), "halloween" to MonthDay.of(10, 31), "valentine's day" to MonthDay.of(2, 14), "valentines day" to MonthDay.of(2, 14), "valentines" to MonthDay.of(2, 14))
        holidays[words]?.let { holiday -> return holiday.atYear(today.year).let { if (it < today) it.plusYears(1) else it } }
        if (words == "today") return today
        if (words == "tomorrow") return today.plusDays(1)
        if (words == "yesterday") return today.minusDays(1)
        val next = words.removePrefix("next ")
        DayOfWeek.values().firstOrNull { it.name.lowercase(Locale.US) == next }?.let { weekday ->
            val difference = (weekday.value - today.dayOfWeek.value + 7) % 7
            return today.plusDays(if (difference == 0) 7 else difference.toLong())
        }
        for (format in listOf("yyyy-MM-dd", "MMM d yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMMM d, yyyy", "M/d/yyyy")) {
            runCatching { LocalDate.parse(words.replaceFirstChar(Char::titlecase), DateTimeFormatter.ofPattern(format, Locale.US)) }.getOrNull()?.let { return it }
        }
        for (format in listOf("MMM d", "MMMM d", "M/d")) {
            runCatching { MonthDay.parse(words.replaceFirstChar(Char::titlecase), DateTimeFormatter.ofPattern(format, Locale.US)).atYear(today.year) }.getOrNull()?.let { return if (it < today) it.plusYears(1) else it }
        }
        return null
    }
}

internal object FieldNumberWords {
    private val small = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(' ')
    private val tens = "zero ten twenty thirty forty fifty sixty seventy eighty ninety".split(' ')
    private fun integer(value: Long): String {
        if (value < 20) return small[value.toInt()]
        if (value < 100) return tens[(value / 10).toInt()] + if (value % 10 == 0L) "" else "-" + small[(value % 10).toInt()]
        if (value < 1000) return small[(value / 100).toInt()] + " hundred" + if (value % 100 == 0L) "" else " " + integer(value % 100)
        for ((scale, name) in listOf(1_000_000_000_000L to "trillion", 1_000_000_000L to "billion", 1_000_000L to "million", 1000L to "thousand")) if (value >= scale) return integer(value / scale) + " " + name + if (value % scale == 0L) "" else " " + integer(value % scale)
        return ""
    }
    fun spell(value: Double): String {
        val words = java.math.BigDecimal.valueOf(abs(value)).stripTrailingZeros().toPlainString().split('.')
        return (if (value < 0) "minus " else "") + integer(words[0].toLong()) + if (words.size == 1) "" else " point " + words[1].map { small[it.digitToInt()] }.joinToString(" ")
    }
}

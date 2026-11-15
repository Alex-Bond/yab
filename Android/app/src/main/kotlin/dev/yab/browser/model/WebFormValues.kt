package dev.yab.browser.model

import java.math.BigDecimal
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.YearMonth
import java.time.ZoneOffset
import java.time.temporal.ChronoField
import java.time.temporal.IsoFields
import java.util.Locale

/** HTML's local calendar values never pass through the device's timezone. */
object WebFormValues {
    enum class Kind { DATE, MONTH, WEEK, TIME, DATETIME_LOCAL }
    data class Value(val canonical: String, val scalar: BigDecimal)

    fun parse(kind: Kind, raw: String?): Value? {
        if (raw == null) return null
        return runCatching {
        val text = raw
        when (kind) {
            Kind.DATE -> date(text).let { Value(dateText(it), it.toEpochDay().toBigDecimal()) }
            Kind.MONTH -> {
                require(text.matches(Regex("[0-9]{4,9}-[0-9]{2}")))
                val parts = text.split('-')
                val month = YearMonth.of(parts[0].toInt(), parts[1].toInt())
                require(month.year > 0)
                Value(String.format(Locale.ROOT, "%04d-%02d", month.year, month.monthValue), ((month.year.toLong() - 1970) * 12 + month.monthValue - 1).toBigDecimal())
            }
            Kind.WEEK -> {
                require(text.matches(Regex("[0-9]{4,9}-W[0-9]{2}")))
                val year = text.substringBefore('-').toInt()
                val week = text.substringAfter('W').toInt()
                require(year > 0 && week in 1..53)
                val monday = LocalDate.of(year, 1, 4).with(IsoFields.WEEK_OF_WEEK_BASED_YEAR, week.toLong()).with(ChronoField.DAY_OF_WEEK, 1)
                require(monday.get(IsoFields.WEEK_BASED_YEAR) == year && monday.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR) == week)
                Value(String.format(Locale.ROOT, "%04d-W%02d", year, week), ((monday.toEpochDay() + 3) / 7).toBigDecimal())
            }
            Kind.TIME -> time(text).let { Value(it.toString(), it.toNanoOfDay().toBigDecimal().movePointLeft(9)) }
            Kind.DATETIME_LOCAL -> {
                require(text.count { it == 'T' } == 1)
                val day = date(text.substringBefore('T'))
                val clock = time(text.substringAfter('T'))
                val local = LocalDateTime.of(day, clock)
                Value(dateText(day) + "T" + clock, local.toEpochSecond(ZoneOffset.UTC).toBigDecimal() + clock.nano.toBigDecimal().movePointLeft(9))
            }
        }
        }.getOrNull()
    }

    fun allowed(kind: Kind, value: String, min: String?, max: String?, step: String?, initial: String?): Boolean {
        val number = parse(kind, value)?.scalar ?: return false
        val low = parse(kind, min)?.scalar
        val high = parse(kind, max)?.scalar
        if (kind == Kind.TIME && low != null && high != null && low > high) {
            if (number < low && number > high) return false // A periodic time range can cross midnight.
        } else if (low != null && number < low || high != null && number > high) return false
        if (step == "any") return true
        val increment = step?.toBigDecimalOrNull()?.takeIf { it > BigDecimal.ZERO }
            ?: if (kind == Kind.TIME || kind == Kind.DATETIME_LOCAL) BigDecimal(60) else BigDecimal.ONE
        val base = low ?: parse(kind, initial)?.scalar ?: BigDecimal.ZERO
        return (number - base).remainder(increment).compareTo(BigDecimal.ZERO) == 0
    }

    fun date(text: String): LocalDate {
        require(text.matches(Regex("[0-9]{4,9}-[0-9]{2}-[0-9]{2}")))
        val parts = text.split('-')
        return LocalDate.of(parts[0].toInt(), parts[1].toInt(), parts[2].toInt()).also { require(it.year > 0) }
    }

    fun time(text: String): LocalTime {
        require(text.matches(Regex("[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]{1,9})?)?")))
        return LocalTime.parse(text)
    }

    fun dateText(date: LocalDate): String = String.format(Locale.ROOT, "%04d-%02d-%02d", date.year, date.monthValue, date.dayOfMonth)
}

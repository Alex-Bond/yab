package dev.yab.reports

import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

/** Transient OS input. Neither exact time nor process identity is persisted or sent. */
data class ReportExitObservation(val id: String, val at: Long, val reason: Int, val importance: Int)

@Serializable
data class ReportExitContribution(val id: String, val day: String, val reason: Int, val importance: Int)

@Serializable
data class ReportExitLedger(val pending: List<ReportExitContribution> = emptyList(),
    val allowed: Set<String> = emptySet(), val seen: List<String> = emptyList())

/** Counts of observed owned OS records, never MetricKit's complete daily counters. */
object ReportExitCounts {
    const val DAYS = 7
    const val KEPT = 200
    const val SEEN = 200
    const val MAX_IMPORT = 10
    const val MAX_WIRE_BYTES = 32 * 1024
    private val key = Regex("[0-9a-f]{64}")
    // Public Android36 SDK enum values; unknown values are omitted, not reclassified.
    private val reasons = (0..16).toSet()
    private val importance = setOf(0, 100, 125, 130, 150, 200, 230, 300, 325, 350, 400, 500, 1000)
    private val date = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
    private fun day(value: String): LocalDate? = if (!date.matches(value)) null else
        runCatching { LocalDate.parse(value).takeIf { it.toString() == value } }.getOrNull()
    private fun day(at: Long): LocalDate? = runCatching { Instant.ofEpochMilli(at).atZone(ZoneOffset.UTC).toLocalDate() }.getOrNull()
    private fun valid(value: ReportExitContribution) = key.matches(value.id) && day(value.day) != null &&
        value.reason in reasons && value.importance in importance
    private fun recent(value: String, since: Long, now: Long): Boolean {
        if (since <= 0 || now < since) return false
        val today = day(now) ?: return false
        val first = day(since) ?: return false
        val current = day(value) ?: return false
        return current >= maxOf(first, today.minusDays(DAYS - 1L)) && current <= today
    }

    /** Caller has already checked this exact installed process through ReportExitOwnership. */
    fun observation(at: Long, pid: Int, reason: Int, importance: Int, ownedProcess: String): ReportExitObservation? {
        if (at <= 0 || pid <= 0 || reason !in reasons || importance !in this.importance || ownedProcess.isEmpty()) return null
        val identity = "android-exit:$at:$pid:$reason:$importance:$ownedProcess"
        val id = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        return ReportExitObservation(id, at, reason, importance)
    }

    fun prune(original: ReportExitLedger, since: Long, now: Long): ReportExitLedger {
        val pending = original.pending.asSequence().filter(::valid).filter { recent(it.day, since, now) }
            .distinctBy { it.id }.toList().takeLast(KEPT)
        val ids = pending.map { it.id }.toSet()
        val previousSeen = original.seen.filter(key::matches).asReversed().distinct().asReversed()
        val keptSeen = ids + previousSeen.filterNot { it in ids }.takeLast(SEEN - ids.size)
        val seen = previousSeen.filter { it in keptSeen } + pending.map { it.id }.filterNot { it in previousSeen }
        return ReportExitLedger(pending, original.allowed.intersect(ids), seen)
    }

    fun add(original: ReportExitLedger, input: List<ReportExitObservation>, since: Long, now: Long): ReportExitLedger {
        val clean = prune(original, since, now)
        val known = (clean.seen + clean.pending.map { it.id }).toMutableSet()
        val fresh = input.asSequence().take(MAX_IMPORT).filter { key.matches(it.id) && it.reason in reasons && it.importance in importance &&
            it.at >= since && it.at <= now && it.at > 0 }.sortedBy { it.at }.mapNotNull {
            day(it.at)?.toString()?.takeIf { d -> recent(d, since, now) }?.let { d -> ReportExitContribution(it.id, d, it.reason, it.importance) }
        }.filter { known.add(it.id) }.toList()
        val pending = (clean.pending + fresh).takeLast(KEPT)
        return prune(ReportExitLedger(pending, clean.allowed.intersect(pending.map { it.id }.toSet()),
            (clean.seen + fresh.map { it.id }).asReversed().distinct().take(SEEN).asReversed()), since, now)
    }

    fun unasked(ledger: ReportExitLedger): Set<String> = ledger.pending.map { it.id }.filterNot { it in ledger.allowed }.toSet()
    fun allow(ledger: ReportExitLedger, captured: Set<String>) = ledger.copy(
        allowed = ledger.allowed + captured.intersect(ledger.pending.map { it.id }.toSet()))
    fun decline(ledger: ReportExitLedger, captured: Set<String>): ReportExitLedger {
        val dropped = captured - ledger.allowed
        return ledger.copy(pending = ledger.pending.filterNot { it.id in dropped })
    }
    fun acknowledge(ledger: ReportExitLedger, captured: Set<String>) = ledger.copy(
        pending = ledger.pending.filterNot { it.id in captured }, allowed = ledger.allowed - captured)
    fun capture(ledger: ReportExitLedger, automatic: Boolean): List<ReportExitContribution> =
        ledger.pending.filter { automatic || it.id in ledger.allowed }

    fun wire(captured: List<ReportExitContribution>): JsonObject? {
        if (captured.isEmpty()) return null
        require(captured.size <= KEPT && captured.all(::valid) && captured.map { it.id }.distinct().size == captured.size)
        val result = buildJsonObject {
            put("version", 1); put("source", "ApplicationExitInfo"); put("coverage", "observed")
            put("maxRecordsPerImport", MAX_IMPORT)
            put("days", buildJsonArray {
                captured.groupBy { it.day }.toSortedMap().forEach { (day, rows) -> add(buildJsonObject {
                    put("day", day)
                    put("counts", buildJsonArray {
                        rows.groupingBy { it.reason to it.importance }.eachCount().entries
                            .sortedWith(compareBy({ it.key.first }, { it.key.second })).forEach { (pair, count) -> add(buildJsonObject {
                                put("reason", pair.first); put("importance", pair.second); put("count", count)
                            }) }
                    })
                }) }
            })
        }
        require(result.toString().toByteArray(Charsets.UTF_8).size <= MAX_WIRE_BYTES)
        return result
    }
}

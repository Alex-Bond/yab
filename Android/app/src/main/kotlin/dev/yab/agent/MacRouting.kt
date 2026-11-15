package dev.yab.agent

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

enum class MacPhase { UP, ASLEEP, CLOSED, SILENT }
data class MacAvailability(val phase: MacPhase, val since: Long? = null) {
    companion object {
        fun heard(asleep: Boolean, why: String?, at: Long?, lastSeen: Long?, now: Long): MacAvailability = when {
            asleep && at != null -> MacAvailability(if (why == "quit") MacPhase.CLOSED else MacPhase.ASLEEP, at)
            lastSeen != null && now - lastSeen in 0L until 150_000L -> MacAvailability(MacPhase.UP)
            else -> MacAvailability(MacPhase.SILENT, lastSeen)
        }
    }
}

/** The production iOS MacPick order: explicit eligible choice, then recent awake, then recent. */
object MacRouting {
    data class ChatTarget(val provider: AgentProvider, val mac: RemoteMac?)
    /** A send's status keeps its original target even before a chat head arrives. */
    fun chatTarget(chat: AgentChat, connection: RemoteConnection, preferred: AgentProvider): ChatTarget {
        chat.owner?.let { owner ->
            return ChatTarget(owner.provider, connection.macs.firstOrNull { it.id == owner.mac && owner.account == connection.account })
        }
        chat.pendingSend?.takeIf { it.account == connection.account && it.epoch == connection.epoch }?.let { send ->
            return ChatTarget(send.provider, connection.macs.firstOrNull { it.id == send.mac })
        }
        return ChatTarget(preferred, connection.route(preferred))
    }
    fun pick(macs: List<RemoteMac>, chosen: String?): RemoteMac? {
        chosen?.let { id -> macs.firstOrNull { it.id == id }?.let { return it } }
        val up = macs.filter { it.availability.phase == MacPhase.UP }
        return (up.ifEmpty { macs }).sortedWith(compareByDescending<RemoteMac> { it.usedAt ?: it.lastSeen ?: Long.MIN_VALUE }
            .thenBy { it.name }.thenBy { it.id }).firstOrNull()
    }
    fun other(macs: List<RemoteMac>, send: RemoteSend): RemoteMac? = macs.filter {
        it.id != send.mac && it.availability.phase == MacPhase.UP && send.provider in it.providers && (send.files.isEmpty() || it.takesFiles)
    }.sortedWith(compareByDescending<RemoteMac> { it.usedAt ?: Long.MIN_VALUE }.thenBy { it.name }.thenBy { it.id }).firstOrNull()
    fun state(mac: RemoteMac, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String {
        val availability = mac.availability
        if (availability.phase == MacPhase.UP) return "Up"
        val date = availability.since?.let { Instant.ofEpochMilli(it).atZone(zone) }
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val suffix = date?.let { at -> "since " + when {
            at.toLocalDate() == today -> at.format(DateTimeFormatter.ofPattern("HH:mm"))
            at.toLocalDate() == today.minusDays(1) -> "yesterday"
            now - at.toInstant().toEpochMilli() in 0L until 7L * 86_400_000 -> at.format(DateTimeFormatter.ofPattern("EEE"))
            else -> at.format(DateTimeFormatter.ofPattern("MMM d"))
        } }
        return when (availability.phase) {
            MacPhase.ASLEEP -> listOfNotNull("Asleep", suffix).joinToString(" ")
            MacPhase.CLOSED -> listOfNotNull("Yab closed", suffix).joinToString(" ")
            else -> suffix?.let { "No word $it" } ?: "No word yet"
        }
    }
    const val LIFETIME = 12L * 3_600_000
    const val EXPIRY_SHOWN = 10L * 3_600_000
    fun waiting(mac: RemoteMac, sentAt: Long? = null, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String? {
        val phase = mac.availability.phase
        if (phase == MacPhase.UP) return null
        val headline = when (phase) { MacPhase.ASLEEP -> "${mac.name} is asleep"; MacPhase.CLOSED -> "Yab is closed on ${mac.name}"; else -> "No word from ${mac.name}" }
        fun time(at: Long) = Instant.ofEpochMilli(at).atZone(zone).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale))
        val since = mac.availability.since?.let { at ->
            val date = Instant.ofEpochMilli(at).atZone(zone).toLocalDate(); val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
            when {
                date == today -> "since ${time(at)}"
                date == today.minusDays(1) -> "since yesterday ${time(at)}"
                now - at in 0L until 7L * 86_400_000 -> "since " + Instant.ofEpochMilli(at).atZone(zone).format(DateTimeFormatter.ofPattern("EEEE", locale))
                else -> "since " + Instant.ofEpochMilli(at).atZone(zone).format(DateTimeFormatter.ofPattern("MMM d", locale))
            }
        }
        val first = headline + (since?.let { " · $it" } ?: "")
        if (sentAt != null && now - sentAt >= EXPIRY_SHOWN) {
            val ends = time(sentAt.coerceAtMost(Long.MAX_VALUE - LIFETIME) + LIFETIME)
            val still = when (phase) { MacPhase.CLOSED -> "closed"; MacPhase.SILENT -> "away"; else -> "asleep" }
            return "$first\nExpires at $ends if it’s still $still."
        }
        return "$first\n" + when (phase) { MacPhase.ASLEEP -> "It starts when it wakes."; MacPhase.CLOSED -> "It starts when Yab opens."; else -> "It starts when it’s back." }
    }
}

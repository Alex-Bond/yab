package dev.yab.browser.engine

import dev.yab.browser.model.HistorySwipeDirection
import dev.yab.browser.model.NativeHistorySwipeTarget
import java.util.UUID
import kotlinx.serialization.json.*

/** One physical native allocation across Pager/history. Invalidating UI never releases a pending allocation. */
internal class NativeFrameCaptureArbiter {
    internal class Ticket
    private var pending: Ticket? = null
    fun acquire(): Ticket? = if (pending != null) null else Ticket().also { pending = it }
    fun finish(ticket: Ticket) { if (pending === ticket) pending = null }
    val busy get() = pending != null
}

/** Exact session-lifetime identity; URLs/titles/form state never enter a cache key or diagnostic. */
internal class HistoryEntryIdentity private constructor(private val docShell: String, private val entry: String,
    private val document: String, private val navigation: String, private val key: String) {
    fun matchesNavigation(key: String, id: String) = this.key == key && navigation == id
    override fun equals(other: Any?) = other is HistoryEntryIdentity && docShell == other.docShell && entry == other.entry &&
        document == other.document && navigation == other.navigation && key == other.key
    override fun hashCode() = listOf(docShell, entry, document, navigation, key).hashCode()
    override fun toString() = "HistoryEntryIdentity"
    companion object {
        fun parse(value: JsonElement): HistoryEntryIdentity? {
            val row = value as? JsonObject ?: return null
            fun scalar(name: String) = (row[name] as? JsonPrimitive)?.contentOrNull?.takeIf { it.length <= 64 }
            fun uuid(name: String): String? = scalar(name)?.let { text ->
                val plain = if (text.startsWith("{") && text.endsWith("}")) text.substring(1, text.length - 1)
                    else text.takeIf { '{' !in it && '}' !in it } ?: return null
                plain.takeIf { it.matches(Regex("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")) }?.lowercase()
            }
            // Preserve all 64 bits as decimal text, never a Double round-trip.
            val entry = scalar("ID")?.takeIf { it.toULongOrNull()?.let { n -> n > 0uL } == true && it.matches(Regex("[1-9][0-9]{0,19}")) } ?: return null
            val document = scalar("docIdentifier")?.takeIf { it.toULongOrNull()?.let { n -> n > 0uL } == true && it.matches(Regex("[1-9][0-9]{0,19}")) } ?: return null
            return HistoryEntryIdentity(uuid("docshellUUID") ?: return null, entry, document,
                uuid("navigationId") ?: return null, uuid("navigationKey") ?: return null)
        }
    }
}

internal class HistoryIdentitySnapshot private constructor(val entries: List<HistoryEntryIdentity>, val current: Int) {
    val shown get() = entries[current]
    fun samePosition(other: HistoryIdentitySnapshot) = current == other.current && entries == other.entries
    fun matchesCurrent(key: HistoryNavigationKey): Boolean = key.initialDocument &&
        entries.count { it.matchesNavigation(key.key, key.id) } == 1 && shown.matchesNavigation(key.key, key.id)
    fun neighbor(direction: HistorySwipeDirection): HistoryEntryIdentity? =
        entries.getOrNull(current + if (direction == HistorySwipeDirection.BACK) -1 else 1)
    companion object {
        /** Project only identity from an already-owned public SessionState. Never persist the input. */
        fun parse(text: String): HistoryIdentitySnapshot? {
            if (text.length !in 2..262_144) return null
            return runCatching {
                val root = Json.parseToJsonElement(text) as? JsonObject ?: return null
                val history = root["history"] as? JsonObject ?: return null
                val rows = history["entries"] as? JsonArray ?: return null
                if (rows.size !in 1..2048) return null
                val index = (history["index"] as? JsonPrimitive)?.intOrNull?.minus(1) ?: return null
                if (index !in rows.indices) return null
                val entries = rows.map { HistoryEntryIdentity.parse(it) ?: return null }
                if (entries.toSet().size != entries.size) return null
                HistoryIdentitySnapshot(entries, index)
            }.getOrNull()
        }
    }
}

/** Bounded fixture metadata only, without entry URLs, titles, tokens or document identities. */
internal data class NativeHistoryRegistryProjection(val entriesCount: Int, val currentIndex: Int,
    val backAvailable: Boolean, val forwardAvailable: Boolean, val countsClamped: Boolean)
internal enum class NativeHistoryCaptureStage { HISTORY_UPDATED, ENTRY_REFUSED, NEIGHBOR_REFUSED, CAPTURED }
internal enum class NativeHistoryCaptureSource { SESSION_STATE, HISTORY_LIST, RESTORE }
internal data class NativeHistoryCaptureObservation(val stage: NativeHistoryCaptureStage,
    val direction: HistorySwipeDirection?, val entryPresent: Boolean, val entryAlive: Boolean,
    val selected: Boolean, val sessionOwned: Boolean, val interactive: Boolean, val loading: Boolean,
    val registry: NativeHistoryRegistryProjection?, val source: NativeHistoryCaptureSource? = null)

/** Native absolute-index targets are one-use and independent from optional cached pixels. */
internal class NativeHistorySwipeRegistry {
    private class Lease(val document: String, val revision: Long, val current: Int, val target: Int)
    private var revision = 0L
    private var pages: List<Pair<String, String>> = emptyList()
    private var current = -1
    private val leases = mutableMapOf<String, Lease>()
    fun projection() = NativeHistoryRegistryProjection(pages.size.coerceAtMost(2048), current.coerceIn(-1, 2047),
        (current in pages.indices && current > 0), (current in pages.indices && current < pages.lastIndex),
        (pages.size > 2048 || current !in -1..2047))
    fun update(next: List<Pair<String, String>>, index: Int) {
        if (pages == next && current == index) return
        pages = next.toList(); current = index.takeIf { it in pages.indices } ?: -1; invalidate()
    }
    fun invalidate() { check(revision < Long.MAX_VALUE); revision++; leases.clear() }
    fun capture(document: String, direction: HistorySwipeDirection): NativeHistorySwipeTarget? {
        val index = current + if (direction == HistorySwipeDirection.BACK) -1 else 1
        if (current !in pages.indices || index !in pages.indices) return null
        leases.clear() // One active user gesture, never an unbounded token map.
        val token = UUID.randomUUID().toString()
        leases[token] = Lease(document, revision, current, index)
        return NativeHistorySwipeTarget(token, direction)
    }
    fun current(document: String, target: NativeHistorySwipeTarget): Boolean = leases[target.token]?.let {
        it.document == document && it.revision == revision && it.current == current && it.target in pages.indices &&
            it.target == current + if (target.direction == HistorySwipeDirection.BACK) -1 else 1
    } == true
    fun consume(document: String, target: NativeHistorySwipeTarget): Int? {
        if (!current(document, target)) return null
        val index = leases[target.token]?.target ?: return null
        invalidate(); return index
    }
    /** The native runtime chooses ONE current neighbor at accepted UP. An unreported SPA
     * change can never turn a stale absolute index into a multiple-entry jump. */
    fun commitRelative(document: String, target: NativeHistorySwipeTarget, back: () -> Unit, forward: () -> Unit): Boolean {
        if (consume(document, target) == null) return false
        if (target.direction == HistorySwipeDirection.BACK) back() else forward()
        return true
    }
}

/** At most TWO original native frames including unpromoted/current candidates, ≤32 MiB total. */
internal class HistoryFrameStore<T : Any>(private val session: Any, private val release: (T) -> Unit = {}) {
    private class Frame<T>(val pixels: T, val width: Int, val height: Int, val bytes: Long)
    private val frames = linkedMapOf<HistoryEntryIdentity, Frame<T>>()
    private var shown: HistoryEntryIdentity? = null
    private var candidate: HistoryEntryIdentity? = null
    private var proven: Set<HistoryEntryIdentity> = emptySet()
    fun retain(owner: Any, snapshot: HistoryIdentitySnapshot, width: Int, height: Int, allocationBytes: Long, pixels: T): Boolean {
        if (owner !== session || !permits(width, height, allocationBytes)) return false
        val id = snapshot.entries[snapshot.current]
        remove(id)
        while (frames.size >= 2 || frames.values.sumOf { it.bytes } + allocationBytes > MAX_TOTAL_BYTES) {
            remove(frames.keys.firstOrNull() ?: return false)
        }
        frames[id] = Frame(pixels, width, height, allocationBytes); shown = id; candidate = null
        proven = snapshot.entries.toSet(); return true
    }
    fun pageStarted() { candidate = shown; shown = null; proven = emptySet() }
    fun historyChanged(owner: Any, snapshot: HistoryIdentitySnapshot?) {
        if (owner !== session || snapshot == null) { clear(); return }
        val old = candidate
        // The old rendered document must still be an exact OTHER entry, not a URL match.
        if (old != null && (old !in snapshot.entries || old == snapshot.entries[snapshot.current])) remove(old)
        candidate = null; proven = snapshot.entries.toSet()
        frames.keys.filter { it !in proven }.forEach(::remove)
    }
    fun frame(owner: Any, target: HistoryEntryIdentity, width: Int, height: Int): T? =
        if (owner !== session || target !in proven || candidate != null) null else frames[target]?.takeIf {
            it.width == width && it.height == height
        }?.pixels
    private fun remove(id: HistoryEntryIdentity) { frames.remove(id)?.let { release(it.pixels) } }
    fun removeCurrent(snapshot: HistoryIdentitySnapshot) { remove(snapshot.shown) }
    fun evictOldest() { frames.keys.firstOrNull()?.let(::remove) }
    fun clear() { frames.keys.toList().forEach(::remove); shown = null; candidate = null; proven = emptySet() }
    val count get() = frames.size
    val bytes get() = frames.values.sumOf { it.bytes }
    companion object {
        const val MAX_FRAME_BYTES = 16L * 1024 * 1024
        const val MAX_TOTAL_BYTES = 32L * 1024 * 1024
        fun permits(width: Int, height: Int, bytes: Long) = width in 1..8192 && height in 1..8192 &&
            bytes in 1..MAX_FRAME_BYTES && width.toLong() * height * 4 <= bytes
    }
}

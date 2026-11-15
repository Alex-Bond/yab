package dev.yab.browser.engine

/** Native Xray Navigation getters, captured at document_start. This is a causal entry
 * check, not a compositor presentation fence. No URL, DOM index or author property. */
internal class HistoryNavigationKey private constructor(val key: String, val id: String,
    private val initialKey: String, private val initialId: String, val changes: Long) {
    val initialDocument get() = changes == 0L && key == initialKey && id == initialId
    fun sameVisit(other: HistoryNavigationKey) = initialDocument && other.initialDocument &&
        key == other.key && id == other.id
    override fun toString() = "HistoryNavigationKey"
    companion object {
        fun read(get: (String) -> Any?): HistoryNavigationKey? {
            if (get("known") != true) return null
            fun uuid(name: String) = (get(name) as? String)?.takeIf {
                it.matches(Regex("[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}"))
            }
            val changes = (get("changes") as? Number)?.toDouble()?.takeIf {
                it.isFinite() && it >= 0 && it <= 9_007_199_254_740_991.0 && it % 1.0 == 0.0
            }?.toLong() ?: return null
            return HistoryNavigationKey(uuid("key") ?: return null, uuid("id") ?: return null,
                uuid("initialKey") ?: return null, uuid("initialId") ?: return null, changes)
        }
    }
}

/** Both independent, already-owned native/isolated observations must agree. A trusted
 * same-document change permanently disqualifies this visit's images, including A→B→A. */
internal class HistoryPaintCandidate(val snapshot: HistoryIdentitySnapshot, val key: HistoryNavigationKey) {
    fun current(next: HistoryIdentitySnapshot?, receipt: HistoryNavigationKey?) = next != null && receipt != null &&
        snapshot.samePosition(next) && key.sameVisit(receipt) && next.matchesCurrent(receipt)
    companion object {
        fun create(snapshot: HistoryIdentitySnapshot?, key: HistoryNavigationKey?): HistoryPaintCandidate? =
            if (snapshot != null && key != null && snapshot.matchesCurrent(key)) HistoryPaintCandidate(snapshot, key) else null
    }
}

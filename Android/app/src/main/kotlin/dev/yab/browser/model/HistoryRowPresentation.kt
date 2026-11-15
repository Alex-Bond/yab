package dev.yab.browser.model

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A row's original source, in addition to the unchanged History screen lease. */
data class HistoryRowPresentationLease internal constructor(
    val visit: BrowserVisit,
    internal val presentation: HistoryPresentationLease,
    internal val source: Any,
)

/** Only live captured rows occupy this map. Removing/changing a row retires its
 * token before publication, including an equal-value remove/readd or value ABA. */
internal class HistoryRowSources {
    private val live = mutableMapOf<String, Any>()
    private val mutable = MutableStateFlow<Map<String, Any>>(emptyMap())
    val state = mutable.asStateFlow()
    fun capture(visit: BrowserVisit): Any = live[visit.identity] ?: Any().also {
        live[visit.identity] = it
        mutable.value = live.toMap()
    }
    fun current(visit: BrowserVisit, source: Any) = live[visit.identity] === source
    fun reconcile(before: List<BrowserVisit>, next: List<BrowserVisit>) {
        if (live.isEmpty()) return
        val old = before.associateBy(BrowserVisit::identity)
        val fresh = next.associateBy(BrowserVisit::identity)
        if (live.keys.removeAll { id -> fresh[id] == null || old[id] != fresh[id] }) mutable.value = live.toMap()
    }
    fun clear() { live.clear(); mutable.value = emptyMap() }
}

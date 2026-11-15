package dev.yab.android

import dev.yab.browser.model.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable

/** Phone LaunchKeyboard.opens. Unknown restored scroll is deliberately not an observed zero. */
internal object LaunchKeyboardPolicy {
    enum class Moment { LAUNCH, BACK }
    data class Situation(val moment: Moment, val enabled: Boolean = true, val asked: Boolean = false,
        val welcome: Boolean = false, val privateFront: Boolean = false, val covered: Boolean = false,
        val hasTab: Boolean = true, val scroll: Double? = null, val awayMillis: Long? = null)
    fun opens(s: Situation): Boolean {
        if (!s.enabled || s.asked || s.welcome || s.privateFront || s.covered) return false
        if (!s.hasTab) return true
        if (s.moment == Moment.BACK) return false
        if (s.awayMillis != null && s.awayMillis < 900_000L && (s.scroll == null || s.scroll > 200.0)) return false
        return true
    }
    fun fixtureAllowed(instrumented: Boolean, explicit: Boolean) = !instrumented || explicit
}

/** One public front only, local to this app, never part of Sync or Private state. */
@Serializable
internal data class LaunchKeyboardFront(val account: String?, val device: String?, val space: String,
    val tab: String, val profile: String, val url: String) {
    fun valid() = listOf(space, tab, profile).all { it.isNotEmpty() && it.length <= 256 } && url.length <= 8192 &&
        (account?.length ?: 0) <= 256 && (device?.length ?: 0) <= 256
    companion object {
        fun capture(state: BrowserState, account: String?, device: String?): LaunchKeyboardFront? {
            val space = state.space ?: return null
            val tab = state.tab ?: return null
            if (state.loading || state.privateContentBlocked || space.isPrivate || tab.isPrivate || space.websiteProfile.isPrivate ||
                state.surface in setOf(BrowserSurface.FIELD, BrowserSurface.SPACES) && state.fieldIsPrivate) return null
            return LaunchKeyboardFront(account, device, space.id, tab.id, space.websiteProfile.id, tab.url).takeIf { it.valid() }
        }
    }
}

@Serializable
internal data class LaunchKeyboardMemory(val leftAt: Long? = null, val front: LaunchKeyboardFront? = null, val scroll: Double? = null) {
    fun valid() = (leftAt == null || leftAt >= 0) && (front == null || front.valid()) &&
        (scroll == null || scroll.isFinite() && scroll >= 0) && (scroll == null || front != null)
    fun away(now: Long): Long? = leftAt?.let { (now - it).coerceAtLeast(0) }
    fun scrollFor(original: LaunchKeyboardFront?) = scroll.takeIf { original != null && front == original }
    fun ownedAway(original: LaunchKeyboardFront?, away: Long?) = away.takeIf { original != null && front == original }
}

/** RAM observations are persisted only at a real public background boundary. */
internal class LaunchKeyboardCache(initial: LaunchKeyboardMemory, private val save: (LaunchKeyboardMemory) -> Unit) {
    var cold = initial.takeIf { it.valid() } ?: LaunchKeyboardMemory()
        private set
    private var persisted = cold
    private data class Observation(val front: LaunchKeyboardFront, val scroll: Double,
        val source: LaunchKeyboardSource, val document: Any, val documentRevision: Long)
    private var observed: Observation? = null
    private var restoredSource: Pair<LaunchKeyboardSource, Long>? = null
    private var restored = false
    fun reconcile(front: LaunchKeyboardFront?, source: LaunchKeyboardSource, erased: Boolean = false, documentRevision: Long = 0) {
        if (erased || front == null || cold.front?.let { it != front } == true || persisted.front?.let { it != front } == true) clear()
        if (!restored) { restored = true; restoredSource = source to documentRevision }
        if (observed?.source != source || observed?.documentRevision != documentRevision) observed = null
    }
    fun clear() {
        val had = cold != LaunchKeyboardMemory() || persisted != LaunchKeyboardMemory() || observed != null
        cold = LaunchKeyboardMemory(); observed = null; restoredSource = null
        if (had) { save(cold); persisted = cold }
    }
    fun observe(front: LaunchKeyboardFront, scroll: Double, source: LaunchKeyboardSource, document: Any, documentRevision: Long = 0) {
        if (front.valid() && scroll.isFinite() && scroll >= 0) observed = Observation(front, scroll, source, document, documentRevision)
    }
    fun background(front: LaunchKeyboardFront?, source: LaunchKeyboardSource?, now: Long, configurationChange: Boolean, documentRevision: Long = 0,
        documentCurrent: (Any) -> Boolean): Boolean {
        if (configurationChange) return false
        if (front == null || !front.valid() || source == null) { clear(); return false }
        val matching = observed?.takeIf { it.front == front && it.source == source && it.documentRevision == documentRevision && documentCurrent(it.document) }
        val value = LaunchKeyboardMemory(now.coerceAtLeast(0), front,
            matching?.scroll ?: cold.scrollFor(front).takeIf { observed == null && (source to documentRevision) == restoredSource })
        save(value); persisted = value
        return true
    }
}

internal data class LaunchKeyboardSource(val account: String?, val device: String?, val accountEpoch: Long,
    val removed: Boolean, val space: String?, val profile: WebsiteProfile?, val tab: String?, val url: String?,
    val epoch: Long, val history: Long, val foreground: Long, val privateBoundary: Long, val active: Boolean)

/** A new VM matches Phone's new Scene/AppModel. Its retained arrival is consumed once;
 * configuration replacement never renews it, while a real return is BACK. */
internal class LaunchKeyboardPresentation(val cache: LaunchKeyboardCache) {
    data class Arrival internal constructor(val token: Any, val owner: Any, val moment: LaunchKeyboardPolicy.Moment,
        val asked: Boolean, val account: Triple<String?, String?, Long>, val awayMillis: Long?,
        val source: LaunchKeyboardSource? = null)
    private var owner: Any? = null
    private var started = false
    private var returning = false
    private var enabledForHost = false
    private val mutableArrival = MutableStateFlow<Arrival?>(null)
    val arrival = mutableArrival.asStateFlow()
    fun attach(next: Any) { mutableArrival.value = null; owner = next; enabledForHost = false }
    fun foreground(original: Any, asked: Boolean, allowed: Boolean, account: Triple<String?, String?, Long>, source: LaunchKeyboardSource?, now: Long) {
        if (owner !== original) return
        val moment = if (!started) LaunchKeyboardPolicy.Moment.LAUNCH else if (returning) LaunchKeyboardPolicy.Moment.BACK else null
        started = true; returning = false; enabledForHost = allowed
        mutableArrival.value = if (moment == null || !allowed) null else Arrival(Any(), original, moment, asked,
            account, cache.cold.away(now), source)
    }
    fun loaded(source: LaunchKeyboardSource) {
        val old = mutableArrival.value ?: return
        if (old.account != Triple(source.account, source.device, source.accountEpoch)) { cancel(old.owner); return }
        if (old.source == null) mutableArrival.value = old.copy(source = source)
        else if (old.source != source) cancel(old.owner)
    }
    fun cancel(original: Any) { if (owner === original) mutableArrival.value = null }
    fun retire(original: Arrival) { if (mutableArrival.value === original) mutableArrival.value = null }
    fun observationsAllowed(original: Any) = owner === original && enabledForHost
    fun background(original: Any, configurationChange: Boolean) {
        if (owner !== original) return
        mutableArrival.value = null
        returning = !configurationChange
        enabledForHost = false
    }
    fun current(original: Arrival, source: LaunchKeyboardSource): Boolean = owner === original.owner &&
        mutableArrival.value === original && original.source == source
    fun consume(original: Arrival, source: LaunchKeyboardSource, current: () -> Boolean, open: () -> Unit): Boolean {
        if (!this.current(original, source) || !current() || !this.current(original, source)) { retire(original); return false }
        mutableArrival.value = null
        open()
        return true
    }
}

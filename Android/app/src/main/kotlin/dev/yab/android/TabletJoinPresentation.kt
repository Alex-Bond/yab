package dev.yab.android

import dev.yab.browser.model.BrowserTabletWorkspaceGeometry
import dev.yab.browser.model.BrowserWorkspaceWindow
import dev.yab.sync.AndroidSyncBridge
import dev.yab.sync.SyncIdentityLease
import java.io.Closeable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Local first-run presentation only. An attempt or success grants no Sync capability. */
class TabletJoinPresentation internal constructor(
    private val source: () -> Source,
    private val hostCurrent: () -> Boolean,
) : Closeable {
    internal data class Source(val identity: SyncIdentityLease?, val epoch: Long, val available: Boolean)
    internal class Attempt internal constructor(internal val original: Source)
    internal class Success internal constructor(val identity: SyncIdentityLease)
    internal data class State(val revision: Long = 0, val success: Success? = null, val finished: Boolean = false)
    internal class Control internal constructor(private val owner: TabletJoinPresentation,
        private val revision: Long, private val original: Source) {
        private var retired = false
        internal fun retire() { retired = true }
        internal fun consume(): Source? {
            if (retired) return null
            retired = true
            return original.takeIf { owner.alive() && owner.revision == revision && original.available &&
                original.identity == null && owner.source() == original && owner.revision == revision }
        }
    }

    private var closed = false
    private var revision = 0L
    private var active: Attempt? = null
    private val mutable = MutableStateFlow(State())
    internal val state = mutable.asStateFlow()

    private fun alive(): Boolean {
        if (closed) return false
        if (!hostCurrent()) { closed = true; active = null; return false }
        return true
    }
    internal fun available(): Boolean = alive()
    internal fun control(original: Source = source()): Control = Control(this, revision, original)
    internal fun begin(control: Control): Attempt? {
        val original = control.consume() ?: return null
        revision++
        return Attempt(original).also { active = it; mutable.value = State(revision) }
    }
    internal fun cancel(control: Control): Boolean {
        if (control.consume() == null) return false
        revision++; active = null; mutable.value = State(revision)
        return true
    }
    /** Called on Main only by the optional original-operation completion observer. */
    internal fun joined(attempt: Attempt, identity: SyncIdentityLease): Boolean {
        if (!alive() || active !== attempt) return false
        active = null
        val current = source()
        if (!current.available || current.identity != identity || current.epoch != identity.epoch ||
            identity.epoch <= attempt.original.epoch) return false
        mutable.value = State(++revision, Success(identity))
        return true
    }
    internal fun current(success: Success): Boolean {
        if (!alive() || mutable.value.success !== success) return false
        val current = source()
        if (!current.available || current.identity != success.identity || current.epoch != success.identity.epoch) {
            closed = true; active = null
            return false
        }
        return true
    }
    internal fun finish(success: Success): Boolean {
        if (!current(success)) return false
        closed = true
        mutable.value = State(++revision, finished = true)
        return true
    }
    override fun close() {
        closed = true; active = null
        mutable.value = State(++revision, finished = true)
    }
}

/** Ordinary source reads stay outside composition; no UI receipt can manufacture an identity. */
internal fun tabletJoinSource(sync: AndroidSyncBridge): TabletJoinPresentation.Source {
    val records = sync.accountRecords.value
    val identity = sync.identityLease()
    val matches = identity?.account == records.account && identity?.device == records.device &&
        (identity == null || identity.epoch == records.epoch)
    return TabletJoinPresentation.Source(identity, records.epoch, matches && sync.nativeOwnerCurrent(records))
}

internal object TabletJoinSuccessGeometry {
    fun eligible(window: BrowserWorkspaceWindow, smallestScreenWidthDp: Int): Boolean =
        BrowserTabletWorkspaceGeometry.eligible(window, smallestScreenWidthDp)
    fun width(available: Double): Double = if (available.isFinite() && available > 0)
        maxOf(1.0, minOf(520.0, available - 48.0)) else 1.0
}

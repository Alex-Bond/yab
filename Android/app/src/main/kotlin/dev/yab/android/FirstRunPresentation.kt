package dev.yab.android

import dev.yab.sync.SyncIdentityLease
import dev.yab.sync.CodeJoinRequest
import dev.yab.sync.RecoveryHandoff
import dev.yab.browser.model.*
import kotlin.math.roundToInt
import java.io.Closeable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** RAM-only journey. A rendered control or pending completion keeps its own native host. */
internal class FirstRunPresentation(
    private val source: () -> TabletJoinPresentation.Source,
    private val codeSource: () -> String?,
) : Closeable {
    internal fun interface Host { fun current(): Boolean }
    internal class RenderedHost(private val valid: () -> Boolean) : Host {
        private var retired = false
        fun retire() { retired = true }
        override fun current(): Boolean {
            if (retired) return false
            if (!valid()) { retired = true; return false }
            return !retired
        }
    }
    internal enum class Step { WELCOME, FOUND, CHOOSE, CODE, RECOVERY, NO_MAC, JOINED, TO_LINKS, LINKS, LEAVING_LINKS, GUIDE, FINISHED }
    internal enum class Haptic { CONFIRM, COPY, JOINED }
    internal data class DefaultBrowser(val available: Boolean, val held: Boolean)
    internal data class State(
        val step: Step = Step.WELCOME,
        val revision: Long = 0,
        val risen: Boolean = false,
        val trayUp: Boolean = false,
        val groundUp: Boolean = true,
        val withoutMac: Boolean = false,
        val recovery: String = "",
        val recoveryRevision: Long = 0,
        val lastCode: String? = null,
        val codeValue: String? = null,
        val codeRevision: Long = 0,
        val failureRevision: Long = 0,
        val ownedRequest: Boolean = false,
        val request: CodeJoinRequest? = null,
        val requestBindingRevision: Long = 0,
        val checkValue: String? = null,
        val requestError: String? = null,
        val handoff: RecoveryHandoff? = null,
        val handoffError: String? = null,
        val joinedFrom: Step? = null,
        val counting: Boolean = false,
        val countTick: Int = 0,
        val counted: Int = 0,
        val foundCounts: FoundCounts? = null,
    )

    internal class Control internal constructor(
        private val owner: FirstRunPresentation,
        internal val host: Host,
        internal val original: TabletJoinPresentation.Source,
        private val revision: Long,
        private val failureRevision: Long,
        private val recoveryRevision: Long?,
        private val codeRevision: Long?,
        private val originalCode: String?,
        internal val requestControl: RequestControl? = null,
        internal val recoveryControl: RecoveryControl? = null,
    ) {
        private var retired = false
        fun retire() { retired = true }
        internal fun current(): Boolean = !retired && owner.current(host, original) &&
            owner.state.value.revision == revision && owner.state.value.failureRevision == failureRevision &&
            (recoveryRevision == null || owner.state.value.recoveryRevision == recoveryRevision) &&
            (codeRevision == null || owner.state.value.codeRevision == codeRevision &&
                owner.state.value.codeValue == originalCode && owner.codeCurrent(originalCode)) &&
            (requestControl?.current() != false) &&
            (recoveryControl?.current() != false) &&
            owner.current(host, original)
        internal fun consume(forOwner: FirstRunPresentation): Boolean {
            if (owner !== forOwner) return false
            val accepted = current()
            retired = true
            return accepted
        }
    }

    internal class Input internal constructor(
        private val owner: FirstRunPresentation,
        internal val host: Host,
        internal val original: TabletJoinPresentation.Source,
        private val revision: Long,
    ) {
        private var retired = false
        fun retire() { retired = true }
        internal fun current(forOwner: FirstRunPresentation = owner): Boolean {
            if (owner !== forOwner) return false
            val accepted = !retired && owner.state.value.step == Step.RECOVERY &&
                owner.state.value.revision == revision && owner.current(host, original)
            if (!accepted) retired = true
            return accepted
        }
    }

    internal class Attempt internal constructor(
        internal val host: Host,
        internal val original: TabletJoinPresentation.Source,
        internal val recovery: Boolean,
    ) {
        internal var failed = false
        internal var cancelPendingCode: (() -> Boolean)? = null
    }
    internal class RequestOwner(val original: TabletJoinPresentation.Source) {
        var request: CodeJoinRequest? = null
        var snapshot: CodeJoinRequest.Presentation? = null
        var binding: RequestBinding? = null
        var retired = false
        fun retire() { retired = true; binding = null }
    }
    internal class RequestBinding(val host: Host)
    internal class RequestControl(private val flow: FirstRunPresentation, internal val owner: RequestOwner,
        private val binding: RequestBinding, internal val snapshot: CodeJoinRequest.Presentation) {
        fun current(): Boolean = flow.logicalRequest === owner && !owner.retired && owner.binding === binding &&
            owner.snapshot === snapshot && owner.request?.presentation?.value === snapshot &&
            owner.request?.permits(snapshot) == true &&
            flow.current(binding.host, owner.original)
    }
    internal class RecoveryOwner(val original: TabletJoinPresentation.Source, val handoff: RecoveryHandoff,
        val automatic: Attempt) {
        var binding: RequestBinding? = null
        var snapshot: RecoveryHandoff.Presentation? = null
        var retired = false
    }
    internal class RecoveryControl(private val flow: FirstRunPresentation, internal val owner: RecoveryOwner,
        private val binding: RequestBinding, private val snapshot: RecoveryHandoff.Presentation) {
        fun current(): Boolean = flow.recoveryOwner === owner && !owner.retired && owner.binding === binding &&
            owner.snapshot === snapshot && owner.handoff.presentation.value === snapshot &&
            flow.current(binding.host, owner.original)
    }
    internal data class FoundCounts(val tabs: Int, val pins: Int, val folders: Int) {
        companion object {
            fun from(spaces: List<BrowserSpace>): FoundCounts {
                var tabs = 0; var pins = 0; var folders = 0
                for (space in spaces.filterNot { it.isPrivate }) {
                    val reachable = mutableSetOf<String>()
                    val pending = ArrayDeque<String?>(); pending.addLast(null)
                    while (pending.isNotEmpty()) {
                        val parent = pending.removeFirst()
                        for (folder in space.folders.filter { it.parentId == parent })
                            if (reachable.add(folder.id)) pending.addLast(folder.id)
                    }
                    folders += reachable.size
                    tabs += space.tabs.count { !it.isPrivate && (it.place == TabPlace.TODAY ||
                        it.place == TabPlace.KEPT && (it.folderId == null || it.folderId in reachable)) }
                    pins += space.tabs.count { !it.isPrivate && it.place == TabPlace.PINNED }
                }
                return FoundCounts(tabs, pins, folders)
            }
        }
    }
    private class FoundAttempt(val host: Host)
    internal class Timer internal constructor(internal val control: Control, val delayMillis: Long, internal val step: Step)
    internal class Completion internal constructor(
        internal val host: Host,
        internal val original: TabletJoinPresentation.Source,
        val withoutMac: Boolean,
    ) {
        fun current(source: () -> TabletJoinPresentation.Source): Boolean = host.current() && source() == original && host.current()
    }

    private var bound = source()
    private var closed = false
    private var active: Attempt? = null
    private var logicalRequest: RequestOwner? = null
    private var recoveryOwner: RecoveryOwner? = null
    private var found: FoundAttempt? = null
    private val mutable = MutableStateFlow(State())
    val state = mutable.asStateFlow()

    private fun current(host: Host, original: TabletJoinPresentation.Source): Boolean =
        !closed && original.available && original == bound && host.current() && source() == original && host.current()

    private fun codeCurrent(code: String?): Boolean = logicalRequest?.let {
        !it.retired && it.snapshot === it.request?.presentation?.value && it.snapshot?.code == code
    } ?: (codeSource() == code)

    /** Called only by a fresh render. This does not create or adopt an account. */
    fun control(host: Host, recoveryValue: Boolean = false, expected: State? = null): Control? {
        val value = state.value
        if (expected != null && (expected.revision != value.revision || expected.failureRevision != value.failureRevision ||
                expected.step == Step.CODE && expected.codeRevision != value.codeRevision ||
                expected.requestBindingRevision != value.requestBindingRevision)) return null
        val requestControl = logicalRequest?.takeIf { value.step in setOf(Step.CODE, Step.RECOVERY) }?.let { owner ->
            val binding = owner.binding?.takeIf { it.host === host } ?: return null
            val snapshot = owner.snapshot ?: return null
            RequestControl(this, owner, binding, snapshot).takeIf { it.current() } ?: return null
        }
        val recoveryControl = recoveryOwner?.takeIf { value.step == Step.RECOVERY }?.let { owner ->
            val binding = owner.binding?.takeIf { it.host === host } ?: return null
            val snapshot = owner.snapshot ?: return null
            RecoveryControl(this, owner, binding, snapshot).takeIf { it.current() } ?: return null
        }
        return if (current(host, bound)) Control(this, host, bound, value.revision, value.failureRevision,
            value.recoveryRevision.takeIf { recoveryValue }, value.codeRevision.takeIf { value.step == Step.CODE }, value.codeValue,
            requestControl, recoveryControl) else null
    }
    fun input(host: Host, expected: State? = null): Input? = if ((expected == null || expected.revision == state.value.revision) &&
        state.value.step == Step.RECOVERY && current(host, bound))
        Input(this, host, bound, state.value.revision) else null
    /** Passive source observation never turns a reconnect or replacement into Joined. */
    fun observe(host: Host) {
        if (closed || !host.current()) return
        if (active?.host?.current() == false) active = null
        if (found?.host?.current() == false) {
            found = null
            change(state.value.copy(step = Step.FOUND, counting = false, countTick = 0, counted = 0, foundCounts = null))
        }
        if (active == null && source() != bound) close()
    }

    /** Fresh render registers user actions only; it never replaces an automatic completion Host. */
    fun observeRequest(host: Host, request: CodeJoinRequest?, snapshot: CodeJoinRequest.Presentation?) {
        val owner = logicalRequest ?: return
        if (owner.retired || owner.request !== request || request == null || snapshot == null ||
            request.presentation.value !== snapshot || state.value.step !in setOf(Step.CODE, Step.RECOVERY)) return
        if (snapshot.stage == CodeJoinRequest.Stage.RETIRED) { owner.retire(); close(); return }
        if (source() != owner.original || bound != owner.original) {
            retireRequest()
            // The original automatic callback alone can accept its genuine new identity.
            // Preserve the existing active-attempt delivery window without adopting it here.
            if (snapshot.stage !in setOf(CodeJoinRequest.Stage.COMMITTED, CodeJoinRequest.Stage.COMPLETE,
                    CodeJoinRequest.Stage.FAILED) || active?.host?.current() != true) close()
            return
        }
        if (!current(host, owner.original)) return
        if (!request.permits(snapshot)) return
        val newHost = owner.binding?.host !== host
        val changed = owner.snapshot !== snapshot
        if (!newHost && !changed) return
        if (newHost) owner.binding = RequestBinding(host)
        owner.snapshot = snapshot
        // Keep Recovery's input revision/value intact while retiring only code/Host actions.
        mutable.value = state.value.copy(requestBindingRevision = state.value.requestBindingRevision + if (newHost) 1 else 0,
            codeValue = snapshot.code, checkValue = snapshot.check, requestError = snapshot.error,
            lastCode = snapshot.code ?: state.value.lastCode, codeRevision = state.value.codeRevision + 1)
    }
    /** Refusal is local data; fresh observation never rebinds the automatic Recovery Attempt. */
    fun observeRecovery(host: Host, handoff: RecoveryHandoff?, snapshot: RecoveryHandoff.Presentation?) {
        val owner = recoveryOwner ?: return
        if (owner.retired || handoff == null || owner.handoff !== handoff || snapshot == null || handoff.presentation.value !== snapshot ||
            state.value.step != Step.RECOVERY) return
        if (source() != owner.original || bound != owner.original) {
            retireRecovery()
            if (snapshot.phase !in setOf(RecoveryHandoff.Phase.COMMITTED, RecoveryHandoff.Phase.COMPLETE) ||
                active?.host?.current() != true) close()
            return
        }
        if (!current(host, owner.original)) return
        if (owner.binding?.host === host && owner.snapshot === snapshot) return
        if (owner.binding?.host !== host) owner.binding = RequestBinding(host)
        owner.snapshot = snapshot
        mutable.value = state.value.copy(handoffError = snapshot.error,
            requestBindingRevision = state.value.requestBindingRevision + 1)
    }

    private fun change(next: State) { mutable.value = next.copy(revision = state.value.revision + 1) }
    private fun accepts(control: Control?, step: Step): Control? = control?.takeIf {
        state.value.step == step && it.consume(this)
    }
    private fun show(step: Step) { change(state.value.copy(step = step, trayUp = true)) }

    fun begin(control: Control?): Boolean {
        if (state.value.risen || accepts(control, Step.WELCOME) == null) return false
        change(state.value.copy(risen = true))
        return true
    }

    fun timer(host: Host, animationsDisabled: Boolean): Timer? {
        val value = state.value
        val delay = when (value.step) {
            Step.WELCOME -> if (value.risen) 1_300L else return null
            Step.FOUND -> if (value.counting && found?.host === host) 100L else return null
            Step.JOINED -> 1_400L
            Step.TO_LINKS -> 400L
            Step.LEAVING_LINKS -> 200L
            else -> return null
        }
        return control(host)?.let { Timer(it, if (animationsDisabled) 0 else delay, value.step) }
    }

    fun advance(timer: Timer, defaultBrowser: DefaultBrowser, finish: (Completion) -> Boolean,
        savedJoined: () -> Unit = {}): Boolean {
        val control = accepts(timer.control, timer.step) ?: return false
        when (timer.step) {
            Step.WELCOME -> show(if (bound.identity != null) Step.FOUND else Step.CHOOSE)
            Step.FOUND -> {
                if (found?.host !== control.host || !state.value.counting || bound.identity == null) return false
                val tick = state.value.countTick + 1
                val progress = tick / 8.0
                val eased = 1 - (1 - progress) * (1 - progress) * (1 - progress)
                if (tick < 8) change(state.value.copy(countTick = tick,
                    counted = ((state.value.foundCounts?.tabs ?: 0) * eased).roundToInt()))
                else {
                    found = null
                    change(state.value.copy(step = Step.JOINED, joinedFrom = Step.FOUND, counting = false,
                        countTick = 8, counted = state.value.foundCounts?.tabs ?: 0))
                    savedJoined()
                }
            }
            Step.JOINED -> toLinks()
            Step.TO_LINKS -> if (defaultBrowser.held || !defaultBrowser.available) leaveLinks() else show(Step.LINKS)
            Step.LEAVING_LINKS -> if (state.value.withoutMac) return complete(control, finish) else {
                change(state.value.copy(step = Step.GUIDE, trayUp = false))
            }
            else -> return false
        }
        return true
    }

    fun joinSaved(control: Control?, counts: FoundCounts): Boolean {
        if (state.value.counting || bound.identity == null) return false
        val accepted = accepts(control, Step.FOUND) ?: return false
        found = FoundAttempt(accepted.host)
        change(state.value.copy(counting = true, countTick = 0, counted = 0, foundCounts = counts))
        return true
    }

    fun chooseNoMac(control: Control?): Boolean {
        if (accepts(control, Step.CHOOSE) == null) return false
        show(Step.NO_MAC)
        return true
    }
    fun useWithoutMac(control: Control?): Boolean {
        if (accepts(control, Step.NO_MAC) == null) return false
        change(state.value.copy(withoutMac = true, step = Step.TO_LINKS, trayUp = false, groundUp = false))
        return true
    }

    fun chooseMac(control: Control?, start: ((SyncIdentityLease) -> Unit, () -> Unit) -> Unit, joined: () -> Unit = {}): Boolean {
        val accepted = accepts(control, Step.CHOOSE) ?: return false
        if (accepted.original.identity != null) return false
        startCode(accepted, start, joined)
        return true
    }
    /** Only this original Attempt receives the request created by its own start. */
    fun chooseMacRequest(control: Control?, start: ((SyncIdentityLease) -> Unit, () -> Unit) -> (() -> Boolean),
        joined: () -> Unit = {}): Boolean = chooseMac(control, requestStart(start), joined)
    fun chooseMacOwnedRequest(control: Control?, start: ((SyncIdentityLease) -> Unit, () -> Unit) -> CodeJoinRequest,
        joined: () -> Unit = {}): Boolean {
        val accepted = accepts(control, Step.CHOOSE) ?: return false
        if (accepted.original.identity != null) return false
        startOwnedCode(accepted, start, joined)
        return true
    }
    private fun startOwnedCode(accepted: Control, start: ((SyncIdentityLease) -> Unit, () -> Unit) -> CodeJoinRequest,
        joined: () -> Unit) {
        logicalRequest?.retire()
        val owner = RequestOwner(accepted.original)
        logicalRequest = owner
        mutable.value = state.value.copy(ownedRequest = true, request = null, codeValue = null, checkValue = null,
            requestError = null, lastCode = null, codeRevision = state.value.codeRevision + 1)
        startCode(accepted, { success, failure ->
            val attempt = checkNotNull(active)
            val request = start(success, failure)
            if (logicalRequest === owner && !owner.retired && !closed) {
                owner.request = request
                if (active === attempt) attempt.cancelPendingCode = request::cancel
                mutable.value = state.value.copy(request = request)
            }
        }, joined)
    }
    private fun requestStart(start: ((SyncIdentityLease) -> Unit, () -> Unit) -> (() -> Boolean)):
        ((SyncIdentityLease) -> Unit, () -> Unit) -> Unit = { success, failure ->
        val attempt = checkNotNull(active)
        val cancel = start(success, failure)
        if (active === attempt) attempt.cancelPendingCode = cancel
    }
    private fun startCode(control: Control, start: ((SyncIdentityLease) -> Unit, () -> Unit) -> Unit, onJoined: () -> Unit) {
        val attempt = Attempt(control.host, control.original, recovery = false)
        active = attempt
        show(Step.CODE)
        start({ if (joined(attempt, it)) onJoined() }, { failed(attempt) })
    }

    fun useRecovery(control: Control?): Boolean {
        if (accepts(control, Step.CODE) == null) return false
        show(Step.RECOVERY)
        return true
    }
    fun editRecovery(input: Input?, text: String): Boolean {
        if (input?.current(this) != true) return false
        val old = state.value
        if (!input.current(this)) return false
        mutable.value = old.copy(recovery = text, recoveryRevision = old.recoveryRevision + 1)
        return true
    }
    /** A current editor's Return owns its existing Input, not a newly captured button. */
    fun restoreFromInput(input: Input?, text: String,
        start: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit, onJoined: () -> Unit = {}): Boolean {
        if (input?.current(this) != true || text.isBlank() || state.value.recovery != text) return false
        val attempt = Attempt(input.host, input.original, recovery = true)
        active = attempt
        change(state.value)
        start(text, { if (joined(attempt, it)) onJoined() }, { failed(attempt) })
        return true
    }
    fun observeCode(host: Host, code: String?) {
        if (logicalRequest != null) return
        if (state.value.codeValue == code || codeSource() != code || state.value.step !in setOf(Step.CODE, Step.RECOVERY) ||
            !current(host, bound)) return
        mutable.value = state.value.copy(lastCode = code ?: state.value.lastCode, codeValue = code,
            codeRevision = state.value.codeRevision + 1)
    }
    private fun releaseOriginalCodeForRecovery(host: Host, original: TabletJoinPresentation.Source): Boolean {
        logicalRequest?.let { owner ->
            if (owner.original != original || owner.binding?.host !== host || !current(host, original)) return false
            val snapshot = owner.snapshot ?: return false
            if (owner.request?.presentation?.value !== snapshot || owner.request?.permitsRecovery(snapshot) != true) return false
            if (snapshot.stage != CodeJoinRequest.Stage.FAILED && owner.request?.cancel() != true) return false
            retireRequest()
            return true
        }
        val attempt = active ?: return false
        if (attempt.host !== host || attempt.original != original || !attempt.host.current()) return false
        if (attempt.failed) return true
        if (attempt.recovery) return false
        return attempt.cancelPendingCode?.invoke() == true
    }
    fun restoreRequest(control: Control?, originalText: String,
        start: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit, onJoined: () -> Unit = {}): Boolean {
        if (state.value.step != Step.RECOVERY || originalText.isBlank() || state.value.recovery != originalText ||
            control?.current() != true) return false
        if (logicalRequest != null) {
            if (accepts(control, Step.RECOVERY) == null ||
                !releaseOriginalCodeForRecovery(control.host, control.original)) return false
            startOwnedRecovery(control.host, control.original, originalText, start, onJoined)
            return true
        }
        if (!releaseOriginalCodeForRecovery(control.host, control.original)) return false
        return restore(control, originalText, start, onJoined)
    }
    fun restoreFromInputRequest(input: Input?, text: String,
        start: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit, onJoined: () -> Unit = {}): Boolean {
        if (input?.current(this) != true || text.isBlank() || state.value.recovery != text) return false
        if (logicalRequest != null) {
            if (!releaseOriginalCodeForRecovery(input.host, input.original)) return false
            startOwnedRecovery(input.host, input.original, text, start, onJoined)
            return true
        }
        if (!releaseOriginalCodeForRecovery(input.host, input.original)) return false
        return restoreFromInput(input, text, start, onJoined)
    }
    private fun startOwnedRecovery(host: Host, original: TabletJoinPresentation.Source, text: String,
        start: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit, onJoined: () -> Unit) {
        val attempt = Attempt(host, original, recovery = true)
        active = attempt
        change(state.value)
        start(text, { if (joined(attempt, it)) onJoined() }, { failed(attempt) })
    }
    private fun guardedHandoff(host: Host, original: TabletJoinPresentation.Source): RecoveryHandoff? {
        if (!current(host, original)) return null
        logicalRequest?.let { owner ->
            if (owner.original != original || owner.binding?.host !== host) return null
            val snapshot = owner.snapshot ?: return null
            return owner.request?.recoveryHandoff(snapshot)
        }
        val owner = recoveryOwner ?: return null
        if (owner.retired || owner.original != original || owner.binding?.host !== host ||
            owner.automatic !== active || owner.automatic.host !== host || !owner.automatic.failed ||
            !owner.automatic.host.current() || owner.handoff.presentation.value !== owner.snapshot) return null
        return owner.handoff.retry()
    }
    fun restoreGuardedRequest(control: Control?, originalText: String,
        start: (String, RecoveryHandoff, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit,
        onJoined: () -> Unit = {}): Boolean {
        if (originalText.isBlank() || state.value.recovery != originalText) return false
        val accepted = accepts(control, Step.RECOVERY) ?: return false
        val handoff = guardedHandoff(accepted.host, accepted.original) ?: return false
        startGuardedRecovery(accepted.host, accepted.original, originalText, handoff, start, onJoined)
        return true
    }
    fun restoreGuardedFromInput(input: Input?, text: String,
        start: (String, RecoveryHandoff, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit,
        onJoined: () -> Unit = {}): Boolean {
        if (input?.current(this) != true || text.isBlank() || state.value.recovery != text) return false
        val handoff = guardedHandoff(input.host, input.original) ?: return false
        startGuardedRecovery(input.host, input.original, text, handoff, start, onJoined)
        return true
    }
    private fun startGuardedRecovery(host: Host, original: TabletJoinPresentation.Source, text: String,
        handoff: RecoveryHandoff, start: (String, RecoveryHandoff, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit,
        onJoined: () -> Unit) {
        retireRequest(); retireRecovery()
        val attempt = Attempt(host, original, recovery = true)
        active = attempt
        recoveryOwner = RecoveryOwner(original, handoff, attempt)
        change(state.value.copy(handoff = handoff, handoffError = null))
        start(text, handoff, { if (joined(attempt, it)) onJoined() }, { failed(attempt) })
    }
    fun restore(control: Control?, originalText: String, start: (String, (SyncIdentityLease) -> Unit, () -> Unit) -> Unit, onJoined: () -> Unit = {}): Boolean {
        if (state.value.recovery != originalText || originalText.isBlank()) return false
        val accepted = accepts(control, Step.RECOVERY) ?: return false
        if (state.value.recovery != originalText || accepted.original.identity != null) return false
        val attempt = Attempt(accepted.host, accepted.original, recovery = true)
        active = attempt
        // A submission retires the old actual field/control; it keeps the typed value in RAM.
        change(state.value)
        start(originalText, { if (joined(attempt, it)) onJoined() }, { failed(attempt) })
        return true
    }

    /** Only the optional110 original-operation callback can call this successfully. */
    internal fun joined(attempt: Attempt, identity: SyncIdentityLease): Boolean {
        if (closed || active !== attempt) return false
        if (attempt.failed || state.value.step !in setOf(Step.CODE, Step.RECOVERY) || !attempt.host.current()) {
            active = null; return false
        }
        val now = source()
        if (!now.available || now.identity != identity || now.epoch != identity.epoch ||
            identity.epoch <= attempt.original.epoch || !attempt.host.current()) {
            active = null; return false
        }
        active = null; bound = now
        change(state.value.copy(step = Step.JOINED, joinedFrom = state.value.step, trayUp = true))
        return true
    }

    /** Only Bridge's original finished-operation failure observer can mark a pending attempt terminal. */
    internal fun failed(attempt: Attempt): Boolean {
        if (closed || active !== attempt || attempt.failed) return false
        if (state.value.step !in setOf(Step.CODE, Step.RECOVERY) || !current(attempt.host, attempt.original)) {
            active = null
            // A terminal callback can retire its own partial-save presentation. It
            // cannot adopt the changed identity or declare that attachment succeeded.
            if (source() != bound) close()
            return false
        }
        attempt.failed = true
        mutable.value = state.value.copy(failureRevision = state.value.failureRevision + 1)
        return true
    }

    fun backRequest(control: Control?, originalCode: String?, cancel: (String) -> Unit,
        restartCode: ((SyncIdentityLease) -> Unit, () -> Unit) -> (() -> Boolean), joined: () -> Unit = {}): Boolean {
        logicalRequest?.let { owner ->
            val step = state.value.step
            if (step !in setOf(Step.CODE, Step.RECOVERY)) return false
            val originalControl = control ?: return false
            val requestControl = originalControl.requestControl ?: return false
            if (requestControl.owner !== owner || state.value.codeValue != originalCode || !requestControl.current()) return false
            val snapshot = owner.snapshot ?: return false
            if (step == Step.RECOVERY) {
                if (accepts(control, Step.RECOVERY) == null) return false
                show(Step.CODE)
                return true
            }
            if (snapshot.stage in setOf(CodeJoinRequest.Stage.COMMITTED, CodeJoinRequest.Stage.COMPLETE,
                    CodeJoinRequest.Stage.RETIRED)) return false
            if (accepts(control, Step.CODE) == null) return false
            if (snapshot.stage !in setOf(CodeJoinRequest.Stage.FAILED, CodeJoinRequest.Stage.CANCELLED) &&
                owner.request?.cancel() != true) return false
            retireRequest(); active = null; show(Step.CHOOSE)
            return true
        }
        val attempt = active
        val step = state.value.step
        if (step == Step.CODE || step == Step.RECOVERY) {
            val originalControl = control ?: return false
            if (attempt == null || originalControl.host !== attempt.host || originalControl.original != attempt.original ||
                !attempt.host.current()) return false
            if (state.value.codeValue != originalCode || codeSource() != originalCode) return false
            if (step == Step.RECOVERY) {
                // Switching back to Code keeps its original request, even before code publication.
                if (!attempt.recovery && attempt.cancelPendingCode != null) {
                    if (accepts(control, Step.RECOVERY) == null || active !== attempt) return false
                    show(Step.CODE); return true
                }
                // A submitted real Recovery has no code-request capability to abandon.
                if (!attempt.failed) return false
            } else if (!attempt.failed) {
                val cancelPending = attempt.cancelPendingCode ?: return false
                if (accepts(control, Step.CODE) == null || active !== attempt || !attempt.host.current()) return false
                if (!cancelPending()) return false
                active = null; show(Step.CHOOSE)
                return true
            }
        }
        return back(control, originalCode, cancel, requestStart(restartCode), joined)
    }
    /** The actual Screen never erases a newly restarted Code request to a cancel-only closure. */
    fun backOwnedRequest(control: Control?, originalCode: String?, cancel: (String) -> Unit,
        restartCode: ((SyncIdentityLease) -> Unit, () -> Unit) -> CodeJoinRequest, joined: () -> Unit = {}): Boolean {
        if (logicalRequest == null && state.value.step == Step.RECOVERY) {
            val attempt = active ?: return false
            val originalControl = control ?: return false
            if (!attempt.recovery || !attempt.failed || originalControl.host !== attempt.host ||
                originalControl.original != attempt.original || !attempt.host.current() ||
                state.value.codeValue != originalCode || codeSource() != originalCode) return false
            val accepted = accepts(control, Step.RECOVERY) ?: return false
            startOwnedCode(accepted, restartCode, joined)
            return true
        }
        return backRequest(control, originalCode, cancel, { success, failure -> restartCode(success, failure)::cancel }, joined)
    }
    fun backGuardedRequest(control: Control?, originalCode: String?, cancel: (String) -> Unit,
        restartCode: ((SyncIdentityLease) -> Unit, () -> Unit) -> CodeJoinRequest, joined: () -> Unit = {}): Boolean {
        val owner = recoveryOwner ?: return backOwnedRequest(control, originalCode, cancel, restartCode, joined)
        val originalControl = control ?: return false
        val recoveryControl = originalControl.recoveryControl ?: return false
        if (state.value.step != Step.RECOVERY || recoveryControl.owner !== owner || !recoveryControl.current()) return false
        val phase = owner.snapshot?.phase ?: return false
        if (phase == RecoveryHandoff.Phase.COMMITTED || phase == RecoveryHandoff.Phase.COMPLETE) return false
        if (accepts(control, Step.RECOVERY) == null) return false
        if (phase in setOf(RecoveryHandoff.Phase.QUEUED, RecoveryHandoff.Phase.ADMITTED) &&
            !owner.handoff.cancel(checkNotNull(owner.snapshot))) return false
        retireRecovery(); active = null; show(Step.CHOOSE)
        return true
    }
    fun back(control: Control?, originalCode: String?, cancel: (String) -> Unit,
        restartCode: ((SyncIdentityLease) -> Unit, () -> Unit) -> Unit, joined: () -> Unit = {}): Boolean {
        val step = state.value.step
        if (step !in setOf(Step.CODE, Step.RECOVERY, Step.NO_MAC)) return false
        // A pending request has no original server key to cancel. Do not abandon a live poll.
        if (step == Step.CODE && (originalCode == null || state.value.codeValue != originalCode || codeSource() != originalCode) &&
            active?.failed != true) return false
        val accepted = accepts(control, step) ?: return false
        when (step) {
            Step.RECOVERY -> {
                if (active?.recovery == false && originalCode != null) show(Step.CODE)
                else { active = null; startCode(accepted, restartCode, joined) }
            }
            Step.CODE -> {
                active = null
                originalCode?.let(cancel)
                show(Step.CHOOSE)
            }
            Step.NO_MAC -> show(Step.CHOOSE)
            else -> return false
        }
        return true
    }

    private fun toLinks() { change(state.value.copy(step = Step.TO_LINKS, trayUp = false, groundUp = false, recovery = "", lastCode = null)) }
    private fun leaveLinks() { change(state.value.copy(step = Step.LEAVING_LINKS, trayUp = false)) }
    fun notNow(control: Control?): Boolean {
        if (accepts(control, Step.LINKS) == null) return false
        leaveLinks(); return true
    }
    fun makeDefault(control: Control?, role: DefaultBrowser, request: () -> Unit): Boolean {
        if (accepts(control, Step.LINKS) == null) return false
        // Phone advances after the accepted tap, never after an assumed permission grant.
        leaveLinks()
        if (role.available && !role.held) request()
        return true
    }
    fun copy(control: Control?, text: String, put: (String) -> Unit): Boolean {
        if (control?.consume(this) != true) return false
        put(text)
        return true
    }
    fun copyCode(control: Control?, text: String, put: (String) -> Unit): Boolean {
        val original = control?.requestControl ?: return false
        if (state.value.step != Step.CODE || original.snapshot.stage != CodeJoinRequest.Stage.PUBLISHED ||
            original.snapshot.code != text || !original.current()) return false
        return copy(control, text, put)
    }
    fun recoveryErrorCurrent(host: Host): Boolean = logicalRequest == null && active?.let {
        it.recovery && it.failed && it.host === host && current(host, it.original)
    } == true
    private fun retireRequest() {
        if (logicalRequest == null && !state.value.ownedRequest && state.value.request == null) return
        logicalRequest?.retire(); logicalRequest = null
        mutable.value = state.value.copy(ownedRequest = false, request = null, codeValue = null,
            checkValue = null, requestError = null, codeRevision = state.value.codeRevision + 1)
    }
    private fun retireRecovery() {
        if (recoveryOwner == null && state.value.handoff == null) return
        recoveryOwner?.retired = true; recoveryOwner = null
        mutable.value = state.value.copy(handoff = null, handoffError = null)
    }
    fun finishGuide(control: Control?, finish: (Completion) -> Boolean): Boolean {
        val accepted = accepts(control, Step.GUIDE) ?: return false
        return complete(accepted, finish)
    }
    private fun complete(control: Control, finish: (Completion) -> Boolean): Boolean {
        val completion = Completion(control.host, control.original, state.value.withoutMac)
        retireRequest(); retireRecovery(); active = null; found = null; closed = true
        change(state.value.copy(step = Step.FINISHED, recovery = "", trayUp = false, groundUp = false))
        return finish(completion)
    }
    override fun close() {
        if (closed) return
        retireRequest(); retireRecovery(); closed = true; active = null; found = null
        change(state.value.copy(step = Step.FINISHED, recovery = "", trayUp = false, groundUp = false))
    }
}

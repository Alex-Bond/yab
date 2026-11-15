package dev.yab.agent

import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** App-local identity only; it is never added to an approval's canonical wire body. */
data class ApprovalAuthenticationIdentity(val account: String, val device: String, val epoch: Long)

/** The original action and facts, captured before authentication starts. */
class ApprovalAuthenticationContext internal constructor(
    internal val request: ApprovalRequest,
    internal val identity: ApprovalAuthenticationIdentity?,
    internal val displayed: ApprovalDisplayLease?,
    internal val choice: String?,
    internal val picks: ApprovalPicks,
    internal val interaction: ApprovalInteractionTicket?,
    private val sourceStillCurrent: () -> Boolean,
) {
    internal val reason get() = "Approve ${request.title}"
    internal fun sourceCurrent(): Boolean = sourceStillCurrent()
    internal fun withDraft(current: () -> Boolean) = ApprovalAuthenticationContext(request, identity, displayed, choice,
        picks, interaction) { sourceCurrent() && current() }
    internal fun sameAction(other: ApprovalAuthenticationContext): Boolean = request === other.request &&
        identity == other.identity && choice == other.choice && picks == other.picks && displayed?.let { before ->
            other.displayed?.let { after -> before.account == after.account && before.epoch == after.epoch &&
                before.id == after.id && before.fingerprint == after.fingerprint && before.generation == after.generation }
        } == true
}

internal enum class ApprovalCredentialPhase { NONE, PIN, CONFIRM }
internal data class ApprovalCredentialState(val revision: Long = 0, val phase: ApprovalCredentialPhase = ApprovalCredentialPhase.NONE)

/**
 * A Keyguard result is RAM-only evidence, never UI/write authority. The original answer returns
 * without a proof. Only a separately rendered, current ticket may consume it after a new click.
 * All operations are on the owning UI thread; final journal admission remains ticket-locked.
 */
internal class ApprovalCredentialReturn(
    private val clock: () -> Long = System::currentTimeMillis,
    private val nonce: () -> String = { UUID.randomUUID().toString() },
) {
    private class Return(val nonce: String, val context: ApprovalAuthenticationContext) {
        var waiting = true
        var departed = false
        var returned = false
        var proof: DeviceAuthenticationProof? = null
        var review: ApprovalInteractionTicket? = null
    }
    private var pending: Return? = null
    private var resumed = false
    private var disposed = false
    private val mutable = MutableStateFlow(ApprovalCredentialState())
    val state = mutable.asStateFlow()

    fun begin(context: ApprovalAuthenticationContext): String? {
        reconcile()
        if (disposed || !resumed || pending?.waiting == true || context.identity == null ||
            context.displayed == null || context.interaction?.isCurrent() != true || !context.sourceCurrent()) return null
        clear()
        return nonce().also { pending = Return(it, context); publish(ApprovalCredentialPhase.PIN) }
    }
    fun owns(nonce: String): Boolean = pending?.nonce == nonce
    fun complete(nonce: String, succeeded: Boolean) {
        val original = pending?.takeIf { it.nonce == nonce && it.waiting } ?: return
        if (!succeeded || disposed || !original.context.sourceCurrent() || original.context.request.expiresAt <= clock()) {
            clear(); return
        }
        original.waiting = false
        original.proof = DeviceAuthenticationProof(clock())
        publish(ApprovalCredentialPhase.CONFIRM)
    }
    fun bindReview(revision: Long, ticket: ApprovalInteractionTicket?) {
        reconcile()
        val original = pending ?: return
        if (revision != mutable.value.revision || original.waiting || !resumed || ticket?.isCurrent() != true ||
            ticket === original.context.interaction) return
        original.review = ticket
    }
    fun consume(context: ApprovalAuthenticationContext): DeviceAuthenticationProof? {
        reconcile()
        val original = pending ?: return null
        val proof = original.proof
        if (original.waiting) return null
        val admitted = !disposed && resumed && proof != null && original.context.sameAction(context) &&
            context.sourceCurrent() && context.interaction?.isCurrent() == true &&
            context.interaction === original.review && context.interaction !== original.context.interaction
        clear() // Even a mismatched second click cannot retain/retry the old credential evidence.
        return proof.takeIf { admitted }
    }
    fun reconcile() {
        val original = pending ?: return
        val proof = original.proof
        if (!original.context.sourceCurrent() || original.context.request.expiresAt <= clock() ||
            proof != null && clock() - proof.authenticatedAt !in 0..60_000) clear()
    }
    fun expiryDelay(): Long? = pending?.takeIf { !it.waiting }?.let { original ->
        original.proof?.let { proof -> (minOf(original.context.request.expiresAt, proof.authenticatedAt + 60_001) - clock()).coerceAtLeast(1) }
    }
    fun resume() { resumed = true; pending?.takeIf { it.departed }?.returned = true; reconcile() }
    fun pause() { resumed = false }
    fun stop() {
        resumed = false
        val original = pending ?: return
        // Only the first departure of this explicitly launched PIN operation may retain a result.
        // It never retains the original UI ticket or resumes the cancelled answer coroutine.
        if (original.waiting && !original.departed && !original.returned) original.departed = true else clear()
    }
    fun cancel() = clear()
    fun dispose() { disposed = true; resumed = false; clear() }
    private fun clear() { if (pending != null) { pending = null; publish(ApprovalCredentialPhase.NONE) } }
    private fun publish(phase: ApprovalCredentialPhase) { mutable.value = ApprovalCredentialState(mutable.value.revision + 1, phase) }
}

package dev.yab.agent

import java.security.MessageDigest
import java.time.YearMonth
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable enum class ApprovalKind { LINES, PAYMENT, MAIL, MAIL_BATCH, FILES, MESSAGE, MAIL_SEARCH, ACCOUNTS }
@Serializable data class ApprovalFile(val id: String, val name: String, val mime: String, val size: Long, val pages: Int = 0,
    val previewPages: Int = pages, val width: Int? = null, val height: Int? = null)
@Serializable data class ApprovalMail(val from: String, val to: List<String>, val subject: String, val body: String,
    val cc: List<String> = emptyList(), val bcc: List<String> = emptyList(), val files: List<ApprovalFile> = emptyList(), val date: Double? = null)
@Serializable data class ApprovalCard(val id: String, val brand: String, val last4: String, val name: String)
@Serializable data class ApprovalPlace(val id: String, val line: String, val who: String)
@Serializable data class ApprovalPreview(val file: String, val page: Int, val jpegBase64: String)
@Serializable data class ApprovalPayment(val site: String, val item: String, val amount: String, val facts: List<String> = emptyList(),
    val delivery: String = "", val cards: List<ApprovalCard> = emptyList(), val places: List<ApprovalPlace> = emptyList(),
    val card: String? = null, val place: String? = null, val takesCard: Boolean = false, val takesPlace: Boolean = false)
@Serializable data class ApprovalRequest(
    val id: String,
    val account: String,
    val mac: String,
    val revision: Long,
    val expiresAt: Long,
    val asker: String,
    val title: String,
    val summary: String,
    val kind: ApprovalKind = ApprovalKind.LINES,
    val lines: List<String> = emptyList(),
    val choices: List<String> = emptyList(),
    val payment: ApprovalPayment? = null,
    val mails: List<ApprovalMail> = emptyList(),
    val files: List<ApprovalFile> = emptyList(),
    val previews: List<ApprovalPreview> = emptyList(),
    val person: String? = null,
    val text: String? = null,
    val verb: String? = null,
    val requestDigest: String? = null,
    val detailDigest: String? = null,
    val permit: String? = null,
    val place: String? = null,
    val issuedAt: Long? = null,
    val sourceEpoch: Long? = null,
    val sourceSession: String? = null,
    val sourceIssuedAt: Double? = null,
    val sourceVerb: String? = null,
) {
    fun fingerprint(): String = MessageDigest.getInstance("SHA-256").digest(Json.encodeToString(this).toByteArray())
        .joinToString("") { "%02x".format(it) }
}

/** A local authentication result is not remote attestation or a substitute for the sync envelope. */
class DeviceAuthenticationProof internal constructor(val authenticatedAt: Long)
interface ApprovalAuthentication {
    suspend fun authenticate(reason: String): DeviceAuthenticationProof?
    suspend fun authenticateApproval(context: ApprovalAuthenticationContext): DeviceAuthenticationProof? = authenticate(context.reason)
    fun cancelApprovalAuthentication() {}
}
data class ApprovalNewCard(val number: String, val csc: String, val name: String, val month: Int, val year: Int)
data class ApprovalNewPlace(val name: String, val street: String, val city: String, val postal: String)
data class ApprovalPicks(val card: String? = null, val place: String? = null, val newCard: ApprovalNewCard? = null, val newPlace: ApprovalNewPlace? = null, val added: List<String> = emptyList()) {
    fun validate(payment: ApprovalPayment?) {
        require(payment != null || this == ApprovalPicks()) { "This request does not take payment details" }
        if (payment == null) return
        require(card == null || (payment.takesCard && payment.cards.any { it.id == card })) { "This request cannot take the chosen card" }
        require(place == null || (payment.takesPlace && payment.places.any { it.id == place })) { "This request cannot take the chosen address" }
        require(added.isEmpty()) { "Only the encrypted sync bridge can add wallet record identities" }
        require(newCard == null || payment.takesCard) { "This payment does not take a new card" }
        require(newPlace == null || payment.takesPlace) { "This payment does not take a new address" }
        newCard?.let {
            val digits = it.number.filter(Char::isDigit)
            require(digits.length in 12..19 && luhn(digits) && it.csc.matches(Regex("\\d{3,4}")) && it.month in 1..12 && it.year in YearMonth.now().year..2200 && it.name.isNotBlank()) { "Check the card number, expiration, security code and name" }
            require(!YearMonth.of(it.year, it.month).isBefore(YearMonth.now())) { "This card has expired" }
        }
        newPlace?.let { require(it.street.isNotBlank() && it.city.isNotBlank()) { "Enter a street and city" } }
    }
    companion object {
        fun luhn(digits: String): Boolean = digits.isNotEmpty() && digits.reversed().mapIndexed { index, char ->
            val value = char.digitToIntOrNull() ?: return false
            if (index % 2 == 1) (value * 2).let { if (it > 9) it - 9 else it } else value
        }.sum() % 10 == 0
    }
}
data class ApprovalAnswer internal constructor(val request: ApprovalRequest, val approved: Boolean, val choice: String?, val proof: DeviceAuthenticationProof?, val picks: ApprovalPicks = ApprovalPicks(), val expectedEpoch: Long? = null, val interaction: ApprovalInteractionTicket? = null,
    val authenticationIdentity: ApprovalAuthenticationIdentity? = null)
enum class ApprovalResultPhase { paying, paid, declined, done, failed }
data class ApprovalResult(val id: String, val account: String, val mac: String, val requestDigest: String,
                          val phase: ApprovalResultPhase, val words: String?, val order: String?, val at: Double)
data class ApprovalReceipt(val request: ApprovalRequest, val sentAt: Long, val result: ApprovalResult? = null, val timedOut: Boolean = false, val resultAt: Long? = null,
    val picks: ApprovalPicks = ApprovalPicks())
/** Captured from the facts actually drawn, before an action is queued on a coroutine. */
class ApprovalDisplayLease internal constructor(internal val account: String?, internal val epoch: Long,
    internal val id: String, internal val fingerprint: String, internal val generation: Long)
data class ApprovalUiState(val requests: List<ApprovalRequest> = emptyList(), val busy: String? = null, val error: String? = null, val selected: String? = null,
                           val deferred: Set<String> = emptySet(), val receipts: List<ApprovalReceipt> = emptyList(),
                           val ownerAccount: String? = null, val ownerEpoch: Long = 0, val presentationGeneration: Long = 0,
                           val failureRevision: Long = 0)

/** Receives only validated/decrypted sync requests. An old prompt cannot approve changed content. */
class ApprovalController(private val remote: AgentSyncPort, private val clock: () -> Long = System::currentTimeMillis) {
    private data class Owner(val account: String?, val epoch: Long)
    private class Submission(val owner: Owner, val request: ApprovalRequest, var generation: Long,
        var dispatched: Boolean = false, var withdrawn: Boolean = false)
    private fun source() = remote.connection.value.let { Owner(it.account, it.epoch) }
    private var owner = source()
    private val mutable = MutableStateFlow(ApprovalUiState(ownerAccount = owner.account, ownerEpoch = owner.epoch))
    private var presentation = 0L
    private var failureRevision = 0L
    private var submission: Submission? = null
    internal val trayPresentation = ApprovalTrayPresentation()
    internal val windowPresentation = ApprovalDetailPresentation()
    internal val picturePresentation = ApprovalDetailPresentation()
    internal val windowPages = ApprovalWindowPages()
    internal val detailClock = ApprovalDetailClock(windowPresentation, picturePresentation, windowPages)
    internal val detailAnchors = ApprovalDetailAnchors()
    val state: StateFlow<ApprovalUiState> = mutable.asStateFlow()
    private fun refreshOwner() {
        val current = source()
        if (owner == current) return
        owner = current
        submission = null
        presentation++
        clearDetails()
        mutable.value = ApprovalUiState(ownerAccount = current.account, ownerEpoch = current.epoch, presentationGeneration = presentation)
    }
    private fun clearDetails() {
        windowPresentation.reconcile(null, false); picturePresentation.reconcile(null, false)
        windowPages.reconcile(null); detailAnchors.reconcile(null)
        detailClock.idle()
    }
    private fun owns(expected: Owner): Boolean = source() == expected && owner == expected
    private fun submissionCurrent(answer: Submission): Boolean = submission === answer && owns(answer.owner) &&
        presentation == answer.generation && remote.connection.value.macs.any { it.id == answer.request.mac }
    internal fun retryRequest(receipt: ApprovalReceipt): ApprovalRequest? = retryRequest(receipt, mutable.value)
    private fun retryRequest(receipt: ApprovalReceipt, current: ApprovalUiState): ApprovalRequest? {
        if (!owns(owner) || receipt !in current.receipts || receipt.result?.phase != ApprovalResultPhase.declined) return null
        val old = receipt.request
        if (old.kind != ApprovalKind.PAYMENT || old.sourceSession.isNullOrBlank() || old.place.isNullOrBlank() || old.sourceEpoch != owner.epoch) return null
        return current.requests.firstOrNull { next ->
            next.id !in current.deferred && next.account == old.account && next.mac == old.mac &&
                next.sourceEpoch == owner.epoch && next.sourceSession == old.sourceSession && next.place == old.place &&
                next.kind == ApprovalKind.PAYMENT && next.payment != null && next.expiresAt > clock() &&
                next.requestDigest != null && (next.id != old.id || next.requestDigest != old.requestDigest || next.detailDigest != old.detailDigest)
        }
    }
    private fun displayedRequest(current: ApprovalUiState = mutable.value): ApprovalRequest? {
        return if (current.selected == null && current.receipts.isNotEmpty()) current.receipts.lastOrNull()?.let { retryRequest(it, current) }
        else current.requests.firstOrNull { it.id == current.selected } ?: current.requests.firstOrNull { it.id !in current.deferred }
    }
    fun captureDisplayed(request: ApprovalRequest): ApprovalDisplayLease? {
        if (!owns(owner) || request.fingerprint() != displayedRequest()?.fingerprint()) return null
        return ApprovalDisplayLease(owner.account, owner.epoch, request.id, request.fingerprint(), presentation)
    }
    fun isDisplayedCurrent(lease: ApprovalDisplayLease): Boolean = owns(Owner(lease.account, lease.epoch)) &&
        lease.generation == presentation && displayedRequest()?.let { it.id == lease.id && it.fingerprint() == lease.fingerprint && it.expiresAt > clock() } == true
    /** Receipts may outlive their question expiry, but never their account, epoch or Mac. */
    internal fun ownsPresentation(request: ApprovalRequest, epoch: Long): Boolean = owns(Owner(request.account, epoch)) &&
        remote.connection.value.macs.any { it.id == request.mac }
    private fun releaseAt(receipt: ApprovalReceipt): Long? = when {
        receipt.request.kind != ApprovalKind.PAYMENT -> receipt.sentAt + 650
        receipt.result?.phase == ApprovalResultPhase.paid -> receipt.resultAt?.plus(1100)
        receipt.result?.phase == ApprovalResultPhase.done -> receipt.resultAt?.plus(500)
        receipt.result?.phase in setOf(ApprovalResultPhase.declined, ApprovalResultPhase.failed) -> null
        else -> receipt.sentAt + 45_000
    }
    suspend fun observe(): Unit = coroutineScope {
        launch { remote.approvalResults.collect { replaceResults(it) } }
        launch { remote.connection.collect { replaceValidated(mutable.value.requests); replaceResults(remote.approvalResults.value) } }
        mutable.collectLatest { current ->
            val lease = owner
            val deadlines = current.requests.map { it.expiresAt } + current.receipts.mapNotNull(::releaseAt)
            val deadline = deadlines.minOrNull() ?: return@collectLatest
            delay((deadline - clock()).coerceAtLeast(1))
            if (owns(lease)) expire()
        }
    }
    fun replaceValidated(requests: List<ApprovalRequest>) {
        refreshOwner()
        val displayed = displayedRequest()?.fingerprint()
        val connection = remote.connection.value
        val account = owner.account
        val current = ApprovalContent.order(requests.filter { it.account == account && it.expiresAt > clock()
            && (it.sourceEpoch == null || it.sourceEpoch == owner.epoch) && connection.macs.any { mac -> mac.id == it.mac } }
        )
        val active = mutable.value.busy ?: mutable.value.selected ?: mutable.value.requests.firstOrNull { it.id !in mutable.value.deferred }?.id
        var superseded = false
        if (active != null && current.firstOrNull { it.id == active }?.fingerprint() != mutable.value.requests.firstOrNull { it.id == active }?.fingerprint()) {
            val inFlight = submission
            // An accepted Sync write may withdraw its original question before the
            // transport returns. Only that exact removal can carry its completion.
            val ownWithdrawal = inFlight != null && submissionCurrent(inFlight) && inFlight.dispatched && !inFlight.withdrawn &&
                active == inFlight.request.id && current.none { it.id == active } &&
                mutable.value.requests.firstOrNull { it.id == active }?.fingerprint() == inFlight.request.fingerprint()
            presentation++; clearDetails()
            if (ownWithdrawal) { inFlight!!.generation = presentation; inFlight.withdrawn = true }
            else { submission = null; superseded = true }
        }
        val next = mutable.value.copy(requests = current, deferred = mutable.value.deferred.intersect(current.map { it.id }.toSet()),
            busy = if (superseded) null else mutable.value.busy, error = if (superseded) null else mutable.value.error,
            selected = mutable.value.selected?.takeIf { selected -> current.any { it.id == selected } },
            receipts = mutable.value.receipts.filter { it.request.account == account && remote.connection.value.macs.any { mac -> mac.id == it.request.mac } },
            presentationGeneration = presentation)
        mutable.value = if (displayedRequest(next)?.fingerprint() == displayed) next else next.copy(error = null)
    }
    fun replaceResults(results: List<ApprovalResult>) {
        refreshOwner()
        val account = owner.account
        mutable.value = mutable.value.copy(receipts = mutable.value.receipts.filter { it.request.account == account && remote.connection.value.macs.any { mac -> mac.id == it.request.mac } }.map { receipt ->
            val result = results.firstOrNull { it.id == receipt.request.id && it.account == receipt.request.account && it.mac == receipt.request.mac && it.requestDigest == receipt.request.requestDigest }
            receipt.copy(result = result ?: receipt.result,
                resultAt = if (result != null && result.phase != receipt.result?.phase) clock() else receipt.resultAt)
        })
    }
    fun expire() {
        replaceValidated(mutable.value.requests)
        val released = mutable.value.receipts.filter { releaseAt(it)?.let { deadline -> deadline <= clock() } == true }
        released.forEach { remote.forgetApprovalResult(it.request.id) }
        mutable.value = mutable.value.copy(receipts = mutable.value.receipts - released.toSet())
    }
    fun later(id: String, displayed: ApprovalDisplayLease? = null) {
        refreshOwner()
        if (displayed != null && (displayed.id != id || !isDisplayedCurrent(displayed))) return
        if (mutable.value.requests.none { it.id == id }) return
        presentation++; submission = null; clearDetails()
        mutable.value = mutable.value.copy(deferred = mutable.value.deferred + id, selected = null, busy = null, error = null, presentationGeneration = presentation)
    }
    internal fun captureFailure(displayed: ApprovalDisplayLease): ApprovalFailureLease? = mutable.value.takeIf {
        isDisplayedCurrent(displayed) && it.busy == null && it.error != null
    }?.let { ApprovalFailureLease(displayed, it.failureRevision) }
    internal fun failureCurrent(lease: ApprovalFailureLease): Boolean = mutable.value.let {
        isDisplayedCurrent(lease.displayed) && it.busy == null && it.error != null && it.failureRevision == lease.revision
    }
    internal fun closeFailure(lease: ApprovalFailureLease, interaction: ApprovalInteractionTicket): Boolean {
        if (!interaction.isCurrent() || !failureCurrent(lease)) return false
        later(lease.displayed.id, lease.displayed)
        return true
    }
    private fun publishFailure(words: String) {
        failureRevision++
        mutable.value = mutable.value.copy(error = words, failureRevision = failureRevision)
    }
    fun dismissResult(id: String) {
        refreshOwner()
        if (mutable.value.receipts.none { it.request.id == id }) return
        remote.forgetApprovalResult(id); mutable.value = mutable.value.copy(receipts = mutable.value.receipts.filterNot { it.request.id == id }, selected = null)
    }
    internal fun dismissPresentedResult(key: ApprovalPresentationKey) {
        refreshOwner()
        if (!owns(Owner(key.account, key.epoch)) || presentation != key.generation ||
            mutable.value.receipts.none { it.request.id == key.id && it.request.mac == key.mac && it.request.fingerprint() == key.facts }) return
        dismissResult(key.id)
    }
    /** Notification Review selects a current question. It never submits an answer. */
    fun select(id: String): Boolean {
        refreshOwner()
        if (mutable.value.requests.none { it.id == id }) return false
        presentation++; submission = null
        clearDetails()
        mutable.value = mutable.value.copy(selected = id, deferred = mutable.value.deferred - id, busy = null, error = null, presentationGeneration = presentation)
        return true
    }
    suspend fun answer(id: String, approved: Boolean, gate: ApprovalAuthentication?, choice: String? = null, picks: ApprovalPicks = ApprovalPicks(), displayed: ApprovalDisplayLease? = null, interaction: ApprovalInteractionTicket? = null) {
        if (interaction != null && !interaction.isCurrent()) return
        refreshOwner()
        // The callback may have waited on the dispatcher while equal-ID facts or owners changed.
        // Reject it before authentication and before touching the new presentation's busy/error state.
        if (displayed != null && (displayed.id != id || !isDisplayedCurrent(displayed))) return
        val lease = owner
        if (mutable.value.busy != null) return
        val request = mutable.value.requests.firstOrNull { it.id == id } ?: return
        if (request.expiresAt <= clock()) { publishFailure("This request expired. Check it again on your Mac."); return }
        val fingerprint = request.fingerprint()
        val shown = presentation
        val authenticationIdentity = remote.approvalAuthenticationIdentity()
        val registration = interaction?.register(currentCoroutineContext().job)
        if (interaction != null && registration == null) return
        val operation = Submission(lease, request, shown)
        submission = operation
        val retry = mutable.value.receipts.lastOrNull()?.takeIf { retryRequest(it) == request }
        mutable.value = mutable.value.copy(busy = id, error = null)
        try {
            require(choice == null || choice in request.choices) { "This choice is no longer available" }
            if (approved) picks.validate(request.payment)
            val proof = if (approved) {
                val authenticator = gate ?: throw AgentUnavailable("Unlock verification is unavailable. Approve this on your Mac.")
                val context = ApprovalAuthenticationContext(request, authenticationIdentity, displayed, choice, picks, interaction) {
                    owns(lease) && shown == presentation && displayed?.let(::isDisplayedCurrent) != false &&
                        mutable.value.requests.firstOrNull { it.id == id } === request && id !in mutable.value.deferred &&
                        request.expiresAt > clock() && remote.approvalAuthenticationIdentity() == authenticationIdentity &&
                        remote.connection.value.macs.any { it.id == request.mac }
                }
                authenticator.authenticateApproval(context) ?: return
            } else { gate?.cancelApprovalAuthentication(); null }
            if (interaction != null && !interaction.awaitResumed()) return
            if (!owns(lease)) return
            val current = mutable.value.requests.firstOrNull { it.id == id }
            require(shown == presentation && id !in mutable.value.deferred && current?.fingerprint() == fingerprint && request.expiresAt > clock()) { "This request changed, expired or was dismissed. Check it again." }
            require(remote.connection.value.account == request.account && remote.connection.value.macs.any { it.id == request.mac }) { "This request's Mac is no longer in this account" }
            require(authenticationIdentity == null || remote.approvalAuthenticationIdentity() == authenticationIdentity) { "Approval authentication ownership changed" }
            require(proof == null || clock() - proof.authenticatedAt in 0..60_000) { "Unlock verification expired. Try again." }
            if (interaction != null && !interaction.isCurrent()) return
            operation.dispatched = true
            remote.answerApproval(ApprovalAnswer(request, approved, choice, proof, if (approved) picks else ApprovalPicks(), expectedEpoch = lease.epoch, interaction = interaction,
                authenticationIdentity = authenticationIdentity.takeIf { approved }))
            if (interaction != null && !interaction.isCurrent()) return
            if (!submissionCurrent(operation)) return
            val after = mutable.value.requests.firstOrNull { it.id == id }
            if (after?.fingerprint() != fingerprint && !(after == null && operation.withdrawn)) return
            clearDetails()
            // A positive equal-ID retry has just replaced the bridge's retained
            // binding. Forgetting that ID now would erase its fresh result owner.
            if (retry != null && (retry.request.id != id || !approved)) remote.forgetApprovalResult(retry.request.id)
            mutable.value = mutable.value.copy(requests = mutable.value.requests.filterNot { it.id == id }, selected = null, deferred = mutable.value.deferred - id,
                receipts = mutable.value.receipts.filterNot { it.request.id == id || it == retry } +
                    if (approved) listOf(ApprovalReceipt(request, clock(), picks = picks)) else emptyList())
            replaceResults(remote.approvalResults.value)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            if ((interaction == null || interaction.isCurrent()) && submissionCurrent(operation) && !operation.withdrawn && displayedRequest()?.let {
                it.id == id && it.fingerprint() == fingerprint && it.expiresAt > clock()
            } == true) publishFailure(error.message ?: "The answer could not be sent")
        }
        finally {
            registration?.close()
            if (submissionCurrent(operation)) { submission = null; mutable.value = mutable.value.copy(busy = null) }
        }
    }
}

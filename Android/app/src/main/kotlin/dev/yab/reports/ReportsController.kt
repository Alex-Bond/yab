package dev.yab.reports

import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Consent applies to a captured set of reports. A successful response alone clears a draft/report. */
class ReportsController(private val store: ReportStore, private val transport: ReportTransport?,
    private val metadata: ReportMetadata, parent: CoroutineScope, private val now: () -> Long = System::currentTimeMillis) : Closeable {
    private val lifetime = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + lifetime)
    private val lock = Mutex()
    private val ready = CompletableDeferred<Unit>()
    private val mutable = MutableStateFlow(ReportsState())
    val state: StateFlow<ReportsState> = mutable
    private var saved = ReportSnapshot()
    private var backlog = false
    @Volatile private var active = false
    @Volatile private var mayAsk = false
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val available get() = transport != null && mutable.value.storageError == null

    init {
        scope.launch {
            ready.await()
            for (signal in wake) {
                lock.withLock {
                    if (available && active) {
                        val exits = ReportExitCounts.prune(saved.exitCounts, saved.since, now())
                        if (exits != saved.exitCounts && !save(saved.copy(exitCounts = exits))) return@withLock
                    }
                    val unasked = saved.pending.filterNot { it.key in saved.allowed }
                    if (available && active && mayAsk && !saved.automaticCrashes && unasked.any { !it.isHang } && mutable.value.question == null) {
                        mutable.value = mutable.value.copy(question = CrashQuestion(UUID.randomUUID().toString(), unasked.map { it.key }.toSet(),
                            ReportExitCounts.unasked(ReportExitCounts.prune(saved.exitCounts, saved.since, now()))))
                    }
                }
                sendDay()
                sendCrashes()
            }
        }
        scope.launch {
            try {
                saved = store.load()
                if (transport != null && saved.since == 0L) { backlog = true; saved = saved.copy(since = now()); store.save(saved) }
                val exits = ReportExitCounts.prune(saved.exitCounts, saved.since, now())
                if (exits != saved.exitCounts) {
                    val next = saved.copy(exitCounts = exits)
                    store.save(next); saved = next
                }
                publish()
            } catch (canceled: CancellationException) { throw canceled } catch (_: Exception) { failStorage() }
            finally { ready.complete(Unit) }
        }
    }

    private fun publish() { mutable.value = mutable.value.copy(loading = false, available = available,
        automaticCrashes = saved.automaticCrashes, dailyActivity = saved.dailyActivity, email = saved.email) }
    private fun failStorage() { mutable.value = mutable.value.copy(loading = false, available = false, question = null,
        storageError = "Saved report choices couldn't be read. Nothing will be sent.") }
    private suspend fun save(next: ReportSnapshot): Boolean = try { store.save(next); saved = next; publish(); true }
        catch (canceled: CancellationException) { throw canceled } catch (_: Exception) { failStorage(); false }

    fun foregrounded(allowedToAsk: Boolean) { active = true; mayAsk = allowedToAsk; kick() }
    fun setPresentationAllowed(allowed: Boolean) {
        mayAsk = allowed
        if (!allowed) mutable.value = mutable.value.copy(question = null)
        kick()
    }
    fun backgrounded() { active = false; mayAsk = false; mutable.value = mutable.value.copy(question = null) }
    fun tick() = kick()
    fun automaticCrashes(enabled: Boolean) { scope.launch { ready.await(); lock.withLock { save(saved.copy(automaticCrashes = enabled)) }; kick() } }
    fun dailyActivity(enabled: Boolean) { scope.launch { ready.await(); lock.withLock { save(saved.copy(dailyActivity = enabled)) }; kick() } }
    fun person(id: String?) { scope.launch { ready.await(); lock.withLock { save(saved.copy(person = id?.takeIf(ReportWire.uuid::matches))) } } }
    fun draft(value: String) { mutable.value = mutable.value.copy(draft = value,
        feedback = if (mutable.value.feedback == FeedbackStatus.SENDING) FeedbackStatus.SENDING else FeedbackStatus.IDLE, feedbackError = null) }
    fun email(value: String) { scope.launch { ready.await(); lock.withLock { save(saved.copy(email = value.take(200))) } } }

    /** Returns only after the imported keys are durably seen, including first-launch backlog. */
    suspend fun received(reports: List<SavedCrash>, observedExits: List<ReportExitObservation> = emptyList()): Boolean {
        ready.await()
        return lock.withLock {
            if (!available) return@withLock false
            val known = (saved.seen + saved.pending.map { it.key }).toMutableSet()
            val fresh = reports.filter { known.add(it.key) }
            val pending = if (backlog) saved.pending else {
                val all = saved.pending + fresh
                val retained = (all.filterNot { it.isHang }.takeLast(5) + all.filter { it.isHang }.takeLast(3)).map { it.key }.toSet()
                all.filter { it.key in retained }
            }
            val seenOrder = (saved.seen + fresh.map { it.key }).asReversed().distinct().asReversed()
            val pendingKeys = pending.map { it.key }.distinct().takeLast(200)
            val protectedKeys = pendingKeys.toSet()
            val keptSeen = protectedKeys + seenOrder.filterNot { it in protectedKeys }.takeLast(200 - protectedKeys.size)
            val seen = seenOrder.filter { it in keptSeen } + pendingKeys.filterNot { it in seenOrder }
            val result = save(saved.copy(pending = pending, allowed = saved.allowed.intersect(pending.map { it.key }.toSet()),
                seen = seen,
                exitCounts = ReportExitCounts.add(saved.exitCounts, observedExits, saved.since, now())))
            if (result) kick()
            result
        }
    }

    fun answer(token: String, allow: Boolean) { scope.launch {
        ready.await()
        lock.withLock {
            val question = mutable.value.question?.takeIf { it.token == token && active && mayAsk } ?: return@withLock
            mutable.value = mutable.value.copy(question = null)
            if (allow) save(saved.copy(allowed = saved.allowed + question.keys.intersect(saved.pending.map { it.key }.toSet()),
                exitCounts = ReportExitCounts.allow(saved.exitCounts, question.exitKeys)))
            else save(saved.copy(pending = saved.pending.filterNot { it.key in question.keys }, allowed = saved.allowed - question.keys,
                exitCounts = ReportExitCounts.decline(saved.exitCounts, question.exitKeys)))
        }
        kick()
    } }

    // Retain one refresh while a transport/store suspension is in flight. Dropping
    // it can leave a newly allowed consent question waiting forever for another tick.
    private fun kick() { if (lifetime.isActive) wake.trySend(Unit) }

    private suspend fun post(request: ReportRequest): Boolean = try { transport?.post(request) == true }
        catch (canceled: CancellationException) { throw canceled } catch (_: Exception) { false }

    private suspend fun sendDay() {
        if (!lifetime.isActive) return
        val due = lock.withLock {
            val day = ReportWire.day(now())
            if (!lifetime.isActive || !available || !active || !saved.dailyActivity || saved.lastDay == day) return@withLock null
            val id = saved.installation?.takeIf(ReportWire.uuid::matches) ?: UUID.randomUUID().toString()
            if (saved.installation != id && !save(saved.copy(installation = id))) return@withLock null
            day to ReportWire.activity(id, saved.person)
        } ?: return
        if (!lifetime.isActive || !post(due.second)) return
        if (!lifetime.isActive) return
        lock.withLock {
            if (!lifetime.isActive) return
            save(saved.copy(lastDay = due.first))
        }
    }

    private suspend fun sendCrashes() {
        while (lifetime.isActive) {
            val captured = lock.withLock {
                if (!available || !active) null else saved.pending.firstOrNull { saved.automaticCrashes || it.key in saved.allowed }?.let {
                    it to ReportExitCounts.capture(ReportExitCounts.prune(saved.exitCounts, saved.since, now()), saved.automaticCrashes)
                }
            } ?: return
            if (!post(ReportWire.crash(captured.first, captured.second))) return
            if (!lifetime.isActive) return
            lock.withLock {
                if (!lifetime.isActive) return
                save(saved.copy(pending = saved.pending.filterNot { it.key == captured.first.key }, allowed = saved.allowed - captured.first.key,
                    exitCounts = ReportExitCounts.acknowledge(saved.exitCounts, captured.second.map { it.id }.toSet())))
            }
        }
    }

    fun sendFeedback() { scope.launch {
        ready.await()
        val captured = mutable.value
        if (captured.feedback == FeedbackStatus.SENDING || captured.draft.isBlank()) return@launch
        if (!available) { mutable.value = captured.copy(feedback = FeedbackStatus.FAILED, feedbackError = "This build has nowhere to send it."); return@launch }
        mutable.value = captured.copy(feedback = FeedbackStatus.SENDING, feedbackError = null)
        val accepted = post(ReportWire.feedback(captured.draft, captured.email, metadata))
        mutable.value = mutable.value.copy(draft = if (accepted && mutable.value.draft == captured.draft) "" else mutable.value.draft,
            feedback = if (accepted) FeedbackStatus.SENT else FeedbackStatus.FAILED,
            feedbackError = if (accepted) null else "Couldn't send feedback. Your draft is still here.")
    } }

    override fun close() { wake.close(); lifetime.cancel(); mutable.value = mutable.value.copy(question = null) }
}

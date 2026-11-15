package dev.yab.sync

import dev.yab.agent.ApprovalAuthentication
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class SyncIdentityLease(val account: String, val device: String, val epoch: Long)

/** One biometric presentation authorizes only this visible account and this reveal request. */
class RecoveryKeyReveal(
    private val source: () -> SyncIdentityLease?,
    private val export: suspend (SyncIdentityLease) -> String,
    private val clock: () -> Long = System::currentTimeMillis,
) : Closeable {
    data class Revealed(val source: SyncIdentityLease, val key: String)
    data class State(val busy: Boolean = false, val revealed: Revealed? = null, val error: String? = null)
    private class Request(val source: SyncIdentityLease)
    private val closed = AtomicBoolean(false)
    private val active = AtomicReference<Request?>(null)
    private val mutable = MutableStateFlow(State())
    val state = mutable.asStateFlow()
    private fun current(request: Request): Boolean = !closed.get() && active.get() === request && source() == request.source
    fun clear() { active.set(null); mutable.value = State() }
    override fun close() { closed.set(true); clear() }

    suspend fun reveal(authentication: ApprovalAuthentication) {
        val expected = source() ?: return
        if (closed.get()) return
        val request = Request(expected); val began = clock()
        active.set(request); mutable.value = State(busy = true)
        try {
            val proof = authentication.authenticate("Show your Recovery Key") ?: return
            if (!current(request)) return
            require(proof.authenticatedAt >= began && clock() - proof.authenticatedAt in 0..60_000) { "Unlock verification expired. Try again." }
            val key = export(expected)
            if (current(request)) mutable.value = State(revealed = Revealed(expected, key))
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (current(request)) mutable.value = State(error = error.message ?: "The Recovery Key could not be shown") }
        finally { if (active.get() === request) mutable.update { it.copy(busy = false) } }
    }
}

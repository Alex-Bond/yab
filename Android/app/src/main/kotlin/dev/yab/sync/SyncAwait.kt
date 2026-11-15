package dev.yab.sync

import dev.yab.agent.RemoteConnection
import dev.yab.agent.RemoteMac
import dev.yab.agent.MacRouting
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/** Closing a client may drop a late callback; a UI/background operation still has a deadline. */
internal suspend fun <T> awaitSyncCallback(timeoutMillis: Long = 15_000, register: ((Result<T>) -> Unit) -> Unit): Result<T> = withTimeout(timeoutMillis) {
    suspendCancellableCoroutine { continuation ->
        val ended = AtomicBoolean(false)
        continuation.invokeOnCancellation { ended.set(true) }
        if (continuation.isActive) register { result -> if (ended.compareAndSet(false, true)) continuation.resume(result) }
    }
}

/** Only new commands use this route; accepted conversation owners never change. */
internal fun RemoteConnection.commandMac(eligible: List<RemoteMac>): RemoteMac? =
    MacRouting.pick(eligible, selectedMac)

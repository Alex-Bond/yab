package dev.yab.agent

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** Immutable rendered action. An old callback can never capture a replacement ticket. */
internal class ApprovalInteraction(private val scope: CoroutineScope, private val ticket: ApprovalInteractionTicket?) {
    fun current(): Boolean = ticket?.isCurrent() == true
    internal fun credentialReviewTicket(): ApprovalInteractionTicket? = ticket?.takeIf { it.isCurrent() }
    fun launch(answer: suspend (ApprovalInteractionTicket) -> Unit): Job? {
        val captured = ticket ?: return null
        val job = scope.launch(start = CoroutineStart.LAZY) { if (captured.isCurrent()) answer(captured) }
        val registration = captured.register(job)
        if (registration == null) { job.cancel(); return null }
        job.invokeOnCompletion { registration.close() }
        job.start()
        return job
    }
}

/** Called and detached on the owning UI thread, including by the owned device fixture. */
internal fun ApprovalInteractionLifetime.observe(lifecycle: Lifecycle): AutoCloseable {
    val observer = LifecycleEventObserver { _, event ->
        when (event) {
            Lifecycle.Event.ON_RESUME -> resume()
            Lifecycle.Event.ON_PAUSE -> pause()
            Lifecycle.Event.ON_STOP -> stop()
            Lifecycle.Event.ON_DESTROY -> dispose()
            else -> Unit
        }
    }
    lifecycle.addObserver(observer)
    return AutoCloseable { lifecycle.removeObserver(observer); dispose() }
}

/** Shared biometric/Private/SyncSettings owners are intentionally outside this lifetime. */
@Composable
internal fun rememberApprovalInteraction(credentialRevision: Long = 0): ApprovalInteraction {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val lifetime = remember(lifecycle) { ApprovalInteractionLifetime() }
    val scope = rememberCoroutineScope()
    DisposableEffect(lifecycle, lifetime) {
        val binding = lifetime.observe(lifecycle)
        onDispose { binding.close() }
    }
    val rendered by lifetime.state.collectAsState()
    return remember(lifetime, scope, rendered, credentialRevision) { ApprovalInteraction(scope, lifetime.capture(rendered)) }
}

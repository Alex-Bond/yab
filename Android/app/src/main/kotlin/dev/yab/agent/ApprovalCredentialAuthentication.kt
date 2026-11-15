package dev.yab.agent

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Build
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/** API29 substitute only. Shared biometric/Private/SyncSettings authentication is unchanged. */
internal class ApprovalCredentialAuthentication(
    private val activity: FragmentActivity?,
    private val delegate: ApprovalAuthentication,
    private val draft: ApprovalTrayDraft,
) : ApprovalAuthentication {
    private val returned = ApprovalCredentialReturn()
    val state get() = returned.state
    private var launcher: Pair<String, ActivityResultLauncher<Intent>>? = null

    override suspend fun authenticate(reason: String) = delegate.authenticate(reason)
    override suspend fun authenticateApproval(context: ApprovalAuthenticationContext): DeviceAuthenticationProof? {
        val revision = draft.revision
        val original = context.withDraft { draft.revision == revision }
        returned.consume(original)?.let { return it }
        if (returned.state.value.phase == ApprovalCredentialPhase.PIN) return null
        if (context.identity == null || context.displayed == null || context.interaction?.isCurrent() != true || !original.sourceCurrent()) return null
        val activity = activity ?: return null // API29 never silently falls back to the combined legacy prompt.
        if (BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) != BiometricManager.BIOMETRIC_SUCCESS) {
            launchCredential(original)
            return null
        }
        // API29 must not use the combined framework credential flag: Android10 moves that prompt
        // into a separate task and AndroidX1.1 cannot distinguish its successful auth type.
        return suspendCancellableCoroutine { continuation ->
            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (continuation.isActive) continuation.resume(DeviceAuthenticationProof(System.currentTimeMillis()))
                }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    if (!continuation.isActive) return
                    try {
                        if (errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON && original.sourceCurrent() && context.interaction?.isCurrent() == true)
                            launchCredential(original)
                        continuation.resume(null)
                    } catch (error: Exception) { continuation.resumeWithException(error) }
                }
            })
            continuation.invokeOnCancellation { prompt.cancelAuthentication() }
            prompt.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle("Approve in Yab").setSubtitle(context.reason.take(140))
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
                .setNegativeButtonText("Use PIN, pattern or password").build())
        }
    }
    private fun launchCredential(original: ApprovalAuthenticationContext) {
        val activity = activity ?: return
        val nonce = returned.begin(original) ?: return
        val keyguard = activity.getSystemService(KeyguardManager::class.java)
        val intent = keyguard?.createConfirmDeviceCredentialIntent("Approve in Yab", "Unlock, then return to Yab and tap the same approval action again.")
        if (intent == null) { returned.cancel(); return }
        launcher?.second?.unregister()
        // A fresh non-saveable registry key and nonce belong to this launch only. Recreation or
        // replacement never credits a late ActivityResult to a newly pending request.
        try {
            val registered = activity.activityResultRegistry.register("yab.approval.pin.$nonce", ActivityResultContracts.StartActivityForResult()) { result ->
                if (launcher?.first == nonce) { launcher?.second?.unregister(); launcher = null }
                returned.complete(nonce, result.resultCode == Activity.RESULT_OK)
            }
            launcher = nonce to registered
            registered.launch(intent)
        } catch (error: Exception) {
            launcher?.second?.unregister(); launcher = null; returned.cancel(); throw error
        }
    }
    fun bindReview(revision: Long, interaction: ApprovalInteraction) = returned.bindReview(revision, interaction.credentialReviewTicket())
    fun expiryDelay(): Long? = returned.expiryDelay()
    fun reconcile() { returned.reconcile(); discardRevokedLauncher() }
    override fun cancelApprovalAuthentication() { returned.cancel(); discardRevokedLauncher() }
    private fun discardRevokedLauncher() {
        launcher?.takeIf { !returned.owns(it.first) }?.let { it.second.unregister(); launcher = null }
    }
    fun observe(lifecycle: Lifecycle): AutoCloseable {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> returned.resume()
                Lifecycle.Event.ON_PAUSE -> returned.pause()
                Lifecycle.Event.ON_STOP -> returned.stop()
                Lifecycle.Event.ON_DESTROY -> returned.dispose()
                else -> Unit
            }
            discardRevokedLauncher()
        }
        lifecycle.addObserver(observer)
        return AutoCloseable {
            lifecycle.removeObserver(observer); returned.dispose()
            launcher?.second?.unregister(); launcher = null
        }
    }
}

private fun Context.approvalActivity(): FragmentActivity? {
    var current = this
    repeat(8) {
        if (current is FragmentActivity) return current as FragmentActivity
        val next = (current as? ContextWrapper)?.baseContext ?: return null
        if (next === current) return null
        current = next
    }
    return null
}

@Composable
internal fun rememberApprovalCredentialAuthentication(authentication: ApprovalAuthentication?, controller: ApprovalController,
    shown: ApprovalPresented, draft: ApprovalTrayDraft): ApprovalCredentialAuthentication? {
    if (Build.VERSION.SDK_INT != 29 || authentication !is BiometricApprovalGate || shown.receipt != null) return null
    val activity = LocalContext.current.approvalActivity()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // Main may create an equivalent BiometricApprovalGate on recomposition. It cannot replace the
    // original callback's authority; the Activity/controller/presentation/draft remain the keys.
    val gate = remember(activity, controller, shown.key, draft) { ApprovalCredentialAuthentication(activity, authentication, draft) }
    DisposableEffect(gate, lifecycle) {
        val binding = gate.observe(lifecycle)
        onDispose { binding.close() }
    }
    return gate
}

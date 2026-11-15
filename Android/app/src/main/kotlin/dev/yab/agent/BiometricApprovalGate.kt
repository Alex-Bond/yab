package dev.yab.agent

import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/** Android owns the biometric/credential prompt. No successful result is synthesized. */
class BiometricApprovalGate(private val activity: FragmentActivity) : ApprovalAuthentication {
    override suspend fun authenticate(reason: String): DeviceAuthenticationProof? = suspendCancellableCoroutine { continuation ->
        val authenticators = if (Build.VERSION.SDK_INT >= 30) BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL
            else BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL
        if (BiometricManager.from(activity).canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
            continuation.resume(null)
            return@suspendCancellableCoroutine
        }
        val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (continuation.isActive) continuation.resume(DeviceAuthenticationProof(System.currentTimeMillis()))
            }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (continuation.isActive) continuation.resume(null)
            }
        })
        val builder = BiometricPrompt.PromptInfo.Builder().setTitle("Approve in Yab").setSubtitle(reason.take(140)).setAllowedAuthenticators(authenticators)
        continuation.invokeOnCancellation { prompt.cancelAuthentication() }
        prompt.authenticate(builder.build())
    }
}

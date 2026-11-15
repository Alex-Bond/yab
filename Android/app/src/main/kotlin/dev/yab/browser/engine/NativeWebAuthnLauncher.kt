package dev.yab.browser.engine

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.withResumed
import java.io.Closeable
import kotlinx.coroutines.launch
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime

/** Launches Gecko's native FIDO activity. Credentials remain inside Gecko and the OS provider. */
class NativeWebAuthnLauncher(private val activity: FragmentActivity, private val engine: GeckoEngine,
    private val pageAvailable: () -> Boolean) : GeckoRuntime.ActivityDelegate, Closeable {
    private data class Request(val owner: GeckoEngine.ExternalActivityOwner, val result: GeckoResult<Intent>)
    private var pending: Request? = null
    private var closed = false
    private val handler = Handler(Looper.getMainLooper())
    private val expiry = Runnable { reject() }
    private val launcher = activity.registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { returned ->
        val request = pending ?: return@registerForActivityResult
        activity.lifecycleScope.launch {
            activity.lifecycle.withResumed { }
            if (pending !== request) return@launch
            pending = null; handler.removeCallbacks(expiry)
            if (!closed && returned.resultCode == Activity.RESULT_OK && returned.data != null &&
                pageAvailable() && engine.ownsExternalActivity(request.owner)) request.result.complete(returned.data!!)
            else request.result.completeExceptionally(IllegalStateException("Web authentication was canceled"))
        }
    }

    fun attach() { check(!closed); engine.runtime.activityDelegate = this }

    private fun captureReadyOwner(): GeckoEngine.ExternalActivityOwner? =
        if (!closed && activity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED) && pageAvailable())
            engine.captureExternalActivityOwner() else null

    /** Read-only readiness for an owned native result probe; admission rechecks it. */
    internal val ready: Boolean get() = pending == null && captureReadyOwner() != null

    override fun onStartActivityForResult(intent: PendingIntent): GeckoResult<Intent> {
        val result = GeckoResult<Intent>()
        val owner = captureReadyOwner()
        if (owner == null || pending != null) {
            result.completeExceptionally(IllegalStateException("No active page for web authentication"))
            return result
        }
        val request = Request(owner, result)
        pending = request
        handler.postDelayed(expiry, 120_000)
        try { launcher.launch(IntentSenderRequest.Builder(intent.intentSender).build()) }
        catch (_: RuntimeException) { reject() }
        return result
    }

    private fun reject() {
        val request = pending ?: return
        pending = null; handler.removeCallbacks(expiry)
        request.result.completeExceptionally(IllegalStateException("Web authentication was canceled"))
    }

    override fun close() {
        if (closed) return
        closed = true; reject(); handler.removeCallbacksAndMessages(null)
        if (engine.runtime.activityDelegate === this) engine.runtime.activityDelegate = null
        launcher.unregister()
    }
}

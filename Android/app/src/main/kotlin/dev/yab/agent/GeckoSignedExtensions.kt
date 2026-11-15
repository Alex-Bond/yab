package dev.yab.agent

import android.content.Context
import android.net.Uri
import java.io.File
import java.net.URI
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.WebExtension
import org.mozilla.geckoview.WebExtensionController

data class InstalledAndroidExtension(val id: String, val name: String, val version: String, val enabled: Boolean, val optionsUrl: String?)
data class ExtensionConsent(val token: String, val name: String, val permissions: List<String>, val origins: List<String>, val dataCollection: List<String>)
data class AndroidExtensionState(val installed: List<InstalledAndroidExtension> = emptyList(), val consent: ExtensionConsent? = null, val busy: Boolean = false, val error: String? = null)

/** Only external signed XPI goes through install. External bytes are never installed as built-ins. */
class GeckoSignedExtensionManager(
    private val runtime: GeckoRuntime,
    context: Context,
    private val privateContext: () -> Boolean = { false },
    private val onInstalled: (WebExtension) -> Unit = {},
) {
    private val app = context.applicationContext
    private val controller = runtime.webExtensionController
    private val mutable = MutableStateFlow(AndroidExtensionState())
    val state: StateFlow<AndroidExtensionState> = mutable
    private var pendingAnswer: ((Boolean) -> Unit)? = null
    private var extensions = emptyList<WebExtension>()
    private var closed = false

    private val promptDelegate = object : WebExtensionController.PromptDelegate {
            override fun onInstallPromptRequest(extension: WebExtension, permissions: Array<out String>, origins: Array<out String>, dataCollectionPermissions: Array<out String>): GeckoResult<WebExtension.PermissionPromptResponse> {
                val result = GeckoResult<WebExtension.PermissionPromptResponse>()
                ask(extension, permissions, origins, dataCollectionPermissions) { allowed -> result.complete(WebExtension.PermissionPromptResponse(allowed, false, false)) }
                return result
            }
            override fun onOptionalPrompt(extension: WebExtension, permissions: Array<out String>, origins: Array<out String>, dataCollectionPermissions: Array<out String>): GeckoResult<AllowOrDeny> {
                val result = GeckoResult<AllowOrDeny>()
                ask(extension, permissions, origins, dataCollectionPermissions) { result.complete(if (it) AllowOrDeny.ALLOW else AllowOrDeny.DENY) }
                return result
            }
            override fun onUpdatePrompt(extension: WebExtension, newPermissions: Array<out String>, newOrigins: Array<out String>, newDataCollectionPermissions: Array<out String>): GeckoResult<AllowOrDeny> {
                val result = GeckoResult<AllowOrDeny>()
                ask(extension, newPermissions, newOrigins, newDataCollectionPermissions) { result.complete(if (it) AllowOrDeny.ALLOW else AllowOrDeny.DENY) }
                return result
            }
        }

    init {
        controller.setPromptDelegate(promptDelegate)
        refresh()
    }

    fun resolveConsent(token: String, allow: Boolean) {
        if (mutable.value.consent?.token != token) return
        val answer = pendingAnswer
        pendingAnswer = null
        mutable.value = mutable.value.copy(consent = null)
        answer?.invoke(allow && !privateContext())
    }
    fun clearError() { mutable.value = mutable.value.copy(error = null) }
    fun close() {
        if (closed) return
        closed = true
        cancelPendingConsent()
        if (controller.promptDelegate === promptDelegate) controller.setPromptDelegate(null)
    }
    fun cancelPendingConsent() {
        val answer = pendingAnswer
        pendingAnswer = null
        mutable.value = mutable.value.copy(consent = null)
        answer?.invoke(false)
    }
    private fun ask(extension: WebExtension, permissions: Array<out String>, origins: Array<out String>, collection: Array<out String>, answer: (Boolean) -> Unit) {
        if (closed || privateContext() || pendingAnswer != null) { answer(false); return }
        pendingAnswer = answer
        mutable.value = mutable.value.copy(consent = ExtensionConsent(UUID.randomUUID().toString(), extension.metaData?.name ?: extension.id, permissions.toList(), origins.toList(), collection.toList()))
    }

    /** Install a local package selected by the person, with a bounded preflight and native signature validation. */
    suspend fun install(uri: Uri) {
        if (closed || mutable.value.busy || privateContext()) return
        mutable.value = mutable.value.copy(busy = true, error = null)
        try {
            val file = withContext(Dispatchers.IO) {
                val bytes = app.contentResolver.openInputStream(uri)?.use { with(ExtensionPackages) { it.readBounded(64 * 1024 * 1024) } }
                    ?: throw AgentUnavailable("The extension could not be read")
                val inspection = ExtensionPackages.inspect(bytes)
                require(inspection.format == ExtensionPackages.Format.MOZILLA_XPI_CANDIDATE) { inspection.reason }
                File.createTempFile("signed-extension-", ".xpi", app.cacheDir).apply { writeBytes(bytes) }
            }
            withContext(Dispatchers.Main.immediate) { installNative(file.toURI().toString()) { file.delete() } }
        } catch (error: Exception) { mutable.value = mutable.value.copy(busy = false, error = error.message ?: "The extension could not be installed") }
    }

    fun installHttps(address: String) {
        if (closed || mutable.value.busy || privateContext()) return
        val uri = try { URI(address) } catch (_: Exception) { null }
        if (uri?.scheme != "https" || uri.host.isNullOrBlank() || !uri.path.endsWith(".xpi", true)) {
            mutable.value = mutable.value.copy(error = "Use a direct HTTPS link to a Mozilla-signed .xpi package. Chrome Web Store CRX is not supported by this engine.")
            return
        }
        mutable.value = mutable.value.copy(busy = true, error = null)
        installNative(address)
    }
    private fun installNative(address: String, cleanup: () -> Unit = {}) {
        if (closed) { cleanup(); return }
        controller.install(address).accept(installed@{ extension ->
            cleanup()
            if (closed) return@installed
            if (extension == null) { installFailed(null); return@installed }
            // The installed object can still be user-disabled. Finish the
            // private restriction first, then activate the explicitly accepted
            // install through Gecko's USER route, keeping other disable flags.
            controller.setAllowedInPrivateBrowsing(extension, false).accept(restricted@{ restricted ->
                if (closed) return@restricted
                if (restricted == null || restricted.metaData?.allowedInPrivateBrowsing != false) {
                    installFailed(null); return@restricted
                }
                controller.enable(restricted, WebExtensionController.EnableSource.USER).accept(enabled@{ enabled ->
                    if (closed) return@enabled
                    if (enabled == null || enabled.metaData?.enabled != true || enabled.metaData?.allowedInPrivateBrowsing != false) {
                        installFailed(null); return@enabled
                    }
                    mutable.value = mutable.value.copy(busy = false)
                    onInstalled(enabled)
                    refresh()
                }, { error -> installFailed(error) })
            }, { error -> installFailed(error) })
        }, { error -> cleanup(); installFailed(error) })
    }
    private fun installFailed(error: Throwable?) {
        if (closed) return
        mutable.value = mutable.value.copy(busy = false, error = error?.message ?: "Signature or extension validation failed")
        refresh()
    }
    fun refresh() {
        if (closed) return
        controller.list().accept({ list ->
            if (closed) return@accept
            extensions = list.orEmpty().filterNot { it.isBuiltIn }
            mutable.value = mutable.value.copy(installed = extensions.map { InstalledAndroidExtension(it.id, it.metaData?.name ?: it.id, it.metaData?.version.orEmpty(), it.metaData?.enabled == true, it.metaData?.optionsPageUrl) })
            extensions.forEach(onInstalled)
        }, { error -> mutable.value = mutable.value.copy(error = error?.message ?: "Extensions could not be read") })
    }
    fun setEnabled(id: String, enabled: Boolean) {
        if (closed) return
        val extension = extensions.firstOrNull { it.id == id } ?: return
        val result = if (enabled) controller.enable(extension, WebExtensionController.EnableSource.USER) else controller.disable(extension, WebExtensionController.EnableSource.USER)
        result.accept({ refresh() }, { error -> mutable.value = mutable.value.copy(error = error?.message ?: "The extension could not be changed") })
    }
    fun remove(id: String) {
        if (closed) return
        val extension = extensions.firstOrNull { it.id == id } ?: return
        controller.uninstall(extension).accept({ refresh() }, { error -> mutable.value = mutable.value.copy(error = error?.message ?: "The extension could not be removed") })
    }
}

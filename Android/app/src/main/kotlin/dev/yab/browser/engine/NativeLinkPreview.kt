package dev.yab.browser.engine

import java.io.Closeable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.WebExtension
import org.mozilla.geckoview.WebRequestError
import org.mozilla.geckoview.WebResponse

data class LinkPreviewPage(val title: String = "", val loading: Boolean = true, val failed: Boolean = false)

/** A view-only document in the source's actual cookie container, never a browser tab. */
class NativeLinkPreview internal constructor(
    val id: String,
    val sourceTab: String,
    val url: String,
    val isPrivate: Boolean,
    settings: GeckoSessionSettings,
    sourceCurrent: () -> Boolean,
    private val invalidated: () -> Unit,
) : Closeable {
    val session = GeckoSession(GeckoSessionSettings.Builder(settings).build())
    private val lease = LinkPreviewLease(sourceCurrent)
    private val mutablePage = MutableStateFlow(LinkPreviewPage())
    val page = mutablePage.asStateFlow()
    private var closed = false
    var deniedNativeConnections: Int = 0
        private set

    init {
        session.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLoadRequest(session: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> =
                GeckoResult.fromValue(if (current() && linkPreviewWebUrl(request.uri)) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
            override fun onNewSession(session: GeckoSession, uri: String): GeckoResult<GeckoSession>? = null
            override fun onLoadError(session: GeckoSession, uri: String?, error: WebRequestError): GeckoResult<String>? {
                if (current()) mutablePage.value = mutablePage.value.copy(loading = false, failed = true)
                return null
            }
        }
        session.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onTitleChange(session: GeckoSession, title: String?) {
                if (current()) mutablePage.value = mutablePage.value.copy(title = title.orEmpty())
            }
            override fun onExternalResponse(session: GeckoSession, response: WebResponse) { response.body?.close() }
            override fun onCrash(session: GeckoSession) { if (!closed) invalidated() }
            override fun onKill(session: GeckoSession) { if (!closed) invalidated() }
            override fun onFullScreen(session: GeckoSession, fullScreen: Boolean) { if (fullScreen) session.exitFullScreen() }
        }
        session.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(session: GeckoSession, url: String) {
                if (current()) mutablePage.value = LinkPreviewPage()
            }
            override fun onPageStop(session: GeckoSession, success: Boolean) {
                if (current()) mutablePage.value = mutablePage.value.copy(loading = false, failed = !success)
            }
        }
        session.permissionDelegate = object : GeckoSession.PermissionDelegate {
            override fun onContentPermissionRequest(session: GeckoSession, perm: GeckoSession.PermissionDelegate.ContentPermission): GeckoResult<Int> =
                GeckoResult.fromValue(GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)
            // The native defaults reject Android and capture permissions.
        }
        // Native defaults dismiss prompts, including file/auth/autocomplete, without presenting UI.
        session.promptDelegate = object : GeckoSession.PromptDelegate {}
    }

    internal fun open(runtime: GeckoRuntime) {
        if (!current()) return
        session.open(runtime)
        session.setFocused(false)
        session.loadUri(url)
    }

    internal fun denyBridge(extension: WebExtension) {
        if (closed) return
        session.webExtensionController.setMessageDelegate(extension, object : WebExtension.MessageDelegate {
            override fun onConnect(port: WebExtension.Port) {
                deniedNativeConnections++
                runCatching { port.postMessage(org.json.JSONObject().put("command", "retire")) }
            }
        }, "yab")
    }

    internal fun current(): Boolean {
        if (closed) return false
        if (lease.current()) return true
        invalidated()
        return false
    }

    internal fun consume(): Boolean = !closed && lease.consume()

    override fun close() {
        if (closed) return
        closed = true
        lease.close()
        if (session.isOpen) session.close()
    }

}
